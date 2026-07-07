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

    func testVideoTrackSelectionEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoTrackSelectionEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoTrackSelectionEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoTrackSelectionEngine"))
        XCTAssertTrue(engine.contains("protocol MpvTrackSelectionTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvTrackSelectionTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("schedule"))
        XCTAssertFalse(engine.contains("screenshot"))
        XCTAssertFalse(engine.contains("vf"))
    }

    func testVideoFrameCommandEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoFrameCommandEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoFrameCommandEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoFrameCommandEngine"))
        XCTAssertTrue(engine.contains("protocol MpvFrameCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvFrameCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("MpvRenderSurface"))
        XCTAssertFalse(engine.contains("captureFramePNGData"))
        XCTAssertFalse(engine.contains("renderView"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("FileManager"))
    }

    func testVideoLoopCommandEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoLoopCommandEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoLoopCommandEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoLoopCommandEngine"))
        XCTAssertTrue(engine.contains("protocol MpvLoopCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvLoopCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("MpvRenderSurface"))
        XCTAssertFalse(engine.contains("PlayerABLoopSelection"))
        XCTAssertFalse(engine.contains("currentTime"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("FileManager"))
        XCTAssertFalse(engine.contains("vf"))
        XCTAssertFalse(engine.contains("screenshot"))
    }

    func testVideoAudioDeviceReaderLivesInAppLayerAndStaysReadOnly() throws {
        let root = repositoryRoot()
        let reader = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoAudioDeviceReader.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reader.contains("struct MpvAudioDevice"))
        XCTAssertTrue(reader.contains("struct VideoAudioDeviceSnapshot"))
        XCTAssertTrue(reader.contains("protocol VideoAudioDeviceReading"))
        XCTAssertTrue(reader.contains("final class MpvVideoAudioDeviceReader"))
        XCTAssertTrue(reader.contains("protocol MpvAudioDeviceReadTransport"))
        XCTAssertTrue(reader.contains("extension LibMpvClient: MpvAudioDeviceReadTransport"))
        XCTAssertFalse(reader.contains("import SwiftUI"))
        XCTAssertFalse(reader.contains("import AppKit"))
        XCTAssertFalse(reader.contains("import AVKit"))
        XCTAssertFalse(reader.contains("command("))
        XCTAssertFalse(reader.contains("setString"))
        XCTAssertFalse(reader.contains("setDouble"))
        XCTAssertFalse(reader.contains("TrackPreferenceStore"))
        XCTAssertFalse(reader.contains("schedule"))
        XCTAssertFalse(reader.contains("MpvRenderSurface"))
        XCTAssertFalse(reader.contains("screenshot"))
        XCTAssertFalse(reader.contains("vf"))
    }

    func testMpvTrackModelLivesInAppLayerInsteadOfPlayerView() throws {
        let root = repositoryRoot()
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvTrack.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(model.contains("struct MpvTrack"))
        XCTAssertTrue(model.contains("enum Kind"))
        XCTAssertTrue(model.contains("func withSelection"))
        XCTAssertFalse(playerView.contains("struct MpvTrack"))
        XCTAssertFalse(model.contains("import SwiftUI"))
        XCTAssertFalse(model.contains("import AppKit"))
        XCTAssertFalse(model.contains("import AVKit"))
        XCTAssertFalse(model.contains("MpvRenderSurface"))
        XCTAssertFalse(model.contains("MpvPlayerController"))
    }

    func testMpvVideoSnapshotReaderLivesInAppLayerWithoutViewOrRenderOwnership() throws {
        let root = repositoryRoot()
        let reader = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvVideoSnapshotReader.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reader.contains("struct MpvChapter"))
        XCTAssertTrue(reader.contains("struct MpvVideoSnapshotRequest"))
        XCTAssertTrue(reader.contains("final class MpvVideoSnapshotReader"))
        XCTAssertFalse(controller.contains("final class MpvVideoSnapshotReader"))
        XCTAssertFalse(controller.contains("struct MpvVideoSnapshotRequest"))
        XCTAssertFalse(reader.contains("import SwiftUI"))
        XCTAssertFalse(reader.contains("import AppKit"))
        XCTAssertFalse(reader.contains("import AVKit"))
        XCTAssertFalse(reader.contains("MpvRenderSurface"))
        XCTAssertFalse(reader.contains("NSView"))
        XCTAssertFalse(reader.contains("captureFramePNGData"))
        XCTAssertFalse(reader.contains("PlayerView"))
        XCTAssertFalse(reader.contains("TrackPreferenceStore"))
    }

    func testTrackLanguageMatcherLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let matcher = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/TrackLanguageMatcher.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(matcher.contains("enum TrackLanguageMatcher"))
        XCTAssertTrue(matcher.contains("static func bestTrack"))
        XCTAssertFalse(controller.contains("private enum TrackLanguageMatcher"))
        XCTAssertFalse(matcher.contains("import SwiftUI"))
        XCTAssertFalse(matcher.contains("import AppKit"))
        XCTAssertFalse(matcher.contains("import AVKit"))
        XCTAssertFalse(matcher.contains("LibMpvClient"))
        XCTAssertFalse(matcher.contains("TrackPreferenceStore"))
        XCTAssertFalse(matcher.contains("ObservableObject"))
        XCTAssertFalse(matcher.contains("@Published"))
        XCTAssertFalse(matcher.contains("command("))
        XCTAssertFalse(matcher.contains("setString"))
        XCTAssertFalse(matcher.contains("NSView"))
    }

    func testMemoryAudioAssetLivesInAppLayerWithoutControllerUIOrMpvOwnership() throws {
        let root = repositoryRoot()
        let asset = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MemoryAudioAsset.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(asset.contains("final class MemoryAudioResourceLoader"))
        XCTAssertTrue(asset.contains("struct MemoryAudioAsset"))
        XCTAssertTrue(asset.contains("enum MemoryAudioResourceLoadingPolicy"))
        XCTAssertFalse(controller.contains("final class MemoryAudioResourceLoader"))
        XCTAssertFalse(controller.contains("private struct MemoryAudioAsset"))
        XCTAssertFalse(asset.contains("import SwiftUI"))
        XCTAssertFalse(asset.contains("import AppKit"))
        XCTAssertFalse(asset.contains("LibMpvClient"))
        XCTAssertFalse(asset.contains("ObservableObject"))
        XCTAssertFalse(asset.contains("@Published"))
        XCTAssertFalse(asset.contains("MpvRenderSurface"))
        XCTAssertFalse(asset.contains("TrackPreferenceStore"))
        XCTAssertFalse(asset.contains("command("))
        XCTAssertFalse(asset.contains("setString"))
    }

    func testMusicPlaybackEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MusicPlaybackEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol MusicPlaybackEngine"))
        XCTAssertTrue(engine.contains("final class AVQueueMusicPlaybackEngine"))
        XCTAssertTrue(engine.contains("protocol MusicPlayerTransport"))
        XCTAssertTrue(engine.contains("final class AVQueueMusicPlayerTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("preload"))
        XCTAssertFalse(engine.contains("RouteProxy"))
        XCTAssertFalse(engine.contains("AirPlay"))
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

    func testMusicOutputPolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/MusicOutputPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum MusicOutputPolicy"))
        XCTAssertTrue(policy.contains("effectiveVolume"))
        XCTAssertTrue(policy.contains("softFadeScale"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
    }

    func testMusicPlaybackBufferPolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/MusicPlaybackBufferPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum MusicPlaybackBufferPolicy"))
        XCTAssertTrue(policy.contains("preferredForwardBufferDuration"))
        XCTAssertTrue(policy.contains("prefersPreciseTiming"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
    }

    func testCyclicModePolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/CyclicModePolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum CyclicModePolicy"))
        XCTAssertTrue(policy.contains("next<"))
        XCTAssertTrue(policy.contains("previous<"))
        XCTAssertFalse(controller.contains("private func nextMode"))
        XCTAssertFalse(playerView.contains("private func nextMode"))
        XCTAssertFalse(controller.contains("modes[(index + delta) % modes.count]"))
        XCTAssertFalse(playerView.contains("modes[(index + (clockwise ? 1 : modes.count - 1)) % modes.count]"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
