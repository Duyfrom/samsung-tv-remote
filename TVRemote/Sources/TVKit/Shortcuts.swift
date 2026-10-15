import Foundation

/// A named, replayable sequence of remote actions, e.g. "VTV1" = open FPT Play, wait, arrows, OK.
/// Recorded in the app or saved by Claude; shared by the app and the MCP server through one JSON file.
public struct Shortcut: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var steps: [Step]

    public struct Step: Codable, Hashable, Sendable {
        public enum Action: String, Codable, CaseIterable, Sendable {
            case key, text, launchApp = "launch_app", openURL = "open_url", wait
        }
        public var action: Action
        /// Key name, text to type, app name or id, URL, or seconds to wait.
        public var value: String

        public init(_ action: Action, _ value: String) {
            self.action = action
            self.value = value
        }
    }

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    public var summary: String {
        steps.map { $0.action == .wait ? "wait \($0.value)s" : "\($0.action.rawValue) \($0.value)" }.joined(separator: " → ")
    }
}

public enum ShortcutStore {
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TV Remote/shortcuts.json")
    }

    /// Read fresh each time: the app and the MCP server both write the file.
    public static func load() -> [Shortcut] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
    }

    public static func find(_ name: String) -> Shortcut? {
        load().first { fold($0.name) == fold(name) }
    }

    public static func save(_ shortcut: Shortcut) throws {
        var all = load().filter { fold($0.name) != fold(shortcut.name) }
        all.append(shortcut)
        try write(all)
    }

    public static func delete(_ name: String) throws {
        try write(load().filter { fold($0.name) != fold(name) })
    }

    private static func write(_ all: [Shortcut]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}
