import SwiftUI

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var tv = TVController.shared

    var body: some Scene {
        MenuBarExtra {
            RemoteView().environmentObject(tv)
        } label: {
            Image(systemName: tv.isConnected ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, also when run straight from `swift run` without the bundle's LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TVREMOTE_SNAPSHOT"] { renderSnapshots(to: path) }
        if ProcessInfo.processInfo.environment["TVREMOTE_SELFTEST"] != nil { selfTest() }
        #endif
    }

    #if DEBUG
    /// `TVREMOTE_SELFTEST=1 swift run TVRemote` drives the controller against the real TV;
    /// `TVREMOTE_SELFTEST=power` also switches the TV off and back on (shutdown-window and Wake-on-LAN paths).
    @MainActor private func selfTest() {
        let tv = TVController.shared
        let start = Date()
        func log(_ s: String) {
            FileHandle.standardError.write(Data(String(format: "[%5.1fs] %@\n", Date().timeIntervalSince(start), s).utf8))
        }
        func waitFor(_ what: String, _ timeout: Double, _ ok: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if ok() { log("✓ \(what)"); return true }; try? await Task.sleep(for: .milliseconds(250)) }
            log("✗ \(what) (status \(tv.status))"); return false
        }
        Task { @MainActor in
            guard await waitFor("connected", 15, { tv.isConnected }) else { exit(1) }
            await tv.refreshVolume()
            let v0 = Int(tv.volume)
            tv.send(.mute)
            try? await Task.sleep(for: .seconds(1.5))
            _ = await waitFor("KEY_MUTE → muted", 1, { tv.muted })
            tv.send(.mute)
            try? await Task.sleep(for: .seconds(1.5))
            _ = await waitFor("KEY_MUTE → unmuted", 1, { !tv.muted })
            for _ in 0..<3 { tv.send(.volumeUp); try? await Task.sleep(for: .milliseconds(60)) }
            try? await Task.sleep(for: .seconds(1)); await tv.refreshVolume()
            _ = await waitFor("3 rapid volume-up clicks → \(v0 + 3)", 2, { Int(tv.volume) == v0 + 3 })
            tv.setVolume(Double(v0 + 2))
            try? await Task.sleep(for: .seconds(1)); await tv.refreshVolume()
            _ = await waitFor("slider → \(v0 + 2)", 2, { Int(tv.volume) == v0 + 2 })
            tv.setVolume(Double(v0))
            _ = await waitFor("apps + icons loaded", 8, { !tv.apps.isEmpty && tv.icons.count == tv.apps.count })
            try? await Task.sleep(for: .milliseconds(400)) // let the debounced volume restore land
            guard ProcessInfo.processInfo.environment["TVREMOTE_SELFTEST"] == "power" else { log("done"); exit(0) }

            log("power off"); tv.togglePower()
            _ = await waitFor("status off", 2, { tv.status == .off })
            try? await Task.sleep(for: .seconds(8))
            log("power on inside the shutdown window"); tv.togglePower()
            _ = await waitFor("reconnected (window path)", 20, { tv.isConnected })

            try? await Task.sleep(for: .seconds(15))
            log("power off again"); tv.togglePower()
            try? await Task.sleep(for: .seconds(45)) // past the window: network is down
            log("power on via Wake-on-LAN"); tv.togglePower()
            _ = await waitFor("reconnected (WoL path)", 45, { tv.isConnected })
            log("done"); exit(0)
        }
    }

    /// `TVREMOTE_SNAPSHOT=/tmp/shot swift run TVRemote` writes shot-<tab>.png for each tab, then quits.
    /// Lets the popover be reviewed without clicking the menu bar (or with the screen locked).
    @MainActor private func renderSnapshots(to prefix: String) {
        let tv = TVController.shared
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6)) // connect, load apps and icons
            FileHandle.standardError.write(Data("snapshot: status=\(tv.status) apps=\(tv.apps.count) icons=\(tv.icons.count)\n".utf8))
            for tab in RemoteView.Tab.allCases {
                let root = RemoteView(initialTab: tab).environmentObject(tv)
                    .background(Color(nsColor: .windowBackgroundColor))
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 312, height: 800),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.frame.size = view.fittingSize
                window.setContentSize(view.fittingSize)
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(500))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(prefix)-\(tab.rawValue.lowercased()).png"))
                }
                window.close()
            }
            NSApp.terminate(nil)
        }
    }
    #endif
}
