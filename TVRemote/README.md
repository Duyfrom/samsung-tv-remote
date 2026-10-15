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

On the TV, *Settings › General › External Device Manager › Device Connection Manager*:
set **Access Notification** to Off (or First Time Only) and make sure **Mac Remote** is allowed,
otherwise the TV asks to Allow on every connection.

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
- Port 8002 accepts TLS but this firmware never issues a token; plain 8001 is used.
- After `KEY_POWER` the TV keeps its network up for ~25 s; the app sends the power key in that window and
  Wake-on-LAN after it.

## Layout

- `Sources/TVKit` — protocol: `RemoteChannel` (WebSocket), `TVRestClient`, `RenderingControl` (UPnP),
  `Discovery` (/24 sweep), `WakeOnLAN`, `TVKey` (codes recovered with REA from Samsung's PC Smart View 2)
- `Sources/TVRemote` — SwiftUI `MenuBarExtra` app (`TVController` owns the connection)
- `Sources/tvctl` — CLI
- Debug builds only: `TVREMOTE_SNAPSHOT=/tmp/shot swift run TVRemote` renders the popover tabs to PNGs;
  `TVREMOTE_SELFTEST=1` (or `=power`, which also switches the TV off and on) drives the controller
  against the real TV; `TVREMOTE_DEBUG=1` logs WebSocket traffic.

Reverse-engineering evidence (REA output for the Smart View 2 assemblies) is in `../evidence`.
