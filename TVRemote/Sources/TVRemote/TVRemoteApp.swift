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
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TVREMOTE_SNAPSHOT"] {
            NSApp.setActivationPolicy(.accessory)
            return renderSnapshots(to: path)
        }
        if let prompts = ProcessInfo.processInfo.environment["TVREMOTE_CHAT"] {
            NSApp.setActivationPolicy(.accessory)
            return chatTest(prompts.components(separatedBy: " || "))
        }
        if ProcessInfo.processInfo.environment["TVREMOTE_SELFTEST"] != nil {
            NSApp.setActivationPolicy(.accessory)
            return selfTest()
        }
        #endif
        // The bundle is a regular app (no LSUIElement) so that opening it from Applications activates it and
        // the window comes to the front. Started at login it drops to menu-bar only straight away.
        if launchedAsLoginItem {
            NSApp.setActivationPolicy(.accessory)
        } else {
            MainWindow.shared.show()
        }
    }

    /// Double-clicking the app (or its Dock icon) while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return false
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    #if DEBUG
    /// `TVREMOTE_CHAT="first message || second message" swift run TVRemote` sends each message to Claude
    /// through the chat bar's code path and prints the transcript.
    @MainActor private func chatTest(_ prompts: [String]) {
        let tv = TVController.shared, chat = ClaudeChat.shared
        Task { @MainActor in
            for _ in 0..<60 where !tv.isConnected { try? await Task.sleep(for: .milliseconds(250)) }
            var printed = 0
            for prompt in prompts {
                let start = Date()
                chat.send(prompt)
                try? await Task.sleep(for: .milliseconds(100))
                while chat.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
                for line in chat.lines[printed...] {
                    FileHandle.standardError.write(Data("[\(line.kind)] \(line.text)\n".utf8))
                }
                printed = chat.lines.count
                FileHandle.standardError.write(Data(String(format: "   (%.1fs)\n", Date().timeIntervalSince(start)).utf8))
            }
            exit(0)
        }
    }

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
            if let message = ProcessInfo.processInfo.environment["TVREMOTE_SNAPSHOT_CHAT"] {
                ClaudeChat.shared.send(message)
                try? await Task.sleep(for: .milliseconds(100))
                while ClaudeChat.shared.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            }
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
