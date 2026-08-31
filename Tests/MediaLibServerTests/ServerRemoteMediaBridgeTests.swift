import Darwin
import Foundation
import XCTest
@testable import MediaLibServer

final class ServerRemoteMediaBridgeTests: XCTestCase {
    func testBridgeUsesRandomPathAndPreservesRangeBeyondFourGiB() throws {
        let totalLength: Int64 = 8 * 1_024 * 1_024 * 1_024
        let lowerBound: Int64 = 5 * 1_024 * 1_024 * 1_024
        let bridge = try XCTUnwrap(makeBridge(byteLength: totalLength))
        defer { bridge.stop() }

        XCTAssertNotEqual(bridge.inputURL.path, "/media")
        XCTAssertEqual(bridge.inputURL.pathComponents.count, 3)
        XCTAssertEqual(bridge.inputURL.pathComponents[1].count, 32)

        let rejected = try request(
            bridge.inputURL,
            head: "HEAD /media HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 404 Not Found\r\n"))

        let response = try request(
            bridge.inputURL,
            head: "HEAD \(bridge.inputURL.path) HTTP/1.1\r\n" +
                "Host: 127.0.0.1\r\n" +
                "Range: bytes=\(lowerBound)-\(lowerBound + 1_023)\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(response.contains("Content-Length: 1024\r\n"))
        XCTAssertTrue(response.contains(
            "Content-Range: bytes \(lowerBound)-\(lowerBound + 1_023)/\(totalLength)\r\n"
        ))
    }

    func testStopShutsDownClientBlockedOnIncompleteRequestHead() throws {
        let bridge = try XCTUnwrap(makeBridge(byteLength: 8 * 1_024 * 1_024 * 1_024))
        let client = try connect(bridge.inputURL)
        defer { close(client) }
        XCTAssertTrue(send(Data("GET \(bridge.inputURL.path) HTTP/1.1\r\n".utf8), to: client))

        let deadline = Date().addingTimeInterval(2)
        while bridge.activeClientCount == 0 && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(bridge.activeClientCount, 1)

        let stoppedAt = Date()
        bridge.stop()
        var byte: UInt8 = 0
        let received = recv(client, &byte, 1, 0)
        XCTAssertLessThanOrEqual(received, 0)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1)

        let cleanupDeadline = Date().addingTimeInterval(2)
        while bridge.activeClientCount != 0 && Date() < cleanupDeadline {
            usleep(5_000)
        }
        XCTAssertEqual(bridge.activeClientCount, 0)
    }

    func testStopCancelsLiveUpstreamRangeInsteadOfWaitingForIdleTimeout() throws {
        let upstream = try HangingMetadataServer()
        defer { upstream.shutDown() }
        let bridge = try XCTUnwrap(makeBridge(
            byteLength: 8 * 1_024 * 1_024 * 1_024,
            remoteURL: upstream.url,
            fetcher: ServerRemoteAssetFetcher()
        ))
        let client = try connect(bridge.inputURL)
        defer { close(client) }
        let lowerBound: Int64 = 5 * 1_024 * 1_024 * 1_024
        XCTAssertTrue(send(Data(
            ("GET \(bridge.inputURL.path) HTTP/1.1\r\n" +
                "Host: 127.0.0.1\r\n" +
                "Range: bytes=\(lowerBound)-\(lowerBound + 1_023)\r\n\r\n").utf8
        ), to: client))
        XCTAssertEqual(upstream.accepted.wait(timeout: .now() + 2), .success)

        let stoppedAt = Date()
        bridge.stop()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while recv(client, &buffer, buffer.count, 0) > 0 {}
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1)

        let deadline = Date().addingTimeInterval(2)
        while bridge.activeClientCount != 0 && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(
            bridge.activeClientCount,
            0,
            "会话 stop 必须主动取消上游任务，不能等待 25 秒 Range 空闲超时"
        )
    }

    private func makeBridge(
        byteLength: Int64,
        remoteURL: URL = URL(string: "https://nas.example/video.mkv?token=SECRET")!,
        fetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher(
            responseOverride: { _, _, _ in nil }
        )
    ) -> ServerRemoteMediaBridge? {
        ServerRemoteMediaBridge(
            asset: ServerMediaAsset(
                id: "large-remote-mkv",
                remoteURL: remoteURL,
                byteLength: byteLength,
                contentType: "video/x-matroska"
            ),
            fetcher: fetcher
        )
    }

    private func connect(_ url: URL) throws -> Int32 {
        guard let port = url.port else { throw BridgeTestError.socket }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw BridgeTestError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(client)
            throw BridgeTestError.socket
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            throw BridgeTestError.socket
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        return client
    }

    private func request(_ url: URL, head: String) throws -> String {
        let client = try connect(url)
        defer { close(client) }
        guard send(Data(head.utf8), to: client) else { throw BridgeTestError.socket }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while true {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        return String(decoding: response, as: UTF8.self)
    }

    private func send(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(client, base.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private enum BridgeTestError: Error { case socket }
