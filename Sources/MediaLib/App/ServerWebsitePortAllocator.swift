import Darwin
import Foundation

/// Finds a free loopback HTTP port without touching the legacy TLS listener.
enum ServerWebsitePortAllocator {
    static func availablePort(excluding legacyTLSPort: Int) -> Int? {
        selectPort(excluding: legacyTLSPort, isAvailable: canBindLoopback)
    }

    static func selectPort(excluding legacyTLSPort: Int, isAvailable: (Int) -> Bool) -> Int? {
        for port in 8098...10_097 where port != legacyTLSPort {
            if isAvailable(port) { return port }
        }
        return nil
    }

    private static func canBindLoopback(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
