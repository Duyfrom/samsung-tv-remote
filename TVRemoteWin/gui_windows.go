//go:build windows

package main

// The window: a plain Win32 window hosting the system's Edge WebView2 (no bundled browser), the tray
// icon, and the bridge between ui/bridge.js and core.call. Closing the window hides it to the tray.

import (
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"fyne.io/systray"
	"github.com/jchv/go-webview2/pkg/edge"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed ui
var uiFiles embed.FS

//go:embed build/tray.ico
var trayOn []byte

//go:embed build/tray-off.ico
var trayOff []byte

const (
	className   = "TVRemoteWindow"
	wsStyle     = 0x00CA0000 // WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX: fixed size
	wmDestroy   = 0x0002
	wmMove      = 0x0003
	wmSize      = 0x0005
	wmActivate  = 0x0006
	wmClose     = 0x0010
	wmDpiChange = 0x02E0
	wmShow      = 0x8001 // WM_APP+1: show the window (second instance, tray menu)
	wmToggle    = 0x8002 // tray click
	wmRun       = 0x8003 // run queued UI-thread work
	wmQuit      = 0x8004
	cssWidth    = 340
	webView2ID  = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
)

var (
	user32            = windows.NewLazySystemDLL("user32.dll")
	dwmapi            = windows.NewLazySystemDLL("dwmapi.dll")
	pRegisterClassEx  = user32.NewProc("RegisterClassExW")
	pCreateWindowEx   = user32.NewProc("CreateWindowExW")
	pDefWindowProc    = user32.NewProc("DefWindowProcW")
	pShowWindow       = user32.NewProc("ShowWindow")
	pGetMessage       = user32.NewProc("GetMessageW")
	pTranslateMessage = user32.NewProc("TranslateMessage")
	pDispatchMessage  = user32.NewProc("DispatchMessageW")
	pPostMessage      = user32.NewProc("PostMessageW")
	pPostQuitMessage  = user32.NewProc("PostQuitMessage")
	pDestroyWindow    = user32.NewProc("DestroyWindow")
	pSetWindowPos     = user32.NewProc("SetWindowPos")
	pSetForeground    = user32.NewProc("SetForegroundWindow")
	pGetForeground    = user32.NewProc("GetForegroundWindow")
	pIsWindowVisible  = user32.NewProc("IsWindowVisible")
	pIsIconic         = user32.NewProc("IsIconic")
	pLoadImage        = user32.NewProc("LoadImageW")
	pGetDpiForWindow  = user32.NewProc("GetDpiForWindow")
	pAdjustRectDpi    = user32.NewProc("AdjustWindowRectExForDpi")
	pSetDpiContext    = user32.NewProc("SetProcessDpiAwarenessContext")
	pSystemParams     = user32.NewProc("SystemParametersInfoW")
	pGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	pFindWindow       = user32.NewProc("FindWindowW")
	pMessageBox       = user32.NewProc("MessageBoxW")
	pDwmSetAttribute  = dwmapi.NewProc("DwmSetWindowAttribute")
)

type rect struct{ Left, Top, Right, Bottom int32 }

type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      struct{ X, Y int32 }
}

type wndClassEx struct {
	Size, Style                        uint32
	WndProc                            uintptr
	ClsExtra, WndExtra                 int32
	Instance, Icon, Cursor, Background uintptr
	MenuName, ClassName                *uint16
	IconSm                             uintptr
}

var gui struct {
	hwnd      uintptr
	web       *edge.Chromium
	app       *core
	quitting  bool
	cssHeight float64
	mu        sync.Mutex
	queue     []func()
}

func utf16(s string) *uint16 { p, _ := windows.UTF16PtrFromString(s); return p }

// onUI runs f on the window thread (WebView2 calls must happen there).
func onUI(f func()) {
	gui.mu.Lock()
	gui.queue = append(gui.queue, f)
	gui.mu.Unlock()
	pPostMessage.Call(gui.hwnd, wmRun, 0, 0)
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}

func messageBox(text string) {
	pMessageBox.Call(0, uintptr(unsafe.Pointer(utf16(text))), uintptr(unsafe.Pointer(utf16("TV Remote"))), 0x40) // MB_ICONINFORMATION
}

func runGUI(hidden bool) {
	pSetDpiContext.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4): crisp at any scaling

	// One instance: a second launch just shows the running window.
	if _, err := windows.CreateMutex(nil, false, utf16("TVRemote.SingleInstance")); err == windows.ERROR_ALREADY_EXISTS {
		if h, _, _ := pFindWindow.Call(uintptr(unsafe.Pointer(utf16(className))), 0); h != 0 {
			pPostMessage.Call(h, wmShow, 0, 0)
		}
		return
	}
	if !webView2Installed() {
		messageBox("TV Remote needs the Microsoft Edge WebView2 Runtime, which is part of Windows 11 and most Windows 10 PCs.\n\nYour browser will open Microsoft's download page; install it, then start TV Remote again.")
		_ = windows.ShellExecute(0, utf16("open"), utf16("https://go.microsoft.com/fwlink/p/?LinkId=2124703"), nil, nil, 1)
		return
	}

	exe, _ := os.Executable()
	gui.app = newCore(platform{
		SavedKey: savedKey,
		SaveKey:  saveKey,
		LoginItem: func() bool {
			v, _ := runKey(func(k registry.Key) (string, error) { s, _, err := k.GetStringValue("TV Remote"); return s, err })
			return strings.Contains(v, exe)
		},
		SetLoginItem:  func(on bool) error { return setLoginItem(on, exe) },
		Quit:          func() { pPostMessage.Call(gui.hwnd, wmQuit, 0, 0) },
		Resize:        func(h float64) { onUI(func() { gui.cssHeight = h; fitWindow() }) },
		MCPCommand:    `claude mcp add tv-remote -s user -- "` + exe + `" mcp`,
		WakeFix:       func() bool { return wakeFixOn.Load() },
		SetWakeFix:    setWakeFix,
		UpdatePrefix:  "windows-v",
		UpdateAsset:   func(v string) string { return "TV-Remote-Setup-" + v + ".exe" },
		InstallUpdate: installUpdate,
	})
	go func() { host, mac := gui.app.tv.HostMac(); wakeFixOn.Store(wakeFixEnabled(host, mac)) }()

	createWindow()
	if !embedWebView() {
		messageBox("TV Remote couldn't start the WebView2 runtime.")
		return
	}
	startTray()

	tv, chat := gui.app.tv, gui.app.chat
	tv.OnState = func(s map[string]any) {
		emit("state", s)
		connected := s["status"] == "connected"
		if connected {
			systray.SetIcon(trayOn)
		} else {
			systray.SetIcon(trayOff)
		}
		systray.SetTooltip("TV Remote — " + statusText[s["status"].(string)])
		setPowerItem(connected)
	}
	tv.OnIcon = func(path string, png []byte) { emit("icon", path, iconURL(png)) }
	chat.OnUpdate = func(s map[string]any) { emit("chat", s) }
	tv.Start()
	if !hidden {
		showWindow(false)
	}

	var m msg
	for {
		if r, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0); int32(r) <= 0 {
			break
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
	tv.Shutdown()
	systray.Quit()
}

var statusText = map[string]string{"noTV": "no TV selected", "connecting": "connecting…", "connected": "connected",
	"waking": "waking the TV…", "off": "TV is off", "failed": "can't connect"}

func webView2Installed() bool {
	for _, k := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\` + webView2ID},
		{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\EdgeUpdate\Clients\` + webView2ID},
		{registry.CURRENT_USER, `Software\Microsoft\EdgeUpdate\Clients\` + webView2ID},
	} {
		if key, err := registry.OpenKey(k.root, k.path, registry.QUERY_VALUE); err == nil {
			v, _, _ := key.GetStringValue("pv")
			key.Close()
			if v != "" && v != "0.0.0.0" {
				return true
			}
		}
	}
	return false
}

// ---- window -------------------------------------------------------------------------------------

func createWindow() {
	var instance windows.Handle
	_ = windows.GetModuleHandleEx(0, nil, &instance)
	icon, _, _ := pLoadImage.Call(uintptr(instance), uintptr(unsafe.Pointer(utf16("APP"))), 1, 0, 0, 0x8040) // IMAGE_ICON, LR_DEFAULTSIZE|LR_SHARED
	wc := wndClassEx{WndProc: windows.NewCallback(wndProc), Instance: uintptr(instance), Icon: icon, IconSm: icon,
		Background: 0, ClassName: utf16(className)}
	wc.Size = uint32(unsafe.Sizeof(wc))
	pRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))
	gui.hwnd, _, _ = pCreateWindowEx.Call(0, uintptr(unsafe.Pointer(utf16(className))), uintptr(unsafe.Pointer(utf16("TV Remote"))),
		wsStyle, 0x80000000, 0x80000000, 400, 800, 0, 0, uintptr(instance), 0) // CW_USEDEFAULT; created hidden
	if darkMode() {
		on := int32(1)
		pDwmSetAttribute.Call(gui.hwnd, 20, uintptr(unsafe.Pointer(&on)), 4) // DWMWA_USE_IMMERSIVE_DARK_MODE
	}
	gui.cssHeight = 760
	fitWindow()
}

func darkMode() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("AppsUseLightTheme")
	return err == nil && v == 0
}

func wndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	switch message {
	case wmClose:
		if !gui.quitting {
			pShowWindow.Call(hwnd, 0) // SW_HIDE: closing keeps the app in the tray
			return 0
		}
	case wmDestroy:
		pPostQuitMessage.Call(0)
		return 0
	case wmSize:
		if gui.web != nil {
			gui.web.Resize()
		}
	case wmMove:
		if gui.web != nil {
			_ = gui.web.NotifyParentWindowPositionChanged()
		}
	case wmActivate:
		if wParam&0xFFFF != 0 && gui.web != nil {
			gui.web.Focus()
		}
	case wmDpiChange:
		r := (*rect)(unsafe.Pointer(lParam))
		pSetWindowPos.Call(hwnd, 0, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), 0x14) // NOZORDER|NOACTIVATE
		fitWindow()
		return 0
	case wmShow:
		showWindow(false)
		return 0
	case wmToggle:
		if visible() && foreground() {
			pShowWindow.Call(hwnd, 0)
		} else {
			showWindow(true)
		}
		return 0
	case wmRun:
		gui.mu.Lock()
		q := gui.queue
		gui.queue = nil
		gui.mu.Unlock()
		for _, f := range q {
			f()
		}
		return 0
	case wmQuit:
		gui.quitting = true
		pDestroyWindow.Call(hwnd)
		return 0
	}
	r, _, _ := pDefWindowProc.Call(hwnd, message, wParam, lParam)
	return r
}

func visible() bool    { r, _, _ := pIsWindowVisible.Call(gui.hwnd); return r != 0 }
func foreground() bool { r, _, _ := pGetForeground.Call(); return r == gui.hwnd }

func workArea() (area rect, screenW, screenH int32) {
	pSystemParams.Call(0x30, 0, uintptr(unsafe.Pointer(&area)), 0) // SPI_GETWORKAREA (primary monitor)
	w, _, _ := pGetSystemMetrics.Call(0)                           // SM_CXSCREEN
	h, _, _ := pGetSystemMetrics.Call(1)                           // SM_CYSCREEN
	return area, int32(w), int32(h)
}

// fitWindow sizes the window to 340 CSS px by the height the UI reports, in this monitor's DPI.
func fitWindow() {
	dpi, _, _ := pGetDpiForWindow.Call(gui.hwnd)
	if dpi == 0 {
		dpi = 96
	}
	area, _, _ := workArea()
	r := rect{0, 0, int32(cssWidth * float64(dpi) / 96), int32(gui.cssHeight * float64(dpi) / 96)}
	if max := area.Bottom - area.Top - 24; r.Bottom > max {
		r.Bottom = max
	}
	pAdjustRectDpi.Call(uintptr(unsafe.Pointer(&r)), wsStyle, 0, 0, dpi)
	pSetWindowPos.Call(gui.hwnd, 0, 0, 0, uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), 0x16) // NOMOVE|NOZORDER|NOACTIVATE
}

// showWindow brings the window up; from the tray it is placed next to the taskbar's notification area.
func showWindow(nearTray bool) {
	if nearTray && !visible() {
		var w rect
		pGetWindowRect.Call(gui.hwnd, uintptr(unsafe.Pointer(&w)))
		width, height := w.Right-w.Left, w.Bottom-w.Top
		area, sw, sh := workArea()
		x, y := area.Right-width-8, area.Bottom-height-8 // taskbar at the bottom (default) or right
		if area.Top > 0 {                                // taskbar at the top
			y = area.Top + 8
		} else if area.Left > 0 && area.Right == sw && area.Bottom == sh { // taskbar on the left
			x = area.Left + 8
		}
		pSetWindowPos.Call(gui.hwnd, 0, uintptr(x), uintptr(y), 0, 0, 0x15) // NOSIZE|NOZORDER|NOACTIVATE
	}
	if r, _, _ := pIsIconic.Call(gui.hwnd); r != 0 {
		pShowWindow.Call(gui.hwnd, 9) // SW_RESTORE
	}
	pShowWindow.Call(gui.hwnd, 5) // SW_SHOW
	pSetForeground.Call(gui.hwnd)
	gui.app.tv.Refresh()
}

var pGetWindowRect = user32.NewProc("GetWindowRect")

// ---- WebView2 + bridge ---------------------------------------------------------------------------

func embedWebView() bool {
	local, _ := os.UserCacheDir() // %LOCALAPPDATA%
	base := filepath.Join(local, "TV Remote")
	uiDir := filepath.Join(base, "ui")
	// The UI is embedded in the exe; WebView2 serves it from disk under https://app.tvremote/ (a secure
	// origin, so the page's CSP and clipboard work as in a normal browser).
	_ = os.RemoveAll(uiDir)
	sub, _ := fs.Sub(uiFiles, "ui")
	if err := os.CopyFS(uiDir, sub); err != nil {
		return false
	}

	w := edge.NewChromium()
	w.DataPath = filepath.Join(base, "WebView2")
	w.MessageCallback = func(m string) { go bridge(m) }
	if !w.Embed(gui.hwnd) {
		return false
	}
	if s, err := w.GetSettings(); err == nil {
		_ = s.PutAreDevToolsEnabled(false)
		_ = s.PutAreDefaultContextMenusEnabled(false)
		_ = s.PutIsStatusBarEnabled(false)
		_ = s.PutIsZoomControlEnabled(false)
		_ = s.PutAreBrowserAcceleratorKeysEnabled(false) // no F5 reload / Ctrl+P / find bar
		_ = s.PutIsPinchZoomEnabled(false)
		_ = s.PutIsSwipeNavigationEnabled(false)
	}
	if c2 := w.GetController().GetICoreWebView2Controller2(); c2 != nil {
		_ = c2.PutDefaultBackgroundColor(edge.COREWEBVIEW2_COLOR{A: 255, R: 28, G: 28, B: 30})
	}
	if wv3 := w.GetICoreWebView2_3(); wv3 == nil || wv3.SetVirtualHostNameToFolderMapping("app.tvremote", uiDir, edge.COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY) != nil {
		return false
	}
	gui.web = w
	w.Resize()
	w.Navigate("https://app.tvremote/index.html")
	return true
}

// bridge answers one window.tv call from ui/bridge.js: {id, method, args} → __tvReply({id, result|error}).
func bridge(raw string) {
	var req struct {
		ID     int    `json:"id"`
		Method string `json:"method"`
		Args   []any  `json:"args"`
	}
	if json.Unmarshal([]byte(raw), &req) != nil {
		return
	}
	reply := map[string]any{"id": req.ID}
	if result, err := gui.app.call(req.Method, req.Args); err != nil {
		reply["error"] = err.Error()
	} else {
		reply["result"] = result
	}
	data, _ := json.Marshal(reply)
	onUI(func() { gui.web.Eval("window.__tvReply(" + string(data) + ")") })
}

func emit(event string, args ...any) {
	data, _ := json.Marshal(map[string]any{"event": event, "args": args})
	onUI(func() {
		if gui.web != nil {
			gui.web.Eval("window.__tvEvent(" + string(data) + ")")
		}
	})
}

// ---- tray ---------------------------------------------------------------------------------------

var (
	powerItem *systray.MenuItem
	trayReady = make(chan struct{})
)

func startTray() {
	go func() {
		runtime.LockOSThread() // the tray's hidden window and its message loop live on this thread
		systray.Run(func() {
			systray.SetIcon(trayOff)
			systray.SetTooltip("TV Remote")
			systray.SetOnTapped(func() { pPostMessage.Call(gui.hwnd, wmToggle, 0, 0) })
			show := systray.AddMenuItem("Show remote", "")
			powerItem = systray.AddMenuItem("Turn TV on", "")
			systray.AddSeparator()
			quit := systray.AddMenuItem("Quit TV Remote", "")
			close(trayReady)
			for {
				select {
				case <-show.ClickedCh:
					pPostMessage.Call(gui.hwnd, wmShow, 0, 0)
				case <-powerItem.ClickedCh:
					go gui.app.tv.TogglePower()
				case <-quit.ClickedCh:
					pPostMessage.Call(gui.hwnd, wmQuit, 0, 0)
				}
			}
		}, nil)
	}()
}

func setPowerItem(connected bool) {
	select {
	case <-trayReady:
	default:
		return
	}
	if connected {
		powerItem.SetTitle("Turn TV off")
	} else {
		powerItem.SetTitle("Turn TV on")
	}
}

// ---- wake from long standby (see pinCommand) ----------------------------------------------------------

var wakeFixOn atomic.Bool

// wakeFixEnabled: is the TV's address pinned? Get-NetNeighbor's output isn't localized (netsh's and arp's are).
func wakeFixEnabled(host, mac string) bool {
	hw, err := net.ParseMAC(strings.ReplaceAll(mac, "-", ":"))
	if !isLocalAddress(host) || err != nil {
		return false
	}
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command",
		"(Get-NetNeighbor -AddressFamily IPv4 -IPAddress '"+host+"' -State Permanent -ErrorAction SilentlyContinue).LinkLayerAddress")
	hideWindow(cmd)
	out, _ := cmd.Output()
	return strings.Contains(strings.ToLower(string(out)), strings.ReplaceAll(hw.String(), ":", "-"))
}

func setWakeFix(on bool) error {
	host, mac := gui.app.tv.HostMac()
	idx, err := interfaceFor(host)
	if err != nil {
		return err
	}
	cmdline, err := pinCommand(on, idx, host, mac)
	if err != nil {
		return err
	}
	// One UAC prompt; the entry is persistent, so it survives restarts.
	if err := windows.ShellExecute(windows.Handle(gui.hwnd), utf16("runas"), utf16("cmd.exe"), utf16("/c "+cmdline), nil, 0); err != nil {
		if err == windows.ERROR_CANCELLED {
			return errors.New("Cancelled.")
		}
		return err
	}
	for range 30 {
		time.Sleep(500 * time.Millisecond)
		if wakeFixEnabled(host, mac) == on {
			wakeFixOn.Store(on)
			return nil
		}
	}
	return errors.New("Windows didn't apply the change.")
}

// ---- updates ------------------------------------------------------------------------------------

// installUpdate runs the verified installer silently; it replaces this exe (the installer closes running
// copies) and starts the new version.
func installUpdate(u *update) error {
	name := "TV-Remote-Setup-" + u.Version + ".exe"
	file, err := fetchUpdate(u, filepath.Join(os.TempDir(), "TV Remote update"), name)
	if err != nil {
		return err
	}
	if _, err := os.Stat(file); err != nil {
		// Real-time protection can remove a just-downloaded unsigned installer.
		return errors.New("Windows removed the downloaded installer (Microsoft Defender may have flagged it). Update by building from source, or report the file to Microsoft as a false positive")
	}
	if err := windows.ShellExecute(windows.Handle(gui.hwnd), utf16("open"), utf16(file), utf16("/S"), nil, 1); err != nil {
		return fmt.Errorf("couldn't start the installer: %w", err)
	}
	time.AfterFunc(800*time.Millisecond, func() { pPostMessage.Call(gui.hwnd, wmQuit, 0, 0) })
	return nil
}

// ---- login item and API key ---------------------------------------------------------------------

func runKey(f func(registry.Key) (string, error)) (string, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return "", err
	}
	defer k.Close()
	return f(k)
}

func setLoginItem(on bool, exe string) error {
	_, err := runKey(func(k registry.Key) (string, error) {
		if on {
			return "", k.SetStringValue("TV Remote", `"`+exe+`" --hidden`)
		}
		if err := k.DeleteValue("TV Remote"); err != nil && err != registry.ErrNotExist {
			return "", err
		}
		return "", nil
	})
	return err
}

// The saved API key is encrypted with DPAPI (bound to this Windows user), like Electron's safeStorage.
func saveKey(key string) error {
	key = strings.TrimSpace(key)
	enc := ""
	if key != "" {
		in := windows.DataBlob{Size: uint32(len(key)), Data: &[]byte(key)[0]}
		var out windows.DataBlob
		if err := windows.CryptProtectData(&in, nil, nil, 0, nil, 1, &out); err != nil { // CRYPTPROTECT_UI_FORBIDDEN
			return err
		}
		enc = base64.StdEncoding.EncodeToString(unsafe.Slice(out.Data, out.Size))
		windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	}
	updateSettings(func(s *Settings) { s.APIKeyDPAPI = enc })
	return nil
}

func savedKey() string {
	data, err := base64.StdEncoding.DecodeString(loadSettings().APIKeyDPAPI)
	if err != nil || len(data) == 0 {
		return ""
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	if windows.CryptUnprotectData(&in, nil, nil, 0, nil, 1, &out) != nil {
		return ""
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return string(unsafe.Slice(out.Data, out.Size))
}
