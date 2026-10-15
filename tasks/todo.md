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

## Review
Bugs found by testing on the TV and fixed: keys dropped when the client hangs up < 0.3 s after sending
(tvctl lingers); keys dropped during an icon request burst (serial fetch + disk cache); quick volume repeats
dropped while the volume bar animates (UPnP absolute volume); REST launch reports ok for native apps
without launching (WS launch); a pending connect continuation leaked on reconnect (resolved in disconnect).
