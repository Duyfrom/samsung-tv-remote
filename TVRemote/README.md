# TV Remote — Samsung UA49K5500 from the Mac menu bar

A menu bar remote for 2016+ Samsung Tizen TVs (built and tested on a UA49K5500, platform `16_HAWKM_FHD`),
plus `tvctl`, a command line client for the same protocol.

## Build & run

```bash
scripts/build-app.sh            # → build/TV Remote.app and build/tvctl (ad-hoc signed)
scripts/build-app.sh --install  # also copies the app to /Applications and launches it
```

First launch: macOS asks to let **TV Remote** find devices on the local network — click **Allow**.
The app scans the Wi-Fi for the TV, remembers it, and connects as **"Mac Remote"**.

Two ways to use it:
- **Window** — open *TV Remote* from Applications, Launchpad or Spotlight. The remote opens in a window with a
  Dock icon; close the window and the app keeps running in the menu bar only.
- **Menu bar** — click the TV icon in the menu bar; the window button in its header opens the window.
  With *Open at login* (settings) the app starts silently in the menu bar.

## Ask Claude (chat bar)

The bar at the bottom of the remote sends what you type to **Claude Haiku 5.5** (`claude-haiku-5-5`, low effort),
which acts through the same tools as the MCP server: "mở FPT Play", "volume 20", "go to phimfly.com/tv",
"turn off the TV". The API key is read when needed from opencode's `~/.local/share/opencode/auth.json`
(or `$ANTHROPIC_API_KEY`); it is never copied.

The TV's screen can't be seen, so getting *inside* an app (a channel in FPT Play) is blind. **Shortcuts** fix that:
press **●**, do it once with the remote (open FPT Play, arrows, OK — pauses are kept as waits), name it "VTV1".
It appears as a chip above the chat, and Claude runs it when you ask for VTV1. Claude can also save a sequence it
just ran ("save that as VTV1"). Shortcuts live in `~/Library/Application Support/TV Remote/shortcuts.json`.

## MCP server

`tvmcp` (bundled in the app) is a stdio MCP server with the same tools — `press_keys`, `type_text`, `list_apps`,
`launch_app`, `play_youtube`, `open_url`, `set_volume`, `mute`, `power`, `get_status`, `wait`, `list_shortcuts`, `run_shortcut`,
`save_shortcut`:

```bash
claude mcp add tv-remote -s user -- "/Applications/TV Remote.app/Contents/MacOS/tvmcp"
```

It finds the TV via `$TV_HOST`, the app's saved TV, or a network scan, and connects as "Mac Remote (Claude)".

## TV setting

On the TV, *Settings › General › External Device Manager › Device Connection Manager*:
set **Access Notification** to Off (or First Time Only) and make sure **Mac Remote** is allowed,
otherwise the TV asks to Allow on every connection.

## Updates

⚙ Settings → **Check for updates** looks for the newest `mac-v*` release on GitHub, downloads the zipped app, checks
it against the published `.sha256` and its bundle id, swaps it into place after quitting and starts it again.
`scripts/build-app.sh` makes the release files (`build/TV-Remote-mac-<version>.zip` + `.sha256`); bump
`CFBundleShortVersionString` in `Support/Info.plist` and publish them under the tag `mac-vX.Y.Z`. (Apple Silicon build.)

## What it does

| Feature | How (verified on the UA49K5500) |
|---|---|
| Remote keys (D-pad, OK, Back, Home, Exit, Source, Menu, Guide, Info, CH, numbers, colour keys, media) | MSF WebSocket `ws://TV:8001/api/v2/channels/samsung.remote.control`, `ms.remote.control` / `SendRemoteKey` |
| Volume slider, volume ± , mute state | UPnP `RenderingControl` on `:9197` (absolute volume; the TV still shows its volume bar) |
| Apps grid with real icons, in Smart Hub order | `ed.installedApp.get` + `ed.apps.icon` over the socket, launch with `ed.apps.launch` (`DEEP_LINK` / `NATIVE_LAUNCH`) |
| Type text into the TV keyboard | `SendInputString` (base64) |
| Touchpad (TV Web Browser) | `ProcessMouseDevice` `Move` / `LeftClick` |
| Power off / on | `KEY_POWER`; switching on uses Wake-on-LAN, which works over Wi-Fi on this set |
| Keyboard while the popover is open | arrows, ⏎ OK, ⌫ Back, + / − volume, M mute, H home, 0–9 |

## tvctl

```bash
export TV_HOST=192.168.50.25
tvctl discover | info | apps | keys
tvctl key home down down enter      # names from `tvctl keys` or raw KEY_* codes
tvctl text "hello"                  # into the focused TV keyboard
tvctl launch 111299001912           # YouTube (ids from `tvctl apps`)
tvctl volume 20 | mute on | power | wake
TV_DEBUG=1 tvctl key mute           # print WebSocket traffic
```

## Protocol notes (found while testing)

- The TV drops a command if the client disconnects within ~0.3 s of sending it — `tvctl` lingers 1.2 s.
- A burst of icon requests makes the TV drop remote keys sent meanwhile — icons are fetched one at a time
  and cached in `~/Library/Caches/com.khuongduypham.tvremote/icons`.
- Quick repeat volume keys are dropped while the volume bar animates in — volume ± uses UPnP instead.
- REST `POST /api/v2/applications/<id>` answers `{"ok":true}` for native apps without opening them.
- The websocket `DEEP_LINK` launch drops its `metaTag` for YouTube. Videos go through **DIAL** instead:
  `POST http://TV:8080/ws/app/YouTube` with body `v=<videoId>&t=0` (Application-URL from `:7678/nservice/`).
  This TV shows "Who's watching?" on every YouTube launch, so `play_youtube` presses OK on the first profile
  4.5 s later. "Latest video of a channel" is resolved from the channel's public RSS feed, Shorts skipped.
- `AVTransport` on :9197 only reports DLNA playback (`NO_MEDIA_PRESENT` otherwise) and the channel pushes no state
  events, so "what's on screen" can't be read from the network; `get_status` reports power, volume, mute and
  which Smart Hub app is in front.
- Port 8002 accepts TLS but this firmware never issues a token; plain 8001 is used.
- After ~20 minutes off, the TV ignores broadcast wake packets and only wakes on one sent straight to its MAC, which
  needs the computer to still know the TV's address – and it forgets it once the TV stops answering. **Wake from long
  standby** (Settings) pins it: a small root LaunchDaemon that re-pins it every minute (restarts and Wi-Fi reconnects
  clear it), installed once with your admin password. Keep *Power On with Mobile* on in the TV's network settings
  (it keeps the TV on Wi-Fi while off).
- After `KEY_POWER` the TV keeps its network up for ~25 s; the app sends the power key in that window and
  Wake-on-LAN after it.

## Layout

- `Sources/TVKit` — protocol: `RemoteChannel` (WebSocket), `TVRestClient`, `RenderingControl` (UPnP),
  `Discovery` (/24 sweep), `WakeOnLAN`, `TVKey` (codes recovered with REA from Samsung's PC Smart View 2);
  `TVTools` (tool definitions + executor shared by the chat and MCP) and `Shortcuts`
- `Sources/tvmcp` — MCP server
- `Sources/TVRemote` — SwiftUI `MenuBarExtra` app plus `MainWindow` (`TVController` owns the connection),
  `ClaudeChat` (Messages API tool loop, raw HTTP) and `ChatBar`
- `Support/` — `Info.plist` and `AppIcon.icns` (regenerate with `scripts/make-icon.sh`)
- `Sources/tvctl` — CLI
- Debug builds only: `TVREMOTE_SNAPSHOT=/tmp/shot swift run TVRemote` renders the popover tabs to PNGs;
  `TVREMOTE_SELFTEST=1` (or `=power`, which also switches the TV off and on) drives the controller
  against the real TV; `TVREMOTE_CHAT="msg || msg"` sends chat messages and prints the transcript;
  `TVREMOTE_DEBUG=1` logs WebSocket traffic.

Reverse-engineering evidence (REA output for the Smart View 2 assemblies) is in `../evidence`.
