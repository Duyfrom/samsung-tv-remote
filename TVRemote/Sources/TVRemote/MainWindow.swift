import AppKit
import SwiftUI

/// The remote in a regular window, for opening the app from Applications, Launchpad or Spotlight.
/// While it is open the app has a Dock icon and menu bar; closing it goes back to menu-bar only.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = NSHostingView(rootView: RemoteView(inWindow: true).environmentObject(TVController.shared))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "TV Remote"
            window.contentView = view
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("TVRemoteMainWindow")
            self.window = window
        }
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        // Activation is only a request since macOS 14 and can be declined (e.g. when opened from the menu
        // bar popover); ordering the window front regardless keeps it from opening hidden behind other apps.
        window?.orderFrontRegardless()
        if wasAccessory {
            // Coming out of menu-bar-only mode the policy change has to settle before activation sticks.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        } else {
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
