import CryptoKit
import Foundation

/// "Check for updates": the newest release on GitHub whose tag has the app's prefix (mac-v / windows-v),
/// downloaded and checked against the .sha256 file published next to it.
public enum Updates {
    public static let api = URL(string: "https://api.github.com/repos/Duyfrom/samsung-tv-remote/releases?per_page=30")!

    public struct Update: Sendable {
        public let version: String
        public let page: URL?
        let asset: URL
        let checksum: URL
    }

    /// Whether version a (1.2.10) is newer than b.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest published release newer than `current` that carries both the asset and its .sha256.
    public static func pick(_ json: Data, prefix: String, current: String, assetName: (String) -> String) -> Update? {
        guard let releases = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var best: Update?
        for r in releases {
            guard let tag = r["tag_name"] as? String, tag.hasPrefix(prefix),
                  r["draft"] as? Bool != true, r["prerelease"] as? Bool != true else { continue }
            let version = String(tag.dropFirst(prefix.count))
            guard isNewer(version, than: current), best.map({ isNewer(version, than: $0.version) }) ?? true else { continue }
            let assets = r["assets"] as? [[String: Any]] ?? []
            func url(_ name: String) -> URL? {
                (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
            }
            if let asset = url(assetName(version)), let checksum = url(assetName(version) + ".sha256") {
                best = Update(version: version, page: (r["html_url"] as? String).flatMap(URL.init(string:)), asset: asset, checksum: checksum)
            }
        }
        return best
    }

    public static func check(prefix: String, current: String, assetName: (String) -> String) async throws -> Update? {
        var req = URLRequest(url: api, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TVToolError("GitHub didn't answer the update check.") }
        return pick(data, prefix: prefix, current: current, assetName: assetName)
    }

    /// Downloads the update into `dir` and returns it only if its SHA-256 matches the published checksum.
    public static func download(_ update: Update, to dir: URL) async throws -> URL {
        let (sums, _) = try await URLSession.shared.data(from: update.checksum)
        let expected = String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let (tmp, response) = try await URLSession.shared.download(from: update.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TVToolError("The download failed.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(update.asset.lastPathComponent)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        guard matches(file, sha256: expected) else {
            try? FileManager.default.removeItem(at: file)
            throw TVToolError("The download doesn't match its published checksum.")
        }
        return file
    }

    public static func matches(_ file: URL, sha256 expected: String) -> Bool {
        guard let data = try? Data(contentsOf: file), !expected.isEmpty else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }
}
