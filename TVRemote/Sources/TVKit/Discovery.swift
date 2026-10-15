import Foundation

public struct DiscoveredTV: Identifiable, Hashable, Sendable {
    public var id: String { host }
    public let host: String
    public let name: String
    public let modelName: String
    public let wifiMac: String?
}

/// Finds TVs by asking every address on the Mac's local /24 for the `/api/v2/` device description.
///
/// Samsung's own clients use SSDP/DIAL first, but the TV drops multicast while it is busy and a
/// direct sweep is both simpler and verifies the API in the same request.
public enum Discovery {
    public static func scan(timeout: TimeInterval = 1.5) async -> [DiscoveredTV] {
        let hosts = localSubnetHosts()
        return await withTaskGroup(of: DiscoveredTV?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let info = try? await TVRestClient(host: host, timeout: timeout).info() else { return nil }
                    return DiscoveredTV(host: host, name: info.name, modelName: info.modelName, wifiMac: info.wifiMac)
                }
            }
            var found: [DiscoveredTV] = []
            for await tv in group { if let tv { found.append(tv) } }
            return found.sorted { $0.host < $1.host }
        }
    }

    /// Every other address in the /24 of each active IPv4 interface (larger subnets are capped to /24).
    static func localSubnetHosts() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Skip link-local 169.254/16.
            if ip >> 16 == 0xA9FE { continue }
            let base = ip & 0xFFFF_FF00
            for last in 1...254 where base | UInt32(last) != ip {
                let a = base | UInt32(last)
                let s = "\(a >> 24).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }
}
