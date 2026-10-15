# Samsung TV remote for the Mac menu bar

Reverse engineering a 2016 Samsung Tizen TV (UA49K5500) and controlling it from macOS.

- **[TVRemote/](TVRemote/)** — the menu bar app (`TV Remote.app`) and `tvctl` CLI, Swift. Start here.
- **evidence/** — [REA](https://github.com/morluto/rea) analysis of Samsung's PC Smart View 2 .NET assemblies
  (MultiscreenWindowsApiCSharp, SmartView2Devices, SmartView2Core, SpcApi): the source of the `ms.channel.*`
  WebSocket protocol, DIAL discovery and the `KEY_*` table.
- **tasks/todo.md** — build log and what was verified on the real TV.

To redo the analysis: `npm install` (installs `rea-agents`), clone REA into `rea/`, and fetch the Smart View
binaries into `apk/` (Samsung Smart View 4.1.63 APK and the 2016 SmartView.msi from archive.org).
