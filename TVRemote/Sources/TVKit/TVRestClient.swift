import Foundation

/// `GET http://<tv>:8001/api/v2/` – the Multiscreen device description (`ms.device.getInfo` over HTTP).
public struct TVInfo: Sendable, Equatable {
    public let name: String
    /// `Samsung SmartTV` for real TVs.
    public let type: String?
    public let modelName: String
    /// Platform code, e.g. `16_JAZZL_UHD` – the leading digits are the model year.
    public let model: String?
    public let wifiMac: String?
    public let ip: String?
    public let networkType: String?
    public let resolution: String?
    public let os: String?
    /// `"true"` on firmwares that only accept `wss://…:8002` with a token.
    public let tokenAuthSupport: Bool
    /// Only reported by 2017+ firmwares (`on` / `standby`).
    public let powerState: String?

    init(json: [String: Any]) {
        let d = json["device"] as? [String: Any] ?? [:]
        name = (d["name"] as? String ?? json["name"] as? String ?? "Samsung TV")
            .replacingOccurrences(of: "[TV] ", with: "")
        type = d["type"] as? String ?? json["type"] as? String
        modelName = d["modelName"] as? String ?? ""
        model = d["model"] as? String
        wifiMac = (d["wifiMac"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ip = d["ip"] as? String
        networkType = d["networkType"] as? String
        resolution = d["resolution"] as? String
        os = d["OS"] as? String
        tokenAuthSupport = (d["TokenAuthSupport"] as? String) == "true"
        powerState = d["PowerState"] as? String
    }
}

public struct AppStatus: Sendable, Equatable {
    public let id: String
    public let name: String
    public let running: Bool
    public let visible: Bool
}

public enum RestError: LocalizedError {
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "TV answered HTTP \(code)."
        case .badResponse: return "Unexpected answer from the TV."
        }
    }
}

/// REST side of the TV API on port 8001 (plain HTTP even on token firmwares).
public struct TVRestClient: Sendable {
    public let host: String
    public let port: Int
    private let session: URLSession

    public init(host: String, port: Int = 8001, timeout: TimeInterval = 3) {
        self.host = host
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
    }

    private func url(_ path: String) -> URL { URL(string: "http://\(host):\(port)/api/v2/\(path)")! }

    public func info() async throws -> TVInfo {
        TVInfo(json: try await json(url("")))
    }

    /// `nil` means the app is not installed (the TV answers 404).
    public func appStatus(_ id: String) async throws -> AppStatus? {
        do {
            let d = try await json(url("applications/\(id)"))
            return AppStatus(id: d["id"] as? String ?? id, name: d["name"] as? String ?? id,
                             running: d["running"] as? Bool ?? false, visible: d["visible"] as? Bool ?? false)
        } catch RestError.http(404) {
            return nil
        }
    }

    public func launchApp(_ id: String) async throws { try await call("POST", url("applications/\(id)")) }
    public func closeApp(_ id: String) async throws { try await call("DELETE", url("applications/\(id)")) }

    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await call("GET", url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RestError.badResponse }
        return obj
    }

    @discardableResult
    private func call(_ method: String, _ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw RestError.http(code) }
        return data
    }
}
