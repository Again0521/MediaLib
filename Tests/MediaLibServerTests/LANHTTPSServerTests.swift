import Foundation
import HummingbirdCore
import HTTPTypes
import MediaLibCore
import NIOCore
import XCTest
@testable import MediaLibServer

final class LANHTTPSServerTests: XCTestCase {
    func testPublicPeersRequireExplicitWANOptIn() {
        guard #available(macOS 14.0, *) else { return }
        XCTAssertFalse(LANHTTPSServer.acceptsClientAddress("203.0.113.7", allowsWANAccess: false))
        XCTAssertTrue(LANHTTPSServer.acceptsClientAddress("203.0.113.7", allowsWANAccess: true))
        XCTAssertTrue(LANHTTPSServer.acceptsClientAddress("192.168.1.2", allowsWANAccess: false))
    }

    func testCallbackBodyFinishesOnlyAfterNormalProducerEOF() async throws {
        guard #available(macOS 14.0, *) else { return }
        let producerFinished = DispatchSemaphore(value: 0)
        let stream = ServerBodyStream(cancel: {}) { consume in
            defer { producerFinished.signal() }
            guard consume(Data("first".utf8)), consume(Data("second".utf8)) else {
                return .cancelled(deliveredByteLength: 0)
            }
            return .completed(deliveredByteLength: 11)
        }
        let state = RecordingBodyWriterState()

        try await LANHTTPSServer.callbackBody(contentLength: 11, stream: stream)
            .write(RecordingBodyWriter(state: state))

        XCTAssertEqual(producerFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(state.body, Data("firstsecond".utf8))
        XCTAssertEqual(state.finishCount, 1)
    }

    func testCallbackBodyPropagatesProducerFailureBeforeFirstChunk() async {
        guard #available(macOS 14.0, *) else { return }
        let stream = ServerBodyStream(cancel: {}) { _ in
            .failed(.upstreamTransport, deliveredByteLength: 0)
        }
        let state = RecordingBodyWriterState()

        do {
            try await LANHTTPSServer.callbackBody(contentLength: 32, stream: stream)
                .write(RecordingBodyWriter(state: state))
            XCTFail("生产者首块前失败不能被当作正常 EOF")
        } catch let error as ServerStreamError {
            XCTAssertEqual(error.failure, .upstreamTransport)
            XCTAssertEqual(error.deliveredByteLength, 0)
            XCTAssertFalse(String(describing: error).contains("token="))
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertEqual(state.body.count, 0)
        XCTAssertEqual(state.finishCount, 0)
    }

    func testCallbackBodyPropagatesProducerFailureAfterOneChunk() async {
        guard #available(macOS 14.0, *) else { return }
        let stream = ServerBodyStream(cancel: {}) { consume in
            guard consume(Data("partial".utf8)) else {
                return .cancelled(deliveredByteLength: 0)
            }
            return .failed(.shortRead(expectedByteLength: 32), deliveredByteLength: 7)
        }
        let state = RecordingBodyWriterState()

        do {
            try await LANHTTPSServer.callbackBody(contentLength: 32, stream: stream)
                .write(RecordingBodyWriter(state: state))
            XCTFail("短流不能被当作正常 EOF")
        } catch let error as ServerStreamError {
            XCTAssertEqual(error.failure, .shortRead(expectedByteLength: 32))
            XCTAssertEqual(error.deliveredByteLength, 7)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertEqual(state.body, Data("partial".utf8))
        XCTAssertEqual(state.finishCount, 0)
    }

    func testCallbackBodyPreservesWriterFailureAndStopsProducer() async {
        guard #available(macOS 14.0, *) else { return }
        let producerFinished = DispatchSemaphore(value: 0)
        let cancelled = LockedBoolean()
        let stream = ServerBodyStream(cancel: { cancelled.value = true }) { consume in
            defer { producerFinished.signal() }
            guard consume(Data("first".utf8)) else { return .cancelled(deliveredByteLength: 0) }
            guard consume(Data("second".utf8)) else { return .cancelled(deliveredByteLength: 5) }
            return .completed(deliveredByteLength: 11)
        }
        let state = RecordingBodyWriterState()

        do {
            try await LANHTTPSServer.callbackBody(contentLength: 11, stream: stream)
                .write(RecordingBodyWriter(state: state, failAtWrite: 1))
            XCTFail("writer 失败必须向上传播")
        } catch is RecordingBodyWriterError {
            // Expected: do not replace the socket/write error with a producer error.
        } catch {
            XCTFail("应保留 writer 错误，实际为：\(error)")
        }
        XCTAssertEqual(producerFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(state.finishCount, 0)
    }

    func testCallbackBodyCancellationDuringBackpressureWakesProducer() async {
        guard #available(macOS 14.0, *) else { return }
        let firstWriteStarted = DispatchSemaphore(value: 0)
        let secondProduceAttempted = DispatchSemaphore(value: 0)
        let producerFinished = DispatchSemaphore(value: 0)
        let cancelled = LockedBoolean()
        let stream = ServerBodyStream(cancel: { cancelled.value = true }) { consume in
            defer { producerFinished.signal() }
            guard consume(Data("first".utf8)) else { return .cancelled(deliveredByteLength: 0) }
            secondProduceAttempted.signal()
            guard consume(Data("second".utf8)) else { return .cancelled(deliveredByteLength: 5) }
            return .completed(deliveredByteLength: 11)
        }
        let state = RecordingBodyWriterState()
        let task = Task {
            try await LANHTTPSServer.callbackBody(contentLength: 11, stream: stream)
                .write(RecordingBodyWriter(
                    state: state,
                    firstWriteStarted: firstWriteStarted,
                    writeDelayNanoseconds: 5_000_000_000
                ))
        }

        XCTAssertEqual(firstWriteStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondProduceAttempted.wait(timeout: .now() + 1), .success)
        task.cancel()
        do {
            try await task.value
            XCTFail("取消的 body task 不得正常 finish")
        } catch is CancellationError {
            // Expected cancellation, not producer failure.
        } catch {
            XCTFail("应保留取消语义，实际为：\(error)")
        }
        XCTAssertEqual(producerFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(state.finishCount, 0)
    }

    func testTLSResponsePreservesDeclaredContentLengthForHEADBody() throws {
        guard #available(macOS 14.0, *) else { return }
        let local = LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "video/mp4",
            payload: .data(Data()),
            declaredContentLength: 4_294_967_296,
            additionalHeaders: ["Accept-Ranges: bytes"]
        )
        let translated = LANHTTPSServer.response(from: local)

        XCTAssertEqual(translated.headers[.contentLength], "4294967296")
        XCTAssertEqual(translated.headers[.acceptRanges], "bytes")
    }

    func testTLSFileRangeReadsThroughBoundedLaneAndClosesAfterWriting() async throws {
        guard #available(macOS 14.0, *) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-range-\(UUID().uuidString)")
        let bytes = Data((0..<(600 * 1_024)).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let executor = ServerRequestWorkExecutor(
            passwordLimit: 1,
            generalLimit: 1,
            fileReadLimit: 1,
            mediaStreamLimit: 1
        )
        let local = LocalHTTPResponse(
            statusCode: 206,
            reason: "Partial Content",
            contentType: "video/mp4",
            payload: .fileRange(LocalHTTPFileRange(url: url, offset: 17, length: 530 * 1_024)),
            declaredContentLength: 530 * 1_024,
            additionalHeaders: []
        )
        let state = RecordingBodyWriterState()

        try await LANHTTPSServer.response(from: local, workExecutor: executor).body
            .write(RecordingBodyWriter(state: state))

        XCTAssertEqual(state.body, bytes.subdata(in: 17..<(17 + 530 * 1_024)))
        XCTAssertEqual(state.finishCount, 1)
        let snapshot = await executor.snapshot().fileRead
        XCTAssertEqual(snapshot.limit, 1)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.queued, 0)
        XCTAssertEqual(snapshot.completed, 4, "一次 open/seek 加三个至多 256 KiB 的分块读取")
    }

    func testMediaBackpressureGateBlocksUntilConsumerReleasesSlot() {
        let gate = LANResponseBackpressureGate()
        XCTAssertTrue(gate.acquire())

        let attempted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = LockedBoolean()
        DispatchQueue.global(qos: .userInitiated).async {
            attempted.signal()
            result.value = gate.acquire()
            completed.signal()
        }

        XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
        gate.release()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.value)
        gate.release()
        gate.terminate()
    }

    func testMediaBackpressureTerminationWakesProducerAndIsSticky() {
        let gate = LANResponseBackpressureGate()
        XCTAssertTrue(gate.acquire())

        let attempted = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = LockedBoolean(true)
        DispatchQueue.global(qos: .userInitiated).async {
            attempted.signal()
            result.value = gate.acquire()
            completed.signal()
        }

        XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
        gate.terminate()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(result.value)
        gate.release()
        XCTAssertFalse(gate.acquire(), "终止后的 release 不能重新开放媒体生产器")
    }

    func testLANAddressPolicyAllowsOnlyPrivateAndLoopbackIPv4() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.31.100", "169.254.1.2"] {
            XCTAssertTrue(LANIPv4AddressPolicy.isPrivateOrLoopback(address), address)
        }
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.0.2.1", "::1", "not-an-address"] {
            XCTAssertFalse(LANIPv4AddressPolicy.isPrivateOrLoopback(address), address)
        }
    }

    func testTLSIdentityStoreCreatesStableCAAndPrivateKeyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LANTLSIdentityStore(directory: root)
        let first = try store.loadOrCreate(serverName: "MediaLIB Test", addresses: ["192.168.31.100"])
        let firstCA = try Data(contentsOf: first.certificateAuthority)
        let second = try store.loadOrCreate(serverName: "MediaLIB Test", addresses: ["192.168.31.100"])

        XCTAssertEqual(try Data(contentsOf: second.certificateAuthority), firstCA)
        XCTAssertTrue(try String(contentsOf: second.certificate).contains("BEGIN CERTIFICATE"))
        let attributes = try FileManager.default.attributesOfItem(atPath: second.privateKey.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTLSIdentityStoreRejectsPublicAddress() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try LANTLSIdentityStore(directory: root)
                .loadOrCreate(serverName: "MediaLIB Test", addresses: ["8.8.8.8"])
        )
    }

    func testTLSIdentityStoreKeepsCAWhileRenewingLeafForChangedAddress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-Renewal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LANTLSIdentityStore(directory: root)

        let first = try store.loadOrCreate(
            serverName: "MediaLIB Test",
            addresses: ["192.168.31.100"]
        )
        let caBefore = try Data(contentsOf: first.certificateAuthority)
        let leafBefore = try Data(contentsOf: first.certificate)
        XCTAssertTrue(try certificateDescription(at: first.certificate).contains("IP Address:192.168.31.100"))

        let second = try store.loadOrCreate(
            serverName: "MediaLIB Test",
            addresses: ["192.168.31.101"]
        )
        let caAfter = try Data(contentsOf: second.certificateAuthority)
        let leafAfter = try Data(contentsOf: second.certificate)
        let secondDescription = try certificateDescription(at: second.certificate)

        XCTAssertEqual(caAfter, caBefore, "客户端已信任的 CA 不能随 DHCP 地址变化而轮换")
        XCTAssertNotEqual(leafAfter, leafBefore, "地址变化必须续签叶证书")
        XCTAssertTrue(secondDescription.contains("IP Address:192.168.31.101"))
        XCTAssertFalse(secondDescription.contains("IP Address:192.168.31.100"))
        XCTAssertEqual(try verify(certificate: second.certificate, using: second.certificateAuthority), "OK")
    }

    private func certificateDescription(at url: URL) throws -> String {
        try runOpenSSL(["x509", "-in", url.path, "-noout", "-text"])
    }

    private func verify(certificate: URL, using certificateAuthority: URL) throws -> String {
        let output = try runOpenSSL([
            "verify", "-CAfile", certificateAuthority.path, certificate.path
        ])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(": OK") ? "OK" : output
    }

    private func runOpenSSL(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)
        else { throw LANHTTPSServerTestError.opensslFailed }
        return value
    }
}

private enum LANHTTPSServerTestError: Error {
    case opensslFailed
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool = false) { storedValue = value }

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

private enum RecordingBodyWriterError: Error {
    case failed
}

private final class RecordingBodyWriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBody = Data()
    private var storedWriteCount = 0
    private var storedFinishCount = 0

    var body: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    var finishCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFinishCount
    }

    func record(_ buffer: ByteBuffer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = storedWriteCount
        storedWriteCount += 1
        storedBody.append(contentsOf: buffer.readableBytesView)
        return index
    }

    func recordFinish() {
        lock.lock()
        storedFinishCount += 1
        lock.unlock()
    }
}

private struct RecordingBodyWriter: ResponseBodyWriter {
    let state: RecordingBodyWriterState
    var failAtWrite: Int?
    var firstWriteStarted: DispatchSemaphore?
    var writeDelayNanoseconds: UInt64?

    init(
        state: RecordingBodyWriterState,
        failAtWrite: Int? = nil,
        firstWriteStarted: DispatchSemaphore? = nil,
        writeDelayNanoseconds: UInt64? = nil
    ) {
        self.state = state
        self.failAtWrite = failAtWrite
        self.firstWriteStarted = firstWriteStarted
        self.writeDelayNanoseconds = writeDelayNanoseconds
    }

    mutating func write(_ buffer: ByteBuffer) async throws {
        let writeIndex = state.record(buffer)
        if writeIndex == 0 { firstWriteStarted?.signal() }
        if failAtWrite == writeIndex { throw RecordingBodyWriterError.failed }
        if let writeDelayNanoseconds {
            try await Task.sleep(nanoseconds: writeDelayNanoseconds)
        }
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        state.recordFinish()
    }
}
