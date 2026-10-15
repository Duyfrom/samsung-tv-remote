import Foundation

/// What the TV tools need from whoever owns the connection: the menu bar app's `TVController`
/// (one persistent connection shared with the UI) or the MCP server's session.
@MainActor
public protocol TVToolHost: AnyObject {
    /// The TV's IP address; throws when no TV is known.
    func resolvedHost() async throws -> String
    /// A connected remote channel, connecting first if needed. Throws when the TV is off or unreachable.
    func readyChannel() async throws -> RemoteChannel
    /// Installed apps in the user's Smart Hub order.
    func installedApps() async throws -> [InstalledApp]
    /// Switches the TV on (Wake-on-LAN) or off; returns what happened.
    func setPower(on: Bool) async throws -> String
}

public struct TVToolError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// A tool definition, serialisable both for the Claude Messages API (`input_schema`) and MCP (`inputSchema`).
public struct TVTool: @unchecked Sendable {
    public let name: String
    public let description: String
    public let schema: [String: Any]

    public var claudeJSON: [String: Any] { ["name": name, "description": description, "input_schema": schema] }
    public var mcpJSON: [String: Any] { ["name": name, "description": description, "inputSchema": schema] }
}

/// The TV control tools shared by the in-app Claude chat and the `tvmcp` MCP server.
@MainActor
public enum TVTools {
    private static func object(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    public static let all: [TVTool] = [
        TVTool(name: "press_keys", description: """
            Press remote control buttons in order (about 0.4 s apart). Names: home, back, exit, up, down, left, \
            right, enter (OK), menu, source, guide, info, tools, search, channelUp, channelDown, previousChannel, \
            channelList, 0-9, red, green, yellow, blue, play, pause, stop, rewind, fastForward, record, mute, \
            volumeUp, volumeDown, power — or any raw Samsung KEY_* code. The screen can't be seen, so menu \
            navigation is blind: prefer launch_app, open_url and shortcuts when they fit.
            """,
            schema: object(["keys": ["type": "array", "items": ["type": "string"], "description": "Button names in order"]],
                           required: ["keys"])),
        TVTool(name: "type_text", description: """
            Type text into the TV's on-screen keyboard (search boxes, browser address bar). Only works while \
            that keyboard is open on the TV.
            """,
            schema: object(["text": ["type": "string"]], required: ["text"])),
        TVTool(name: "list_apps", description: "List the apps installed on the TV, in the user's Smart Hub order.",
               schema: object()),
        TVTool(name: "launch_app", description: """
            Open an installed app by name or id. Names match loosely and ignore case and accents \
            ("fpt" opens FPT Play, "youtube" opens YouTube). Pass `link` to open straight to content: for \
            YouTube a video id or watch URL plays that video.
            """,
            schema: object(["app": ["type": "string", "description": "App name or id"],
                            "link": ["type": "string", "description": "Optional deep link / launch data, e.g. a YouTube video id"]],
                           required: ["app"])),
        TVTool(name: "play_youtube", description: """
            Play a YouTube video on the TV. Give `video` (an 11-character id or a youtube.com / youtu.be URL), \
            or `channel` (an @handle such as @mkbhd, a channel id, or a name that is the channel's handle) to play \
            that channel's most recent video (Shorts skipped). Use this instead of launch_app + key presses for \
            YouTube content. This TV shows a "Who's watching?" picker on every YouTube launch, so the first \
            profile is chosen automatically (set `choose_profile` to false to skip). Returns the title playing.
            """,
            schema: object(["video": ["type": "string"],
                            "channel": ["type": "string"],
                            "choose_profile": ["type": "boolean", "description": "Press OK on the first profile after launch (default true)"]])),
        TVTool(name: "open_url", description: """
            Open a web page in the TV's Web Browser. The 2016 browser is slow and some modern sites don't render.
            """,
            schema: object(["url": ["type": "string"]], required: ["url"])),
        TVTool(name: "set_volume", description: "Set the TV volume (0-100) with `level`, or adjust it with `change` (e.g. 5 or -3).",
               schema: object(["level": ["type": "integer", "minimum": 0, "maximum": 100],
                               "change": ["type": "integer"]])),
        TVTool(name: "mute", description: "Mute or unmute the TV.",
               schema: object(["muted": ["type": "boolean"]], required: ["muted"])),
        TVTool(name: "power", description: "Turn the TV on (Wake-on-LAN, takes a few seconds) or off.",
               schema: object(["state": ["type": "string", "enum": ["on", "off"]]], required: ["state"])),
        TVTool(name: "get_status", description: "Whether the TV is on, its volume and mute state, and which app is in front.",
               schema: object()),
        TVTool(name: "wait", description: "Wait before the next action, e.g. 4-6 seconds for an app to finish opening.",
               schema: object(["seconds": ["type": "number", "minimum": 0.5, "maximum": 15]], required: ["seconds"])),
        TVTool(name: "list_shortcuts", description: """
            List the user's saved shortcuts: named action sequences that reach places the remote can't jump to \
            directly (e.g. a channel inside FPT Play). Check these before navigating inside an app.
            """,
            schema: object()),
        TVTool(name: "run_shortcut", description: "Run a saved shortcut by name.",
               schema: object(["name": ["type": "string"]], required: ["name"])),
        TVTool(name: "save_shortcut", description: """
            Save a sequence of actions as a named shortcut so it can be replayed later, e.g. after a sequence \
            you ran worked and the user asks you to remember it. Each step's value is a key name, text to type, \
            app name or id, URL, or seconds to wait.
            """,
            schema: object([
                "name": ["type": "string"],
                "steps": ["type": "array", "items": object([
                    "action": ["type": "string", "enum": Shortcut.Step.Action.allCases.map(\.rawValue)],
                    "value": ["type": "string"],
                ], required: ["action", "value"])],
            ], required: ["name", "steps"])),
    ]

    /// Runs one tool call; failures come back as text with `isError` so the model can react.
    public static func run(_ name: String, _ input: [String: Any], on host: TVToolHost) async -> (text: String, isError: Bool) {
        do {
            return (try await perform(name, input, on: host), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private static func perform(_ name: String, _ input: [String: Any], on host: TVToolHost) async throws -> String {
        switch name {
        case "press_keys":
            guard let keys = input["keys"] as? [String], !keys.isEmpty else { throw TVToolError("`keys` must be a list of button names.") }
            guard keys.count <= 40 else { throw TVToolError("At most 40 keys per call.") }
            let channel = try await host.readyChannel()
            for key in keys {
                channel.sendKey(TVKey.code(for: key))
                try await Task.sleep(for: .milliseconds(400))
            }
            return "Pressed \(keys.joined(separator: ", "))."

        case "type_text":
            guard let text = input["text"] as? String, !text.isEmpty else { throw TVToolError("`text` is empty.") }
            try await host.readyChannel().sendText(text)
            try await Task.sleep(for: .milliseconds(500))
            return "Typed “\(text)”."

        case "list_apps":
            let apps = try await host.installedApps()
            return apps.map { "\(plain($0.name, max: 60)) (\(plain($0.id, max: 60)))" }.joined(separator: "\n")

        case "launch_app":
            guard let query = input["app"] as? String else { throw TVToolError("Which app?") }
            return try await launch(query, link: input["link"] as? String, on: host)

        case "play_youtube":
            let address = try await host.resolvedHost()
            var id = (input["video"] as? String).flatMap(YouTube.videoID(from:))
            var playing = ""
            if id == nil, let channel = input["channel"] as? String, !channel.isEmpty {
                let video = try await YouTube.latestVideo(channel: channel)
                id = video.id
                playing = "“\(plain(video.title))” by \(plain(video.channel, max: 60)) (\(plain(video.published, max: 10))) "
            }
            guard let id else { throw TVToolError("Give `video` (an id or URL) or `channel` (an @handle).") }
            guard (try? await TVRestClient(host: address, timeout: 2).info()) != nil else {
                throw TVToolError("The TV is off. Turn it on first.")
            }
            try await DIAL.launch(host: address, app: "YouTube", payload: "v=\(id)&t=0")
            var note = ""
            if (input["choose_profile"] as? Bool) != false {
                try await Task.sleep(for: .seconds(4.5)) // the picker appears within a couple of seconds
                try await host.readyChannel().sendKey(.enter)
                note = " Picked the first profile."
            }
            return "Playing \(playing)https://youtu.be/\(id).\(note)"

        case "open_url":
            let url = try webURL(input["url"] as? String ?? "")
            try await host.readyChannel().openURL(url)
            return "Opened \(url) in the TV's Web Browser."

        case "set_volume":
            let rc = RenderingControl(host: try await host.resolvedHost())
            let before = try await rc.volume()
            let target: Int
            if let level = input["level"] as? Int {
                target = level
            } else if let change = input["change"] as? Int {
                target = before + change
            } else {
                throw TVToolError("Give `level` or `change`.")
            }
            try await rc.setVolume(max(0, min(100, target)))
            // Report the old level too, so "put it back" can be undone.
            return "Volume \(before) → \(try await rc.volume())."

        case "mute":
            guard let muted = input["muted"] as? Bool else { throw TVToolError("`muted` must be true or false.") }
            try await RenderingControl(host: try await host.resolvedHost()).setMute(muted)
            return muted ? "Muted." : "Unmuted."

        case "power":
            guard let state = input["state"] as? String, ["on", "off"].contains(state) else { throw TVToolError("`state` must be on or off.") }
            return try await host.setPower(on: state == "on")

        case "get_status":
            return try await status(on: host)

        case "wait":
            let seconds = min(15, max(0.5, (input["seconds"] as? Double) ?? Double(input["seconds"] as? Int ?? 3)))
            try await Task.sleep(for: .seconds(seconds))
            return "Waited \(seconds) s."

        case "list_shortcuts":
            let all = ShortcutStore.load()
            return all.isEmpty ? "No shortcuts saved yet." : all.map { "\($0.name): \($0.summary)" }.joined(separator: "\n")

        case "run_shortcut":
            guard let name = input["name"] as? String, let shortcut = ShortcutStore.find(name) else {
                throw TVToolError("No shortcut named “\(input["name"] as? String ?? "")”. Saved: "
                                  + ShortcutStore.load().map(\.name).joined(separator: ", "))
            }
            try await runShortcut(shortcut, on: host)
            return "Ran shortcut “\(shortcut.name)”."

        case "save_shortcut":
            guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let raw = input["steps"] as? [[String: Any]], !raw.isEmpty else {
                throw TVToolError("Give a `name` and at least one step.")
            }
            let steps = try raw.map { step -> Shortcut.Step in
                guard let action = (step["action"] as? String).flatMap(Shortcut.Step.Action.init(rawValue:)) else {
                    throw TVToolError("Unknown step action \(step["action"] ?? "nil").")
                }
                let value = step["value"] as? String ?? (step["value"].map { "\($0)" } ?? "")
                return Shortcut.Step(action, action == .openURL ? try webURL(value) : value)
            }
            try ShortcutStore.save(Shortcut(name: name, steps: steps))
            return "Saved shortcut “\(name)” (\(steps.count) steps)."

        default:
            throw TVToolError("Unknown tool \(name).")
        }
    }

    // MARK: - Helpers

    /// The one gate for anything the TV's Web Browser will open (open_url, a browser launch link,
    /// shortcut steps): http(s) only.
    nonisolated static func webURL(_ raw: String) throws -> String {
        var url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { throw TVToolError("Which URL?") }
        if !url.contains("://") { url = "https://" + url }
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false else {
            throw TVToolError("Only http and https links can be opened.")
        }
        return parsed.absoluteString
    }

    /// Text from outside (video titles, channel and app names) is handed to the model as data:
    /// flattened to one line and bounded, so it can't smuggle in fake structure or long instructions.
    static func plain(_ value: String, max: Int = 100) -> String {
        let flat = value.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }.joined()
        return String(flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(max))
    }

    public static func runShortcut(_ shortcut: Shortcut, on host: TVToolHost) async throws {
        for step in shortcut.steps {
            switch step.action {
            case .key:
                try await host.readyChannel().sendKey(TVKey.code(for: step.value))
                try await Task.sleep(for: .milliseconds(400))
            case .text:
                try await host.readyChannel().sendText(step.value)
                try await Task.sleep(for: .milliseconds(500))
            case .launchApp:
                _ = try await launch(step.value, on: host)
            case .openURL:
                try await host.readyChannel().openURL(webURL(step.value)) // shortcuts are a file anyone can edit
            case .wait:
                try await Task.sleep(for: .seconds(min(20, max(0, Double(step.value) ?? 1))))
            }
        }
    }

    private static func launch(_ query: String, link: String? = nil, on host: TVToolHost) async throws -> String {
        let apps = try await host.installedApps()
        guard let app = findApp(query, in: apps) else {
            throw TVToolError("No app matches “\(plain(query, max: 60))”. Installed: "
                              + apps.map { plain($0.name, max: 60) }.joined(separator: ", "))
        }
        // The browser's launch data is a URL: same gate as open_url.
        let meta = app.id == "org.tizen.browser" && !(link ?? "").isEmpty ? try webURL(link!) : (link ?? "")
        try await host.readyChannel().launchApp(app.id, appType: app.appType, metaTag: meta)
        return link == nil ? "Opened \(app.name)." : "Opened \(app.name) with link \(link!)."
    }

    /// Exact id, then name equality, prefix, substring, or the name inside the query ("the fpt play app").
    public static func findApp(_ query: String, in apps: [InstalledApp]) -> InstalledApp? {
        let q = ShortcutStore.fold(query)
        guard !q.isEmpty else { return nil }
        let names = apps.map { ($0, ShortcutStore.fold($0.name)) }
        return apps.first { $0.id == query }
            ?? names.first { $0.1 == q }?.0
            ?? names.first { $0.1.hasPrefix(q) }?.0
            ?? names.first { $0.1.contains(q) }?.0
            ?? names.first { q.contains($0.1) }?.0
    }

    private static func status(on host: TVToolHost) async throws -> String {
        let address = try await host.resolvedHost()
        guard let info = try? await TVRestClient(host: address, timeout: 2).info() else {
            return "The TV at \(address) is off or unreachable."
        }
        var parts = ["\(info.name) (\(info.modelName)) is on at \(address)."]
        let rc = RenderingControl(host: address)
        if let volume = try? await rc.volume() {
            parts.append("Volume \(volume)\((try? await rc.isMuted()) == true ? ", muted" : "").")
        }
        if let apps = try? await host.installedApps() {
            let front = await withTaskGroup(of: String?.self) { group in
                for app in apps {
                    group.addTask {
                        let status = try? await TVRestClient(host: address, timeout: 2).appStatus(app.id)
                        return status?.visible == true ? app.name : nil
                    }
                }
                var names: [String] = []
                for await name in group { if let name { names.append(name) } }
                return names
            }
            parts.append(front.isEmpty
                ? "No Smart Hub web app is in front: it's TV/HDMI input, the home screen or a built-in app like the Web Browser."
                : "In front: \(front.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
