import XCTest

final class LayeringPlanDocumentationTests: XCTestCase {
    func testLayeringPlanDocumentsSplitBoundariesWhenDocsAreAvailable() throws {
        let root = repositoryRoot()
        try skipIfDocumentationIsUnavailable(root: root)
        let planURL = root.appendingPathComponent("doc/Architecture/Layering_Refactor_Plan.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: planURL.path),
            "Missing documentation artifact: doc/Architecture/Layering_Refactor_Plan.md"
        )
        let plan = try String(contentsOf: planURL, encoding: .utf8)

        XCTAssertTrue(plan.contains("MediaLibCore"))
        XCTAssertTrue(plan.contains("TaskCenterStore"))
        XCTAssertTrue(plan.contains("ScanActivityStore"))
        XCTAssertTrue(plan.contains("MusicQueueStore"))
        XCTAssertTrue(plan.contains("PlaybackSessionStore"))
        XCTAssertTrue(plan.contains("LibraryDomainStore"))
        XCTAssertTrue(plan.contains("RemoteConnectorStore"))
        XCTAssertTrue(plan.contains("PlaybackQueuePolicy"))
        XCTAssertTrue(plan.contains("PlaybackTimelinePolicy"))
        XCTAssertTrue(plan.contains("PlaybackSeekState"))
        XCTAssertTrue(plan.contains("PlaybackClockPolicy"))
        XCTAssertTrue(plan.contains("PlaybackSeekCoordinator"))
        XCTAssertTrue(plan.contains("PendingPlaybackSeek"))
        XCTAssertTrue(plan.contains("PlaybackSeekCommandPolicy"))
        XCTAssertTrue(plan.contains("PlaybackClockSnapshot"))
        XCTAssertTrue(plan.contains("VideoPlaybackControlling"))
        XCTAssertTrue(plan.contains("VideoPlaybackStateProjecting"))
        XCTAssertTrue(plan.contains("MpvTrack"))
        XCTAssertTrue(plan.contains("MpvVideoSnapshotReader"))
        XCTAssertTrue(plan.contains("TrackLanguageMatcher"))
        XCTAssertTrue(plan.contains("VideoPlaybackEngine"))
        XCTAssertTrue(plan.contains("VideoTrackSelectionEngine"))
        XCTAssertTrue(plan.contains("VideoFrameCommandEngine"))
        XCTAssertTrue(plan.contains("VideoLoopCommandEngine"))
        XCTAssertTrue(plan.contains("VideoAudioDeviceReader"))
        XCTAssertTrue(plan.contains("MusicPlaybackEngine"))
        XCTAssertTrue(plan.contains("防 god object"))
    }

    private func skipIfDocumentationIsUnavailable(root: URL) throws {
        let docsDirectory = root.appendingPathComponent("doc", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docsDirectory.path) else {
            throw XCTSkip("doc/ is not available in this environment; documentation checks are local-only.")
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
