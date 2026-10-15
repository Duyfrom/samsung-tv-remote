package main

// Samsung Tizen (2016+) TV protocol: MSF websocket remote channel, REST device/app API, UPnP volume,
// /24 discovery, Wake-on-LAN, DIAL (YouTube) and YouTube's public channel feed.
// Behaviour learned on a UA49K5500 is noted where it matters.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// ---- keys ------------------------------------------------------------------------------------

// Remote key codes recovered with REA from Samsung's PC Smart View 2 (TvKeyCode); any KEY_* works too.
var keys = map[string]string{
	"power": "KEY_POWER", "powerOff": "KEY_POWEROFF", "source": "KEY_SOURCE", "hdmi": "KEY_HDMI",
	"hdmi1": "KEY_HDMI1", "hdmi2": "KEY_HDMI2", "hdmi3": "KEY_HDMI3", "tv": "KEY_TV",
	"home": "KEY_HOME", "menu": "KEY_MENU", "up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT",
	"enter": "KEY_ENTER", "back": "KEY_RETURN", "exit": "KEY_EXIT", "info": "KEY_INFO", "tools": "KEY_TOOLS",
	"guide": "KEY_GUIDE", "search": "KEY_SEARCH", "eManual": "KEY_EMANUAL",
	"volumeUp": "KEY_VOLUP", "volumeDown": "KEY_VOLDOWN", "mute": "KEY_MUTE",
	"channelUp": "KEY_CHUP", "channelDown": "KEY_CHDOWN", "previousChannel": "KEY_PRECH", "channelList": "KEY_CH_LIST",
	"num0": "KEY_0", "num1": "KEY_1", "num2": "KEY_2", "num3": "KEY_3", "num4": "KEY_4",
	"num5": "KEY_5", "num6": "KEY_6", "num7": "KEY_7", "num8": "KEY_8", "num9": "KEY_9", "minus": "KEY_PLUS100",
	"red": "KEY_RED", "green": "KEY_GREEN", "yellow": "KEY_YELLOW", "blue": "KEY_CYAN",
	"play": "KEY_PLAY", "pause": "KEY_PAUSE", "stop": "KEY_STOP", "rewind": "KEY_REWIND",
	"fastForward": "KEY_FF", "record": "KEY_REC",
	"pictureMode": "KEY_PMODE", "soundMode": "KEY_SOUND_MODE", "aspect": "KEY_ASPECT",
	"subtitle": "KEY_SUB_TITLE", "caption": "KEY_CAPTION", "sleep": "KEY_SLEEP",
}

var keyAliases = map[string]string{
	"ok": "enter", "select": "enter", "return": "back",
	"vol+": "volumeUp", "volume_up": "volumeUp", "vol-": "volumeDown", "volume_down": "volumeDown",
}

// keyCode maps a friendly name (volumeUp, home, ok, 5) or a raw code (KEY_VOLUP) to a KEY_* code.
func keyCode(name string) string {
	s := strings.TrimSpace(name)
	if strings.HasPrefix(strings.ToUpper(s), "KEY_") {
		return strings.ToUpper(s)
	}
	for k, v := range keys {
		if strings.EqualFold(k, s) {
			return v
		}
	}
	if a, ok := keyAliases[strings.ToLower(s)]; ok {
		return keys[a]
	}
	return "KEY_" + strings.ToUpper(s)
}

// ---- HTTP ------------------------------------------------------------------------------------

// One client for everything; no proxy (the TV is on the LAN, and the old Electron build ignored proxies too).
var httpClient = &http.Client{Transport: &http.Transport{Proxy: nil, MaxIdleConnsPerHost: 8, IdleConnTimeout: 30 * time.Second}}

type httpStatusError int

func (e httpStatusError) Error() string { return fmt.Sprintf("TV answered HTTP %d.", int(e)) }

// addr adds the TV's default port unless host already carries one (the tests run a fake TV on one port).
func addr(host string, port int) string {
	if strings.Contains(host, ":") {
		return host
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

func request(method, url string, body io.Reader, header map[string]string, timeout time.Duration) ([]byte, *http.Response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, nil, err
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	res, err := httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	return data, res, err
}

func getJSON(url string, timeout time.Duration, v any) error {
	data, res, err := request("GET", url, nil, nil, timeout)
	if err != nil {
		return err
	}
	if res.StatusCode/100 != 2 {
		return httpStatusError(res.StatusCode)
	}
	return json.Unmarshal(data, v)
}

// ---- REST (/api/v2/) ---------------------------------------------------------------------------

type TVInfo struct {
	Name             string `json:"name"`
	Type             string `json:"type"` // "Samsung SmartTV" for real TVs
	ModelName        string `json:"modelName"`
	Model            string `json:"model"` // platform code, e.g. 16_HAWKM_FHD
	WifiMac          string `json:"wifiMac"`
	IP               string `json:"ip"`
	NetworkType      string `json:"networkType"`
	Resolution       string `json:"resolution"`
	OS               string `json:"os"`
	TokenAuthSupport bool   `json:"tokenAuthSupport"` // true: wss :8002 with a token
	PowerState       string `json:"powerState"`       // 2017+ firmwares only
}

func tvInfo(host string, timeout time.Duration) (*TVInfo, error) {
	var j struct {
		Name   string            `json:"name"`
		Type   string            `json:"type"`
		Device map[string]string `json:"device"`
	}
	if err := getJSON("http://"+addr(host, 8001)+"/api/v2/", timeout, &j); err != nil {
		return nil, err
	}
	d := j.Device
	name := d["name"]
	if name == "" {
		name = j.Name
	}
	if name == "" {
		name = "Samsung TV"
	}
	typ := d["type"]
	if typ == "" {
		typ = j.Type
	}
	return &TVInfo{
		Name: strings.Replace(name, "[TV] ", "", 1), Type: typ, ModelName: d["modelName"], Model: d["model"],
		WifiMac: d["wifiMac"], IP: d["ip"], NetworkType: d["networkType"], Resolution: d["resolution"], OS: d["OS"],
		TokenAuthSupport: d["TokenAuthSupport"] == "true", PowerState: d["PowerState"],
	}, nil
}

type AppStatus struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Running bool   `json:"running"`
	Visible bool   `json:"visible"`
}

// appStatus returns nil (no error) when the app isn't installed.
func appStatus(host, id string, timeout time.Duration) (*AppStatus, error) {
	var s AppStatus
	err := getJSON("http://"+addr(host, 8001)+"/api/v2/applications/"+url.PathEscape(id), timeout, &s)
	var status httpStatusError
	if errors.As(err, &status) && status == 404 {
		return nil, nil
	}
	return &s, err
}

// ---- UPnP RenderingControl (:9197) ------------------------------------------------------------
// The remote channel only has relative volume keys; this gives absolute volume and mute state.

const renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

func xmlValue(tag, xml string) string {
	m := regexp.MustCompile(`<` + tag + `>\s*([^<]*?)\s*</` + tag + `>`).FindStringSubmatch(xml)
	if m == nil {
		return ""
	}
	return m[1]
}

func upnp(host, action, args string) (string, error) {
	body := `<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">` +
		`<s:Body><u:` + action + ` xmlns:u="` + renderingControl + `"><InstanceID>0</InstanceID><Channel>Master</Channel>` + args + `</u:` + action + `></s:Body></s:Envelope>`
	data, res, err := request("POST", "http://"+addr(host, 9197)+"/upnp/control/RenderingControl1", strings.NewReader(body),
		map[string]string{"Content-Type": `text/xml; charset="utf-8"`, "SOAPACTION": `"` + renderingControl + `#` + action + `"`}, 3*time.Second)
	if err != nil {
		return "", err
	}
	if res.StatusCode/100 != 2 {
		return "", httpStatusError(res.StatusCode)
	}
	return string(data), nil
}

func getVolume(host string) (int, error) {
	xml, err := upnp(host, "GetVolume", "")
	if err != nil {
		return 0, err
	}
	v, err := strconv.Atoi(xmlValue("CurrentVolume", xml))
	if err != nil {
		return 0, errors.New("unexpected answer from the TV")
	}
	return v, nil
}

func setVolume(host string, level int) error {
	_, err := upnp(host, "SetVolume", fmt.Sprintf("<DesiredVolume>%d</DesiredVolume>", max(0, min(100, level))))
	return err
}

func getMute(host string) (bool, error) {
	xml, err := upnp(host, "GetMute", "")
	return xmlValue("CurrentMute", xml) == "1", err
}

func setMute(host string, muted bool) error {
	v := 0
	if muted {
		v = 1
	}
	_, err := upnp(host, "SetMute", fmt.Sprintf("<DesiredMute>%d</DesiredMute>", v))
	return err
}

// ---- remote channel (websocket) ---------------------------------------------------------------

type App struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	AppType int    `json:"appType"` // 2 = web app (DEEP_LINK), 4 = native (NATIVE_LAUNCH)
	Icon    string `json:"icon"`
}

type channelError struct{ kind, msg string } // kind: unauthorized | timeout | insecure | closed

func (e *channelError) Error() string { return e.msg }

// isLocalAddress: RFC 1918, link-local and loopback IPv4 – the only hosts we talk unverified TLS to.
// net.ParseIP only accepts canonical dotted quads (no leading zeros, hex or short forms), so the address
// approved here is the address that gets connected to.
func isLocalAddress(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil || strings.Contains(host, ":") {
		return false
	}
	return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()
}

// Channel is the Samsung Multiscreen remote-control websocket:
//
//	ws://<tv>:8001/api/v2/channels/samsung.remote.control?name=<base64 app name>
//	wss://<tv>:8002/...&token=<token>   (token TVs, self-signed certificate)
//
// The TV drops a command if the client hangs up within ~0.3 s of sending it, and drops keys during a burst
// of icon requests – callers keep the socket open and fetch icons one at a time.
type Channel struct {
	Host, Transport, AppName, Token string

	OnApps         func([]App)
	OnIcon         func(path string, png []byte)
	OnEvent        func(name string)
	OnDisconnected func(error)

	conn      *websocket.Conn
	cancel    context.CancelFunc
	connected atomic.Bool
	closed    atomic.Bool
	settle    chan error
	failOnce  sync.Once
}

func (c *Channel) URL() string {
	secure := c.Transport == "secure"
	scheme, port := "ws", 8001
	if secure {
		scheme, port = "wss", 8002
	}
	u := fmt.Sprintf("%s://%s/api/v2/channels/samsung.remote.control?name=%s", scheme, addr(c.Host, port),
		url.QueryEscape(base64.StdEncoding.EncodeToString([]byte(c.AppName))))
	if secure && c.Token != "" { // a credential: only ever sent over TLS
		u += "&token=" + url.QueryEscape(c.Token)
	}
	return u
}

func (c *Channel) IsConnected() bool { return c.connected.Load() }

// Connect opens the socket and waits for ms.channel.connect (up to 35 s: the first connection waits for
// someone to press Allow on the TV). Returns the (possibly new) token.
func (c *Channel) Connect() (string, error) {
	opts := &websocket.DialOptions{CompressionMode: websocket.CompressionDisabled}
	if c.Transport == "secure" {
		// Samsung TVs only present self-signed certificates on :8002, so the connection is encrypted but not
		// authenticated – acceptable (and the token safe to send) only on the local network.
		if !isLocalAddress(c.Host) {
			return "", &channelError{"insecure", "Refusing an unverified TLS connection to a non-local address. Use the TV's LAN IP."}
		}
		opts.HTTPClient = &http.Client{Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	dialCtx, dialCancel := context.WithTimeout(ctx, 10*time.Second)
	conn, _, err := websocket.Dial(dialCtx, c.URL(), opts)
	dialCancel()
	if err != nil {
		cancel()
		return "", err
	}
	conn.SetReadLimit(16 << 20) // icons arrive as ~130 KB base64 messages
	c.conn = conn
	c.settle = make(chan error, 1)
	go c.readLoop(ctx)
	select {
	case err := <-c.settle:
		if err != nil {
			c.Close()
			return "", err
		}
		return c.Token, nil
	case <-time.After(35 * time.Second):
		c.Close()
		return "", &channelError{"timeout", "No answer from the TV. Accept the Allow prompt on the TV screen."}
	}
}

// Close hangs up without firing OnDisconnected.
func (c *Channel) Close() {
	c.closed.Store(true)
	c.connected.Store(false)
	if c.cancel != nil {
		c.cancel()
	}
	if c.conn != nil {
		_ = c.conn.CloseNow()
	}
}

func (c *Channel) readLoop(ctx context.Context) {
	for {
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			c.fail(err)
			return
		}
		c.handle(data)
	}
}

func (c *Channel) settleWith(err error) {
	select {
	case c.settle <- err:
	default:
	}
}

func (c *Channel) fail(err error) {
	wasConnected := c.connected.Swap(false)
	c.settleWith(err)
	if c.closed.Load() || !wasConnected {
		return
	}
	c.failOnce.Do(func() {
		if c.OnDisconnected != nil {
			c.OnDisconnected(err)
		}
	})
}

func (c *Channel) handle(data []byte) {
	var msg struct {
		Event string          `json:"event"`
		Data  json.RawMessage `json:"data"`
	}
	if json.Unmarshal(data, &msg) != nil {
		return
	}
	switch msg.Event {
	case "ms.channel.connect":
		var d struct{ Token string }
		_ = json.Unmarshal(msg.Data, &d)
		if d.Token != "" {
			c.Token = d.Token
		}
		c.connected.Store(true)
		go c.pingLoop()
		c.settleWith(nil)
	case "ms.channel.unauthorized":
		c.settleWith(&channelError{"unauthorized", "The TV refused the connection. Allow this device in TV Settings › General › External Device Manager › Device Connection Manager."})
	case "ms.channel.timeOut":
		c.settleWith(&channelError{"timeout", "No answer from the TV. Accept the Allow prompt on the TV screen."})
	case "ed.installedApp.get":
		var d struct {
			Data []struct {
				AppID   string `json:"appId"`
				Name    string `json:"name"`
				AppType *int   `json:"app_type"`
				Icon    string `json:"icon"`
			} `json:"data"`
		}
		_ = json.Unmarshal(msg.Data, &d)
		apps := []App{}
		for _, a := range d.Data {
			if a.AppID == "" {
				continue
			}
			app := App{ID: a.AppID, Name: a.Name, AppType: 2, Icon: a.Icon}
			if app.Name == "" {
				app.Name = a.AppID
			}
			if a.AppType != nil {
				app.AppType = *a.AppType
			}
			apps = append(apps, app)
		}
		if c.OnApps != nil {
			c.OnApps(apps)
		}
	case "ed.apps.icon":
		var d struct{ IconPath, ImageBase64 string }
		_ = json.Unmarshal(msg.Data, &d)
		if png, err := base64.StdEncoding.DecodeString(d.ImageBase64); err == nil && d.IconPath != "" && c.OnIcon != nil {
			c.OnIcon(d.IconPath, png)
		}
	default:
		if msg.Event != "" && c.OnEvent != nil {
			c.OnEvent(msg.Event)
		}
	}
}

func (c *Channel) pingLoop() {
	for c.connected.Load() {
		time.Sleep(20 * time.Second)
		if !c.connected.Load() {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := c.conn.Ping(ctx)
		cancel()
		if err != nil {
			c.fail(err)
			return
		}
	}
}

func (c *Channel) send(v any) {
	if !c.connected.Load() {
		return
	}
	data, _ := json.Marshal(v)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.conn.Write(ctx, websocket.MessageText, data); err != nil {
		c.fail(err)
	}
}

type m = map[string]any

func (c *Channel) SendKey(code string) {
	c.send(m{"method": "ms.remote.control", "params": m{"Cmd": "Click", "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"}})
}

// SendText types into the focused on-screen keyboard.
func (c *Channel) SendText(text string) {
	c.send(m{"method": "ms.remote.control", "params": m{"Cmd": base64.StdEncoding.EncodeToString([]byte(text)), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"}})
}

// MoveMouse moves the pointer (Web Browser and apps that show a cursor).
func (c *Channel) MoveMouse(dx, dy int) {
	c.send(m{"method": "ms.remote.control", "params": m{"Cmd": "Move", "Position": m{"x": dx, "y": dy, "Time": strconv.FormatInt(time.Now().UnixMilli(), 10)}, "TypeOfRemote": "ProcessMouseDevice"}})
}

func (c *Channel) Click() {
	c.send(m{"method": "ms.remote.control", "params": m{"Cmd": "LeftClick", "TypeOfRemote": "ProcessMouseDevice"}})
}

func (c *Channel) RequestApps() {
	c.send(m{"method": "ms.channel.emit", "params": m{"event": "ed.installedApp.get", "to": "host"}})
}

// RequestIcon is answered through OnIcon.
func (c *Channel) RequestIcon(path string) {
	c.send(m{"method": "ms.channel.emit", "params": m{"event": "ed.apps.icon", "to": "host", "data": m{"iconPath": path}}})
}

// LaunchApp always goes over the socket: the REST launch says "ok" for native apps without opening them.
func (c *Channel) LaunchApp(id string, appType int, metaTag string) {
	action := "NATIVE_LAUNCH"
	if appType == 2 {
		action = "DEEP_LINK"
	}
	c.send(m{"method": "ms.channel.emit", "params": m{"event": "ed.apps.launch", "to": "host", "data": m{"appId": id, "action_type": action, "metaTag": metaTag}}})
}

// OpenURL opens a page in the Web Browser, which takes the URL as launch data.
func (c *Channel) OpenURL(u string) { c.LaunchApp("org.tizen.browser", 4, u) }

// ---- discovery ---------------------------------------------------------------------------------

type Discovered struct {
	Host      string `json:"host"`
	Name      string `json:"name"`
	ModelName string `json:"modelName"`
	WifiMac   string `json:"wifiMac"`
}

// localIPv4 lists the active, non-loopback, non-link-local IPv4 addresses with their masks.
func localIPv4() []*net.IPNet {
	var out []*net.IPNet
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLinkLocalUnicast() {
				out = append(out, &net.IPNet{IP: n.IP.To4(), Mask: n.Mask})
			}
		}
	}
	return out
}

func localSubnetHosts() []string {
	seen := map[string]bool{}
	var hosts []string
	for _, n := range localIPv4() {
		for i := 1; i <= 254; i++ {
			ip := net.IPv4(n.IP[0], n.IP[1], n.IP[2], byte(i)).String()
			if ip != n.IP.String() && !seen[ip] {
				seen[ip] = true
				hosts = append(hosts, ip)
			}
		}
	}
	return hosts
}

// scan asks every address on the local /24 for the device description. Samsung's own clients use SSDP,
// but the TV drops multicast while busy. Port 8001 is a common dev-server port, so only devices that say
// they are Samsung TVs count.
func scan() []Discovered {
	hosts := make(chan string)
	var mu sync.Mutex
	var found []Discovered
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for h := range hosts {
				if i, err := tvInfo(h, 1500*time.Millisecond); err == nil && i.Type == "Samsung SmartTV" {
					mu.Lock()
					found = append(found, Discovered{h, i.Name, i.ModelName, i.WifiMac})
					mu.Unlock()
				}
			}
		}()
	}
	for _, h := range localSubnetHosts() {
		hosts <- h
	}
	close(hosts)
	wg.Wait()
	sort.Slice(found, func(a, b int) bool {
		return bytes.Compare(net.ParseIP(found[a].Host).To16(), net.ParseIP(found[b].Host).To16()) < 0
	})
	return found
}

// ---- Wake-on-LAN -------------------------------------------------------------------------------

func magicPacket(mac string) ([]byte, error) {
	hw, err := net.ParseMAC(strings.ReplaceAll(mac, "-", ":"))
	if err != nil || len(hw) != 6 {
		return nil, fmt.Errorf("%q is not a MAC address", mac)
	}
	p := bytes.Repeat([]byte{0xff}, 6)
	for range 16 {
		p = append(p, hw...)
	}
	return p, nil
}

func broadcastOf(n *net.IPNet) net.IP {
	ip := make(net.IP, 4)
	for i := range 4 {
		ip[i] = n.IP[i] | ^n.Mask[len(n.Mask)-4+i]
	}
	return ip
}

// wake sends the magic packet from every IPv4 adapter (on Windows a plain 255.255.255.255 send leaves
// through one arbitrary adapter), to the limited and directed broadcast and to the TV itself, ports 9 and 7.
func wake(mac, host string) (int, error) {
	packet, err := magicPacket(mac)
	if err != nil {
		return 0, err
	}
	sent := 0
	for _, n := range localIPv4() {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: n.IP}) // Go sets SO_BROADCAST on UDP sockets
		if err != nil {
			continue
		}
		targets := []string{"255.255.255.255", broadcastOf(n).String()}
		if host != "" && !strings.Contains(host, ":") {
			targets = append(targets, host)
		}
		for _, t := range targets {
			for _, port := range []int{9, 7} {
				if _, err := conn.WriteToUDP(packet, &net.UDPAddr{IP: net.ParseIP(t), Port: port}); err == nil {
					sent++
				}
			}
		}
		conn.Close()
	}
	if sent == 0 {
		return 0, errors.New("could not send the wake packet (no usable network adapter)")
	}
	return sent, nil
}

var macRe = regexp.MustCompile(`(?i)\b([0-9a-f]{1,2}(?:[:-][0-9a-f]{1,2}){5})\b`)

// parseArp reads the MAC for host from `arp -a <ip>` (Windows: f8-77-…) or `arp -n` (macOS: 8:0:…).
func parseArp(out, host string) string {
	hostRe := regexp.MustCompile(`(^|[\s(])` + regexp.QuoteMeta(host) + `([\s)]|$)`)
	for _, line := range strings.Split(out, "\n") {
		if host != "" && !hostRe.MatchString(line) {
			continue
		}
		mm := macRe.FindStringSubmatch(line)
		if mm == nil {
			continue
		}
		parts := strings.FieldsFunc(mm[1], func(r rune) bool { return r == ':' || r == '-' })
		for i, p := range parts {
			parts[i] = strings.ToUpper(fmt.Sprintf("%02s", p))
		}
		mac := strings.Join(parts, ":")
		if mac == "FF:FF:FF:FF:FF:FF" || mac == "00:00:00:00:00:00" {
			continue
		}
		return mac
	}
	return ""
}

// macAddress reads the host's MAC from the ARP cache (filled by any recent traffic to it).
func macAddress(host string) string {
	args := []string{"-n", host}
	if runtime.GOOS == "windows" {
		args = []string{"-a", host}
	}
	cmd := exec.Command("arp", args...)
	hideWindow(cmd)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return parseArp(string(out), host)
}

// ---- DIAL + YouTube ------------------------------------------------------------------------------
// DIAL is how phones "cast" to YouTube. On the 2016 Tizen YouTube app it is the only launch path that
// carries a video: the websocket DEEP_LINK launch drops its metaTag.

func dialLaunch(host, app, payload string) error {
	base := "http://" + addr(host, 8080) + "/ws/app/"
	if _, res, err := request("GET", "http://"+addr(host, 7678)+"/nservice/", nil, nil, 2*time.Second); err == nil {
		if v, err := url.Parse(res.Header.Get("Application-URL")); err == nil && v.Hostname() == strings.Split(host, ":")[0] && v.Host != "" {
			base = strings.TrimSuffix(v.String(), "/") + "/"
		}
	}
	_, res, err := request("POST", base+app, strings.NewReader(payload), map[string]string{"Content-Type": "text/plain; charset=utf-8"}, 8*time.Second)
	if err != nil {
		return err
	}
	switch res.StatusCode {
	case 200, 201:
		return nil
	case 404:
		return fmt.Errorf("the TV has no “%s” app", app)
	default:
		return fmt.Errorf("the TV refused the launch (HTTP %d)", res.StatusCode)
	}
}

var videoIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)

// videoID takes a bare id or a watch / youtu.be / shorts / embed / live URL.
func videoID(input string) string {
	s := strings.TrimSpace(input)
	if videoIDRe.MatchString(s) {
		return s
	}
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	u, err := url.Parse(s)
	if err != nil {
		return ""
	}
	if v := u.Query().Get("v"); videoIDRe.MatchString(v) {
		return v
	}
	parts := strings.FieldsFunc(u.Path, func(r rune) bool { return r == '/' })
	if strings.Contains(u.Hostname(), "youtu.be") && len(parts) > 0 && videoIDRe.MatchString(parts[0]) {
		return parts[0]
	}
	for i, p := range parts {
		if (p == "shorts" || p == "embed" || p == "live" || p == "v") && i+1 < len(parts) && videoIDRe.MatchString(parts[i+1]) {
			return parts[i+1]
		}
	}
	return ""
}

type Video struct{ ID, Title, Channel, Published string }

func first(re, text string) string {
	if mm := regexp.MustCompile(re).FindStringSubmatch(text); mm != nil {
		return mm[1]
	}
	return ""
}

// latestFromFeed picks the newest regular upload (Shorts skipped) from a channel's RSS feed.
func latestFromFeed(xml, fallbackChannel string) *Video {
	parts := strings.Split(xml, "<entry>")
	channel := html.UnescapeString(first(`<title>([^<]*)</title>`, parts[0]))
	if channel == "" {
		channel = fallbackChannel
	}
	for _, e := range parts[1:] {
		if strings.Contains(e, "/shorts/") {
			continue
		}
		id := first(`<yt:videoId>([^<]+)</yt:videoId>`, e)
		if id == "" {
			continue
		}
		title := html.UnescapeString(first(`<title>([^<]*)</title>`, e))
		if title == "" {
			title = id
		}
		published := first(`<published>([^<]+)</published>`, e)
		return &Video{id, title, channel, published[:min(10, len(published))]}
	}
	return nil
}

func youtubeGet(u string) ([]byte, int, error) {
	data, res, err := request("GET", u, nil, map[string]string{
		"Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1", "User-Agent": "Mozilla/5.0"}, 10*time.Second)
	if err != nil {
		return nil, 0, err
	}
	return data, res.StatusCode, nil
}

// channelID accepts a channel id (UC…), an @handle, a channel URL, or a plain name used as the handle.
func channelID(query string) (string, error) {
	q := strings.TrimSpace(query)
	if id := first(`(UC[\w-]{22})`, q); id != "" {
		return id, nil
	}
	handle := first(`(@[\w.-]+)`, q)
	if handle == "" {
		simple := strings.Map(func(r rune) rune {
			if r == '_' || r == '.' || r == '-' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || r > 127 {
				return r
			}
			return -1
		}, strings.ToLower(q))
		if simple == "" {
			return "", errors.New("which channel? Give an @handle such as @mkbhd")
		}
		handle = "@" + simple
	}
	data, status, err := youtubeGet("https://www.youtube.com/" + url.PathEscape(handle))
	if err != nil {
		return "", err
	}
	if status != 200 {
		return "", fmt.Errorf("no YouTube channel %s. Give the channel's @handle, its id, or a video URL", handle)
	}
	page := string(data)
	if id := first(`channel_id=(UC[\w-]{22})`, page); id != "" {
		return id, nil
	}
	if id := first(`"externalId":"(UC[\w-]{22})"`, page); id != "" {
		return id, nil
	}
	return "", fmt.Errorf("couldn't read the channel id for %s", handle)
}

func latestVideo(channel string) (*Video, error) {
	id, err := channelID(channel)
	if err != nil {
		return nil, err
	}
	data, status, err := youtubeGet("https://www.youtube.com/feeds/videos.xml?channel_id=" + id)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("YouTube's feed for that channel answered HTTP %d", status)
	}
	if v := latestFromFeed(string(data), channel); v != nil {
		return v, nil
	}
	return nil, fmt.Errorf("no videos found for “%s”", channel)
}
