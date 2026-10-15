# Samsung UA49K5500 menu bar remote

Picked up from Antigravity (quota exhausted 2026-10-15) — RE phase done with REA on PC Smart View 2
(MultiscreenWindowsApiCSharp / SmartView2Devices assemblies, evidence/ folder).

## TVKit (protocol)
- [x] TVKey — KEY_* codes (from SmartView2.Devices.RemoteControls.TvKeyCode)
- [x] RemoteChannel — MSF WebSocket ws:8001 / wss:8002 + token; icon events; traffic log hook
- [x] TVRestClient — /api/v2/ device info, app status/launch/close
- [x] Discovery — /24 sweep verified with /api/v2/ (SSDP dropped: sweep is simpler and verifies)
- [x] RenderingControl — UPnP volume/mute on :9197
- [x] WakeOnLAN — magic packet + ARP MAC lookup
- [x] ~~AppCatalog~~ — not needed, TV returns its app list + icons over WS

## Apps
- [x] tvctl CLI
- [x] TVRemote MenuBarExtra app (controller, remote UI, apps, numbers, typing/touchpad, settings, shortcuts)
- [x] scripts/build-app.sh + Info.plist (LSUIElement, local network)

## Verify (real TV, camera for visual checks)
- [x] ~~Python mock TV~~ — real TV available, tested live instead
- [x] tvctl: discover, info, apps, volume, mute, keys, launch (web + native), text, pointer move/click
- [x] TV setting: Access Notification Off → no more Allow prompts (user)
- [x] Wake-on-LAN over Wi-Fi fully powers the TV on
- [x] App self-test: connect, mute key, rapid volume, slider, apps+icons — 3/3 runs
- [x] App power: off → on (shutdown window) and off → on (WoL), confirmed on camera
- [x] Popover rendered offscreen for all three tabs (screen was locked)
- [ ] Click through the real popover once the Mac is unlocked; approve the Local Network prompt (user)

## Mac app (window + icon)
- [x] App icon rendered by scripts/make-icon.swift → Support/AppIcon.icns, bundled via Info.plist
- [x] MainWindow: launching from Applications opens the remote in a window with a Dock icon;
      closing it returns to menu-bar only; reopening shows it again; login launch stays in the menu bar
- [x] Verified: window renders connected; close → UIElement, reopen → Foreground with one window
- [x] Security review follow-ups: token only sent over wss; discovery only accepts `Samsung SmartTV`
      devices; self-signed 8002 certificate trust kept (Samsung only ships self-signed certs, and this
      TV uses unauthenticated ws:8001 anyway)

## Claude chat + MCP + shortcuts
- [x] TVTools in TVKit: 13 tools shared by chat and MCP (keys, text, apps w/ fuzzy match, open_url, volume, mute,
      power, status, wait, shortcuts list/run/save)
- [x] tvmcp stdio MCP server, bundled in the app, registered in Claude Code (user scope) — ✔ Connected
- [x] Chat bar (Haiku 5.5, low effort, raw HTTP tool loop, append-only history), key from opencode auth.json
- [x] Shortcut recorder (● button; pauses ≥1.5 s kept as waits) + chips; Claude can save/run shortcuts
- [x] Verified on the TV: MCP initialize/tools/list/status/apps/volume; chat: status, "mở FPT Play" (visible),
      volume set + "put it back", blind VTV1 attempt via FPT search, shortcut save + run, reply language
- [x] play_youtube: DIAL launch + profile pick; latest video of a channel via RSS. Verified by the user on the TV:
      "Apple Homeview Impressions" played (MCP stdio call and the in-app chat)
- [x] State checks: probed AVTransport/RenderingControl SCPDs and the event stream — nothing beyond what
      get_status already reports (documented in the README)
- [ ] User: try the chat field in the app; record a real "VTV1" shortcut in FPT Play

## Review
Bugs found by testing on the TV and fixed: keys dropped when the client hangs up < 0.3 s after sending
(tvctl lingers); keys dropped during an icon request burst (serial fetch + disk cache); quick volume repeats
dropped while the volume bar animates (UPnP absolute volume); REST launch reports ok for native apps
without launching (WS launch); a pending connect continuation leaked on reconnect (resolved in disconnect).

## Windows app (TVRemoteWin, Electron)
- [x] src/core: channel, rest, upnp, discovery, wol (per-adapter), youtube/DIAL, tools (14), shortcuts — ported from TVKit
- [x] src/main: controller (same state machine/retry/power logic), Claude chat (Haiku 5.5, raw HTTP), tray + window, IPC
- [x] src/renderer: same layout as the Mac app; compact mode for short screens (found + fixed: CSP-blocked inline
      style on the SVG sprite pushed the layout down by one line)
- [x] src/mcp/server.js: stdio MCP, 14 tools, remembers the TV it finds
- [x] 21 tests: unit + fake-TV websocket/REST/UPnP integration; all pass
- [x] Real TV from macOS: selftest (mute, rapid volume, slider, apps+icons), chat (status, shortcuts), MCP over stdio
- [x] WoL sender: valid 102-byte packets from every adapter (loopback check; a real power cycle was not run to avoid
      interrupting the user)
- [x] electron-builder (from macOS): TV-Remote-Setup-1.0.0.exe, NSIS one-click per-user; exe has the icon + version info
- [ ] User: run the installer on a Windows PC (SmartScreen: More info → Run anyway) and report anything odd
- [x] Security review follow-ups: tool-result sanitising + http(s)-only open_url + local-address-only unverified TLS
      (canonical dotted-quad, same host the URL layer connects to); JS tests 23, Swift XCTest 4
