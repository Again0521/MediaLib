import Darwin
import Foundation
import XCTest
@testable import MediaLibServer

final class ServerRemoteAssetFetcherCancellationTests: XCTestCase {
    func testMetadataCancellationStopsAnActiveURLSessionWait() throws {
        let upstream = try HangingMetadataServer()
        defer { upstream.shutDown() }
        let fetcher = ServerRemoteAssetFetcher()
        let cancellation = ServerRemoteAssetFetcher.Cancellation()
        let result = LockedRemoteMetadataResult()
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = fetcher.metadataBytes(
                url: upstream.url,
                maximumByteLength: 1_024,
                accept: "text/vtt",
                cancellation: cancellation
            )
            completion.leave()
        }

        XCTAssertEqual(upstream.accepted.wait(timeout: .now() + 2), .success)
        let cancelledAt = Date()
        cancellation.cancel()
        XCTAssertEqual(completion.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        XCTAssertNil(result.value)
    }

    func testCancellationBeforeMetadataRequestDoesNotInvokeOverride() {
        let calls = LockedRemoteMetadataCounter()
        let fetcher = ServerRemoteAssetFetcher(responseOverride: { _, _, _ in
            calls.increment()
            return Data("WEBVTT\n\n".utf8)
        })
        let cancellation = ServerRemoteAssetFetcher.Cancellation()
        cancellation.cancel()

        XCTAssertNil(fetcher.metadataBytes(
            url: URL(string: "https://media.example/subtitle.vtt?token=SECRET")!,
            maximumByteLength: 1_024,
            cancellation: cancellation
        ))
        XCTAssertEqual(calls.value, 0)
    }

    func testMediaCancellationStopsAnActiveRangeAndClassifiesSessionTeardown() throws {
        let upstream = try HangingMetadataServer()
        defer { upstream.shutDown() }
        let telemetry = ServerPlaybackTelemetry()
        let fetcher = ServerRemoteAssetFetcher(telemetry: telemetry)
        let cancellation = ServerRemoteAssetFetcher.Cancellation()
        let result = LockedBooleanResult(true)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = fetcher.streamMediaBytes(
                url: upstream.url,
                offset: 5 * 1_024 * 1_024 * 1_024,
                length: 1_024,
                cancellation: cancellation
            ) { _ in true }
            completion.leave()
        }

        XCTAssertEqual(upstream.accepted.wait(timeout: .now() + 2), .success)
        let cancelledAt = Date()
        cancellation.cancel()
        XCTAssertEqual(completion.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        XCTAssertFalse(result.value)
        XCTAssertEqual(telemetry.snapshot().outcomes[.clientDisconnected], 1)
    }

    func testMediaRangeArithmeticRejectsInt64OverflowBeforeInvokingUpstream() {
        let calls = LockedRemoteMetadataCounter()
        let fetcher = ServerRemoteAssetFetcher(responseOverride: { _, _, _ in
            calls.increment()
            return Data(repeating: 0, count: 2)
        })

        XCTAssertFalse(fetcher.streamMediaBytes(
            url: URL(string: "https://media.example/video.mkv?token=SECRET")!,
            offset: Int64.max,
            length: 2
        ) { _ in true })
        XCTAssertFalse(fetcher.streamMediaBytes(
            url: URL(string: "https://media.example/video.mkv?token=SECRET")!,
            offset: Int64.max,
            length: 1
        ) { _ in true })
        XCTAssertEqual(calls.value, 0)
    }
}

private final class LockedBooleanResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) { storedValue = value }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedRemoteMetadataResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?

    var value: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedRemoteMetadataCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

/// Accepts one HTTP connection and deliberately never sends response headers.
/// Without active URLSession cancellation the fetcher would wait its complete
/// 12-second metadata timeout, making the test fail its one-second bound.
final class HangingMetadataServer: @unchecked Sendable {
    enum FixtureError: Error { case socket }

    let url: URL
    let accepted = DispatchSemaphore(value: 0)
    private let listener: Int32
    private let queue = DispatchQueue(label: "MediaLibTests.HangingMetadata")
    private let lock = NSLock()
    private var client: Int32 = -1
    private var stopped = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureError.socket }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(descriptor)
            throw FixtureError.socket
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw FixtureError.socket
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0,
              let endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))/subtitle.vtt")
        else {
            close(descriptor)
            throw FixtureError.socket
        }
        listener = descriptor
        url = endpoint
        queue.async { [weak self] in self?.serve() }
    }

    func shutDown() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let activeClient = client
        client = -1
        lock.unlock()
        if activeClient >= 0 {
            _ = Darwin.shutdown(activeClient, SHUT_RDWR)
            close(activeClient)
        }
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func serve() {
        let acceptedClient = accept(listener, nil, nil)
        guard acceptedClient >= 0 else { return }
        lock.lock()
        if stopped {
            lock.unlock()
            close(acceptedClient)
            return
        }
        client = acceptedClient
        lock.unlock()
        accepted.signal()

        var byte: UInt8 = 0
        while recv(acceptedClient, &byte, 1, 0) == 1 {}
        lock.lock()
        let ownsDescriptor = client == acceptedClient
        if ownsDescriptor { client = -1 }
        lock.unlock()
        if ownsDescriptor { close(acceptedClient) }
    }
}
