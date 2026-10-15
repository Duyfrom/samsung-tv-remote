import Foundation

/// DIAL (the protocol phones use to "cast" to the YouTube app): the TV advertises an Application-URL and
/// accepts a POST with the launch payload. This is the only launch path on the 2016 Tizen YouTube app
/// that carries a video – the websocket `DEEP_LINK` launch drops its `metaTag`.
public enum DIAL {
    /// `http://<tv>:8080/ws/app/` on the UA49K5500; read from the device description when possible.
    static func applicationURL(host: String) async -> URL {
        let fallback = URL(string: "http://\(host):8080/ws/app/")!
        var req = URLRequest(url: URL(string: "http://\(host):7678/nservice/")!)
        req.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "Application-URL"),
              let url = URL(string: value), url.host == host else { return fallback }
        return url
    }

    /// POSTs `payload` (e.g. `v=<videoId>&t=0`) to the app; the TV answers 201 and (re)starts the app.
    public static func launch(host: String, app: String, payload: String) async throws {
        let base = await applicationURL(host: host)
        var req = URLRequest(url: base.appendingPathComponent(app))
        req.httpMethod = "POST"
        req.httpBody = Data(payload.utf8)
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard [200, 201].contains(code) else {
            throw TVToolError(code == 404 ? "The TV has no “\(app)” app." : "The TV refused the launch (HTTP \(code)).")
        }
    }
}

public enum YouTube {
    public struct Video: Sendable {
        public let id: String
        public let title: String
        public let channel: String
        public let published: String
    }

    /// 11-character video id from a bare id, a watch URL, youtu.be, shorts, embed or live link.
    public static func videoID(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ x: String) -> Bool {
            x.count == 11 && x.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        if valid(s) { return s }
        guard let url = URLComponents(string: s) else { return nil }
        if let v = url.queryItems?.first(where: { $0.name == "v" })?.value, valid(v) { return v }
        let parts = url.path.split(separator: "/").map(String.init)
        if (url.host ?? "").contains("youtu.be"), let first = parts.first, valid(first) { return first }
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }),
           i + 1 < parts.count, valid(parts[i + 1]) { return parts[i + 1] }
        return nil
    }

    /// The newest regular upload (Shorts skipped) from a channel's public RSS feed – no API key needed.
    public static func latestVideo(channel query: String) async throws -> Video {
        let id = try await channelID(for: query)
        let feed = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")!
        let (data, _) = try await session.data(from: feed)
        let xml = String(decoding: data, as: UTF8.self)
        let sections = xml.components(separatedBy: "<entry>")
        let channelTitle = match("<title>([^<]*)</title>", in: sections[0]).map(unescape) ?? query
        for entry in sections.dropFirst() where !entry.contains("/shorts/") {
            guard let videoID = match("<yt:videoId>([^<]+)</yt:videoId>", in: entry) else { continue }
            return Video(id: videoID,
                         title: match("<title>([^<]*)</title>", in: entry).map(unescape) ?? videoID,
                         channel: channelTitle,
                         published: String((match("<published>([^<]+)</published>", in: entry) ?? "").prefix(10)))
        }
        throw TVToolError("No videos found for “\(query)”.")
    }

    // MARK: - Channel lookup

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1"]
        return URLSession(configuration: config)
    }()

    /// Accepts a channel id (`UC…`), an `@handle`, a channel/handle URL, or a plain name used as the handle.
    static func channelID(for query: String) async throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = match("(UC[\\w-]{22})", in: q) { return id }
        var handle = match("(@[\\w.\\-]+)", in: q)
        if handle == nil {
            let simple = q.lowercased().filter { $0.isLetter || $0.isNumber || "_-.".contains($0) }
            handle = simple.isEmpty ? nil : "@" + simple
        }
        guard let handle, let path = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.youtube.com/\(path)") else {
            throw TVToolError("Which channel? Give an @handle such as @mkbhd.")
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TVToolError("No YouTube channel \(handle). Give the channel's @handle, its id, or a video URL.")
        }
        let html = String(decoding: data, as: UTF8.self)
        if let id = match("channel_id=(UC[\\w-]{22})", in: html) ?? match("\"externalId\":\"(UC[\\w-]{22})\"", in: html) {
            return id
        }
        throw TVToolError("Couldn't read the channel id for \(handle).")
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
