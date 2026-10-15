import Foundation
import TVKit

/// "Wake from long standby": a root LaunchDaemon that keeps the TV's address pinned in the ARP table (see
/// `WakeOnLAN.pinScript`). It re-applies every minute because reboots and Wi-Fi reconnects drop static entries.
/// Installing and removing it asks for an administrator password (macOS's own dialog).
enum WakeFix {
    static let label = "com.khuongduypham.tvremote.wake"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    static func isInstalled(host: String, mac: String) -> Bool {
        guard let script = WakeOnLAN.pinScript(host: host, mac: mac),
              let plist = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return false }
        return plist.contains(script)
    }

    static func install(host: String, mac: String) throws {
        guard let script = WakeOnLAN.pinScript(host: host, mac: mac) else {
            throw TVToolError("Needs the TV's IP address and MAC address first.")
        }
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(label)</string>
              <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>\(script)</string></array>
              <key>RunAtLoad</key><true/>
              <key>StartInterval</key><integer>60</integer>
            </dict></plist>
            """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        try plist.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runAsAdmin("""
            /usr/bin/install -m 644 -o root -g wheel '\(tmp.path)' '\(plistPath)' && \
            { /bin/launchctl bootout system/\(label) 2>/dev/null; /bin/launchctl bootstrap system '\(plistPath)'; }
            """)
    }

    static func uninstall(host: String) throws {
        let unpin = RemoteChannel.isLocalAddress(host) ? "/usr/sbin/arp -d \(host) 2>/dev/null;" : ""
        try runAsAdmin("/bin/launchctl bootout system/\(label) 2>/dev/null; /bin/rm -f '\(plistPath)'; \(unpin) true")
    }

    private static func runAsAdmin(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TVToolError(message.contains("-128") ? "Cancelled." : "Couldn't change the setting: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
