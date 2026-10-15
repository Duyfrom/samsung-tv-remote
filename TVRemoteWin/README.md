# TV Remote for Windows

Remote for 2016+ Samsung Tizen TVs (built and tested on a UA49K5500): D-pad, volume, channel, media keys,
your TV's apps with their real icons, number pad, typing and touchpad, power on/off (Wake-on-LAN over Wi-Fi),
a **Claude chat bar** ("mở FPT Play", "play the latest MKBHD video"), recordable **shortcuts**, and an **MCP server**
so Claude Code / Claude Desktop can control the TV too.

It is the Electron twin of the macOS menu bar app in `../TVRemote` — same protocol, same tools, same
shortcuts file format. It also runs on macOS and Linux (`npm start`).

## Install (Windows 10/11, 64-bit)

1. Download **`TV-Remote-Setup-1.0.0.exe`** from the repo's *Releases* page and run it. One click, no admin rights;
   it installs per user, adds Start menu and desktop shortcuts, and starts the app.
2. The installer isn't code-signed, so Windows SmartScreen says *"Windows protected your PC"*:
   click **More info → Run anyway**. (Checksum is in the release notes.)
3. Windows Firewall may ask to allow TV Remote on private networks — allow it, it needs the local network.
4. First start scans your network and picks the TV (or pick it in ⚙ Settings). Closing the window keeps the app in the
   system tray; right-click the tray icon for *Turn TV on/off* and *Quit*.

On the TV, *Settings › General › External Device Manager › Device Connection Manager*: set **Access Notification**
to Off (or First Time Only) so the TV doesn't ask to Allow on every connection.

## Claude chat

The bar at the bottom sends what you type to **Claude Haiku 5.5** (`claude-haiku-5-5`, low effort), which acts through
the same tools as the MCP server. The API key is found, in order, in:

1. opencode's auth store — `%USERPROFILE%\.local\share\opencode\auth.json` (also `%APPDATA%\opencode`, `%LOCALAPPDATA%\opencode`),
2. a key pasted into ⚙ Settings (encrypted with Windows DPAPI via Electron `safeStorage`),
3. the `ANTHROPIC_API_KEY` environment variable.

**Shortcuts:** the TV's screen can't be read, so getting *inside* an app (a channel in FPT Play) is blind. Press **●**,
do it once with the remote, name it "VTV1" — it becomes a chip above the chat and Claude can run it by name.
They live in `%APPDATA%\TV Remote\shortcuts.json`.

## MCP server

⚙ Settings shows the exact command for your install. For the installed app it is:

```
claude mcp add tv-remote -s user -e ELECTRON_RUN_AS_NODE=1 -- "%LOCALAPPDATA%\Programs\TV Remote\TV Remote.exe" "%LOCALAPPDATA%\Programs\TV Remote\resources\app\src\mcp\server.js"
```

(the app's own executable runs the script as plain Node), or with Node installed: `claude mcp add tv-remote -s user -- node <repo>\TVRemoteWin\src\mcp\server.js`.
Tools: `press_keys`, `type_text`, `list_apps`, `launch_app`, `play_youtube`, `open_url`, `set_volume`, `mute`, `power`,
`get_status`, `wait`, `list_shortcuts`, `run_shortcut`, `save_shortcut`.

## Develop / build

```bash
npm install
npm start                 # run the app (any OS)
npm test                  # unit tests + a fake-TV websocket/REST/UPnP integration test
npm run mcp               # MCP server on stdio
npm run dist              # Windows installer → dist/TV-Remote-Setup-<version>.exe (works from macOS/Linux too)
npm run icons             # regenerate build/*.png|ico from ../TVRemote's icon artwork (macOS + Pillow)
```

Development-only hooks (never loaded from a packaged build): `TVREMOTE_SHOT=/tmp/shot` renders every tab to PNG,
`TVREMOTE_CHAT="msg || msg"` runs chat messages through the real code path, `TVREMOTE_SELFTEST=1|power` drives the
controller against the real TV (`power` also switches it off and on).

```
src/core      protocol, no Electron: channel (websocket), rest, upnp, discovery, wol, youtube/DIAL, tools, shortcuts
src/main      Electron main: controller (connection + state), chat (Claude loop), tray/window, IPC
src/renderer  the UI (plain DOM)
src/mcp       MCP server (stdio) on src/core
```

## Behaviour worth knowing (all found on the real TV)

- The TV drops a command if the client disconnects within ~0.3 s of sending it, and drops remote keys while a burst
  of icon requests is in flight — the app keeps one connection open and fetches icons one at a time (cached in
  `%APPDATA%\TV Remote\icons`).
- Quick repeated volume keys are dropped while the TV's volume bar animates in, so volume ± uses UPnP absolute volume.
- REST app launch answers "ok" for native apps (Web Browser) without opening them — launches go over the websocket.
- YouTube videos launch through DIAL (`POST :8080/ws/app/YouTube`, `v=<id>`); this TV then shows "Who's watching?",
  which `play_youtube` answers with OK on the first profile.
- After `KEY_POWER` the TV keeps its network up ~25 s; the power button sends the key in that window and
  Wake-on-LAN after it. Wake packets go out of **every** network adapter (Wi-Fi, Ethernet, VPN, virtual switches).
- Compact layout is used automatically on screens shorter than ~790 px (1080p laptops at 150% scaling).

## Security notes

- Claude only ever gets the TV tools (keys, apps, volume, power, URLs, shortcuts). Text coming back from the internet
  (video titles, channel names) is flattened and length-capped before the model sees it, the instructions tell the
  model to treat it as data, and `open_url` accepts only `http(s)` links.
- Token-based TVs (2017+) use `wss://:8002` with a self-signed certificate, so that connection is encrypted but not
  authenticated; the app refuses to make it to anything but a local-network address. The UA49K5500 uses plain
  `ws://:8001` and never takes that path. Use token TVs on a network you trust.
- The API key is read from opencode's file or the system keystore at call time and only ever sent to `api.anthropic.com`.

## Status

Everything except the installer wrapper was exercised against the real UA49K5500 from macOS (same Electron app and
code): connect, keys, volume/mute, apps + icons, chat with shortcuts, MCP over stdio, DIAL YouTube. The Wake-on-LAN
sender was checked for valid packets on every adapter locally. The Windows installer is built from macOS and its
contents verified (64-bit exe, icons, version info, sources) but **has not been run on a Windows machine yet**.
