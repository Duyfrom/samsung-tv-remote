package main

// The bridge between the web UI (ui/) and the Go side: every window.tv.* call in ui/bridge.js lands in
// call(). Platform-specific pieces (key encryption, login item, window) come in through platform.

import (
	"encoding/base64"
	"errors"
	"fmt"
	"runtime"
)

type platform struct {
	SavedKey     func() string     // decrypted key saved in this app, or ""
	SaveKey      func(string) error // nil: saving keys unsupported
	LoginItem    func() bool
	SetLoginItem func(bool) error // nil: unsupported
	Quit         func()
	Resize       func(cssHeight float64)
	MCPCommand   string
}

type core struct {
	tv   *Controller
	chat *Chat
	p    platform
}

func newCore(p platform) *core {
	a := &core{tv: NewController(), p: p}
	a.chat = NewChat(a.tv, a.tv, func() string { k, _ := resolveAPIKey(a.savedKey()); return k })
	return a
}

func (a *core) savedKey() string {
	if a.p.SavedKey == nil {
		return ""
	}
	return a.p.SavedKey()
}

func iconURL(png []byte) string { return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png) }

func (a *core) extras() map[string]any {
	_, source := resolveAPIKey(a.savedKey())
	var src any
	if source != "" {
		src = source
	}
	login := false
	if a.p.LoginItem != nil {
		login = a.p.LoginItem()
	}
	return map[string]any{
		"model": chatModel, "keySource": src, "keyEncryptable": a.p.SaveKey != nil, "mcpCommand": a.p.MCPCommand,
		"packaged": a.p.SetLoginItem != nil, "openAtLogin": login, "platform": runtime.GOOS, "version": version_,
	}
}

func (a *core) call(method string, args []any) (any, error) {
	str := func(i int) string {
		if i < len(args) {
			if s, ok := args[i].(string); ok {
				return s
			}
		}
		return ""
	}
	num := func(i int) float64 {
		if i < len(args) {
			if f, ok := args[i].(float64); ok {
				return f
			}
		}
		return 0
	}
	tv := a.tv
	switch method {
	case "init":
		icons := map[string]string{}
		for path, png := range tv.Icons() {
			icons[path] = iconURL(png)
		}
		return map[string]any{"state": tv.Snapshot(), "chat": a.chat.Snapshot(), "extras": a.extras(), "icons": icons}, nil
	case "send":
		tv.Send(str(0))
	case "sendText":
		tv.SendText(str(0))
	case "movePointer":
		tv.MovePointer(num(0), num(1))
	case "click":
		tv.Click()
	case "launch":
		tv.Launch(str(0))
	case "setVolume":
		tv.SetVolume(num(0))
	case "togglePower":
		tv.TogglePower()
	case "startRecording":
		tv.StartRecording()
	case "stopRecording":
		tv.StopRecording(str(0))
	case "runShortcut":
		tv.RunShortcut(str(0))
	case "deleteShortcut":
		tv.DeleteShortcut(str(0))
	case "scan":
		go tv.Scan(false)
	case "select":
		tv.Select(str(0))
	case "setHost":
		tv.SetHost(str(0), "")
	case "setMac":
		tv.SetMac(str(0))
	case "connect":
		tv.Connect()
	case "chatSend":
		a.chat.Send(str(0))
	case "chatClear":
		a.chat.Clear()
	case "setOpenAtLogin":
		if a.p.SetLoginItem != nil {
			if err := a.p.SetLoginItem(len(args) > 0 && args[0] == true); err != nil {
				return nil, err
			}
		}
		return a.extras(), nil
	case "saveApiKey":
		if a.p.SaveKey == nil {
			return nil, errors.New("saving a key isn't supported here")
		}
		if err := a.p.SaveKey(str(0)); err != nil {
			return nil, err
		}
		return a.extras(), nil
	case "quit":
		if a.p.Quit != nil {
			a.p.Quit()
		}
	case "resize":
		if a.p.Resize != nil {
			a.p.Resize(num(0))
		}
	default:
		return nil, fmt.Errorf("unknown method %s", method)
	}
	return nil, nil
}
