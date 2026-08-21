import Foundation
import MediaLibServerProtocol
import XCTest
@testable import MediaLibServer

/// 遥测最重要的性质不是它记了什么，而是它**记不下**什么：路径、token、上游
/// 地址、标题、用户与客户端地址都不在它的接口上。这些用例把该性质钉死。
final class ServerPlaybackTelemetryTests: XCTestCase {
    func testAggregatesCountsBucketsAndOutcomes() {
        let telemetry = ServerPlaybackTelemetry()
        telemetry.recordRange(
            source: .localFile, requestedByteLength: 32_000, deliveredByteLength: 32_000,
            outcome: .completed, upstreamTimeToFirstByte: nil, totalDuration: 0.010
        )
        telemetry.recordRange(
            source: .remoteUpstream, requestedByteLength: 524_288, deliveredByteLength: 524_288,
            outcome: .completed, upstreamTimeToFirstByte: 0.030, totalDuration: 0.080
        )
        telemetry.recordRange(
            source: .remoteUpstream, requestedByteLength: 8_000_000, deliveredByteLength: 1_024,
            outcome: .clientDisconnected, upstreamTimeToFirstByte: 0.050, totalDuration: 0.060
        )

        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.localRangeCount, 1)
        XCTAssertEqual(snapshot.remoteRangeCount, 2)
        XCTAssertEqual(snapshot.deliveredByteCount, 32_000 + 524_288 + 1_024)
        XCTAssertEqual(snapshot.rangeSizeBuckets[.upTo64KiB], 1)
        XCTAssertEqual(snapshot.rangeSizeBuckets[.upTo1MiB], 1)
        XCTAssertEqual(snapshot.rangeSizeBuckets[.upTo16MiB], 1)
        XCTAssertEqual(snapshot.outcomes[.completed], 2)
        XCTAssertEqual(snapshot.outcomes[.clientDisconnected], 1)
        XCTAssertEqual(snapshot.upstreamTimeToFirstByte.sampleCount, 2)
        XCTAssertEqual(snapshot.rangeCompletion.sampleCount, 3)
    }

    func testSizeBucketBoundaries() {
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 1), .upTo64KiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 65_536), .upTo64KiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 65_537), .upTo256KiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 262_144), .upTo256KiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 1_048_576), .upTo1MiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 4_194_304), .upTo4MiB)
        XCTAssertEqual(ServerRangeSizeBucket(byteLength: 16 * 1_024 * 1_024), .upTo16MiB)
    }

    func testBufferAccountingTracksConcurrentPeakNotCumulativeTraffic() {
        let telemetry = ServerPlaybackTelemetry()
        telemetry.acquiredBuffer(256 * 1_024)
        telemetry.acquiredBuffer(256 * 1_024)
        telemetry.releasedBuffer(256 * 1_024)
        telemetry.acquiredBuffer(256 * 1_024)
        telemetry.releasedBuffer(256 * 1_024)
        telemetry.releasedBuffer(256 * 1_024)

        // 三次共 768 KiB 流过，但同时最多只驻留两块。
        XCTAssertEqual(telemetry.snapshot().peakConcurrentBufferedBytes, 512 * 1_024)
    }

    func testConcurrentRangePeakIsTracked() {
        let telemetry = ServerPlaybackTelemetry()
        telemetry.rangeBegan()
        telemetry.rangeBegan()
        telemetry.rangeBegan()
        telemetry.rangeEnded()
        telemetry.rangeEnded()
        telemetry.rangeBegan()
        XCTAssertEqual(telemetry.snapshot().peakConcurrentRanges, 3)
    }

    func testPercentilesAreOrderedAndBounded() {
        let telemetry = ServerPlaybackTelemetry()
        for milliseconds in 1...200 {
            telemetry.recordRange(
                source: .remoteUpstream, requestedByteLength: 1_024, deliveredByteLength: 1_024,
                outcome: .completed, upstreamTimeToFirstByte: nil,
                totalDuration: Double(milliseconds) / 1_000
            )
        }
        let summary = telemetry.snapshot().rangeCompletion
        XCTAssertEqual(summary.sampleCount, 200)
        XCTAssertLessThanOrEqual(summary.p50Milliseconds, summary.p95Milliseconds)
        XCTAssertLessThanOrEqual(summary.p95Milliseconds, summary.maximumMilliseconds)
        XCTAssertEqual(summary.maximumMilliseconds, 200)
        XCTAssertEqual(summary.p50Milliseconds, 101)
    }

    /// 样本必须有界，否则长时间运行的服务会把内存耗在遥测上。
    func testLatencySamplesAreBounded() {
        let telemetry = ServerPlaybackTelemetry()
        for index in 1...2_000 {
            telemetry.recordRange(
                source: .localFile, requestedByteLength: 1_024, deliveredByteLength: 1_024,
                outcome: .completed, upstreamTimeToFirstByte: nil,
                totalDuration: Double(index) / 1_000
            )
        }
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.localRangeCount, 2_000, "计数不封顶")
        XCTAssertEqual(snapshot.rangeCompletion.sampleCount, 512, "分位数样本必须有界")
    }

    func testResetGivesCleanObservationWindow() {
        let telemetry = ServerPlaybackTelemetry()
        telemetry.recordRange(
            source: .localFile, requestedByteLength: 1_024, deliveredByteLength: 1_024,
            outcome: .completed, upstreamTimeToFirstByte: nil, totalDuration: 0.1
        )
        telemetry.acquiredBuffer(1_024)
        telemetry.reset()
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.localRangeCount, 0)
        XCTAssertEqual(snapshot.remoteRangeCount, 0)
        XCTAssertEqual(snapshot.deliveredByteCount, 0)
        XCTAssertEqual(snapshot.peakConcurrentBufferedBytes, 0)
        XCTAssertTrue(snapshot.outcomes.isEmpty)
    }

    /// 快照 JSON 用字符串键，且不含任何可识别到具体媒体或用户的字段。
    func testSnapshotJSONUsesStringKeysAndCarriesNoIdentifiers() throws {
        let telemetry = ServerPlaybackTelemetry()
        telemetry.recordRange(
            source: .remoteUpstream, requestedByteLength: 524_288, deliveredByteLength: 524_288,
            outcome: .completed, upstreamTimeToFirstByte: 0.02, totalDuration: 0.05
        )
        telemetry.recordTransportReason(.upstreamCredentialAccountScoped)

        let data = try XCTUnwrap(ServerCommandOutput.jsonData(telemetry.snapshot()))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"upTo1MiB\":1"))
        XCTAssertTrue(json.contains("\"completed\":1"))
        XCTAssertTrue(json.contains("\"upstreamCredentialAccountScoped\":1"))
        for forbidden in ["itemID", "item_id", "path", "url", "token", "api_key", "title", "userID", "sessionID"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()), "遥测不得出现 \(forbidden)")
        }

        // 往返一致：管理端与压测脚本读到的结构可被稳定解析。
        let decoded = try JSONDecoder().decode(ServerPlaybackTelemetrySnapshot.self, from: data)
        XCTAssertEqual(decoded.rangeSizeBuckets[.upTo1MiB], 1)
        XCTAssertEqual(decoded.outcomes[.completed], 1)
        XCTAssertEqual(decoded.transportReasons[.upstreamCredentialAccountScoped], 1)
    }
}
