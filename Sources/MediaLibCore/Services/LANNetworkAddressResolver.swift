import Darwin
import Foundation

public struct LANIPv4InterfaceAddress: Equatable, Sendable {
    public let interfaceName: String
    public let address: String

    public init(interfaceName: String, address: String) {
        self.interfaceName = interfaceName
        self.address = address
    }
}

/// Discovers private IPv4 addresses that are suitable for a household LAN URL.
/// Tunnel and peer-to-peer helper interfaces are excluded so a VPN or AirDrop
/// address cannot silently become the address shown to TVs and phones.
public enum LANNetworkAddressResolver {
    public static func privateIPv4Addresses() -> [LANIPv4InterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var results: [LANIPv4InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let value = current.pointee
            defer { cursor = value.ifa_next }
            guard let address = value.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  value.ifa_flags & UInt32(IFF_UP) != 0,
                  value.ifa_flags & UInt32(IFF_RUNNING) != 0
            else { continue }

            let interfaceName = String(cString: value.ifa_name)
            guard isEligibleInterface(interfaceName) else { continue }
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard withUnsafePointer(to: &socketAddress.sin_addr, { source in
                inet_ntop(AF_INET, source, &buffer, socklen_t(buffer.count))
            }) != nil else { continue }
            let text = String(cString: buffer)
            guard LANIPv4AddressPolicy.isPrivate(text) else { continue }
            let candidate = LANIPv4InterfaceAddress(interfaceName: interfaceName, address: text)
            if !results.contains(candidate) { results.append(candidate) }
        }
        return sortedCandidates(results)
    }

    public static func preferredPrivateIPv4Address() -> String? {
        privateIPv4Addresses().first?.address
    }

    public static func sortedCandidates(
        _ candidates: [LANIPv4InterfaceAddress]
    ) -> [LANIPv4InterfaceAddress] {
        candidates.sorted { lhs, rhs in
            let leftRank = interfaceRank(lhs.interfaceName)
            let rightRank = interfaceRank(rhs.interfaceName)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.interfaceName != rhs.interfaceName {
                return lhs.interfaceName.localizedStandardCompare(rhs.interfaceName) == .orderedAscending
            }
            return lhs.address.localizedStandardCompare(rhs.address) == .orderedAscending
        }
    }

    private static func isEligibleInterface(_ name: String) -> Bool {
        let excludedPrefixes = ["lo", "utun", "awdl", "llw", "gif", "stf"]
        return !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func interfaceRank(_ name: String) -> Int {
        if name.hasPrefix("en") { return 0 }
        if name.hasPrefix("bridge") { return 1 }
        return 2
    }
}

public enum LANIPv4AddressPolicy {
    public static func isPrivate(_ value: String) -> Bool {
        guard let parts = octets(value) else { return false }
        return parts[0] == 10 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 169 && parts[1] == 254)
    }

    public static func isPrivateOrLoopback(_ value: String) -> Bool {
        guard let parts = octets(value) else { return false }
        return parts[0] == 127 || isPrivate(value)
    }

    private static func octets(_ value: String) -> [Int]? {
        let rawParts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard rawParts.count == 4 else { return nil }
        let parts = rawParts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            return value
        }
        return parts.count == 4 ? parts : nil
    }
}
