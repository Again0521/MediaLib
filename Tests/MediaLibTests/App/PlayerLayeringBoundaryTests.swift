import XCTest

final class PlayerLayeringBoundaryTests: XCTestCase {
    func testPlayerViewNoLongerOwnsMpvControllerImplementation() throws {
        let root = repositoryRoot()
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(playerView.contains("final class MpvPlayerController"))
        XCTAssertTrue(controller.contains("final class MpvPlayerController"))
        XCTAssertFalse(controller.contains("struct PlayerView: View"))
    }

    func testVideoPlaybackControllingCommandSurfaceLivesInAppLayer() throws {
        let root = repositoryRoot()
        let protocolFile = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPlaybackControlling.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(protocolFile.contains("protocol VideoPlaybackControlling"))
        XCTAssertTrue(protocolFile.contains("extension MpvPlayerController: VideoPlaybackControlling"))
        XCTAssertTrue(playerView.contains("VideoPlaybackControlling"))
        XCTAssertFalse(playerView.contains("protocol VideoPlaybackControlling"))
    }

    func testVideoPlaybackEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPlaybackEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoPlaybackEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoPlaybackEngine"))
        XCTAssertTrue(engine.contains("protocol MpvCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("subtitle"))
        XCTAssertFalse(engine.contains("screenshot"))
        XCTAssertFalse(engine.contains("render("))
    }

    func testPlayerStateProjectionIsGenericAndKeepsControllerCompatibilityAlias() throws {
        let root = repositoryRoot()
        let support = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerControllerSupport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(support.contains("protocol PlayerStateProjecting"))
        XCTAssertTrue(support.contains("final class PlayerStateProjection<Controller: PlayerStateProjecting, Value: Equatable>"))
        XCTAssertTrue(support.contains("typealias PlayerControllerProjection<Value: Equatable> = PlayerStateProjection<MpvPlayerController, Value>"))
        XCTAssertFalse(support.contains("import AppKit"))
        XCTAssertFalse(support.contains("import SwiftUI"))
        XCTAssertFalse(support.contains("LibMpvClient"))
    }

    func testPlaybackQueuePolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackQueuePolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackQueuePolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackTimelinePolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackTimelinePolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackTimelinePolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackClockPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackClockPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackClockPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackSeekStateStaysInCoreWithoutPlatformImportsOrViewOwnership() throws {
        let root = repositoryRoot()
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )
        let seekState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekState.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(playerView.contains("struct PlaybackSeekState"))
        XCTAssertTrue(seekState.contains("struct PlaybackSeekState"))
        XCTAssertFalse(seekState.contains("import AppKit"))
        XCTAssertFalse(seekState.contains("import SwiftUI"))
        XCTAssertFalse(seekState.contains("import AVKit"))
        XCTAssertFalse(seekState.contains("LibMpvClient"))
    }

    func testPlaybackSeekCoordinatorStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(coordinator.contains("enum PlaybackSeekCoordinator"))
        XCTAssertFalse(coordinator.contains("import AppKit"))
        XCTAssertFalse(coordinator.contains("import SwiftUI"))
        XCTAssertFalse(coordinator.contains("import AVKit"))
        XCTAssertFalse(coordinator.contains("LibMpvClient"))
    }

    func testPendingPlaybackSeekStaysInCoreWithoutPlatformImportsOrControllerPrivateOwnership() throws {
        let root = repositoryRoot()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let pending = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PendingPlaybackSeek.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(controller.contains("struct PendingTimelineSeek"))
        XCTAssertTrue(pending.contains("struct PendingPlaybackSeek"))
        XCTAssertFalse(pending.contains("import AppKit"))
        XCTAssertFalse(pending.contains("import SwiftUI"))
        XCTAssertFalse(pending.contains("import AVKit"))
        XCTAssertFalse(pending.contains("LibMpvClient"))
    }

    func testPlaybackSeekCommandPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekCommandPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackSeekCommandPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackClockSnapshotPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackClockSnapshotPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackClockSnapshotPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testAppStateLibraryRemoteSessionScanAndTaskCenterStateAreOwnedByDomainStores() throws {
        let root = repositoryRoot()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("let libraryDomain = LibraryDomainStore()"))
        XCTAssertTrue(appState.contains("let remoteConnectorStore = RemoteConnectorStore()"))
        XCTAssertTrue(appState.contains("let playbackSession = PlaybackSessionStore()"))
        XCTAssertTrue(appState.contains("let scanActivity = ScanActivityStore()"))
        XCTAssertTrue(appState.contains("let taskCenter = TaskCenterStore()"))
        XCTAssertTrue(appState.contains("let musicQueueStore = MusicQueueStore()"))
        XCTAssertFalse(appState.contains("@Published var sources"))
        XCTAssertFalse(appState.contains("@Published var items"))
        XCTAssertFalse(appState.contains("@Published private(set) var libraryRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var posterRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var favoriteRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var watchlistRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var ratingRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var videoCacheRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var musicProjectionRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var musicContentRevision"))
        XCTAssertFalse(appState.contains("@Published var remoteConnectorAccounts"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingEmby"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingJellyfin"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingPlex"))
        XCTAssertFalse(appState.contains("@Published var activePlayerItem"))
        XCTAssertFalse(appState.contains("@Published var videoQueue"))
        XCTAssertFalse(appState.contains("@Published var playbackCommandRequest"))
        XCTAssertFalse(appState.contains("@Published var scanProgress"))
        XCTAssertFalse(appState.contains("@Published var isScanning"))
        XCTAssertFalse(appState.contains("@Published var scanQueueCount"))
        XCTAssertFalse(appState.contains("@Published private(set) var backgroundTasks"))
        XCTAssertFalse(appState.contains("@Published var musicQueue"))
        XCTAssertFalse(appState.contains("@Published var musicRepeatMode"))
        XCTAssertFalse(appState.contains("@Published var musicShuffleEnabled"))
    }

    func testLayeringPlanDocumentsNextSplitBoundaries() throws {
        let root = repositoryRoot()
        let plan = try String(
            contentsOf: root.appendingPathComponent("doc/Architecture/Layering_Refactor_Plan.md"),
            encoding: .utf8
        )

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
        XCTAssertTrue(plan.contains("VideoPlaybackEngine"))
        XCTAssertTrue(plan.contains("防 god object"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
