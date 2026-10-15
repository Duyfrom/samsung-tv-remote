import Foundation

/// UPnP `RenderingControl:1` on the TV's DLNA renderer (`http://<tv>:9197/dmr`).
///
/// The remote channel only has relative volume keys; this gives absolute volume and mute state,
/// which is what the menu bar slider needs.
public struct RenderingControl: Sendable {
    public let host: String
    public let port: Int
    public let controlPath: String
    private let session: URLSession

    private static let service = "urn:schemas-upnp-org:service:RenderingControl:1"

    public init(host: String, port: Int = 9197, controlPath: String = "/upnp/control/RenderingControl1") {
        self.host = host
        self.port = port
        self.controlPath = controlPath
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        session = URLSession(configuration: config)
    }

    public func volume() async throws -> Int {
        let xml = try await call("GetVolume")
        guard let v = Self.value(of: "CurrentVolume", in: xml).flatMap(Int.init) else { throw RestError.badResponse }
        return v
    }

    public func setVolume(_ volume: Int) async throws {
        try await call("SetVolume", args: "<DesiredVolume>\(max(0, min(100, volume)))</DesiredVolume>")
    }

    public func isMuted() async throws -> Bool {
        let xml = try await call("GetMute")
        return Self.value(of: "CurrentMute", in: xml) == "1"
    }

    public func setMute(_ muted: Bool) async throws {
        try await call("SetMute", args: "<DesiredMute>\(muted ? 1 : 0)</DesiredMute>")
    }

    @discardableResult
    private func call(_ action: String, args: String = "") async throws -> String {
        var req = URLRequest(url: URL(string: "http://\(host):\(port)\(controlPath)")!)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(Self.service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>\
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(Self.service)"><InstanceID>0</InstanceID><Channel>Master</Channel>\(args)</u:\(action)></s:Body>\
            </s:Envelope>
            """.utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RestError.http(code) }
        return String(decoding: data, as: UTF8.self)
    }

    static func value(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
