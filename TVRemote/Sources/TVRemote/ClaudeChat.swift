import Foundation
import TVKit

/// The chat bar's brain: sends what the user types to Claude Haiku 5.5 with the TV tools and runs the
/// tool calls on `TVController.shared` until Claude is done. Raw HTTP – there is no Swift Anthropic SDK.
@MainActor
final class ClaudeChat: ObservableObject {
    struct Line: Identifiable, Equatable {
        enum Kind { case user, assistant, action, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var isBusy = false

    static let shared = ClaudeChat()
    static let model = "claude-haiku-5-5"

    /// The API conversation. Append-only (thinking blocks are bound to the history they were made in);
    /// it is dropped, never edited, when it grows long or a request fails.
    private var history: [[String: Any]] = []
    private var task: Task<Void, Never>?

    private static let system = """
        You are the voice of a TV remote. You control the user's Samsung UA49K5500 (a 2016 Tizen Smart TV) \
        through the tools. Act right away when a request maps to tools; ask only when it is \
        genuinely ambiguous.

        You cannot see the screen. Prefer direct tools — launch_app, open_url, set_volume, mute, power and saved \
        shortcuts — over navigating menus with press_keys. Before navigating inside an app (a channel, a show, \
        a page of a site), call list_shortcuts: the user may have recorded the exact path. If none fits, open the \
        app, wait 4–6 seconds for it to load, try a short best-guess key sequence, and say plainly that you are \
        navigating blind; suggest recording a shortcut with the ● button next to the chat so it works every time. \
        type_text only works while the TV's on-screen keyboard is open. For YouTube content ("play the latest \
        MKBHD video", a video link) use play_youtube – it finds the video itself.

        After acting, reply with one short sentence, written in the same language as the user's latest message \
        (English in, English out; Vietnamese in, Vietnamese out) – app names don't change that.
        """

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        lines.append(Line(kind: .user, text: text))
        if history.count > 40 { history = [] } // start a fresh conversation rather than editing the old one
        history.append(["role": "user", "content": text])
        task = Task { await runLoop() }
    }

    func clear() {
        task?.cancel()
        task = nil
        isBusy = false
        lines = []
        history = []
    }

    private func runLoop() async {
        isBusy = true
        defer { isBusy = false }
        guard let key = APIKey.load() else {
            fail("No Anthropic API key: expected one in ~/.local/share/opencode/auth.json or $ANTHROPIC_API_KEY.")
            return
        }
        let tv = TVController.shared
        for _ in 0..<15 {
            let response: [String: Any]
            do {
                response = try await request(key: key)
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
                return
            }
            guard !Task.isCancelled else { return }
            let content = response["content"] as? [[String: Any]] ?? []
            history.append(["role": "assistant", "content": content])
            for block in content where block["type"] as? String == "text" {
                if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    lines.append(Line(kind: .assistant, text: text))
                }
            }

            switch response["stop_reason"] as? String {
            case "tool_use":
                break
            case "refusal":
                lines.append(Line(kind: .error, text: "Claude declined that request."))
                history = []
                return
            case "max_tokens":
                lines.append(Line(kind: .error, text: "Claude's reply was cut off."))
                history = []
                return
            default:
                return
            }

            // Run the calls in order (the TV needs them sequential) and answer them all in one message.
            var results: [[String: Any]] = []
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                lines.append(Line(kind: .action, text: Self.describe(name, input)))
                let (text, isError) = await TVTools.run(name, input, on: tv)
                guard !Task.isCancelled else { return }
                if isError { lines.append(Line(kind: .error, text: text)) }
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
                if isError { result["is_error"] = true }
                results.append(result)
            }
            history.append(["role": "user", "content": results])
            tv.reloadShortcuts()
            await tv.refreshVolume()
        }
        lines.append(Line(kind: .error, text: "Stopped after too many steps."))
        history = []
    }

    private func fail(_ message: String) {
        lines.append(Line(kind: .error, text: message))
        history = [] // a failed turn leaves the history unbalanced; start over next time
    }

    private func request(key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            // A remote has to feel instant: low effort keeps thinking short.
            "output_config": ["effort": "low"],
            "system": Self.system,
            "tools": TVTools.all.map(\.claudeJSON),
            "messages": history,
            "cache_control": ["type": "ephemeral"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw TVToolError("Claude API: \(message)")
        }
        return json
    }

    /// Short label for the action chips in the transcript.
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "press_keys": return "Keys: " + ((input["keys"] as? [String]) ?? []).joined(separator: " ")
        case "type_text": return "Type “\(input["text"] as? String ?? "")”"
        case "launch_app":
            let app = input["app"] as? String ?? "app"
            return (input["link"] as? String).map { "Open \(app) → \($0)" } ?? "Open \(app)"
        case "open_url": return "Browse \(input["url"] as? String ?? "")"
        case "play_youtube":
            return "YouTube → " + ((input["channel"] as? String) ?? (input["video"] as? String) ?? "video")
        case "set_volume":
            if let level = input["level"] as? Int { return "Volume \(level)" }
            return "Volume \((input["change"] as? Int).map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "")"
        case "mute": return (input["muted"] as? Bool) == false ? "Unmute" : "Mute"
        case "power": return "Power \(input["state"] as? String ?? "")"
        case "wait": return "Wait \(input["seconds"] ?? "")s"
        case "run_shortcut": return "Shortcut “\(input["name"] as? String ?? "")”"
        case "save_shortcut": return "Save shortcut “\(input["name"] as? String ?? "")”"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The Anthropic API key, read when needed from opencode's auth store (or $ANTHROPIC_API_KEY); never copied.
enum APIKey {
    static let opencodeAuth = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")

    static func load() -> String? {
        if let data = try? Data(contentsOf: opencodeAuth),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let anthropic = json["anthropic"] as? [String: Any],
           anthropic["type"] as? String == "api",
           let key = anthropic["key"] as? String, !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var source: String? {
        guard load() != nil else { return nil }
        return (try? Data(contentsOf: opencodeAuth)) != nil ? "opencode" : "ANTHROPIC_API_KEY"
    }
}
