# TV Remote for Windows

Remote for 2016+ Samsung Tizen TVs (built and tested on a UA49K5500): D-pad, volume, channel, media keys, your TV's
apps with their real icons, number pad, typing and touchpad, power on/off (Wake-on-LAN over Wi-Fi), a **Claude chat
bar** ("mở FPT Play", "play the latest MKBHD video"), recordable **shortcuts**, a tray icon, and an **MCP server** so
Claude Code / Claude Desktop can control the TV too.

**One 8 MB exe, 2.7 MB installer.** Written in Go; the window is the Edge WebView2 that ships with Windows, so no
browser or runtime is bundled. (v1 was Electron: a 106 MB installer, 374 MB installed.)

## Install (Windows 10/11, 64-bit)

1. Download **`TV-Remote-Setup-2.0.1.exe`** from *Releases* and run it — per user, no admin rights, adds Start menu and
   desktop shortcuts. Or just run the portable **`TV-Remote-2.0.1-portable.exe`** (the same app, one file).
2. Not code-signed: SmartScreen says *"Windows protected your PC"* → **More info → Run anyway**.
3. Allow it through Windows Firewall on private networks. It finds the TV itself (or pick it in ⚙ Settings).
4. **Upgrading from 1.0.0 (Electron):** just run the new installer. It replaces the old app in place, removes its
   ~370 MB runtime and its *Apps & features* entry, and keeps your TV, settings and shortcuts. There's no
   auto-update: newer versions are installed the same way.
5. On the TV: *Settings › General › External Device Manager › Device Connection Manager* → **Access Notification Off**,
   so the TV doesn't ask to Allow every connection.

Closing the window keeps it in the tray (click: show/hide; right-click: *Turn TV on/off*, *Quit*). Needs the WebView2
Runtime, which Windows 11 and most Windows 10 PCs have; if it's missing, the app says so and opens Microsoft's download.

## Claude chat and shortcuts

The bar at the bottom sends what you type to **Claude Haiku 5.5** (`claude-haiku-5-5`, low effort) with the TV tools.
The API key is read when needed from opencode's `auth.json` (`%USERPROFILE%\.local\share\opencode`, `%APPDATA%\opencode`
or `%LOCALAPPDATA%\opencode`), else a key pasted in ⚙ Settings (encrypted with Windows DPAPI), else `ANTHROPIC_API_KEY`.

The TV's screen can't be read, so getting *inside* an app (a channel in FPT Play) is blind. **Shortcuts** fix that: press
**●**, do it once with the remote, name it "VTV1" — it becomes a chip above the chat and Claude runs it by name.
Settings and shortcuts live in `%APPDATA%\TV Remote` (same format as the macOS app).

## MCP server

The same exe, with `mcp`:

```
claude mcp add tv-remote -s user -- "%LOCALAPPDATA%\Programs\TV Remote\TV Remote.exe" mcp
```

(⚙ Settings shows the exact path.) Tools: `press_keys`, `type_text`, `list_apps`, `launch_app`, `play_youtube`, `open_url`,
`set_volume`, `mute`, `power`, `get_status`, `wait`, `list_shortcuts`, `run_shortcut`, `save_shortcut`. The TV comes from
`$TV_HOST`, the app's saved TV, or a network scan. `go run . mcp` runs it on macOS/Linux too.

## Build

```bash
./build.sh            # go test, then dist/TV Remote.exe + dist/TV-Remote-Setup-<version>.exe (needs Go + makensis)
go test ./...         # unit tests + a fake TV (websocket/REST/UPnP) + a fake Claude API
TVREMOTE_LIVE=1 go test -run TestLive -v .               # drive the real TV (TVREMOTE_LIVE_CHAT=1 adds Claude)
build/make-icons.sh   # only when the icon or version changes: build/*.ico + rsrc_windows_amd64.syso
```

```
tv.go          protocol: websocket channel, REST, UPnP volume, discovery, Wake-on-LAN, DIAL/YouTube, keys
tools.go       the 14 tools shared by the chat and MCP        store.go   settings + shortcuts files
controller.go  connection state, retry, power, icons, recording
chat.go        Claude Haiku tool loop                         mcp.go     MCP server (stdio)
app.go         UI calls → controller (platform-neutral)       gui_windows.go  window, WebView2, tray, DPAPI, login item
ui/            the remote's HTML/CSS/JS (bridge.js talks to Go)
```

## Behaviour worth knowing (found on the real TV)

- The TV drops a command if the client disconnects within ~0.3 s, and drops keys during a burst of icon requests —
  one connection stays open and icons are fetched one at a time (cached in `%APPDATA%\TV Remote\icons`).
- Quick repeat volume keys are dropped while the TV's volume bar animates in, so volume ± uses UPnP absolute volume.
- REST app launch says "ok" for native apps (Web Browser) without opening them — launches go over the websocket.
- YouTube videos launch through DIAL (`POST :8080/ws/app/YouTube`, `v=<id>`); this TV then shows "Who's watching?",
  which `play_youtube` answers with OK on the first profile.
- After `KEY_POWER` the TV keeps its network up ~25 s: the power button sends the key in that window and Wake-on-LAN
  after it, from every network adapter.

## Security notes

- Claude only gets the TV tools. Text from the internet (video titles, channel names) is flattened and length-capped
  before the model sees it, the instructions say it's data, and `open_url` takes only `http(s)` links.
- Token TVs (2017+) use `wss://:8002` with a self-signed certificate — encrypted, not authenticated — so that connection
  is refused for anything but a canonical local-network IPv4 address. The UA49K5500 uses plain `ws://:8001`.
- The UI is served from the exe to WebView2 under `https://app.tvremote/` with dev tools, context menu, zoom and browser
  shortcuts off.

## Status

Everything except the Windows window code ran against the real UA49K5500 from macOS: protocol, controller, chat with
Claude, MCP, and the UI itself (rendered in Chromium through `bridge.js` against the Go core). The Windows build
compiles and its resources (icon, DPI manifest, version) and installer payload are verified, but the window, tray and
WebView2 hosting **have not been run on a Windows PC yet**.
