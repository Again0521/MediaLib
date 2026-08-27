import Darwin
import Foundation
import XCTest
@testable import MediaLib
import MediaLibServerProtocol

final class ServerHostControlListenerTests: XCTestCase {
    func testListenerUsesPrivateSocketAuthenticatesTokenAndForwardsNoSecret() throws {
        let applied = expectation(description: "configuration applied")
        let listener = try ServerHostControlListener { configuration in
            XCTAssertEqual(configuration.serverName, "Living Room")
            XCTAssertEqual(configuration.port, 8098)
            applied.fulfill()
        }
        defer { listener.stop() }
        listener.start()

        var socketMetadata = stat()
        XCTAssertEqual(lstat(listener.socketPath, &socketMetadata), 0)
        XCTAssertEqual(socketMetadata.st_uid, geteuid())
        XCTAssertEqual(socketMetadata.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(socketMetadata.st_mode & 0o777, 0o600)
        var directoryMetadata = stat()
        XCTAssertEqual(lstat(URL(fileURLWithPath: listener.socketPath).deletingLastPathComponent().path, &directoryMetadata), 0)
        XCTAssertEqual(directoryMetadata.st_mode & 0o777, 0o700)
        XCTAssertEqual(listener.token.utf8.count, 64)

        let request = ServerHostControlRequest(
            requestID: "request-1",
            token: listener.token,
            action: .applyRuntimeConfiguration,
            configuration: ServerHostRuntimeConfiguration(
                serverName: "Living Room",
                port: 8098,
                networkAccessMode: "loopback",
                publicOrigin: nil,
                trustedProxyAddresses: []
            )
        )
        let responseData = try exchange(request, socketPath: listener.socketPath)
        let response = try JSONDecoder().decode(ServerHostControlResponse.self, from: responseData)
        XCTAssertEqual(response.requestID, "request-1")
        XCTAssertEqual(response.status, .accepted)
        XCTAssertFalse(String(data: responseData, encoding: .utf8)?.contains(listener.token) ?? true)
        wait(for: [applied], timeout: 1)
    }

    func testForgedTokenGetsNoResponseAndDoesNotInvokeHandler() throws {
        let notApplied = expectation(description: "configuration not applied")
        notApplied.isInverted = true
        let listener = try ServerHostControlListener { _ in notApplied.fulfill() }
        defer { listener.stop() }
        listener.start()
        let request = ServerHostControlRequest(
            requestID: "request-forged",
            token: String(repeating: "0", count: 64),
            action: .applyRuntimeConfiguration,
            configuration: ServerHostRuntimeConfiguration(
                serverName: "Forged",
                port: 8098,
                networkAccessMode: "loopback",
                publicOrigin: nil,
                trustedProxyAddresses: []
            )
        )
        XCTAssertThrowsError(try exchange(request, socketPath: listener.socketPath))
        wait(for: [notApplied], timeout: 0.2)
    }

    private func exchange(
        _ request: ServerHostControlRequest,
        socketPath: String
    ) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestSocketError.failed }
        defer { _ = close(descriptor) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            socketPath.withCString { source in
                _ = strlcpy(destination.baseAddress?.assumingMemoryBound(to: CChar.self), source, destination.count)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw TestSocketError.failed }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == payload.count else { throw TestSocketError.failed }
        var result = Data()
        var byte = UInt8()
        while result.count <= 8_192 {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { throw TestSocketError.failed }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        throw TestSocketError.failed
    }
}

private enum TestSocketError: Error { case failed }
