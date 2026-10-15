package main

// Controller owns the connection to one TV and everything the window shows about it. It is also the
// ToolHost for the in-app Claude chat.

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// clientName differs per platform so the TV (which routes some replies per client name) never confuses
// this app with the macOS one on the same network.
var clientName = map[bool]string{true: "Windows Remote", false: "Desktop Remote"}[runtime.GOOS == "windows"]

type Controller struct {
	mu           sync.Mutex
	host, mac    string
	status       string // noTV | connecting | connected | waking | off | failed
	errMsg       string
	info         *TVInfo
	volume       float64
	muted        bool
	apps         []App
	icons        map[string][]byte
	pointer      bool
	recording    []Step // nil = not recording
	lastRecorded time.Time
	shortcuts    []Shortcut
	discovered   []Discovered
	scanning     bool

	channel      *Channel
	generation   int       // bumped per connect: a stale establish must not touch the state
	offUntil     time.Time // after we switch the TV off its network stays up ~25 s; that is not "on"
	retry        *time.Timer
	volumeTimer  *time.Timer
	iconQueue    []string
	iconInFlight string
	iconTimer    *time.Timer

	OnState func(snapshot map[string]any)
	OnIcon  func(path string, png []byte)
	notify  chan struct{}
}

func NewController() *Controller {
	s := loadSettings()
	c := &Controller{host: s.Host, mac: s.Mac, status: "noTV", icons: map[string][]byte{}, shortcuts: loadShortcuts(), notify: make(chan struct{}, 1)}
	go func() { // one emitter goroutine: snapshots reach the UI in order, coalesced
		for range c.notify {
			if c.OnState != nil {
				c.OnState(c.Snapshot())
			}
		}
	}()
	return c
}

func (c *Controller) changed() {
	select {
	case c.notify <- struct{}{}:
	default:
	}
}

func (c *Controller) setStatus(status, msg string) { // mu held
	c.status, c.errMsg = status, msg
	c.changed()
}

func (c *Controller) Start() {
	c.mu.Lock()
	host := c.host
	c.mu.Unlock()
	if host != "" {
		c.Connect()
	} else {
		go c.Scan(true)
	}
}

func (c *Controller) connectedLocked() bool {
	return c.status == "connected" && c.channel != nil && c.channel.IsConnected()
}

func (c *Controller) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectedLocked()
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func (c *Controller) Snapshot() map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	var recording any
	if c.recording != nil {
		recording = len(c.recording)
	}
	return map[string]any{
		"status": c.status, "error": c.errMsg, "host": c.host, "mac": c.mac, "info": c.info,
		"volume": c.volume, "muted": c.muted, "apps": nonNil(c.apps), "pointerAvailable": c.pointer,
		"recording": recording, "shortcuts": nonNil(c.shortcuts), "discovered": nonNil(c.discovered),
		"scanning": c.scanning, "clientName": clientName,
	}
}

// ---- connection ---------------------------------------------------------------------------------

func (c *Controller) Connect() {
	c.mu.Lock()
	stop(c.retry)
	if c.host == "" {
		c.setStatus("noTV", "")
		c.mu.Unlock()
		return
	}
	c.generation++
	gen := c.generation
	c.mu.Unlock()
	go c.establish(gen)
}

// Refresh runs when the window is shown, so a TV switched on with its own remote shows up at once.
func (c *Controller) Refresh() {
	c.mu.Lock()
	connected, busy := c.connectedLocked(), c.status == "waking" || c.status == "connecting"
	off := c.offUntil.After(time.Now())
	c.mu.Unlock()
	if connected {
		go c.RefreshVolume()
	} else if !busy && !off {
		c.Connect()
	}
}

func stop(t *time.Timer) {
	if t != nil {
		t.Stop()
	}
}

func (c *Controller) establish(gen int) {
	c.mu.Lock()
	if c.status == "noTV" || c.status == "connected" { // background retries while off stay quiet
		c.setStatus("connecting", "")
	}
	host := c.host
	c.mu.Unlock()
	live := func() bool { return gen == c.generation } // mu held

	info, err := tvInfo(host, 2500*time.Millisecond)
	if err != nil {
		c.connectFailed(gen, nil, err)
		return
	}
	c.mu.Lock()
	if !live() {
		c.mu.Unlock()
		return
	}
	c.info = info
	needMac := c.mac == ""
	c.mu.Unlock()
	if needMac {
		mac := info.WifiMac
		if mac == "" {
			mac = macAddress(host)
		}
		if mac != "" {
			c.mu.Lock()
			c.mac = mac
			c.mu.Unlock()
			updateSettings(func(s *Settings) { s.Mac = mac })
		}
	}

	token := loadSettings().Tokens[host]
	transport := "plain"
	if info.TokenAuthSupport {
		transport = "secure"
	}
	ch := &Channel{Host: host, Transport: transport, AppName: clientName, Token: token}
	ch.OnApps = func(apps []App) {
		c.mu.Lock()
		if ch != c.channel {
			c.mu.Unlock()
			return
		}
		c.apps = apps // already in the user's Smart Hub order
		c.changed()
		c.mu.Unlock()
		c.loadIcons(apps)
	}
	ch.OnIcon = func(path string, png []byte) {
		c.storeIcon(path, png, true)
		c.mu.Lock()
		if c.iconInFlight == path {
			c.iconInFlight = ""
		}
		c.mu.Unlock()
		c.requestNextIcon()
	}
	ch.OnEvent = func(name string) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if ch == c.channel && (name == "ms.remote.touchEnable" || name == "ms.remote.touchDisable") {
			c.pointer = name == "ms.remote.touchEnable"
			c.changed()
		}
	}
	ch.OnDisconnected = func(error) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if ch != c.channel {
			return
		}
		c.channel, c.pointer, c.iconInFlight = nil, false, ""
		if c.status == "connected" {
			c.setStatus("connecting", "")
			c.scheduleRetry(2 * time.Second)
		}
	}

	c.mu.Lock()
	if !live() {
		c.mu.Unlock()
		return
	}
	old := c.channel
	c.channel = ch
	c.mu.Unlock()
	if old != nil {
		old.Close()
	}

	newToken, err := ch.Connect()
	if err != nil {
		c.connectFailed(gen, ch, err)
		return
	}
	c.mu.Lock()
	if !live() || ch != c.channel {
		c.mu.Unlock()
		ch.Close()
		return
	}
	c.setStatus("connected", "")
	c.mu.Unlock()
	if newToken != "" && newToken != token {
		updateSettings(func(s *Settings) {
			if s.Tokens == nil {
				s.Tokens = map[string]string{}
			}
			s.Tokens[host] = newToken
		})
	}
	ch.RequestApps()
	c.RefreshVolume()
}

func (c *Controller) connectFailed(gen int, ch *Channel, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.generation {
		return
	}
	if ch != nil && c.channel == ch {
		c.channel = nil
	}
	var ce *channelError
	if errors.As(err, &ce) {
		c.setStatus("failed", ce.msg)
		c.scheduleRetry(15 * time.Second)
	} else { // no answer on :8001 – the TV is off (or not on this network)
		c.setStatus("off", "")
		c.scheduleRetry(8 * time.Second)
	}
}

func (c *Controller) scheduleRetry(d time.Duration) { // mu held
	stop(c.retry)
	c.retry = time.AfterFunc(d, func() {
		c.mu.Lock()
		if wait := time.Until(c.offUntil); wait > 0 {
			c.scheduleRetry(wait + time.Second)
			c.mu.Unlock()
			return
		}
		c.mu.Unlock()
		c.Connect()
	})
}

// ---- power --------------------------------------------------------------------------------------

func (c *Controller) TogglePower() {
	if c.IsConnected() {
		c.turnOff()
	} else {
		c.turnOn()
	}
}

func (c *Controller) turnOff() {
	c.mu.Lock()
	ch := c.channel
	c.offUntil = time.Now().Add(35 * time.Second)
	c.channel, c.pointer = nil, false
	c.generation++
	c.setStatus("off", "")
	c.scheduleRetry(36 * time.Second)
	c.mu.Unlock()
	if ch != nil {
		ch.SendKey("KEY_POWER")
		// Keep the socket open briefly: the TV drops a command if the client hangs up right away.
		time.AfterFunc(1200*time.Millisecond, ch.Close)
	}
}

func (c *Controller) turnOn() {
	c.mu.Lock()
	shuttingDown := c.offUntil.After(time.Now())
	c.offUntil = time.Time{}
	stop(c.retry)
	c.generation++
	gen := c.generation
	c.setStatus("waking", "")
	host, mac := c.host, c.mac
	c.mu.Unlock()
	live := func() bool { c.mu.Lock(); defer c.mu.Unlock(); return gen == c.generation }
	reachable := func() bool { _, err := tvInfo(host, 1500*time.Millisecond); return err == nil }
	go func() {
		// Still in its shutdown window the TV ignores Wake-on-LAN but accepts the power key.
		if shuttingDown && reachable() {
			c.establish(gen)
			c.mu.Lock()
			ch, ok := c.channel, gen == c.generation && c.connectedLocked()
			c.mu.Unlock()
			if ok {
				ch.SendKey("KEY_POWER")
			}
			return
		}
		for i := 0; i < 20 && live(); i++ {
			if mac != "" {
				_, _ = wake(mac, host)
			}
			if reachable() {
				break
			}
			time.Sleep(time.Second)
		}
		if live() {
			c.establish(gen)
		}
	}()
}

// ---- remote -------------------------------------------------------------------------------------

func (c *Controller) readyLocked() *Channel {
	if c.connectedLocked() {
		return c.channel
	}
	return nil
}

// Send takes a key name (home, volumeUp, 5) or a raw KEY_* code.
func (c *Controller) Send(name string) {
	c.mu.Lock()
	ch := c.readyLocked()
	if ch == nil {
		c.mu.Unlock()
		return
	}
	c.record("key", name)
	vol := c.volume
	c.mu.Unlock()
	switch name {
	case "volumeUp", "volumeDown":
		// Step the absolute UPnP volume: the TV drops repeat volume keys while its volume bar animates in,
		// so quick clicks got lost. It still shows the volume bar.
		step := 1.0
		if name == "volumeDown" {
			step = -1
		}
		c.SetVolume(math.Min(100, math.Max(0, math.Round(vol)+step)))
	default:
		ch.SendKey(keyCode(name))
		if name == "mute" {
			go c.refreshVolumeSoon()
		}
	}
}

func (c *Controller) SendText(text string) {
	c.mu.Lock()
	ch := c.readyLocked()
	if ch != nil && text != "" {
		c.record("text", text)
	}
	c.mu.Unlock()
	if ch != nil && text != "" {
		ch.SendText(text)
	}
}

func (c *Controller) MovePointer(dx, dy float64) {
	c.mu.Lock()
	ch := c.readyLocked()
	c.mu.Unlock()
	if ch != nil {
		ch.MoveMouse(int(math.Round(dx)), int(math.Round(dy)))
	}
}

func (c *Controller) Click() {
	c.mu.Lock()
	ch := c.readyLocked()
	c.mu.Unlock()
	if ch != nil {
		ch.Click()
	}
}

func (c *Controller) Launch(appID string) {
	c.mu.Lock()
	ch := c.readyLocked()
	var app *App
	for i := range c.apps {
		if c.apps[i].ID == appID {
			app = &c.apps[i]
		}
	}
	if ch == nil || app == nil {
		c.mu.Unlock()
		return
	}
	c.record("launch_app", app.ID)
	id, typ := app.ID, app.AppType
	c.mu.Unlock()
	ch.LaunchApp(id, typ, "")
}

// ---- volume -------------------------------------------------------------------------------------

func (c *Controller) SetVolume(v float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.volume = v
	c.changed()
	stop(c.volumeTimer)
	host := c.host
	c.volumeTimer = time.AfterFunc(120*time.Millisecond, func() { _ = setVolume(host, int(math.Round(v))) })
}

func (c *Controller) RefreshVolume() {
	c.mu.Lock()
	host := c.host
	c.mu.Unlock()
	if host == "" {
		return
	}
	v, verr := getVolume(host)
	muted, merr := getMute(host)
	c.mu.Lock()
	if verr == nil {
		c.volume = float64(v)
	}
	if merr == nil {
		c.muted = muted
	}
	c.changed()
	c.mu.Unlock()
}

// The renderer's volume lags the key by up to ~1 s, so read it twice.
func (c *Controller) refreshVolumeSoon() {
	time.Sleep(500 * time.Millisecond)
	c.RefreshVolume()
	time.Sleep(800 * time.Millisecond)
	c.RefreshVolume()
}

// ---- app icons ----------------------------------------------------------------------------------

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]`)

func iconFile(path string) string {
	return filepath.Join(dataDir(), "icons", unsafeName.ReplaceAllString(path, "_"))
}

func (c *Controller) Icons() map[string][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string][]byte, len(c.icons))
	for k, v := range c.icons {
		out[k] = v
	}
	return out
}

func (c *Controller) storeIcon(path string, png []byte, persist bool) {
	c.mu.Lock()
	c.icons[path] = png
	c.mu.Unlock()
	if c.OnIcon != nil {
		c.OnIcon(path, png)
	}
	if persist {
		_ = os.MkdirAll(filepath.Dir(iconFile(path)), 0o755)
		_ = os.WriteFile(iconFile(path), png, 0o644)
	}
}

func (c *Controller) loadIcons(apps []App) {
	for _, a := range apps {
		if a.Icon == "" {
			continue
		}
		c.mu.Lock()
		_, have := c.icons[a.Icon]
		c.mu.Unlock()
		if have {
			continue
		}
		if png, err := os.ReadFile(iconFile(a.Icon)); err == nil {
			c.storeIcon(a.Icon, png, false)
			continue
		}
		c.mu.Lock()
		queued := false
		for _, q := range c.iconQueue {
			queued = queued || q == a.Icon
		}
		if !queued {
			c.iconQueue = append(c.iconQueue, a.Icon)
		}
		c.mu.Unlock()
	}
	c.requestNextIcon()
}

// requestNextIcon keeps one request in flight: during a burst of icon requests the TV drops remote keys.
func (c *Controller) requestNextIcon() {
	c.mu.Lock()
	ch := c.channel
	if c.iconInFlight != "" || len(c.iconQueue) == 0 || ch == nil || !ch.IsConnected() {
		c.mu.Unlock()
		return
	}
	path := c.iconQueue[0]
	c.iconQueue = c.iconQueue[1:]
	c.iconInFlight = path
	stop(c.iconTimer)
	c.iconTimer = time.AfterFunc(3*time.Second, func() {
		c.mu.Lock()
		timedOut := c.iconInFlight == path
		if timedOut {
			c.iconInFlight = ""
		}
		c.mu.Unlock()
		if timedOut {
			c.requestNextIcon()
		}
	})
	c.mu.Unlock()
	ch.RequestIcon(path)
}

// ---- shortcut recording -------------------------------------------------------------------------

func (c *Controller) StartRecording() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recording, c.lastRecorded = []Step{}, time.Time{}
	c.changed()
}

// StopRecording saves the steps under name unless it is empty.
func (c *Controller) StopRecording(name string) {
	c.mu.Lock()
	steps := c.recording
	c.recording = nil
	c.mu.Unlock()
	if name = strings.TrimSpace(name); len(steps) > 0 && name != "" {
		_ = saveShortcut(Shortcut{name, steps})
	}
	c.ReloadShortcuts()
}

func (c *Controller) ReloadShortcuts() {
	all := loadShortcuts()
	c.mu.Lock()
	c.shortcuts = all
	c.changed()
	c.mu.Unlock()
}

func (c *Controller) DeleteShortcut(name string) {
	_ = deleteShortcut(name)
	c.ReloadShortcuts()
}

func (c *Controller) RunShortcut(name string) {
	if sc := findShortcut(name); sc != nil {
		go func() { _ = runShortcut(*sc, c) }()
	}
}

// record turns pauses longer than 1.5 s into wait steps, so an app gets the time it needed to open on replay.
func (c *Controller) record(action, value string) { // mu held
	if c.recording == nil {
		return
	}
	now := time.Now()
	if !c.lastRecorded.IsZero() {
		if gap := now.Sub(c.lastRecorded).Seconds(); gap >= 1.5 {
			c.recording = append(c.recording, Step{"wait", strconv.FormatFloat(math.Round(math.Min(gap, 10)*2)/2, 'f', -1, 64)})
		}
	}
	c.recording = append(c.recording, Step{action, value})
	c.lastRecorded = now
	c.changed()
}

// ---- discovery / settings -----------------------------------------------------------------------

func (c *Controller) Scan(autoSelect bool) {
	c.mu.Lock()
	if c.scanning {
		c.mu.Unlock()
		return
	}
	c.scanning = true
	c.changed()
	c.mu.Unlock()
	found := scan()
	c.mu.Lock()
	c.discovered, c.scanning = found, false
	c.changed()
	pick := autoSelect && c.host == "" && len(found) == 1
	c.mu.Unlock()
	if pick {
		c.Select(found[0].Host)
	}
}

func (c *Controller) Select(host string) {
	mac := ""
	c.mu.Lock()
	for _, d := range c.discovered {
		if d.Host == host {
			mac = d.WifiMac
		}
	}
	c.mu.Unlock()
	c.SetHost(host, mac)
}

func (c *Controller) SetHost(host, mac string) {
	host = strings.TrimSpace(host)
	c.mu.Lock()
	if host == "" || host == c.host {
		c.mu.Unlock()
		return
	}
	c.host, c.mac, c.apps, c.info = host, mac, nil, nil
	c.mu.Unlock()
	updateSettings(func(s *Settings) { s.Host, s.Mac = host, mac })
	c.Connect()
}

func (c *Controller) SetMac(mac string) {
	mac = strings.TrimSpace(mac)
	c.mu.Lock()
	c.mac = mac
	c.changed()
	c.mu.Unlock()
	updateSettings(func(s *Settings) { s.Mac = mac })
}

func (c *Controller) Shutdown() {
	c.mu.Lock()
	c.generation++
	stop(c.retry)
	stop(c.volumeTimer)
	stop(c.iconTimer)
	ch := c.channel
	c.channel = nil
	c.mu.Unlock()
	if ch != nil {
		ch.Close()
	}
}

// ---- ToolHost -----------------------------------------------------------------------------------

func (c *Controller) ResolvedHost() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.host == "" {
		return "", errors.New("No TV selected yet – pick one in TV Remote's settings.")
	}
	return c.host, nil
}

func (c *Controller) ReadyChannel() (*Channel, error) {
	c.mu.Lock()
	ch := c.readyLocked()
	c.mu.Unlock()
	if ch != nil {
		return ch, nil
	}
	c.Connect()
	for range 40 {
		time.Sleep(250 * time.Millisecond)
		c.mu.Lock()
		ch = c.readyLocked()
		c.mu.Unlock()
		if ch != nil {
			return ch, nil
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.status == "off" {
		return nil, errors.New("The TV is off. Turn it on first.")
	}
	return nil, fmt.Errorf("Can't reach the TV at %s.", c.host)
}

func (c *Controller) InstalledApps() ([]App, error) {
	ch, err := c.ReadyChannel()
	if err != nil {
		return nil, err
	}
	for i := 0; i < 17; i++ {
		c.mu.Lock()
		apps := c.apps
		c.mu.Unlock()
		if len(apps) > 0 {
			return apps, nil
		}
		if i == 0 {
			ch.RequestApps()
		}
		time.Sleep(250 * time.Millisecond)
	}
	return nil, errors.New("The TV did not send its app list.")
}

func (c *Controller) SetPower(on bool) (string, error) {
	connected := c.IsConnected()
	if on {
		if connected {
			return "The TV is already on.", nil
		}
		c.TogglePower()
		for range 180 {
			time.Sleep(250 * time.Millisecond)
			if c.IsConnected() {
				return "The TV is on.", nil
			}
		}
		return "", errors.New("The TV didn't wake up.")
	}
	if !connected {
		return "The TV is already off.", nil
	}
	c.TogglePower()
	return "The TV is switching off.", nil
}
