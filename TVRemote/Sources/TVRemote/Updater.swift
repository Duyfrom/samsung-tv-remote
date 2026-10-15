import AppKit
import TVKit

/// Updates the installed app in place: download the zipped app from the newest mac-v* release, check its
/// checksum and bundle id, then swap it in once this process has quit and start it again.
enum Updater {
    static let prefix = "mac-v"
    static var current: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    static func assetName(_ version: String) -> String { "TV-Remote-mac-\(version).zip" }

    static func check() async throws -> Updates.Update? {
        guard let current else { throw TVToolError("Updates work in the installed app.") }
        return try await Updates.check(prefix: prefix, current: current, assetName: assetName)
    }

    static func install(_ update: Updates.Update) async throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw TVToolError("Can't replace the app where it is; move TV Remote to your Applications folder first.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TV Remote update \(UUID().uuidString)")
        let zip = try await Updates.download(update, to: dir)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.appendingPathComponent("new").path]
        try unzip.run()
        unzip.waitUntilExit()
        let newApp = dir.appendingPathComponent("new/TV Remote.app")
        guard unzip.terminationStatus == 0, Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw TVToolError("The download isn't a TV Remote app.")
        }
        // Paths go in as arguments, never into the script text.
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2.old"
            mv "$2" "$2.old" && mv "$3" "$2" && rm -rf "$2.old"
            open "$2"
            """, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path]
        try swap.run()
        await MainActor.run { NSApp.terminate(nil) }
    }
}
