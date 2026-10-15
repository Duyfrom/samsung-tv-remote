import Foundation

/// Events delivered by the TV on the `samsung.remote.control` channel.
public enum ChannelEvent {
    /// `ms.channel.connect` – the TV accepted us. `token` is only issued on port 8002 (TLS) firmwares.
    case connected(token: String?, clientCount: Int)
    /// `ms.channel.unauthorized` – the user pressed "Deny" on the TV, or the token was rejected.
    case unauthorized
    /// `ms.channel.timeOut` – nobody answered the "Allow" prompt on the TV in time.
    case timeout
    /// `ed.installedApp.get` response (Tizen 3+, not every 2016 firmware answers it).
    case installedApps([InstalledApp])
    /// `ed.apps.icon` response – PNG bytes for an `InstalledApp.icon` path.
    case icon(path: String, png: Data)
    /// `ms.channel.clientConnect` / `clientDisconnect` etc.
    case other(event: String, raw: [String: Any])
    case disconnected(Error?)

    // [String: Any] is not Sendable; the payload is only ever read on the receiving actor.
}

extension ChannelEvent: @unchecked Sendable {}

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let appType: Int
    public let icon: String?
}

public enum ChannelError: LocalizedError {
    case unauthorized
    case timedOut
    case notConnected
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The TV refused the connection. Allow \"Mac Remote\" in TV Settings › General › External Device Manager › Device Connection Manager."
        case .timedOut: return "No answer from the TV. Accept the Allow prompt on the TV screen."
        case .notConnected: return "Not connected to the TV."
        case .closed(let why): return "Connection closed: \(why)"
        }
    }
}

/// WebSocket client for the Samsung Multiscreen (MSF) remote-control channel.
///
/// Protocol (verified against Samsung's MultiscreenWindowsApiCSharp assembly with REA and the
/// public Tizen behaviour of 2016 K-series sets such as the UA49K5500):
///
///     ws://<tv>:8001/api/v2/channels/samsung.remote.control?name=<base64 app name>
///     wss://<tv>:8002/api/v2/channels/samsung.remote.control?name=<base64>&token=<token>
///
/// Messages are JSON `{ "method": "...", "params": { ... } }`.
public final class RemoteChannel: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Transport: Sendable, Equatable {
        case plain      // ws  :8001 – original 2016 firmware
        case secure     // wss :8002 – token auth (later K firmware and every 2017+ set)
        public var port: Int { self == .plain ? 8001 : 8002 }
        public var scheme: String { self == .plain ? "ws" : "wss" }
    }

    public enum KeyAction: String, Sendable { case click = "Click", press = "Press", release = "Release" }

    public let host: String
    public let transport: Transport
    public let appName: String
    public private(set) var token: String?

    public var onEvent: ((ChannelEvent) -> Void)?
    /// Raw traffic trace (`→` sent, `←` received, `✕` errors) for debugging.
    public var log: ((String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let queue = DispatchQueue(label: "tvremote.channel")
    private var connectContinuation: CheckedContinuation<String?, Error>?
    public private(set) var isConnected = false

    public init(host: String, transport: Transport, appName: String = "Mac Remote", token: String? = nil) {
        self.host = host
        self.transport = transport
        self.appName = appName
        self.token = token
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35 // the TV waits up to ~30 s for the user to press Allow
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public var url: URL {
        let name = Data(appName.utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var s = "\(transport.scheme)://\(host):\(transport.port)/api/v2/channels/samsung.remote.control?name=\(name)"
        if let token, !token.isEmpty { s += "&token=\(token)" }
        return URL(string: s)!
    }

    /// Opens the socket and waits for `ms.channel.connect`. Returns the (possibly new) token.
    @discardableResult
    public func connect() async throws -> String? {
        disconnect()
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
        receive(on: task)
        return try await withCheckedThrowingContinuation { cont in
            queue.sync { self.connectContinuation = cont }
        }
    }

    public func disconnect() {
        DispatchQueue.main.async { [pingTimer] in pingTimer?.invalidate() }
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        resolveConnect(.failure(CancellationError()))
    }

    // MARK: - Commands

    public func sendKey(_ key: TVKey, _ action: KeyAction = .click) {
        sendKey(key.rawValue, action)
    }

    public func sendKey(_ code: String, _ action: KeyAction = .click) {
        send([
            "method": "ms.remote.control",
            "params": [
                "Cmd": action.rawValue,
                "DataOfCmd": code,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey",
            ],
        ])
    }

    /// Types text into the currently focused on-screen keyboard (search boxes, browser, YouTube…).
    public func sendText(_ text: String) {
        send([
            "method": "ms.remote.control",
            "params": [
                "Cmd": Data(text.utf8).base64EncodedString(),
                "DataOfCmd": "base64",
                "TypeOfRemote": "SendInputString",
            ],
        ])
    }

    public func endText() {
        send(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    /// Relative pointer movement (browser / apps that show a cursor).
    public func moveMouse(dx: Int, dy: Int) {
        send([
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Move",
                "Position": ["x": dx, "y": dy, "Time": String(Int(Date().timeIntervalSince1970 * 1000))],
                "TypeOfRemote": "ProcessMouseDevice",
            ],
        ])
    }

    public func click(right: Bool = false) {
        send([
            "method": "ms.remote.control",
            "params": ["Cmd": right ? "RightClick" : "LeftClick", "TypeOfRemote": "ProcessMouseDevice"],
        ])
    }

    public func requestInstalledApps() {
        send(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
    }

    /// Asks the TV for the PNG behind `InstalledApp.icon`; answered with `.icon`.
    public func requestIcon(_ path: String) {
        send(["method": "ms.channel.emit", "params": ["event": "ed.apps.icon", "to": "host", "data": ["iconPath": path]]])
    }

    /// Launch over the socket. `appType` 2 = web/DEEP_LINK, 4 = native.
    public func launchApp(_ id: String, appType: Int = 2, metaTag: String = "") {
        send([
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch",
                "to": "host",
                "data": ["appId": id, "action_type": appType == 2 ? "DEEP_LINK" : "NATIVE_LAUNCH", "metaTag": metaTag],
            ],
        ])
    }

    public func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            log?("✕ not sent (no socket): \(object)")
            return
        }
        log?("→ \(text)")
        task.send(.string(text)) { [weak self] error in
            if let error { self?.log?("✕ send: \(error)"); self?.fail(error) }
        }
    }

    // MARK: - Receive

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                switch message {
                case .string(let s): self.log?("← \(s.prefix(300))"); self.handle(Data(s.utf8))
                case .data(let d): self.handle(d)
                @unknown default: break
                }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        let payload = obj["data"] as? [String: Any] ?? [:]

        switch event {
        case "ms.channel.connect":
            let token = payload["token"] as? String
            if let token { self.token = token }
            isConnected = true
            startPing()
            resolveConnect(.success(self.token))
            onEvent?(.connected(token: self.token, clientCount: (payload["clients"] as? [Any])?.count ?? 0))
        case "ms.channel.unauthorized":
            resolveConnect(.failure(ChannelError.unauthorized))
            onEvent?(.unauthorized)
        case "ms.channel.timeOut":
            resolveConnect(.failure(ChannelError.timedOut))
            onEvent?(.timeout)
        case "ed.installedApp.get":
            let list = (payload["data"] as? [[String: Any]]) ?? []
            let apps = list.compactMap { d -> InstalledApp? in
                guard let id = d["appId"] as? String else { return nil }
                return InstalledApp(id: id, name: d["name"] as? String ?? id,
                                    appType: d["app_type"] as? Int ?? 2, icon: d["icon"] as? String)
            }
            onEvent?(.installedApps(apps))
        case "ed.apps.icon":
            if let path = payload["iconPath"] as? String, let b64 = payload["imageBase64"] as? String,
               let png = Data(base64Encoded: b64) {
                onEvent?(.icon(path: path, png: png))
            }
        default:
            onEvent?(.other(event: event, raw: obj))
        }
    }

    private func resolveConnect(_ result: Result<String?, Error>) {
        queue.sync {
            guard let c = connectContinuation else { return }
            connectContinuation = nil
            c.resume(with: result)
        }
    }

    private func fail(_ error: Error) {
        let wasConnected = isConnected
        isConnected = false
        resolveConnect(.failure(error))
        if wasConnected || task != nil { onEvent?(.disconnected(error)) }
        task = nil
    }

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in if let error { self?.fail(error) } }
            }
        }
    }

    // MARK: - URLSession delegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        fail(ChannelError.closed("code \(closeCode.rawValue)"))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, task === self.task else { return }
        fail(error)
    }

    /// The TV presents a self-signed certificate on 8002; only trust it for the TV host.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
