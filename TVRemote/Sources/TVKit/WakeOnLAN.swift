import Foundation

public enum WakeOnLANError: LocalizedError {
    case badMAC(String)
    case socket(Int32)

    public var errorDescription: String? {
        switch self {
        case .badMAC(let mac): return "\"\(mac)\" is not a MAC address."
        case .socket(let err): return "Could not send the wake packet (\(String(cString: strerror(err))))."
        }
    }
}

/// Magic packet sender. The K-series only honours it while the TV is in network standby
/// (shortly after switching off, or with Ethernet + "Power On with Mobile" enabled).
public enum WakeOnLAN {
    public static func wake(mac: String, host: String? = nil) throws {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw WakeOnLANError.badMAC(mac) }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeOnLANError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255"]
        if let host {
            targets.append(host)
            // Directed broadcast for the TV's /24 – some routers drop 255.255.255.255.
            let parts = host.split(separator: ".")
            if parts.count == 4 { targets.append(parts.prefix(3).joined(separator: ".") + ".255") }
        }
        var sent = false
        for target in targets {
            for port: UInt16 in [9, 7] {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                let n = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if n == packet.count { sent = true }
            }
        }
        if !sent { throw WakeOnLANError.socket(errno) }
    }

    /// After ~20 minutes off, this TV only wakes on a magic packet sent straight to its MAC (it ignores
    /// broadcasts), which needs the Mac to still know the TV's address – and macOS forgets it about 20 minutes
    /// after the TV goes quiet. `pinScript` is the root command that pins it; nil unless host is a canonical
    /// local IPv4 address and mac a plain MAC, since it is run with administrator rights.
    public static func pinScript(host: String, mac: String) -> String? {
        let mac = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        guard RemoteChannel.isLocalAddress(host),
              mac.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil else { return nil }
        return "/usr/sbin/arp -n \(host) | /usr/bin/grep -q permanent || /usr/sbin/arp -s \(host) \(mac)"
    }

    /// MAC of a host from the system ARP cache (populated by any recent traffic to it).
    public static func macAddress(for host: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-n", host]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // "? (192.168.50.25) at f8:77:b8:bf:df:bb on en0 ifscope [ethernet]"
        guard let at = out.range(of: " at ") else { return nil }
        let mac = out[at.upperBound...].prefix { $0 != " " }
        let octets = mac.split(separator: ":")
        guard octets.count == 6 else { return nil }
        return octets.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").uppercased()
    }
}
