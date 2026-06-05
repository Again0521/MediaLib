import AppKit
import AVKit
import AVFoundation
import Combine
import MediaLibCore
import OpenGL.GL3
import SwiftUI

enum VideoWindowSizing {
    static let minimumPreferredWidth: CGFloat = 680
    static let minimumControlSafeWidth: CGFloat = 680
    static let minimumControlSafeHeight: CGFloat = 382
    static let minimumScreenWidthRatio: Double = 0.45
    static let maximumScreenWidthRatio: Double = 1.0

    static func maximumPreferredWidth(on screen: NSScreen? = nil) -> CGFloat {
        visibleWidth(on: screen) * CGFloat(maximumScreenWidthRatio)
    }

    static func clampedPreferredWidth(_ width: Double, on screen: NSScreen? = nil) -> CGFloat {
        min(max(CGFloat(width), minimumPreferredWidth), maximumPreferredWidth(on: screen))
    }

    static func screenWidthRatio(for preferredWidth: Double, on screen: NSScreen? = nil) -> Double {
        let visibleWidth = max(Double(visibleWidth(on: screen)), 1)
        let ratio = Double(clampedPreferredWidth(preferredWidth, on: screen)) / visibleWidth
        return min(max(ratio, minimumScreenWidthRatio), maximumScreenWidthRatio)
    }

    static func preferredWidth(forScreenWidthRatio ratio: Double, on screen: NSScreen? = nil) -> Double {
        let clampedRatio = min(max(ratio, minimumScreenWidthRatio), maximumScreenWidthRatio)
        return Double(visibleWidth(on: screen)) * clampedRatio
    }

    private static func visibleWidth(on screen: NSScreen? = nil) -> CGFloat {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        return targetScreen?.visibleFrame.width ?? 1440
    }
}

private struct PendingTimelineSeek {
    let revision: Int
    let generation: Int
    let targetTime: Double
    let originTime: Double
    let startedAt: Date
    var lastReissuedAt: Date?
    var reissueCount: Int = 0
}

struct PlaybackSeekState: Equatable {
    enum Phase: Equatable {
        case scrubbing
        case seeking
        case settled
    }

    let revision: Int
    let phase: Phase
    let targetTime: Double
    let originTime: Double
    let resolvedTime: Double?

    var presentationTime: Double {
        resolvedTime ?? targetTime
    }

    var isUserPreview: Bool {
        phase == .scrubbing
    }

    var isAwaitingPlaybackClock: Bool {
        phase == .seeking
    }
}

struct PlayerPlaybackReport {
    enum Phase: Equatable {
        case started
        case progress
        case stopped
    }

    let phase: Phase
    let item: MediaItem
    let position: Double
    let duration: Double?
    let isPaused: Bool
}

struct VideoStreamQualityOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let detail: String
    let baseURLString: String
    let isOriginal: Bool
    let appliesInPlace: Bool
    let videoFilter: String?
    let width: Int?
    let height: Int?
    let videoBitrate: Int64?

    var systemImage: String {
        isOriginal ? "sparkles.tv" : "rectangle.compress.vertical"
    }

    func playbackURLString(startTime: Double? = nil) -> String {
        guard !isOriginal,
              let startTime,
              startTime.isFinite,
              startTime > 1,
              var components = URLComponents(string: baseURLString) else {
            return baseURLString
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("StartTimeTicks") == .orderedSame }
        let ticks = Int64((startTime * 10_000_000).rounded(.down))
        queryItems.append(URLQueryItem(name: "StartTimeTicks", value: "\(ticks)"))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? baseURLString
    }
}

private enum RemoteVideoQualityPlanner {
    private static let minimum1080pVideoBitrate: Double = 5_800_000
    private static let targetAudioBitrate: Int64 = 192_000
    private static let minimumMeaningfulReduction = 0.88

    static func options(for item: MediaItem, knownMountedNetworkFile: Bool? = nil) -> [VideoStreamQualityOption] {
        guard item.type != .music,
              let originalPath = item.filePath,
              let sourceSize = VideoAspectRatioResolver.sizeFromResolution(item.resolution) else {
            return []
        }
        if item.isRemoteResource, item.metadataProvider == "Emby", let originalURL = URL(string: originalPath) {
            return embyOptions(for: item, originalURLString: originalPath, originalURL: originalURL, sourceSize: sourceSize)
        }
        let mountedNetworkFile = knownMountedNetworkFile ?? isMountedNetworkFile(for: item)
        if mountedNetworkFile {
            return mountedNetworkOptions(for: item, originalPath: originalPath, sourceSize: sourceSize)
        }
        return []
    }

    static func isMountedNetworkFile(for item: MediaItem) -> Bool {
        guard !item.isRemoteResource,
              let filePath = item.filePath,
              !filePath.isEmpty,
              FileManager.default.fileExists(atPath: filePath) else {
            return false
        }
        let url = URL(fileURLWithPath: filePath)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           values.volumeIsLocal == false {
            return true
        }
        return filePath.hasPrefix("/Volumes/")
    }

    private static func embyOptions(
        for item: MediaItem,
        originalURLString: String,
        originalURL: URL,
        sourceSize: (width: Int, height: Int)
    ) -> [VideoStreamQualityOption] {
        let sourceWidth = sourceSize.width
        let sourceHeight = sourceSize.height
        guard sourceWidth > 0, sourceHeight >= 1080 else { return [] }
        let sourcePixels = Double(sourceWidth * sourceHeight)
        guard sourcePixels > 0 else { return [] }

        let sourceBitrate = sourceVideoBitrate(for: item)
        guard let sourceBitrate, sourceBitrate >= Int64(minimum1080pVideoBitrate * 1.03) else {
            return []
        }

        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let original = VideoStreamQualityOption(
            id: "original",
            label: "原画",
            detail: originalDetail(item: item, bitrate: sourceBitrate),
            baseURLString: originalURLString,
            isOriginal: true,
            appliesInPlace: false,
            videoFilter: nil,
            width: sourceWidth,
            height: sourceHeight,
            videoBitrate: sourceBitrate
        )

        let targetHeights = candidateHeights(sourceHeight: sourceHeight)
        var transcodeOptions: [VideoStreamQualityOption] = []
        var seenHeights = Set<Int>()
        for targetHeight in targetHeights where seenHeights.insert(targetHeight).inserted {
            let targetWidth = evenInt(Double(targetHeight) * aspect)
            guard targetWidth > 0, targetHeight >= 1080 else { continue }
            let targetPixels = Double(targetWidth * targetHeight)
            let targetBitrate = plannedBitrate(
                sourceBitrate: Double(sourceBitrate),
                sourceHeight: sourceHeight,
                targetHeight: targetHeight,
                targetPixels: targetPixels
            )
            guard targetBitrate < Double(sourceBitrate) * minimumMeaningfulReduction else { continue }
            guard let url = embyTranscodeURL(
                from: originalURL,
                width: targetWidth,
                height: targetHeight,
                videoBitrate: Int64(targetBitrate.rounded())
            ) else { continue }
            transcodeOptions.append(
                VideoStreamQualityOption(
                    id: "\(targetHeight)-\(Int(targetBitrate.rounded()))",
                    label: label(forHeight: targetHeight),
                    detail: "\(targetWidth)x\(targetHeight) · \(formatBitrate(Int64(targetBitrate.rounded())))",
                    baseURLString: url.absoluteString,
                    isOriginal: false,
                    appliesInPlace: false,
                    videoFilter: nil,
                    width: targetWidth,
                    height: targetHeight,
                    videoBitrate: Int64(targetBitrate.rounded())
                )
            )
        }

        guard !transcodeOptions.isEmpty else { return [] }
        return [original] + transcodeOptions
    }

    private static func mountedNetworkOptions(
        for item: MediaItem,
        originalPath: String,
        sourceSize: (width: Int, height: Int)
    ) -> [VideoStreamQualityOption] {
        let sourceWidth = sourceSize.width
        let sourceHeight = sourceSize.height
        guard sourceWidth > 0, sourceHeight > 1080 else { return [] }
        let sourceBitrate = sourceVideoBitrate(for: item)
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let original = VideoStreamQualityOption(
            id: "mounted-original",
            label: "原画",
            detail: originalDetail(item: item, bitrate: sourceBitrate, suffix: "挂载直读"),
            baseURLString: originalPath,
            isOriginal: true,
            appliesInPlace: true,
            videoFilter: nil,
            width: sourceWidth,
            height: sourceHeight,
            videoBitrate: sourceBitrate
        )

        let options = candidateHeights(sourceHeight: sourceHeight)
            .filter { $0 < sourceHeight && $0 >= 1080 }
            .map { targetHeight -> VideoStreamQualityOption in
                let targetWidth = evenInt(Double(targetHeight) * aspect)
                let filter = "lavfi=[scale=w=\(targetWidth):h=\(targetHeight):force_original_aspect_ratio=decrease]"
                return VideoStreamQualityOption(
                    id: "mounted-\(targetHeight)",
                    label: label(forHeight: targetHeight),
                    detail: "\(targetWidth)x\(targetHeight) · 播放端降采样",
                    baseURLString: originalPath,
                    isOriginal: false,
                    appliesInPlace: true,
                    videoFilter: filter,
                    width: targetWidth,
                    height: targetHeight,
                    videoBitrate: sourceBitrate
                )
            }
        guard !options.isEmpty else { return [] }
        return [original] + options
    }

    private static func sourceVideoBitrate(for item: MediaItem) -> Int64? {
        if let videoBitrate = item.videoBitrate, videoBitrate > 0 {
            return videoBitrate
        }
        guard let fileSize = item.fileSize,
              let duration = item.duration,
              fileSize > 0,
              duration.isFinite,
              duration > 1 else { return nil }
        return Int64((Double(fileSize) * 8 / duration).rounded())
    }

    private static func candidateHeights(sourceHeight: Int) -> [Int] {
        if sourceHeight >= 2160 {
            return [2160, 1440, 1080]
        }
        if sourceHeight >= 1440 {
            return [1440, 1080]
        }
        return [1080]
    }

    private static func plannedBitrate(
        sourceBitrate: Double,
        sourceHeight: Int,
        targetHeight: Int,
        targetPixels: Double
    ) -> Double {
        let normalizedPixels = max(targetPixels / (1920 * 1080), 1)
        let floor = minimum1080pVideoBitrate * pow(normalizedPixels, 0.72)
        let ceiling = floor * 1.45
        let heightRatio = min(Double(targetHeight) / Double(max(sourceHeight, 1)), 1)
        let perTitle = sourceBitrate * pow(heightRatio, 1.35) * 0.72
        return max(floor, min(ceiling, perTitle))
            .roundedToNearest(50_000)
    }

    private static func embyTranscodeURL(from originalURL: URL, width: Int, height: Int, videoBitrate: Int64) -> URL? {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { return nil }
        let pathComponents = originalURL.pathComponents
        guard let videosIndex = pathComponents.firstIndex(where: { component in
            component.caseInsensitiveCompare("Videos") == .orderedSame ||
            component.caseInsensitiveCompare("Video") == .orderedSame
        }),
        pathComponents.indices.contains(videosIndex + 1) else {
            return nil
        }
        let itemID = pathComponents[videosIndex + 1]
        let prefixComponents = Array(pathComponents.prefix(videosIndex))
        components.path = joinedPath(prefixComponents + ["Videos", itemID, "stream.mp4"])

        let originalItems = components.queryItems ?? []
        let preservedNames = Set(["api_key", "MediaSourceId", "DeviceId", "PlaySessionId"])
        var queryItems = originalItems.filter { item in
            preservedNames.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
        }
        guard queryItems.contains(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }),
              queryItems.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }) else {
            return nil
        }
        if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame }) {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: "MediaLIB\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"))
        }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "AudioBitrate", value: "\(targetAudioBitrate)"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
            URLQueryItem(name: "VideoBitrate", value: "\(videoBitrate)"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(videoBitrate + targetAudioBitrate)"),
            URLQueryItem(name: "MaxWidth", value: "\(width)"),
            URLQueryItem(name: "MaxHeight", value: "\(height)"),
            URLQueryItem(name: "TranscodingContainer", value: "mp4"),
            URLQueryItem(name: "TranscodingProtocol", value: "http")
        ])
        components.queryItems = queryItems
        return components.url
    }

    private static func joinedPath(_ components: [String]) -> String {
        var path = ""
        for component in components {
            if component == "/" {
                path = "/"
            } else {
                if !path.hasSuffix("/") {
                    path += "/"
                }
                path += component
            }
        }
        return path.isEmpty ? "/" : path
    }

    private static func originalDetail(item: MediaItem, bitrate: Int64?, suffix: String = "直连") -> String {
        let resolution = item.resolution?.isEmpty == false ? item.resolution! : "原始分辨率"
        if let bitrate {
            return "\(resolution) · \(formatBitrate(bitrate)) · \(suffix)"
        }
        return "\(resolution) · \(suffix)"
    }

    private static func label(forHeight height: Int) -> String {
        if height >= 2160 {
            return "蓝光 4K"
        }
        if height >= 1440 {
            return "超清 2K"
        }
        return "高清 1080P"
    }

    private static func evenInt(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - rounded % 2)
    }

    private static func formatBitrate(_ bitrate: Int64) -> String {
        let mbps = Double(bitrate) / 1_000_000
        if mbps >= 10 {
            return String(format: "%.0f Mbps", mbps)
        }
        return String(format: "%.1f Mbps", mbps)
    }
}

private extension Double {
    func roundedToNearest(_ step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}

private struct PlayerAuxiliaryPlaybackMetadata: Sendable {
    let sidecarSubtitles: [SidecarSubtitleFile]
    let previewPrefersFFmpeg: Bool
    let qualityOptions: [VideoStreamQualityOption]
}

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    var initialAspectRatio: CGFloat? = nil
    var onVideoAspectRatioChange: ((CGFloat) -> Void)? = nil

    @State private var controller = MpvPlayerController()
    @StateObject private var controlsAutoHide = PlayerControlsAutoHideCoordinator()
    @State private var sidecarSubtitles: [SidecarSubtitleFile] = []
    @State private var controlsVisible = true
    @State private var controlsHovered = false
    @State private var controlsLocked = false
    @State private var qualityOptions: [VideoStreamQualityOption] = []
    @State private var selectedQualityID: String?
    @State private var volumeHUDVisible = false
    @State private var volumeHUDTask: Task<Void, Never>?
    @State private var scrubberPreview: VideoScrubberPreview?
    @State private var previewImage: NSImage?
    @State private var previewIsLoading = false
    @State private var previewPrefersFFmpeg = false
    @State private var previewLoadTask: Task<Void, Never>?
    @State private var auxiliaryMetadataTask: Task<Void, Never>?
    @State private var playbackMarkers: [PlaybackMarker] = []

    var body: some View {
        ZStack {
            playerBackdrop

            MpvPlayerView(controller: controller)
                .ignoresSafeArea()

            PlayerInteractionOverlay {
                if controller.canControl {
                    controller.togglePlay()
                }
            } onActivity: {
                showControlsTemporarily()
            } onSecondaryClick: {
                hideControlsImmediately()
            }
            .ignoresSafeArea()

            PlayerPlaybackStatusLayer(controller: controller, item: item)

            PlayerMarkerSkipLayer(controller: controller, markers: playbackMarkers)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PlayerControlsBar(
                    controller: controller,
                    item: item,
                    sidecarSubtitles: sidecarSubtitles,
                    qualityOptions: qualityOptions,
                    selectedQualityID: $selectedQualityID,
                    previewPrefersFFmpeg: previewPrefersFFmpeg,
                    scrubberPreview: $scrubberPreview,
                    previewImage: previewImage,
                    previewIsLoading: previewIsLoading,
                    markers: playbackMarkers,
                    onSetMarkerBoundary: setMarkerBoundary,
                    onAddChapter: addManualChapter,
                    onDeleteMarker: deleteMarker,
                    onPlayAdjacent: playAdjacentVideo
                )
                .onHover { hovering in
                    controlsHovered = hovering
                    if hovering {
                        controlsAutoHide.cancel()
                        if !controlsVisible {
                            withAnimation(AppMotion.fast) {
                                controlsVisible = true
                            }
                        }
                    } else {
                        scheduleControlsAutoHide()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(AppMotion.fast, value: controlsVisible)

            if volumeHUDVisible {
                VStack {
                    Spacer(minLength: 0)
                    PlayerVolumeHUDLayer(controller: controller)
                        .padding(.bottom, 78)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            HStack {
                Spacer()
                Button {
                    toggleControlsLock()
                } label: {
                    Image(systemName: controlsLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(controlsLocked ? 0.92 : 0.72))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .playerGlass(cornerRadius: 19)
                .opacity(controlsVisible || controlsLocked ? 1 : 0)
                .allowsHitTesting(controlsVisible || controlsLocked)
                .padding(.trailing, 18)
                Spacer(minLength: 0).frame(width: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(
            idealWidth: preferredSize.width,
            maxWidth: .infinity,
            idealHeight: preferredSize.height,
            maxHeight: .infinity
        )
        .onAppear {
            controller.onVolumeChange = { volume in
                appState.rememberPlayerVolume(volume, for: item.type)
            }
            controller.onPlaybackReport = { report in
                appState.syncEmbyPlayback(report)
            }
            controller.configure(item: item, settings: appState.settings)
            loadPlaybackMarkers()
            loadAuxiliaryPlaybackMetadata()
            scheduleControlsAutoHide()
        }
        .onDisappear {
            controlsAutoHide.cancel()
            volumeHUDTask?.cancel()
            previewLoadTask?.cancel()
            auxiliaryMetadataTask?.cancel()
            controller.onVolumeChange = nil
            controller.teardown()
            controller.saveProgress(appState: appState, reloadLibrary: false)
            controller.onPlaybackReport = nil
        }
        .onChange(of: previewRequestKey) { _ in
            loadPreviewImage()
        }
        .onChange(of: appState.playbackCommandRequest?.id) { _ in
            handlePlaybackCommand()
        }
        .onReceive(controller.$chapters.removeDuplicates()) { chapters in
            syncEmbeddedChapters(chapters)
        }
        .overlay {
            PlayerWindowChromeVisibilityLayer(controller: controller, controlsVisible: controlsVisible)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .overlay {
            PlayerVideoAspectRatioReporter(controller: controller, onChange: onVideoAspectRatioChange)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .background {
            KeyCaptureView { key in
                handleKey(key)
            }
            .frame(width: 0, height: 0)
        }
    }

    private var playerBackdrop: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.10, alpha: 1)),
                    Color.black,
                    Color(nsColor: NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.08, alpha: 1))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color(nsColor: NSColor.systemBlue).opacity(0.18),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 80,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    private var videoAspectRatio: CGFloat {
        initialAspectRatio ?? VideoAspectRatioResolver.cachedAspectRatio(for: item) ?? 16.0 / 9.0
    }

    private func loadAuxiliaryPlaybackMetadata() {
        auxiliaryMetadataTask?.cancel()
        sidecarSubtitles = []
        qualityOptions = []
        selectedQualityID = nil
        previewPrefersFFmpeg = item.isRemoteResource

        let targetItem = item
        auxiliaryMetadataTask = Task {
            let metadata = await Task.detached(priority: .utility) {
                let mountedNetworkFile = RemoteVideoQualityPlanner.isMountedNetworkFile(for: targetItem)
                return PlayerAuxiliaryPlaybackMetadata(
                    sidecarSubtitles: SidecarSubtitleFile.find(for: targetItem),
                    previewPrefersFFmpeg: targetItem.isRemoteResource || mountedNetworkFile,
                    qualityOptions: RemoteVideoQualityPlanner.options(for: targetItem, knownMountedNetworkFile: mountedNetworkFile)
                )
            }.value

            guard !Task.isCancelled, item.id == targetItem.id else { return }
            sidecarSubtitles = metadata.sidecarSubtitles
            previewPrefersFFmpeg = metadata.previewPrefersFFmpeg
            qualityOptions = metadata.qualityOptions
            selectedQualityID = metadata.qualityOptions.first?.id
        }
    }

    private var preferredSize: CGSize {
        let width = VideoWindowSizing.clampedPreferredWidth(appState.settings.videoPlayerPreferredWidth)
        return CGSize(width: width, height: width / videoAspectRatio)
    }

    private var previewRequestKey: String? {
        guard let scrubberPreview else { return nil }
        let bucket = VideoFramePreviewGenerator.bucket(for: scrubberPreview.time, duration: controller.duration, preferCoarse: previewPrefersFFmpeg)
        return "\(item.id)-\(bucket)"
    }

    private func close() {
        controller.teardown()
        appState.activePlayerItem = nil
        controller.saveProgress(appState: appState, reloadLibrary: false)
    }

    private func playAdjacentVideo(direction: Int) {
        controller.teardown()
        controller.saveProgress(appState: appState, reloadLibrary: false)
        appState.playAdjacent(to: item, direction: direction)
    }

    private func loadPlaybackMarkers() {
        playbackMarkers = appState.playbackMarkers(for: item)
    }

    private func syncEmbeddedChapters(_ chapters: [MpvChapter]) {
        guard !chapters.isEmpty else { return }
        let embedded = chapters.enumerated().map { index, chapter in
            let endTime = chapters.indices.contains(index + 1)
                ? chapters[index + 1].time
                : (controller.duration > chapter.time ? controller.duration : nil)
            return PlaybackMarker(
                id: "embedded-\(item.id)-\(index)-\(Int((chapter.time * 1_000).rounded()))",
                mediaID: item.id,
                kind: .chapter,
                title: chapter.title,
                startTime: chapter.time,
                endTime: endTime,
                origin: .embedded
            )
        }
        appState.replaceEmbeddedPlaybackChapters(for: item, chapters: embedded)
        loadPlaybackMarkers()
    }

    private func setMarkerBoundary(_ kind: PlaybackMarker.Kind, _ isStart: Bool, _ time: Double) {
        guard kind == .intro || kind == .credits else { return }
        let existing = playbackMarkers.first { $0.kind == kind && $0.origin == .manual }
        var marker = existing ?? PlaybackMarker(
            id: "manual-\(item.id)-\(kind.rawValue)",
            mediaID: item.id,
            kind: kind,
            title: kind.title,
            startTime: max(time, 0),
            origin: .manual
        )
        if isStart {
            marker.startTime = max(time, 0)
            if let endTime = marker.endTime, endTime <= marker.startTime {
                marker.endTime = nil
            }
        } else {
            if marker.startTime >= time {
                marker.startTime = max(0, time - 90)
            }
            marker.endTime = max(time, marker.startTime + 0.1)
        }
        if appState.savePlaybackMarker(marker) != nil {
            loadPlaybackMarkers()
        }
    }

    private func addManualChapter(_ time: Double) {
        let chapterNumber = playbackMarkers.filter { $0.kind == .chapter && $0.origin == .manual }.count + 1
        let marker = PlaybackMarker(
            mediaID: item.id,
            kind: .chapter,
            title: "手动章节 \(chapterNumber)",
            startTime: time,
            origin: .manual
        )
        if appState.savePlaybackMarker(marker) != nil {
            loadPlaybackMarkers()
        }
    }

    private func deleteMarker(_ marker: PlaybackMarker) {
        guard marker.origin == .manual else { return }
        appState.deletePlaybackMarker(marker)
        loadPlaybackMarkers()
    }

    private func handlePlaybackCommand() {
        guard let request = appState.playbackCommandRequest,
              appState.activePlayerItem?.id == item.id,
              item.type != .music else { return }
        switch request.command {
        case .play:
            if controller.canControl, !controller.isPlaying {
                controller.togglePlay()
            }
        case .pause:
            if controller.canControl, controller.isPlaying {
                controller.togglePlay()
            }
        case .togglePlay:
            controller.togglePlay()
        case .previous:
            playAdjacentVideo(direction: -1)
        case .next:
            playAdjacentVideo(direction: 1)
        case .seekBackward:
            controller.seek(by: -appState.settings.skipInterval)
        case .seekForward:
            controller.seek(by: appState.settings.skipInterval)
        case .toggleShuffle, .cycleRepeat:
            break
        }
    }

    private func showControlsTemporarily() {
        guard !controlsLocked else { return }
        if !controlsVisible {
            withAnimation(AppMotion.fast) {
                controlsVisible = true
            }
        }
        scheduleControlsAutoHide()
    }

    private func toggleControlsLock() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            controlsLocked.toggle()
            controlsVisible = !controlsLocked
        }
        if controlsLocked {
            controlsAutoHide.cancel()
        } else {
            showControlsTemporarily()
        }
    }

    private func hideControlsImmediately() {
        controlsAutoHide.cancel()
        guard !controlsHovered else { return }
        withAnimation(AppMotion.immediate) {
            controlsVisible = false
        }
    }

    private func scheduleControlsAutoHide() {
        guard !controlsLocked else { return }
        controlsAutoHide.schedule(throttleInterval: controlsVisible ? 0.35 : 0) {
            do {
                try await Task.sleep(nanoseconds: 3_200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard controller.isPlaying, controller.errorMessage == nil, !controlsHovered else { return }
            withAnimation(AppMotion.standard) {
                controlsVisible = false
            }
        }
    }

    private func handleKey(_ key: CapturedKey) {
        var shouldShowControls = true
        switch key {
        case .escape:
            if !PlayerWindowActions.exitFullScreenIfNeeded() {
                close()
            }
        case .closeWindow:
            close()
        case .space, .k:
            controller.togglePlay()
        case .leftArrow:
            controller.seek(by: -appState.settings.skipInterval)
        case .rightArrow:
            controller.seek(by: appState.settings.skipInterval)
        case .seekBackwardSmall:
            controller.seek(by: -5)
        case .seekForwardSmall:
            controller.seek(by: 5)
        case .seekBackwardLarge, .pageDown:
            controller.seek(by: -60)
        case .seekForwardLarge, .pageUp:
            controller.seek(by: 60)
        case .j:
            controller.seek(by: -10)
        case .l:
            controller.seek(by: 10)
        case .upArrow:
            controller.setVolume(controller.volume + 0.05)
            showVolumeHUD()
            shouldShowControls = false
        case .downArrow:
            controller.setVolume(controller.volume - 0.05)
            showVolumeHUD()
            shouldShowControls = false
        case .mute:
            controller.toggleMute()
            showVolumeHUD()
            shouldShowControls = false
        case .returnKey, .fullscreen:
            controller.toggleFullscreen()
        case .beginning:
            controller.seek(to: 0)
        case .ending:
            controller.seek(to: max(controller.duration - 0.5, 0))
        case .number(let value):
            guard controller.duration > 0 else { return }
            controller.seek(to: controller.duration * Double(value) / 10.0)
        case .speedDown:
            controller.changeRate(by: -0.25)
        case .speedUp:
            controller.changeRate(by: 0.25)
        case .resetSpeed:
            controller.setPlaybackRate(1.0)
        case .frameBackward:
            controller.stepFrame(backward: true)
        case .frameForward:
            controller.stepFrame(backward: false)
        case .subtitleCycle:
            controller.cycleSubtitle()
        case .subtitleToggle:
            controller.toggleSubtitleVisibility()
        case .audioCycle:
            controller.cycleAudioTrack()
        case .other:
            break
        }
        if shouldShowControls {
            showControlsTemporarily()
        }
    }

    private func showVolumeHUD() {
        volumeHUDTask?.cancel()
        withAnimation(AppMotion.fast) {
            volumeHUDVisible = true
        }
        volumeHUDTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 950_000_000)
            } catch {
                return
            }
            withAnimation(AppMotion.standard) {
                volumeHUDVisible = false
            }
        }
    }

    private func loadPreviewImage() {
        previewLoadTask?.cancel()
        guard let scrubberPreview,
              let filePath = item.filePath else {
            previewImage = nil
            previewIsLoading = false
            return
        }
        let time = scrubberPreview.time
        let itemID = item.id
        let prefersFFmpeg = previewPrefersFFmpeg
        let duration = controller.duration
        if let cached = VideoFramePreviewGenerator.cachedImage(itemID: itemID, time: time, duration: duration, preferFFmpeg: prefersFFmpeg) {
            previewImage = cached
            previewIsLoading = false
            VideoFramePreviewGenerator.prefetchAround(
                itemID: itemID,
                filePath: filePath,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            )
            return
        }
        previewImage = nil
        previewIsLoading = true
        previewLoadTask = Task { @MainActor in
            let loaded = SendableVideoPreviewImage(await VideoFramePreviewGenerator.image(
                itemID: itemID,
                filePath: filePath,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            ))
            guard !Task.isCancelled,
                  self.scrubberPreview != nil,
                  self.item.id == itemID else { return }
            self.previewImage = loaded.image
            self.previewIsLoading = false
            VideoFramePreviewGenerator.prefetchAround(
                itemID: itemID,
                filePath: filePath,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            )
        }
    }
}

@MainActor
private final class PlayerControlsAutoHideCoordinator: ObservableObject {
    private var hideTask: Task<Void, Never>?
    private var lastScheduleTime = Date.distantPast

    func schedule(throttleInterval: TimeInterval = 0, _ action: @escaping @MainActor () async -> Void) {
        let now = Date()
        if hideTask != nil, throttleInterval > 0, now.timeIntervalSince(lastScheduleTime) < throttleInterval {
            return
        }
        lastScheduleTime = now
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            await action()
        }
    }

    func cancel() {
        hideTask?.cancel()
        hideTask = nil
        lastScheduleTime = .distantPast
    }
}

@MainActor
private final class PlayerControllerProjection<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private weak var controller: MpvPlayerController?
    private let map: @MainActor (MpvPlayerController) -> Value
    private var cancellable: AnyCancellable?
    private var refreshScheduled = false

    init(controller: MpvPlayerController, map: @escaping @MainActor (MpvPlayerController) -> Value) {
        self.controller = controller
        self.map = map
        self.value = map(controller)
        self.cancellable = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let controller else { return }
        let nextValue = map(controller)
        guard nextValue != value else { return }
        value = nextValue
    }
}

private struct PlayerPlaybackStatusState: Equatable {
    let errorMessage: String?
    let statusMessage: String?
    let isPreparing: Bool
    let isReady: Bool
    let isBuffering: Bool
    let isWaitingForVideoFrame: Bool
    let bufferProgress: Double?

    @MainActor
    init(controller: MpvPlayerController) {
        self.errorMessage = controller.errorMessage
        self.statusMessage = controller.statusMessage
        self.isPreparing = controller.isPreparing
        self.isReady = controller.isReady
        self.isBuffering = controller.isBuffering
        self.isWaitingForVideoFrame = controller.isWaitingForVideoFrame
        self.bufferProgress = controller.bufferProgress
    }
}

private struct PlayerWindowChromeState: Equatable {
    let isPreparing: Bool
    let hasError: Bool

    @MainActor
    init(controller: MpvPlayerController) {
        self.isPreparing = controller.isPreparing
        self.hasError = controller.errorMessage != nil
    }
}

private struct PlayerTimelineState: Equatable {
    let currentTime: Double
    let duration: Double
    let canControl: Bool
    let formattedCurrentTime: String
    let formattedDuration: String

    @MainActor
    init(controller: MpvPlayerController) {
        self.currentTime = controller.currentTime
        self.duration = controller.duration
        self.canControl = controller.canControl
        self.formattedCurrentTime = controller.formattedCurrentTime
        self.formattedDuration = controller.formattedDuration
    }
}

private struct PlayerTransportState: Equatable {
    let canControl: Bool
    let isPlaying: Bool
    let volume: Float
    let playbackRate: Float
    let routePickerRevision: Int

    @MainActor
    init(controller: MpvPlayerController) {
        self.canControl = controller.canControl
        self.isPlaying = controller.isPlaying
        self.volume = controller.volume
        self.playbackRate = controller.playbackRate
        self.routePickerRevision = controller.routePickerRevision
    }
}

private struct PlayerPlaybackStatusLayer: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let item: MediaItem
    @StateObject private var status: PlayerControllerProjection<PlayerPlaybackStatusState>

    init(controller: MpvPlayerController, item: MediaItem) {
        self.controller = controller
        self.item = item
        _status = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerPlaybackStatusState.init))
    }

    var body: some View {
        let state = status.value
        if let errorMessage = state.errorMessage {
            PlayerStatusOverlay(
                title: "内置播放器无法播放",
                systemImage: "play.slash",
                message: errorMessage,
                actionTitle: "用外部播放器打开"
            ) {
                appState.openExternally(item)
            }
        } else if state.isPreparing || !state.isReady || state.isBuffering || state.isWaitingForVideoFrame {
            PlayerBufferingOverlay(
                title: state.isBuffering ? "正在缓冲" : "正在加载",
                progress: state.bufferProgress,
                message: state.statusMessage
            )
        }
    }
}

private struct PlayerWindowChromeVisibilityLayer: View {
    let controller: MpvPlayerController
    let controlsVisible: Bool
    @StateObject private var chrome: PlayerControllerProjection<PlayerWindowChromeState>

    init(controller: MpvPlayerController, controlsVisible: Bool) {
        self.controller = controller
        self.controlsVisible = controlsVisible
        _chrome = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerWindowChromeState.init))
    }

    var body: some View {
        PlayerWindowChromeVisibility(
            visible: controlsVisible || chrome.value.isPreparing || chrome.value.hasError
        )
    }
}

private struct PlayerVideoAspectRatioReporter: View {
    let onChange: ((CGFloat) -> Void)?
    @StateObject private var aspectRatio: PlayerControllerProjection<CGFloat?>

    init(controller: MpvPlayerController, onChange: ((CGFloat) -> Void)?) {
        self.onChange = onChange
        _aspectRatio = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.videoAspectRatio })
    }

    var body: some View {
        Color.clear
            .onChange(of: aspectRatio.value) { aspect in
                guard let aspect else { return }
                onChange?(aspect)
            }
    }
}

private struct PlayerVolumeHUDLayer: View {
    @StateObject private var volume: PlayerControllerProjection<Float>

    init(controller: MpvPlayerController) {
        _volume = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.volume })
    }

    var body: some View {
        PlayerVolumeHUD(volume: volume.value)
    }
}

private struct PlayerControlsBar: View {
    let controller: MpvPlayerController
    let item: MediaItem
    let sidecarSubtitles: [SidecarSubtitleFile]
    let qualityOptions: [VideoStreamQualityOption]
    @Binding var selectedQualityID: String?
    let previewPrefersFFmpeg: Bool
    @Binding var scrubberPreview: VideoScrubberPreview?
    let previewImage: NSImage?
    let previewIsLoading: Bool
    let markers: [PlaybackMarker]
    let onSetMarkerBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onDeleteMarker: (PlaybackMarker) -> Void
    let onPlayAdjacent: (Int) -> Void
    @StateObject private var timeline: PlayerControllerProjection<PlayerTimelineState>
    @StateObject private var transport: PlayerControllerProjection<PlayerTransportState>
    @State private var showingVolumePopover = false
    @State private var showingSpeedPopover = false
    @State private var showingSubtitlePopover = false
    @State private var showingAudioPopover = false
    @State private var showingQualityPopover = false
    @State private var showingMarkerPopover = false

    init(
        controller: MpvPlayerController,
        item: MediaItem,
        sidecarSubtitles: [SidecarSubtitleFile],
        qualityOptions: [VideoStreamQualityOption],
        selectedQualityID: Binding<String?>,
        previewPrefersFFmpeg: Bool,
        scrubberPreview: Binding<VideoScrubberPreview?>,
        previewImage: NSImage?,
        previewIsLoading: Bool,
        markers: [PlaybackMarker],
        onSetMarkerBoundary: @escaping (PlaybackMarker.Kind, Bool, Double) -> Void,
        onAddChapter: @escaping (Double) -> Void,
        onDeleteMarker: @escaping (PlaybackMarker) -> Void,
        onPlayAdjacent: @escaping (Int) -> Void
    ) {
        self.controller = controller
        self.item = item
        self.sidecarSubtitles = sidecarSubtitles
        self.qualityOptions = qualityOptions
        _selectedQualityID = selectedQualityID
        self.previewPrefersFFmpeg = previewPrefersFFmpeg
        _scrubberPreview = scrubberPreview
        self.previewImage = previewImage
        self.previewIsLoading = previewIsLoading
        self.markers = markers
        self.onSetMarkerBoundary = onSetMarkerBoundary
        self.onAddChapter = onAddChapter
        self.onDeleteMarker = onDeleteMarker
        self.onPlayAdjacent = onPlayAdjacent
        _timeline = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerTimelineState.init))
        _transport = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerTransportState.init))
    }

    var body: some View {
        let timelineState = timeline.value
        let transportState = transport.value
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Text(timelineState.formattedCurrentTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 42, alignment: .trailing)

                VideoProgressScrubber(
                    currentTime: timelineState.currentTime,
                    duration: timelineState.duration,
                    enabled: timelineState.canControl && timelineState.duration > 0,
                    coarsePreviewBuckets: previewPrefersFFmpeg,
                    preview: $scrubberPreview,
                    previewImage: previewImage,
                    previewIsLoading: previewIsLoading,
                    markers: markers,
                    onSeek: { controller.seek(to: $0) }
                )

                Text(timelineState.formattedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 42, alignment: .leading)
            }

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    // 视频隔空播放按钮已移除：内置视频经 libmpv 渲染到自有 OpenGL 视图，
                    // AVRoutePicker 仅能驱动音频代理播放器，无法把画面投到外部设备，
                    // 点击只会在本机播放、造成误导。系统级整窗投屏可由 macOS“屏幕镜像”承担。
                    subtitleButton
                        .disabled(!transportState.canControl)
                    audioButton
                        .disabled(!transportState.canControl)
                    if qualityOptions.count > 1 {
                        qualityButton
                            .disabled(!transportState.canControl)
                    }
                    markerButton(currentTime: timelineState.currentTime, duration: timelineState.duration)
                        .disabled(!transportState.canControl)
                }
                .frame(width: 180, alignment: .leading)

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        onPlayAdjacent(-1)
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .playerControlIcon(width: 29, height: 28)
                    }
                    .help("上一集")

                    Button {
                        controller.togglePlay()
                    } label: {
                        Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 32)
                            .playerCapsuleControl(cornerRadius: 16)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("播放/暂停")
                    .disabled(!transportState.canControl)

                    Button {
                        onPlayAdjacent(1)
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .playerControlIcon(width: 29, height: 28)
                    }
                    .help("下一集")
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    volumeButton(volume: transportState.volume)
                        .disabled(!transportState.canControl)
                    speedButton(playbackRate: transportState.playbackRate)
                        .disabled(!transportState.canControl)
                    Button {
                        controller.toggleFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .playerControlIcon()
                    }
                    .help("全屏")
                }
                .frame(width: 180, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 596)
        .playerGlass(cornerRadius: 15)
        .padding(.bottom, 7)
    }

    private var subtitleButton: some View {
        Button {
            togglePopover {
                showingSubtitlePopover.toggle()
            }
        } label: {
            Image(systemName: "captions.bubble")
                .playerControlIcon()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSubtitlePopover, arrowEdge: .bottom) {
            PlayerSubtitlePopover(
                controller: controller,
                sidecarSubtitles: sidecarSubtitles,
                item: item
            )
        }
        .help("字幕")
    }

    private var audioButton: some View {
        Button {
            togglePopover {
                showingAudioPopover.toggle()
            }
        } label: {
            Image(systemName: "waveform.circle")
                .playerControlIcon()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAudioPopover, arrowEdge: .bottom) {
            PlayerAudioTrackPopover(controller: controller)
        }
        .help("音轨")
    }

    private func volumeButton(volume: Float) -> some View {
        Button {
            togglePopover {
                showingVolumePopover.toggle()
            }
        } label: {
            Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.2")
                .playerControlIcon()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingVolumePopover, arrowEdge: .bottom) {
            PlayerVolumePopover(controller: controller)
        }
        .help("音量")
    }

    private func speedButton(playbackRate: Float) -> some View {
        Button {
            togglePopover {
                showingSpeedPopover.toggle()
            }
        } label: {
            Text(String(format: "%.2fx", playbackRate))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 28)
                .playerCapsuleControl(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSpeedPopover, arrowEdge: .bottom) {
            PlayerSpeedPopover(controller: controller)
        }
        .help("倍速")
    }

    private var qualityButton: some View {
        Button {
            togglePopover {
                showingQualityPopover.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.system(size: 12, weight: .semibold))
                Text("画质")
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 28)
            .playerCapsuleControl(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingQualityPopover, arrowEdge: .bottom) {
            PlayerQualityPopover(
                options: qualityOptions,
                selectedID: selectedQualityID
            ) { option in
                togglePopover {
                    selectedQualityID = option.id
                    showingQualityPopover = false
                }
                controller.switchVideoQuality(to: option)
            }
        }
        .help("画质")
    }

    private func markerButton(currentTime: Double, duration: Double) -> some View {
        Button {
            togglePopover {
                showingMarkerPopover.toggle()
            }
        } label: {
            Image(systemName: "bookmark")
                .playerControlIcon()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingMarkerPopover, arrowEdge: .bottom) {
            PlayerMarkerPopover(
                currentTime: currentTime,
                duration: duration,
                markers: markers,
                onSeek: { controller.seek(to: $0) },
                onSetBoundary: onSetMarkerBoundary,
                onAddChapter: onAddChapter,
                onDeleteMarker: onDeleteMarker
            )
        }
        .help("章节与播放标记")
    }

    private func togglePopover(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            action()
        }
    }
}

private struct PlayerWindowChromeVisibility: NSViewRepresentable {
    let visible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.updateChrome(for: view.window, visible: visible)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.updateChrome(for: nsView.window, visible: visible)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        Coordinator.updateChrome(for: nsView.window, visible: true, animated: false)
    }

    final class Coordinator {
        private var lastVisible: Bool?

        func updateChrome(for window: NSWindow?, visible: Bool) {
            guard window != nil else { return }
            guard lastVisible != visible else { return }
            lastVisible = visible
            Self.updateChrome(for: window, visible: visible, animated: true)
        }

        static func updateChrome(for window: NSWindow?, visible: Bool, animated: Bool) {
            guard let window else { return }
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
            if visible {
                buttons.forEach { $0.isHidden = false }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? (visible ? 0.12 : 0.14) : 0
                context.allowsImplicitAnimation = animated
                for button in buttons {
                    button.animator().alphaValue = visible ? 1 : 0
                }
            } completionHandler: {
                guard !visible else { return }
                for button in buttons where button.alphaValue < 0.05 {
                    button.isHidden = true
                }
            }
        }
    }
}

struct PlayerInteractionOverlay: NSViewRepresentable {
    let onPrimaryClick: () -> Void
    let onActivity: () -> Void
    let onSecondaryClick: () -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onPrimaryClick = onPrimaryClick
        view.onActivity = onActivity
        view.onSecondaryClick = onSecondaryClick
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onPrimaryClick = onPrimaryClick
        nsView.onActivity = onActivity
        nsView.onSecondaryClick = onSecondaryClick
    }

    final class InteractionView: NSView {
        var onPrimaryClick: (() -> Void)?
        var onActivity: (() -> Void)?
        var onSecondaryClick: (() -> Void)?
        private var trackingArea: NSTrackingArea?
        private var didDragWindow = false
        private var dragStartEvent: NSEvent?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            onActivity?()
        }

        override func mouseDown(with event: NSEvent) {
            onActivity?()
            didDragWindow = false
            dragStartEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            didDragWindow = true
            window?.performDrag(with: dragStartEvent ?? event)
            dragStartEvent = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard !didDragWindow else {
                didDragWindow = false
                dragStartEvent = nil
                return
            }
            dragStartEvent = nil
            onPrimaryClick?()
        }

        override func rightMouseDown(with event: NSEvent) {
            onSecondaryClick?()
        }

        override func otherMouseDown(with event: NSEvent) {
            onSecondaryClick?()
        }
    }
}

struct PlayerStatusOverlay: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 520)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34, prominent: true))
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .playerGlass(cornerRadius: 22)
    }
}

private struct PlayerBufferingOverlay: View {
    let title: String
    let progress: Double?
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            PlayerBufferingSpinner()
                .frame(width: 46, height: 46)

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.94))

            Text(progressText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.08), .black.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .shadow(color: .white.opacity(0.08), radius: 1, y: -0.5)
        .allowsHitTesting(false)
    }

    private var progressText: String {
        guard let progress, progress.isFinite, progress >= 0 else {
            return "等待数据"
        }
        return "\(Int(min(max(progress, 0), 100).rounded()))%"
    }
}

private struct PlayerBufferingSpinner: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 4)
            Circle()
                .trim(from: 0.06, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [
                            .white.opacity(0.12),
                            .white.opacity(0.92),
                            .white.opacity(0.46)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 0.86).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct PlayerGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.14),
                            Color.black.opacity(0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(0.30), lineWidth: 0.9)
                    .blur(radius: 0.5)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .white.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .shadow(color: .white.opacity(0.07), radius: 1, y: -0.5)
    }
}

private struct PlayerVolumePopover: View {
    @ObservedObject var controller: MpvPlayerController
    @State private var draftVolume: Double = 0
    @State private var isEditing = false

    private var visibleVolume: Double {
        isEditing ? draftVolume : Double(controller.volume)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .frame(width: 22, height: 24)
            PlayerLinearSlider(value: Binding(get: {
                visibleVolume
            }, set: { value in
                draftVolume = value
                controller.setVolume(Float(value), remember: false)
            }), range: 0...1, isEditing: $isEditing) {
                controller.setVolume(Float(draftVolume), remember: true)
            }
            .frame(width: 282, height: 26)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 338)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass()
        .onAppear {
            draftVolume = Double(controller.volume)
        }
        .onChange(of: controller.volume) { volume in
            if !isEditing {
                draftVolume = Double(volume)
            }
        }
    }
}

private struct PlayerSpeedPopover: View {
    @ObservedObject var controller: MpvPlayerController
    @State private var draftRate: Double = 1
    @State private var isEditing = false
    private let snapRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5]

    private var visibleRate: Double {
        isEditing ? draftRate : Double(controller.playbackRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(width: 22, height: 24)

                PlayerSnapSlider(
                    value: Binding(get: {
                        visibleRate
                    }, set: { value in
                        let snapped = snappedRate(Float(value))
                        draftRate = Double(snapped)
                        controller.setPlaybackRate(snapped, updateExternalState: false)
                    }),
                    range: 0.5...2.5,
                    snapValues: snapRates.map(Double.init),
                    isEditing: $isEditing
                ) {
                    controller.setPlaybackRate(Float(draftRate), updateExternalState: true)
                }
                .frame(width: 294, height: 28)
            }

            HStack(spacing: 10) {
                Color.clear.frame(width: 22, height: 1)
                PlayerSpeedTickLabels(
                    currentRate: visibleRate,
                    ticks: [0.5, 0.75, 1.0, 1.5, 2.0, 2.5],
                    range: 0.5...2.5
                )
                .frame(width: 294, height: 16)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 350)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass()
        .onAppear {
            draftRate = Double(controller.playbackRate)
        }
        .onChange(of: controller.playbackRate) { rate in
            if !isEditing {
                draftRate = Double(rate)
            }
        }
    }

    private func snappedRate(_ value: Float) -> Float {
        if let snap = snapRates.min(by: { abs($0 - value) < abs($1 - value) }),
           abs(snap - value) <= 0.035 {
            return snap
        }
        return min(max(value, 0.5), 2.5)
    }
}

private struct PlayerSnapSlider: View {
    private static let knobSize: CGFloat = 24
    @Binding var value: Double
    let range: ClosedRange<Double>
    let snapValues: [Double]
    @Binding var isEditing: Bool
    let onEditingEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knobRadius = Self.knobSize / 2
            let trackWidth = max(width - Self.knobSize, 1)
            let fraction = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knobCenterX = knobRadius + trackWidth * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: trackWidth, height: 6)
                    .offset(x: knobRadius)
                Capsule()
                    .fill(.white.opacity(0.84))
                    .frame(width: max(trackWidth * fraction, 0), height: 6)
                    .offset(x: knobRadius)
                ForEach(snapValues, id: \.self) { snap in
                    let snapFraction = CGFloat((snap - range.lowerBound) / (range.upperBound - range.lowerBound))
                    let snapActive = abs(value - snap) < 0.02
                    Circle()
                        .fill(.white.opacity(snapActive ? 0.92 : 0.34))
                        .frame(width: snapActive ? 4.8 : 3.2, height: snapActive ? 4.8 : 3.2)
                        .position(x: knobRadius + trackWidth * snapFraction, y: 14)
                }
                Circle()
                    .fill(.white)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 1.5)
                    .overlay {
                        Circle().stroke(.white.opacity(0.42), lineWidth: 0.8)
                    }
                    .position(x: knobCenterX, y: 14)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isEditing = true
                        let clampedX = min(max(drag.location.x - knobRadius, 0), trackWidth)
                        value = range.lowerBound + Double(clampedX / trackWidth) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isEditing = false
                        onEditingEnded()
                    }
            )
        }
    }
}

private struct PlayerLinearSlider: View {
    private static let knobSize: CGFloat = 20
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Binding var isEditing: Bool
    let onEditingEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knobRadius = Self.knobSize / 2
            let trackWidth = max(width - Self.knobSize, 1)
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let fraction = CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knobCenterX = knobRadius + trackWidth * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.17))
                    .overlay {
                        Capsule().stroke(.white.opacity(0.14), lineWidth: 0.6)
                    }
                    .frame(width: trackWidth, height: 5.5)
                    .offset(x: knobRadius)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.92), .white.opacity(0.62)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackWidth * fraction, 0), height: 5.5)
                    .offset(x: knobRadius)

                Circle()
                    .fill(.white)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 1.5)
                    .overlay {
                        Circle().stroke(.white.opacity(0.48), lineWidth: 0.8)
                    }
                    .position(x: knobCenterX, y: 13)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isEditing = true
                        let clampedX = min(max(drag.location.x - knobRadius, 0), trackWidth)
                        value = range.lowerBound + Double(clampedX / trackWidth) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isEditing = false
                        onEditingEnded()
                    }
            )
        }
    }
}

private struct PlayerSpeedTickLabels: View {
    private static let knobSize: CGFloat = 24
    let currentRate: Double
    let ticks: [Double]
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knobRadius = Self.knobSize / 2
            let trackWidth = max(width - Self.knobSize, 1)
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { tick in
                    let fraction = CGFloat((tick - range.lowerBound) / (range.upperBound - range.lowerBound))
                    Text(rateLabel(tick))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(abs(currentRate - tick) < 0.01 ? .white.opacity(0.92) : .white.opacity(0.46))
                        .fixedSize()
                        .position(x: knobRadius + trackWidth * fraction, y: 8)
                }
            }
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - 1.0) < 0.001 { return "1x" }
        if rate < 1 { return String(format: "%.2fx", rate) }
        return String(format: "%.1fx", rate)
    }
}

private struct PlayerMarkerSkipLayer: View {
    let controller: MpvPlayerController
    let markers: [PlaybackMarker]
    @StateObject private var timeline: PlayerControllerProjection<PlayerTimelineState>

    init(controller: MpvPlayerController, markers: [PlaybackMarker]) {
        self.controller = controller
        self.markers = markers
        _timeline = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerTimelineState.init))
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let marker = activeMarker, let endTime = marker.endTime {
                Button {
                    controller.seek(to: endTime)
                } label: {
                    Label("跳过\(marker.kind.title)", systemImage: "forward.end.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .playerGlass(cornerRadius: 17)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 98)
            }
        }
        .animation(AppMotion.fast, value: activeMarker?.id)
    }

    private var activeMarker: PlaybackMarker? {
        markers.first {
            ($0.kind == .intro || $0.kind == .credits) && $0.contains(timeline.value.currentTime)
        }
    }
}

private struct PlayerMarkerPopover: View {
    let currentTime: Double
    let duration: Double
    let markers: [PlaybackMarker]
    let onSeek: (Double) -> Void
    let onSetBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onDeleteMarker: (PlaybackMarker) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("章节与播放标记", systemImage: "bookmark")
                    .font(.callout.weight(.semibold))

                HStack(spacing: 7) {
                    markerAction("片头开始", systemImage: "play.fill") {
                        onSetBoundary(.intro, true, currentTime)
                    }
                    markerAction("片头结束", systemImage: "forward.end.fill") {
                        onSetBoundary(.intro, false, currentTime)
                    }
                }
                HStack(spacing: 7) {
                    markerAction("片尾开始", systemImage: "text.append") {
                        onSetBoundary(.credits, true, currentTime)
                    }
                    markerAction("片尾结束", systemImage: "stop.fill") {
                        onSetBoundary(.credits, false, currentTime)
                    }
                }
                Button {
                    onAddChapter(currentTime)
                } label: {
                    Label("在 \(formatTime(currentTime)) 添加章节", systemImage: "bookmark.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .playerCapsuleControl(cornerRadius: 9)
                }
                .buttonStyle(.plain)

                Divider()
                    .background(.white.opacity(0.18))

                if markers.isEmpty {
                    Text("当前视频还没有章节或手动标记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(markers) { marker in
                        HStack(spacing: 7) {
                            Button {
                                onSeek(marker.startTime)
                            } label: {
                                PlayerTrackRow(
                                    title: marker.title,
                                    subtitle: markerSubtitle(marker),
                                    selected: marker.contains(currentTime)
                                )
                            }
                            .buttonStyle(.plain)
                            if marker.origin == .manual {
                                Button(role: .destructive) {
                                    onDeleteMarker(marker)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("删除标记")
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 330)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: true, vertical: false)
        .playerPopoverGlass()
    }

    private func markerAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .playerCapsuleControl(cornerRadius: 9)
        }
        .buttonStyle(.plain)
    }

    private func markerSubtitle(_ marker: PlaybackMarker) -> String {
        let origin = marker.origin == .embedded ? "内嵌章节" : "手动标记"
        guard let endTime = marker.endTime, endTime > marker.startTime else {
            return "\(origin) · \(formatTime(marker.startTime))"
        }
        return "\(origin) · \(formatTime(marker.startTime)) – \(formatTime(endTime))"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PlayerQualityPopover: View {
    let options: [VideoStreamQualityOption]
    let selectedID: String?
    let onSelect: (VideoStreamQualityOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("清晰度", systemImage: "slider.horizontal.2.square")
                .font(.callout.weight(.semibold))

            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    PlayerTrackRow(
                        title: option.label,
                        subtitle: option.detail,
                        selected: option.id == selectedID
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass()
    }
}

private struct PlayerAudioTrackPopover: View {
    @ObservedObject var controller: MpvPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("音轨", systemImage: "waveform.circle")
                .font(.callout.weight(.semibold))

            Button {
                controller.selectDefaultAudioTrack()
            } label: {
                PlayerTrackRow(title: "自动选择", subtitle: "由播放器选择默认音轨", selected: controller.audioTracks.allSatisfy { !$0.isSelected })
            }
            .buttonStyle(.plain)

            if controller.audioTracks.isEmpty {
                Text("播放器暂未回传音轨列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(controller.audioTracks) { track in
                    Button {
                        controller.selectAudioTrack(track.id)
                    } label: {
                        PlayerTrackRow(
                            title: track.displayName,
                            subtitle: "ID \(track.id)",
                            selected: track.isSelected
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass()
    }
}

private struct PlayerSubtitlePopover: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: MpvPlayerController
    let sidecarSubtitles: [SidecarSubtitleFile]
    let item: MediaItem

    @State private var onlineResults: [OnlineSubtitleResult] = []
    @State private var isSearchingOnline = false
    @State private var onlineSearchError: String?
    @State private var downloadingID: String?
    @State private var downloadedIDs: Set<String> = []
    @State private var didAutoSearch = false

    private var embeddedSubtitleTracks: [MpvTrack] {
        controller.subtitleTracks.filter { !$0.isExternal }
    }

    private var externalSubtitleTracks: [MpvTrack] {
        controller.subtitleTracks.filter(\.isExternal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                Label("字幕", systemImage: "captions.bubble")
                    .font(.callout.weight(.semibold))

                // Off + auto-load
                Button {
                    controller.disableSubtitle()
                } label: {
                    PlayerTrackRow(
                        title: "关闭字幕",
                        subtitle: nil,
                        selected: controller.subtitleTracks.allSatisfy { !$0.isSelected }
                    )
                }
                .buttonStyle(.plain)

                Button {
                    controller.enableAutoSubtitle()
                } label: {
                    PlayerTrackRow(
                        title: "自动加载目录字幕",
                        subtitle: "扫描同目录字幕文件",
                        selected: controller.subtitleAutoLoadEnabled
                    )
                }
                .buttonStyle(.plain)

                // Embedded tracks
                if !embeddedSubtitleTracks.isEmpty {
                    playerPopoverSectionHeader("内嵌字幕")
                    ForEach(embeddedSubtitleTracks) { track in
                        Button {
                            controller.selectSubtitleTrack(track.id)
                        } label: {
                            PlayerTrackRow(
                                title: track.displayName,
                                subtitle: "ID \(track.id)",
                                selected: track.isSelected
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Sidecar (local) tracks
                if !sidecarSubtitles.isEmpty || !externalSubtitleTracks.isEmpty {
                    playerPopoverSectionHeader("同目录字幕")
                    ForEach(sidecarSubtitles) { subtitle in
                        let matchedTrack = controller.externalSubtitleTrack(for: subtitle.path)
                        Button {
                            controller.selectOrAddExternalSubtitle(path: subtitle.path)
                        } label: {
                            PlayerTrackRow(
                                title: subtitle.displayName,
                                subtitle: subtitle.languageHint,
                                selected: matchedTrack?.isSelected == true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(externalSubtitleTracks.filter { track in
                        guard let ext = track.externalFilename else { return true }
                        return !sidecarSubtitles.contains { $0.path == ext }
                    }) { track in
                        Button {
                            controller.selectSubtitleTrack(track.id)
                        } label: {
                            PlayerTrackRow(title: track.displayName, subtitle: "外挂字幕", selected: track.isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Online subtitle search section
                Divider()
                    .background(.white.opacity(0.18))

                HStack(spacing: 6) {
                    Text("在线字幕")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("· Podnapisi" + (appState.settings.openSubtitlesAPIKey?.isEmpty == false ? " · OpenSubtitles" : ""))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.30))
                    Spacer()
                    if isSearchingOnline {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(.white.opacity(0.7))
                    } else {
                        Button {
                            Task { await searchOnlineSubtitles() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("重新搜索")
                    }
                }

                if let error = onlineSearchError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                        .padding(.top, 2)
                } else if onlineResults.isEmpty && !isSearchingOnline {
                    Text("暂无在线字幕结果")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.top, 2)
                } else {
                    ForEach(onlineResults.prefix(20)) { result in
                        onlineSubtitleRow(result)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 360)
        .frame(maxHeight: 540)
        .fixedSize(horizontal: true, vertical: false)
        .playerPopoverGlass()
        .onAppear {
            guard !didAutoSearch else { return }
            didAutoSearch = true
            Task { await searchOnlineSubtitles() }
        }
    }

    // MARK: - Online search

    @MainActor
    private func searchOnlineSubtitles() async {
        guard item.filePath != nil || item.isRemoteResource else { return }
        isSearchingOnline = true
        onlineSearchError = nil
        let service = SubtitleSearchService()
        let language = appState.settings.subtitleLanguage
        let apiKey = appState.settings.openSubtitlesAPIKey
        let imdbID: String? = {
            guard let ext = item.externalID else { return nil }
            if ext.hasPrefix("imdb:") { return String(ext.dropFirst(5)) }
            if ext.hasPrefix("tmdb:movie:") || ext.hasPrefix("tmdb:tv:") { return nil }
            return nil
        }()
        let results = await service.searchAll(
            title: item.title,
            year: item.year,
            imdbID: imdbID,
            language: language,
            openSubtitlesKey: apiKey
        )
        isSearchingOnline = false
        if results.isEmpty {
            onlineSearchError = "未找到字幕，可尝试修改标题后重新搜索"
        } else {
            onlineResults = results
        }
    }

    @MainActor
    private func downloadOnlineSubtitle(_ result: OnlineSubtitleResult) async {
        guard let videoPath = item.filePath,
              downloadingID == nil else { return }
        downloadingID = result.id
        defer { downloadingID = nil }
        do {
            let service = SubtitleSearchService()
            let url = try await service.downloadOnline(
                result: result,
                videoPath: videoPath,
                apiKey: appState.settings.openSubtitlesAPIKey
            )
            controller.selectOrAddExternalSubtitle(path: url.path)
            downloadedIDs.insert(result.id)
        } catch {
            onlineSearchError = error.localizedDescription
        }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func onlineSubtitleRow(_ result: OnlineSubtitleResult) -> some View {
        let isDownloading = downloadingID == result.id
        let isDownloaded = downloadedIDs.contains(result.id)
        Button {
            guard !isDownloaded else {
                // already downloaded — try to reload from filesystem
                if let path = item.filePath {
                    let videoURL = URL(fileURLWithPath: path)
                    let srtURL = videoURL.deletingLastPathComponent()
                        .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent)
                        .appendingPathExtension("srt")
                    controller.selectOrAddExternalSubtitle(path: srtURL.path)
                }
                return
            }
            Task { await downloadOnlineSubtitle(result) }
        } label: {
            HStack(spacing: 9) {
                Group {
                    if isDownloading {
                        ProgressView().scaleEffect(0.65).tint(.white.opacity(0.7))
                    } else if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.70))
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.white.opacity(0.40))
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(result.sourceName) · \(result.language) · \(result.downloads) 下载")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .background(
                isDownloaded
                    ? Color.white.opacity(0.10)
                    : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if isDownloaded {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDownloading || (downloadingID != nil && !isDownloading))
    }

    @ViewBuilder
    private func playerPopoverSectionHeader(_ title: String) -> some View {
        Divider()
            .background(.white.opacity(0.18))
            .padding(.vertical, 2)
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct PlayerTrackRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.white.opacity(0.94) : Color.white.opacity(0.42))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.06), lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PlayerVolumeHUD: View {
    let volume: Float

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            GeometryReader { proxy in
                let width = proxy.size.width * CGFloat(volume)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.78)).frame(width: width)
                }
            }
            .frame(width: 128, height: 6)
            Text("\(Int((volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .playerGlass(cornerRadius: 18)
    }
}

private struct VideoScrubberPreview: Equatable {
    let time: Double
    let x: CGFloat
}

private struct VideoProgressScrubber: View {
    let currentTime: Double
    let duration: Double
    let enabled: Bool
    let coarsePreviewBuckets: Bool
    @Binding var preview: VideoScrubberPreview?
    let previewImage: NSImage?
    let previewIsLoading: Bool
    let markers: [PlaybackMarker]
    let onSeek: (Double) -> Void
    @State private var isDragging = false
    @State private var draftTime: Double?
    @State private var lastPreviewLocation: CGPoint?
    @State private var lastPreviewUpdate = Date.distantPast
    @State private var lastPreviewBucket: Int?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let displayTime = draftTime ?? currentTime
            let fraction = duration > 0 ? min(max(displayTime / duration, 0), 1) : 0
            let progressWidth = width * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 6)
                Capsule()
                    .fill(.white.opacity(enabled ? 0.78 : 0.34))
                    .frame(width: progressWidth, height: 6)
                ForEach(markers.filter { ($0.kind == .intro || $0.kind == .credits) && $0.isCompleteRange }) { marker in
                    let startFraction = duration > 0 ? min(max(marker.startTime / duration, 0), 1) : 0
                    let endFraction = duration > 0 ? min(max((marker.endTime ?? marker.startTime) / duration, 0), 1) : 0
                    Capsule()
                        .fill(marker.kind == .intro ? Color.cyan.opacity(0.62) : Color.orange.opacity(0.62))
                        .frame(width: max(width * CGFloat(endFraction - startFraction), 2), height: 6)
                        .offset(x: width * CGFloat(startFraction))
                }
                ForEach(markers) { marker in
                    let markerFraction = duration > 0 ? min(max(marker.startTime / duration, 0), 1) : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(marker.kind == .chapter ? 0.82 : 0.96))
                        .frame(width: 2, height: marker.kind == .chapter ? 9 : 11)
                        .offset(x: min(max(width * CGFloat(markerFraction) - 1, 0), max(width - 2, 0)))
                }
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 13 : 10, height: isDragging ? 13 : 10)
                    .shadow(color: .black.opacity(0.11), radius: 3, y: 1)
                    .offset(x: min(max(progressWidth - 5, 0), max(width - 10, 0)))
                    .opacity(enabled ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let preview {
                    PlayerProgressPreviewBubble(
                        time: preview.time,
                        image: previewImage,
                        isLoading: previewIsLoading
                    )
                    .offset(x: min(max(preview.x - 82, 0), max(width - 164, 0)), y: -106)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, duration > 0 else { return }
                        isDragging = true
                        let clampedX = min(max(value.location.x, 0), width)
                        updatePreview(
                            location: CGPoint(x: clampedX, y: value.location.y),
                            width: width,
                            force: true,
                            updateDraftTime: true
                        )
                    }
                    .onEnded { value in
                        guard enabled, duration > 0 else {
                            isDragging = false
                            draftTime = nil
                            return
                        }
                        let clampedX = min(max(value.location.x, 0), width)
                        let target = Double(clampedX / max(width, 1)) * duration
                        isDragging = false
                        draftTime = target
                        onSeek(target)
                        lastPreviewLocation = nil
                        lastPreviewBucket = nil
                        DispatchQueue.main.async {
                            draftTime = nil
                        }
                    }
            )
            .onContinuousHover { phase in
                guard enabled, duration > 0 else {
                    clearPreview()
                    return
                }
                switch phase {
                case .active(let location):
                    let clampedX = min(max(location.x, 0), width)
                    updatePreview(
                        location: CGPoint(x: clampedX, y: location.y),
                        width: width,
                        force: false,
                        updateDraftTime: false
                    )
                case .ended:
                    if !isDragging {
                        clearPreview()
                    }
                }
            }
        }
        .frame(height: 22)
        .animation(AppMotion.fast, value: isDragging)
    }

    private func updatePreview(
        location: CGPoint,
        width: CGFloat,
        force: Bool,
        updateDraftTime: Bool
    ) {
        let target = Double(location.x / max(width, 1)) * duration
        let bucket = VideoFramePreviewGenerator.bucket(for: target, duration: duration, preferCoarse: coarsePreviewBuckets)
        if !force {
            let now = Date()
            guard bucket != lastPreviewBucket ||
                    PointerHoverThrottle.shouldUpdate(
                        from: lastPreviewLocation,
                        previousUpdate: lastPreviewUpdate,
                        to: location,
                        now: now,
                        minInterval: 1.0 / 30.0,
                        minDistance: 8
                    ) else { return }
            lastPreviewUpdate = now
        } else {
            lastPreviewUpdate = Date()
        }
        lastPreviewLocation = location
        lastPreviewBucket = bucket
        if updateDraftTime {
            draftTime = target
        }
        preview = VideoScrubberPreview(time: target, x: location.x)
    }

    private func clearPreview() {
        preview = nil
        lastPreviewLocation = nil
        lastPreviewBucket = nil
    }
}

private struct PlayerMiniSpinner: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.16, to: 0.78)
            .stroke(
                AngularGradient(
                    colors: [
                        .white.opacity(0.18),
                        .white.opacity(0.92),
                        .white.opacity(0.34)
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.82).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct PlayerProgressPreviewBubble: View {
    let time: Double
    let image: NSImage?
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 148, height: 83)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 7) {
                        PlayerMiniSpinner()
                            .frame(width: 22, height: 22)
                            .opacity(isLoading ? 1 : 0.72)
                        Text(isLoading ? "提取预览" : "暂无预览")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.66))
                    }
                }
            }
            .frame(width: 148, height: 83)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.10),
                                Color.black.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.12), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.55
                    )
            }

            Text(PlayerProgressPreviewBubble.format(time))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(7)
        .playerGlass(cornerRadius: 13)
        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private enum VideoFramePreviewGenerator {
    private static let cache = NSCache<NSString, NSImage>()
    private static let previewSize = CGSize(width: 312, height: 176)

    static func bucket(for time: Double, duration: Double, preferCoarse: Bool) -> Int {
        let interval = segmentInterval(duration: duration, preferCoarse: preferCoarse)
        let segmentIndex = floor(max(time, 0) / interval)
        let sampleTime = min(max(segmentIndex * interval + interval * 0.5, 0), max(duration - 0.25, 0))
        return Int(sampleTime.rounded())
    }

    static func cachedImage(itemID: String, time: Double, duration: Double, preferFFmpeg: Bool) -> NSImage? {
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let key = "\(itemID)-\(bucket)" as NSString
        return cache.object(forKey: key)
    }

    static func prefetchAround(itemID: String, filePath: String, time: Double, duration: Double, preferFFmpeg: Bool) {
        let interval = segmentInterval(duration: duration, preferCoarse: preferFFmpeg)
        let candidates = [time + interval, time - interval, time + interval * 2]
            .filter { $0 >= 0 && (duration <= 0 || $0 <= duration) }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .background) {
            for candidate in candidates {
                if Task.isCancelled { return }
                if Self.cachedImage(itemID: itemID, time: candidate, duration: duration, preferFFmpeg: preferFFmpeg) != nil { continue }
                _ = await Self.image(itemID: itemID, filePath: filePath, time: candidate, duration: duration, preferFFmpeg: preferFFmpeg)
            }
        }
    }

    static func image(itemID: String, filePath: String, time: Double, duration: Double, preferFFmpeg: Bool) async -> NSImage? {
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let key = "\(itemID)-\(bucket)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        return await Task.detached(priority: .utility) {
            let seconds = max(Double(bucket), 0)
            if !preferFFmpeg,
               let image = Self.avFoundationImage(filePath: filePath, seconds: seconds) {
                return SendableVideoPreviewImage(image)
            }
            if let image = Self.ffmpegImage(itemID: itemID, filePath: filePath, bucket: bucket, seconds: seconds) {
                return SendableVideoPreviewImage(image)
            }
            if preferFFmpeg,
               let image = Self.avFoundationImage(filePath: filePath, seconds: seconds) {
                return SendableVideoPreviewImage(image)
            }
            return SendableVideoPreviewImage(nil)
        }.value.image.map { image in
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            return image
        }
    }

    private static func segmentInterval(duration: Double, preferCoarse: Bool) -> Double {
        guard duration.isFinite, duration > 0 else {
            return preferCoarse ? 18 : 12
        }
        let targetSegments = preferCoarse ? 84.0 : 96.0
        let minimum = preferCoarse ? 12.0 : 8.0
        let maximum = preferCoarse ? 120.0 : 90.0
        return min(max(duration / targetSegments, minimum), maximum)
    }

    private static func avFoundationImage(filePath: String, seconds: Double) -> NSImage? {
        let url: URL
        if let remoteURL = URL(string: filePath),
           let scheme = remoteURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            url = remoteURL
        } else {
            url = URL(fileURLWithPath: filePath)
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = previewSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil
        ), !Self.isLikelyBlackFrame(cgImage) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func ffmpegImage(itemID: String, filePath: String, bucket: Int, seconds: Double) -> NSImage? {
        guard let ffmpegURL = Self.ffmpegExecutableURL() else { return nil }
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaLibPreviewFrames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let safeID = itemID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let outputURL = outputDirectory.appendingPathComponent("\(safeID)-\(bucket).jpg")
        if let cached = NSImage(contentsOf: outputURL),
           let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil),
           !Self.isLikelyBlackFrame(cgImage) {
            return cached
        }

        let seekTimes = [seconds, max(seconds + 1.5, 0), max(seconds - 1.5, 0)]
        for seek in seekTimes {
            try? FileManager.default.removeItem(at: outputURL)
            let arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-ss", String(format: "%.3f", seek),
                "-i", filePath,
                "-frames:v", "1",
                "-vf", "scale=312:176:force_original_aspect_ratio=decrease,pad=312:176:(ow-iw)/2:(oh-ih)/2",
                "-q:v", "4",
                outputURL.path
            ]
            if Self.runFFmpeg(ffmpegURL: ffmpegURL, arguments: arguments, timeout: 9),
               let image = Self.validateGeneratedFrame(outputURL) {
                return image
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
        return nil
    }

    private static func ffmpegExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(ffmpegURL: URL, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func validateGeneratedFrame(_ url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !Self.isLikelyBlackFrame(cgImage) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return image
    }

    private static func isLikelyBlackFrame(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let sampleCount = min(600, image.width * image.height)
        guard sampleCount > 0 else { return false }

        var darkSamples = 0
        let dataLength = CFDataGetLength(data)
        for i in 0..<sampleCount {
            let x = (i * 37) % image.width
            let y = (i * 53) % image.height
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            guard offset + min(bytesPerPixel - 1, 2) < dataLength else { continue }
            let r = Int(bytes[offset])
            let g = bytesPerPixel > 1 ? Int(bytes[offset + 1]) : r
            let b = bytesPerPixel > 2 ? Int(bytes[offset + 2]) : r
            if (r + g + b) / 3 < 14 {
                darkSamples += 1
            }
        }
        return Double(darkSamples) / Double(sampleCount) > 0.90
    }
}

private struct SendableVideoPreviewImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

private extension View {
    func playerPopoverGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self
            .foregroundStyle(.white)
            .tint(.white.opacity(0.92))
            .environment(\.colorScheme, .dark)
            .background(.thinMaterial, in: shape)
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.13),
                            Color.black.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(0.34), lineWidth: 0.9)
                    .blur(radius: 0.5)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .white.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
            .shadow(color: .white.opacity(0.07), radius: 1, y: -0.5)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private extension View {
    func playerGlass(cornerRadius: CGFloat) -> some View {
        modifier(PlayerGlassModifier(cornerRadius: cornerRadius))
    }

    func playerControlIcon(width: CGFloat = 28, height: CGFloat = 28) -> some View {
        self
            .font(.system(size: 13, weight: .semibold))
            .frame(width: width, height: height)
            .background {
                ZStack {
                    Circle().fill(.thinMaterial)
                    Circle().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .white.opacity(0.11), .black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.36), .white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
    }

    func playerCapsuleControl(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.31), .white.opacity(0.12), .black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: .black.opacity(0.055), radius: 3, y: 1)
    }
}

struct MpvPlayerView: NSViewRepresentable {
    @ObservedObject var controller: MpvPlayerController

    func makeNSView(context: Context) -> MpvOpenGLView {
        let view = MpvOpenGLView(controller: controller)
        DispatchQueue.main.async {
            controller.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: MpvOpenGLView, context: Context) {
        nsView.controller = controller
        DispatchQueue.main.async {
            controller.attach(to: nsView)
        }
    }
}

final class MpvOpenGLView: NSOpenGLView {
    weak var controller: MpvPlayerController?

    init(controller: MpvPlayerController) {
        self.controller = controller
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize),
            24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize),
            8,
            0
        ]
        if let pixelFormat = NSOpenGLPixelFormat(attributes: attributes) {
            super.init(frame: .zero, pixelFormat: pixelFormat)!
        } else {
            super.init(frame: .zero)
        }
        wantsBestResolutionOpenGLSurface = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        attachWhenReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWhenReady()
    }

    override func reshape() {
        super.reshape()
        openGLContext?.update()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let openGLContext else { return }
        openGLContext.makeCurrentContext()
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        let backingBounds = convertToBacking(bounds)
        controller?.render(
            width: Int(backingBounds.width.rounded(.toNearestOrAwayFromZero)),
            height: Int(backingBounds.height.rounded(.toNearestOrAwayFromZero))
        )
        openGLContext.flushBuffer()
    }

    private func attachWhenReady() {
        guard window != nil, openGLContext != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.controller?.attach(to: self)
        }
    }
}

struct MpvTrack: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case audio
        case subtitle = "sub"
        case unknown
    }

    let id: Int
    let type: Kind
    let title: String?
    let language: String?
    let codec: String?
    let isSelected: Bool
    let isExternal: Bool
    let externalFilename: String?

    var displayName: String {
        var parts: [String] = []
        if let language, !language.isEmpty {
            parts.append(language.uppercased())
        }
        if let title, !title.isEmpty {
            parts.append(title)
        }
        if let codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if parts.isEmpty {
            switch type {
            case .audio:
                parts.append("音轨 \(id)")
            case .subtitle:
                parts.append("字幕 \(id)")
            case .unknown:
                parts.append("轨道 \(id)")
            }
        }
        if isExternal {
            parts.append("外挂")
        }
        return parts.joined(separator: " · ")
    }
}

struct MpvChapter: Identifiable, Hashable {
    let id: Int
    let title: String
    let time: Double
}

@MainActor
final class MpvPlayerController: ObservableObject {
    private struct PreloadedMusicItem {
        let itemID: String
        let filePath: String
        let playerItem: AVPlayerItem
    }

    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isPreparing = false
    @Published var isReady = false
    @Published var hasVideoFrame = false
    @Published var isPlaying = false
    @Published var playbackRate: Float = 1.0
    @Published var volume: Float = 0.8
    @Published var currentTime: Double = 0
    @Published private(set) var lyricTime: Double = 0
    @Published var duration: Double = 0
    @Published var videoAspectRatio: CGFloat?
    @Published var audioTracks: [MpvTrack] = []
    @Published var subtitleTracks: [MpvTrack] = []
    @Published var chapters: [MpvChapter] = []
    @Published var subtitleAutoLoadEnabled = false
    @Published var isBuffering = false
    @Published var bufferProgress: Double?
    @Published var audioSpectrumBands: [CGFloat] = AudioSpectrumAnalyzer.silenceBands
    @Published private(set) var seekSyncRevision = 0
    @Published private(set) var seekState: PlaybackSeekState?
    @Published private(set) var routePickerRevision = 0

    let routePickerSession = AirPlayRoutePickerSession()
    var onVolumeChange: ((Float) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onPlaybackReport: ((PlayerPlaybackReport) -> Void)?

    var routePickerPlayer: AVPlayer? {
        return audioPlayer ?? videoRouteProxyPlayer
    }

    var canControl: Bool {
        if audioPlayer != nil {
            return errorMessage == nil && !isPreparing
        }
        if libMpvClient != nil {
            return errorMessage == nil && !isPreparing
        }
        return false
    }

    var isWaitingForVideoFrame: Bool {
        item?.type != .music && isReady && !hasVideoFrame && errorMessage == nil
    }

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        duration > 0 ? formatTime(duration) : "--:--"
    }

    var playbackStatusText: String {
        if isPreparing {
            return statusMessage ?? "正在启动 libmpv 核心"
        }
        if errorMessage != nil {
            return "libmpv 核心不可用"
        }
        if duration > 0 {
            return "libmpv 内核 · \(formattedCurrentTime) / \(formattedDuration)"
        }
        return "libmpv 内核"
    }

    private var item: MediaItem?
    /// A7：当前条目是否已套用过剧集音轨/字幕偏好（每次 configure 重置，避免重复套用或覆盖用户手动选择）。
    private var didApplyTrackPreference = false
    private var libMpvClient: LibMpvClient?
    private var audioPlayer: AVQueuePlayer?
    private var audioLocalMirrorPlayer: AVPlayer?
    private var audioRouteProxyPlayer: AVPlayer?
    private var audioRouteProxyObservation: NSKeyValueObservation?
    private var audioRouteProxyIsActive = false
    private var audioExternalPlaybackObservation: NSKeyValueObservation?
    private var audioRouteRefreshTask: Task<Void, Never>?
    private var videoRouteProxyPlayer: AVPlayer?
    private var videoRouteProxyObservation: NSKeyValueObservation?
    private var videoRouteProxyActivationTask: Task<Void, Never>?
    private var videoRouteProxyIsActive = false
    private var videoRouteProxyIsAudibleProbing = false
    private var audioEndObserver: NSObjectProtocol?
    private weak var renderView: MpvOpenGLView?
    private var timer: Timer?
    private var securityScopedURL: URL?
    private var didSaveProgress = false
    private var didReportPlaybackStart = false
    private var lastPlaybackProgressReportDate = Date.distantPast
    private var filePath: String?
    private var videoStartRetryCount = 0
    private var volumeBeforeMute: Float = 0.8
    private var playbackGeneration = 0
    private var keepLocalAudioWithAirPlay = false
    private var lastTrackRefreshDate = Date.distantPast
    private var lastBufferingState: (active: Bool, progress: Double?) = (false, nil)
    private var playbackTimelineOffset: Double = 0
    private var activeVideoQualityOption: VideoStreamQualityOption?
    private var initialRedrawTask: Task<Void, Never>?
    private var audioSpectrumTask: Task<Void, Never>?
    private var audioTransitionTask: Task<Void, Never>?
    private var musicPreloadTask: Task<Void, Never>?
    private var preloadedMusicItem: PreloadedMusicItem?
    private var seekSyncCorrectionTask: Task<Void, Never>?
    private var clearSeekStateTask: Task<Void, Never>?
    private var pendingTimelineSeek: PendingTimelineSeek?
    private var audioSpectrumVisualizationActive = false
    private var lastAudioSpectrumSampleDate = Date.distantPast
    private var musicNormalizationGain: Float = 1
    private var musicTransitionMode: MusicTransitionMode = .immediate
    private var musicSoftFadeDuration: Double = 0.8
    // EQ：仅当启用且预设非纯平时才给音乐 AVPlayerItem 挂 MTAudioProcessingTap；变更下一首生效。
    private var musicEqualizerEnabled = false
    private var musicEqualizerGains: [Double] = MusicEqualizerPreset.flat.gainsDB
    private var audioTransitionVolumeScale: Float = 1
    private(set) var spectrumSuppressedDuringWindowDrag = false

    /// 窗口拖动/缩放期间临时挂起频谱解码（拖动结束立即恢复）。
    func setSpectrumSuppressedDuringWindowDrag(_ suppressed: Bool) {
        spectrumSuppressedDuringWindowDrag = suppressed
    }

    func configure(item: MediaItem, settings: AppSettings) {
        guard libMpvClient == nil, audioPlayer == nil, !isPreparing else { return }
        playbackGeneration += 1
        clearVideoRouteProxy()
        self.item = item
        didApplyTrackPreference = false
        didSaveProgress = false
        didReportPlaybackStart = false
        lastPlaybackProgressReportDate = .distantPast
        videoStartRetryCount = 0
        errorMessage = nil
        statusMessage = "正在启动 mpv 内核。"
        pendingTimelineSeek = nil
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekState = nil
        isPreparing = true
        hasVideoFrame = false
        playbackRate = Float(settings.defaultPlaybackRate)
        keepLocalAudioWithAirPlay = false
        volume = Float(settings.rememberedVolume(for: item.type))
        volumeBeforeMute = max(volume, 0.4)
        configureMusicOutput(for: item, settings: settings, isTrackTransition: false)
        videoAspectRatio = nil
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands
        playbackTimelineOffset = 0
        activeVideoQualityOption = nil
        updateBuffering(active: false, progress: nil)
        lastTrackRefreshDate = .distantPast

        guard let filePath = item.filePath,
              item.isRemoteResource || FileManager.default.fileExists(atPath: filePath) else {
            fail("媒体文件不存在，可能是 NAS 未挂载、移动硬盘断开，或文件已被移动。")
            return
        }
        self.filePath = filePath
        duration = item.duration ?? 0
        currentTime = item.type == .music ? 0 : (settings.rememberPlaybackPosition ? item.playPosition : 0)
        lyricTime = currentTime

        if !item.isRemoteResource {
            let url = URL(fileURLWithPath: filePath)
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
            }
        }
        if item.type == .music {
            startNativeAudio()
        } else {
            updateBuffering(active: true, progress: 0)
            prepareVideoRouteProxy(for: item, filePath: filePath)
            startMpv()
        }
    }

    func configureMusic(item: MediaItem, settings: AppSettings) {
        guard item.type == .music else {
            configure(item: item, settings: settings)
            return
        }
        if self.item?.id == item.id,
           audioPlayer != nil,
           audioPlayer?.currentItem != nil,
           libMpvClient == nil,
           errorMessage == nil {
            return
        }
        guard audioPlayer != nil, libMpvClient == nil else {
            teardown()
            configure(item: item, settings: settings)
            return
        }
        switchNativeAudio(to: item, settings: settings)
    }

    func updateMusicOutputSettings(settings: AppSettings) {
        guard let item, item.type == .music, audioPlayer != nil else { return }
        configureMusicOutput(for: item, settings: settings, isTrackTransition: false)
        applyAudioOutputVolume()
    }

    func preloadNextMusicItem(_ nextItem: MediaItem?) {
        musicPreloadTask?.cancel()
        musicPreloadTask = nil

        guard let nextItem,
              nextItem.type == .music,
              musicTransitionMode == .immediate,
              !nextItem.isRemoteResource,
              nextItem.id != item?.id,
              let nextPath = nextItem.filePath,
              FileManager.default.fileExists(atPath: nextPath),
              let player = audioPlayer else {
            clearPreloadedMusicItem()
            return
        }
        if preloadedMusicItem?.itemID == nextItem.id {
            return
        }

        clearPreloadedMusicItem()
        let generation = playbackGeneration
        let asset = AVURLAsset(url: URL(fileURLWithPath: nextPath))
        musicPreloadTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let playable = try await asset.load(.isPlayable)
                _ = try await asset.load(.duration)
                guard playable,
                      !Task.isCancelled,
                      self.playbackGeneration == generation,
                      self.audioPlayer === player,
                      self.item?.id != nextItem.id else { return }
                let playerItem = self.makeAudioPlayerItem(asset: asset, isLocal: true, preloaded: true)
                guard player.canInsert(playerItem, after: player.items().last) else { return }
                player.insert(playerItem, after: player.items().last)
                self.preloadedMusicItem = PreloadedMusicItem(
                    itemID: nextItem.id,
                    filePath: nextPath,
                    playerItem: playerItem
                )
            } catch {
                return
            }
            self.musicPreloadTask = nil
        }
    }

    func attach(to view: MpvOpenGLView) {
        renderView = view
        if item?.type != .music, isPreparing, libMpvClient == nil {
            startMpv()
        }
    }

    func detach(from view: MpvOpenGLView) {
        if renderView === view {
            renderView = nil
        }
    }

    private func startMpv() {
        guard libMpvClient == nil, let filePath else { return }
        guard let renderView, renderView.window != nil, let openGLContext = renderView.openGLContext else {
            videoStartRetryCount += 1
            if videoStartRetryCount <= 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.startMpv()
                }
            } else {
                fail("播放器视图没有准备完成，无法创建视频渲染上下文。")
            }
            return
        }

        do {
            let client = try LibMpvClient(
                openGLContext: openGLContext,
                startTime: currentTime,
                volume: volume,
                speed: playbackRate
            ) { [weak renderView] in
                renderView?.needsDisplay = true
            }
            try client.loadFile(filePath)
            libMpvClient = client
            isPreparing = false
            isReady = true
            isPlaying = true
            statusMessage = nil
            updateBuffering(active: false, progress: nil)
            scheduleInitialVideoRedraws()
            updateSystemNowPlaying()
            startTimer()
            reportPlayback(.started, force: true)
            return
        } catch {
            fail("libmpv 播放核心启动失败：\(error.localizedDescription)")
            return
        }
    }

    func render(width: Int, height: Int) {
        libMpvClient?.render(width: width, height: height)
    }

    private func startNativeAudio() {
        guard let filePath else { return }
        guard let url = audioURL(for: filePath, isRemote: item?.isRemoteResource == true) else {
            fail("音频路径不可用。")
            return
        }

        let generation = playbackGeneration
        let playerItem = makeAudioPlayerItem(url: url)
        let player = AVQueuePlayer(items: [playerItem])
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        player.volume = effectiveMusicVolume

        observeAudioEnd(for: playerItem, generation: generation)
        observeAudioExternalPlayback(for: player)

        audioPlayer = player
        isPreparing = false
        isReady = true
        isPlaying = false
        statusMessage = nil
        updateSystemNowPlaying()
        configureMusicRouteProxyIfNeeded()

        let startSeconds = max(currentTime, 0)
        if startSeconds > 0 {
            player.seek(
                to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.playbackGeneration == generation,
                          self.audioPlayer === player,
                          player.currentItem === playerItem else { return }
                    player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                    self.updateSystemNowPlaying()
                    self.reportPlayback(.started, force: true)
                }
            }
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            updateSystemNowPlaying()
            reportPlayback(.started, force: true)
        }
        startTimer()
        refreshMusicAirPlayRoute(afterRoutePicker: true)
    }

    private func switchNativeAudio(to nextItem: MediaItem, settings: AppSettings) {
        guard let player = audioPlayer else {
            configure(item: nextItem, settings: settings)
            return
        }
        guard let nextPath = nextItem.filePath,
              nextItem.isRemoteResource || FileManager.default.fileExists(atPath: nextPath),
              let url = audioURL(for: nextPath, isRemote: nextItem.isRemoteResource) else {
            fail("音频文件不存在，可能是 NAS 未挂载、移动硬盘断开，或文件已被移动。")
            return
        }

        let queuedPreload: PreloadedMusicItem? = preloadedMusicItem.flatMap { preloaded -> PreloadedMusicItem? in
            guard preloaded.itemID == nextItem.id,
                  player.items().contains(where: { $0 === preloaded.playerItem }) else {
                return nil
            }
            return preloaded
        }
        let alreadyAdvancedToPreload = queuedPreload.map { player.currentItem === $0.playerItem } == true
        reportPlayback(.stopped, force: true)
        playbackGeneration += 1
        let generation = playbackGeneration
        removeAudioEndObserver()
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        musicPreloadTask?.cancel()
        musicPreloadTask = nil
        if alreadyAdvancedToPreload {
            preloadedMusicItem = nil
        } else {
            player.currentItem?.cancelPendingSeeks()
            removeAudioExternalPlaybackObserver()
            audioRouteRefreshTask?.cancel()
            audioRouteRefreshTask = nil
            stopAudioLocalMirror()
            clearAudioRouteProxy()
            player.pause()
            if queuedPreload == nil {
                clearPreloadedMusicItem()
            }
        }
        stopSecurityScopedResource()

        self.item = nextItem
        didSaveProgress = false
        didReportPlaybackStart = false
        lastPlaybackProgressReportDate = .distantPast
        filePath = nextPath
        errorMessage = nil
        statusMessage = nil
        isPreparing = false
        isReady = true
        isPlaying = false
        playbackRate = Float(settings.defaultPlaybackRate)
        keepLocalAudioWithAirPlay = false
        volume = Float(settings.rememberedVolume(for: nextItem.type))
        volumeBeforeMute = max(volume, 0.4)
        configureMusicOutput(for: nextItem, settings: settings, isTrackTransition: true)
        duration = nextItem.duration ?? 0
        currentTime = 0
        lyricTime = 0
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekState = nil
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands

        if !nextItem.isRemoteResource {
            let securityURL = URL(fileURLWithPath: nextPath)
            if securityURL.startAccessingSecurityScopedResource() {
                securityScopedURL = securityURL
            }
        }

        let playerItem = queuedPreload?.playerItem ?? makeAudioPlayerItem(url: url)
        observeAudioEnd(for: playerItem, generation: generation)
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        if !alreadyAdvancedToPreload {
            observeAudioExternalPlayback(for: player)
            if queuedPreload != nil {
                player.advanceToNextItem()
                preloadedMusicItem = nil
            } else {
                player.removeAllItems()
                player.insert(playerItem, after: nil)
            }
        }
        applyAudioOutputVolume()
        updateSystemNowPlaying()
        if !alreadyAdvancedToPreload {
            configureMusicRouteProxyIfNeeded()
        }

        let startSeconds = max(currentTime, 0)
        if alreadyAdvancedToPreload {
            isPlaying = player.rate > 0
            if !isPlaying {
                player.playImmediately(atRate: playbackRate)
                isPlaying = true
            }
            startSoftFadeInIfNeeded(generation: generation)
            updateSystemNowPlaying()
            reportPlayback(.started, force: true)
            startTimer()
            return
        }
        if startSeconds > 0 {
            player.seek(
                to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.playbackGeneration == generation,
                          self.audioPlayer === player,
                          player.currentItem === playerItem else { return }
                    player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                    self.startSoftFadeInIfNeeded(generation: generation)
                    self.updateSystemNowPlaying()
                    self.reportPlayback(.started, force: true)
                }
            }
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            startSoftFadeInIfNeeded(generation: generation)
            updateSystemNowPlaying()
            reportPlayback(.started, force: true)
        }
        startTimer()
        refreshMusicAirPlayRoute(afterRoutePicker: true)
    }

    private func audioURL(for filePath: String, isRemote: Bool) -> URL? {
        if isRemote {
            return URL(string: filePath)
        }
        return URL(fileURLWithPath: filePath)
    }

    private func makeAudioPlayerItem(url: URL, applyEqualizer: Bool = true) -> AVPlayerItem {
        makeAudioPlayerItem(asset: AVURLAsset(url: url), isLocal: url.isFileURL, applyEqualizer: applyEqualizer)
    }

    private func makeAudioPlayerItem(asset: AVAsset, isLocal: Bool, preloaded: Bool = false, applyEqualizer: Bool = true) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: asset)
        if isLocal {
            playerItem.preferredForwardBufferDuration = preloaded ? 6 : 0
        } else {
            playerItem.preferredForwardBufferDuration = 2
        }
        // 仅在启用且非纯平时挂 EQ；失败则保持原样（透传），不影响播放。
        // 仅对本地文件挂 EQ：makeAudioMix 内部会同步访问 asset.tracks，远端资源在主线程同步取轨会阻塞 UI；
        // EQ 主要面向本地高保真，远端流跳过以规避主线程卡顿。
        if applyEqualizer, musicEqualizerEnabled, isLocal {
            let processor = AudioEQProcessor(gainsDB: musicEqualizerGains)
            if let mix = processor.makeAudioMix(for: asset) {
                playerItem.audioMix = mix
            }
        }
        return playerItem
    }

    private func clearPreloadedMusicItem() {
        musicPreloadTask?.cancel()
        musicPreloadTask = nil
        guard let preloadedMusicItem else { return }
        if audioPlayer?.currentItem !== preloadedMusicItem.playerItem {
            audioPlayer?.remove(preloadedMusicItem.playerItem)
        }
        self.preloadedMusicItem = nil
    }

    private func prepareVideoRouteProxy(for item: MediaItem, filePath: String) {
        clearVideoRouteProxy()
        guard let url = audioURL(for: filePath, isRemote: item.isRemoteResource) else { return }
        let playerItem = makeAudioPlayerItem(url: url, applyEqualizer: false)
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.isMuted = true
        player.volume = 0
        videoRouteProxyPlayer = player
        videoRouteProxyObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self,
                      self.videoRouteProxyPlayer === observedPlayer else { return }
                self.setVideoRouteProxyActive(observedPlayer.isExternalPlaybackActive)
            }
        }
        routePickerRevision &+= 1
    }

    func refreshVideoAirPlayRoute(afterRoutePicker: Bool = false) {
        guard item?.type != .music, let player = videoRouteProxyPlayer else { return }
        videoRouteProxyActivationTask?.cancel()
        setVideoRouteProxyActive(player.isExternalPlaybackActive)
        if isPlaying {
            syncVideoRouteProxyPlayback(probing: true, audibleProbe: afterRoutePicker)
        }
        videoRouteProxyActivationTask = Task { @MainActor [weak self, weak player] in
            let probeCount = afterRoutePicker ? 32 : 12
            for _ in 0..<probeCount {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                guard let self,
                      let player,
                      self.videoRouteProxyPlayer === player else { return }
                self.setVideoRouteProxyActive(player.isExternalPlaybackActive)
                if player.isExternalPlaybackActive {
                    return
                }
            }
            self?.videoRouteProxyIsAudibleProbing = false
            self?.applyVideoLocalVolumeForRouteState()
            if self?.videoRouteProxyIsActive != true {
                player?.pause()
            }
        }
    }

    func prepareForVideoAirPlayRouteSelection() {
        guard item?.type != .music else { return }
        routePickerRevision &+= 1
        videoRouteProxyPlayer?.allowsExternalPlayback = true
        syncVideoRouteProxyPlayback(probing: true, audibleProbe: true)
    }

    private func setVideoRouteProxyActive(_ active: Bool) {
        guard item?.type != .music, let player = videoRouteProxyPlayer else { return }
        videoRouteProxyIsActive = active
        if active {
            videoRouteProxyIsAudibleProbing = false
        }
        player.isMuted = !active
        player.volume = active ? volume : 0
        applyVideoLocalVolumeForRouteState()
        if active {
            syncVideoRouteProxyPlayback(probing: false)
        } else {
            player.pause()
        }
    }

    private func syncVideoRouteProxyPlayback(probing: Bool = false, audibleProbe: Bool = false) {
        guard item?.type != .music, let player = videoRouteProxyPlayer else { return }
        videoRouteProxyIsAudibleProbing = audibleProbe && probing && isPlaying
        applyVideoLocalVolumeForRouteState()
        guard videoRouteProxyIsActive || probing else {
            player.pause()
            return
        }
        player.allowsExternalPlayback = true
        let proxyShouldOutput = videoRouteProxyIsActive || videoRouteProxyIsAudibleProbing
        player.volume = proxyShouldOutput ? volume : 0
        player.isMuted = !proxyShouldOutput
        player.seek(
            to: CMTime(seconds: max(currentTime, 0), preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self,
                      let player,
                      self.videoRouteProxyPlayer === player else { return }
                if self.isPlaying {
                    player.playImmediately(atRate: self.playbackRate)
                } else {
                    player.pause()
                }
            }
        }
    }

    private func clearVideoRouteProxy() {
        videoRouteProxyActivationTask?.cancel()
        videoRouteProxyActivationTask = nil
        videoRouteProxyObservation = nil
        videoRouteProxyPlayer?.pause()
        videoRouteProxyPlayer?.replaceCurrentItem(with: nil)
        videoRouteProxyPlayer = nil
        videoRouteProxyIsActive = false
        videoRouteProxyIsAudibleProbing = false
        applyVideoLocalVolumeForRouteState()
        routePickerRevision &+= 1
    }

    private func applyVideoLocalVolumeForRouteState() {
        guard item?.type != .music, let libMpvClient else { return }
        let localVolume = (videoRouteProxyIsActive || videoRouteProxyIsAudibleProbing) ? 0 : volume
        libMpvClient.setDouble("volume", Double(localVolume * 100))
    }

    private func configureMusicRouteProxyIfNeeded() {
        guard item?.type == .music, let player = audioPlayer else { return }
        keepLocalAudioWithAirPlay = false
        player.allowsExternalPlayback = true
        clearAudioRouteProxy()
        setAudioLocalMirrorActive(false)
        routePickerRevision &+= 1
    }

    private func prepareAudioRouteProxyIfNeeded() {
        guard audioRouteProxyPlayer == nil,
              item?.type == .music,
              let filePath,
              let url = audioURL(for: filePath, isRemote: item?.isRemoteResource == true) else { return }
        let proxyItem = makeAudioPlayerItem(url: url)
        let proxy = AVPlayer(playerItem: proxyItem)
        proxy.allowsExternalPlayback = true
        proxy.automaticallyWaitsToMinimizeStalling = false
        proxy.actionAtItemEnd = .pause
        proxy.isMuted = true
        proxy.volume = 0
        audioRouteProxyPlayer = proxy
        audioRouteProxyObservation = proxy.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self,
                      self.audioRouteProxyPlayer === observedPlayer else { return }
                self.setAudioRouteProxyActive(observedPlayer.isExternalPlaybackActive)
            }
        }
    }

    private func clearAudioRouteProxy() {
        audioRouteProxyObservation = nil
        audioRouteProxyPlayer?.pause()
        audioRouteProxyPlayer?.replaceCurrentItem(with: nil)
        audioRouteProxyPlayer = nil
        audioRouteProxyIsActive = false
        routePickerRevision &+= 1
    }

    private func setAudioRouteProxyActive(_ active: Bool) {
        guard item?.type == .music,
              keepLocalAudioWithAirPlay,
              let proxy = audioRouteProxyPlayer else { return }
        audioRouteProxyIsActive = active
        proxy.isMuted = !active
        proxy.volume = active ? effectiveMusicVolume : 0
        if active {
            syncAudioRouteProxyPlayback(probing: false)
        } else {
            proxy.pause()
        }
    }

    private func syncAudioRouteProxyPlayback(probing: Bool = false) {
        guard item?.type == .music,
              keepLocalAudioWithAirPlay,
              let proxy = audioRouteProxyPlayer else { return }
        guard audioRouteProxyIsActive || probing else {
            proxy.pause()
            return
        }
        proxy.allowsExternalPlayback = true
        proxy.isMuted = probing || !audioRouteProxyIsActive
        proxy.volume = audioRouteProxyIsActive ? effectiveMusicVolume : 0
        proxy.seek(
            to: CMTime(seconds: max(currentTime, 0), preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.20, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.20, preferredTimescale: 600)
        ) { [weak self, weak proxy] _ in
            Task { @MainActor in
                guard let self,
                      let proxy,
                      self.audioRouteProxyPlayer === proxy else { return }
                if self.isPlaying {
                    proxy.playImmediately(atRate: self.playbackRate)
                } else {
                    proxy.pause()
                }
            }
        }
    }

    private func observeAudioEnd(for playerItem: AVPlayerItem, generation: Int) {
        removeAudioEndObserver()
        audioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                guard let self, self.playbackGeneration == generation else { return }
                let advancedToPreloaded = self.preloadedMusicItem.map {
                    self.audioPlayer?.currentItem === $0.playerItem
                } == true
                self.isPlaying = advancedToPreloaded || (self.audioPlayer?.rate ?? 0) > 0
                self.onPlaybackFinished?()
            }
        }
    }

    private func observeAudioExternalPlayback(for player: AVPlayer) {
        removeAudioExternalPlaybackObserver()
        audioExternalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor in
                guard let self,
                      self.audioPlayer === observedPlayer else { return }
                self.routePickerRevision &+= 1
            }
        }
        routePickerRevision &+= 1
    }

    func refreshMusicAirPlayRoute(afterRoutePicker: Bool = false) {
        guard item?.type == .music, let player = audioPlayer else { return }
        audioRouteRefreshTask?.cancel()
        keepLocalAudioWithAirPlay = false
        player.allowsExternalPlayback = true
        setAudioLocalMirrorActive(false)
        audioRouteRefreshTask = Task { @MainActor [weak self, weak player] in
            let probeCount = afterRoutePicker ? 32 : 12
            for _ in 0..<probeCount {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                guard let self,
                      let player,
                      self.item?.type == .music,
                      self.audioPlayer === player else { return }
                player.allowsExternalPlayback = true
                self.setAudioLocalMirrorActive(false)
                if player.isExternalPlaybackActive {
                    return
                }
            }
        }
    }

    func prepareForMusicAirPlayRouteSelection() {
        guard item?.type == .music else { return }
        keepLocalAudioWithAirPlay = false
        clearAudioRouteProxy()
        setAudioLocalMirrorActive(false)
        audioPlayer?.allowsExternalPlayback = true
        refreshMusicAirPlayRoute()
    }

    func setAirPlayLocalMirrorEnabled(_ enabled: Bool) {
        keepLocalAudioWithAirPlay = false
        guard item?.type == .music, let player = audioPlayer else { return }
        player.allowsExternalPlayback = true
        configureMusicRouteProxyIfNeeded()
        setAudioLocalMirrorActive(false)
    }

    private func removeAudioEndObserver() {
        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
            self.audioEndObserver = nil
        }
    }

    private func removeAudioExternalPlaybackObserver() {
        audioRouteRefreshTask?.cancel()
        audioRouteRefreshTask = nil
        audioExternalPlaybackObservation = nil
    }

    private func setAudioLocalMirrorActive(_ active: Bool) {
        guard item?.type == .music else { return }
        if active, keepLocalAudioWithAirPlay {
            startAudioLocalMirrorIfNeeded()
            syncAudioLocalMirrorPlayback()
        } else {
            stopAudioLocalMirror()
        }
    }

    private func startAudioLocalMirrorIfNeeded() {
        guard audioLocalMirrorPlayer == nil,
              item?.type == .music,
              let filePath,
              let url = audioURL(for: filePath, isRemote: item?.isRemoteResource == true) else { return }
        let mirrorItem = makeAudioPlayerItem(url: url)
        let mirror = AVPlayer(playerItem: mirrorItem)
        mirror.allowsExternalPlayback = false
        mirror.automaticallyWaitsToMinimizeStalling = false
        mirror.actionAtItemEnd = .pause
        mirror.volume = effectiveMusicVolume
        audioLocalMirrorPlayer = mirror
    }

    private func syncAudioLocalMirrorPlayback() {
        guard let mirror = audioLocalMirrorPlayer else { return }
        mirror.volume = effectiveMusicVolume
        mirror.seek(
            to: CMTime(seconds: max(currentTime, 0), preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.20, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.20, preferredTimescale: 600)
        ) { [weak self, weak mirror] _ in
            Task { @MainActor in
                guard let self,
                      let mirror,
                      self.audioLocalMirrorPlayer === mirror else { return }
                if self.isPlaying {
                    mirror.playImmediately(atRate: self.playbackRate)
                } else {
                    mirror.pause()
                }
            }
        }
    }

    private func stopAudioLocalMirror() {
        audioLocalMirrorPlayer?.pause()
        audioLocalMirrorPlayer?.replaceCurrentItem(with: nil)
        audioLocalMirrorPlayer = nil
    }

    private func stopSecurityScopedResource() {
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
    }

    func togglePlay() {
        guard canControl else { return }
        if let audioPlayer {
            if audioPlayer.currentItem == nil {
                restartFromBeginning()
                return
            }
            if isPlaying {
                audioPlayer.pause()
                audioLocalMirrorPlayer?.pause()
                audioRouteProxyPlayer?.pause()
                isPlaying = false
            } else {
                audioPlayer.playImmediately(atRate: playbackRate)
                syncAudioLocalMirrorPlayback()
                syncAudioRouteProxyPlayback()
                isPlaying = true
            }
            updateSystemNowPlaying()
            reportPlayback(.progress, force: true)
            return
        }
        if let libMpvClient {
            let shouldPlay = !isPlaying
            isPlaying = shouldPlay
            libMpvClient.setFlag("pause", !shouldPlay)
            syncVideoRouteProxyPlayback()
            updateSystemNowPlaying()
            reportPlayback(.progress, force: true)
            return
        }
    }

    func seek(by seconds: Double) {
        seek(to: max(currentTime + seconds, 0))
    }

    func seek(to seconds: Double) {
        guard canControl else { return }
        let target = min(max(seconds, 0), max(duration, 0))
        commitTimelineSeek(to: target)
    }

    func beginScrubbing(to seconds: Double) {
        guard canControl else { return }
        updateScrubbing(to: seconds, createIfNeeded: true)
    }

    func updateScrubbing(to seconds: Double) {
        guard canControl else { return }
        updateScrubbing(to: seconds, createIfNeeded: true)
    }

    func finishScrubbing(to seconds: Double) {
        guard canControl else { return }
        let target = clampedTimelineTime(seconds)
        commitTimelineSeek(to: target)
    }

    func cancelScrubbing() {
        guard seekState?.phase == .scrubbing else { return }
        seekState = nil
        currentTime = lyricTime
        seekSyncRevision &+= 1
    }

    private func updateScrubbing(to seconds: Double, createIfNeeded: Bool) {
        let target = clampedTimelineTime(seconds)
        let revision: Int
        let origin: Double
        if let current = seekState, current.phase == .scrubbing {
            revision = current.revision
            origin = current.originTime
        } else if createIfNeeded {
            revision = nextSeekRevision()
            origin = lyricTime
        } else {
            return
        }
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        pendingTimelineSeek = nil
        currentTime = target
        seekState = PlaybackSeekState(
            revision: revision,
            phase: .scrubbing,
            targetTime: target,
            originTime: origin,
            resolvedTime: nil
        )
    }

    private func commitTimelineSeek(to target: Double) {
        let generation = playbackGeneration
        let seekRevision = beginTimelineSeek(to: target, generation: generation)
        if let audioPlayer {
            scheduleSeekSyncCorrection(for: generation)
            audioPlayer.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak audioPlayer] finished in
                Task { @MainActor in
                    guard let self,
                          let audioPlayer,
                          self.audioPlayer === audioPlayer,
                          self.playbackGeneration == generation,
                          self.seekState?.revision == seekRevision else { return }
                    guard finished else {
                        self.scheduleSeekSyncCorrection(for: generation)
                        return
                    }
                    let actualTime = audioPlayer.currentTime().seconds
                    if self.applyPlaybackClock(
                        actualTime,
                        generation: generation,
                        currentTolerance: 0.035,
                        lyricTolerance: 0.020,
                        force: true
                    ) {
                        self.seekSyncRevision &+= 1
                    }
                    self.scheduleSeekSyncCorrection(for: generation)
                }
            }
            syncAudioLocalMirrorPlayback()
            syncAudioRouteProxyPlayback()
            updateSystemNowPlaying()
            return
        }
        if let libMpvClient {
            if let activeVideoQualityOption,
               !activeVideoQualityOption.appliesInPlace,
               !activeVideoQualityOption.isOriginal,
               playbackTimelineOffset > 0,
               target < playbackTimelineOffset - 0.5 {
                reloadRemoteQualityStream(activeVideoQualityOption, at: target, wasPlaying: isPlaying)
                return
            }
            try? libMpvClient.command(["seek", "\(mpvTimelineTime(for: target))", "absolute", "exact"])
            syncVideoRouteProxyPlayback()
            updateSystemNowPlaying()
            scheduleSeekSyncCorrection(for: playbackGeneration)
            return
        }
    }

    private func clampedTimelineTime(_ seconds: Double) -> Double {
        min(max(seconds, 0), max(duration, 0))
    }

    private func nextSeekRevision() -> Int {
        (seekState?.revision ?? 0) &+ 1
    }

    func restartFromBeginning() {
        currentTime = 0
        lyricTime = 0
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekState = nil
        if let audioPlayer {
            if audioPlayer.currentItem == nil,
               let filePath,
               let url = audioURL(for: filePath, isRemote: item?.isRemoteResource == true) {
                let playerItem = makeAudioPlayerItem(url: url)
                audioPlayer.removeAllItems()
                audioPlayer.insert(playerItem, after: nil)
                observeAudioEnd(for: playerItem, generation: playbackGeneration)
            }
            guard audioPlayer.currentItem != nil else { return }
            audioPlayer.seek(
                to: .zero,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak audioPlayer] _ in
                Task { @MainActor in
                    guard let self, let audioPlayer, self.audioPlayer === audioPlayer else { return }
                    audioPlayer.playImmediately(atRate: self.playbackRate)
                    self.syncAudioLocalMirrorPlayback()
                    self.syncAudioRouteProxyPlayback()
                    self.isPlaying = true
                    self.updateSystemNowPlaying()
                }
            }
            return
        }
        if let libMpvClient {
            try? libMpvClient.command(["seek", "0", "absolute", "exact"])
            libMpvClient.setFlag("pause", false)
            isPlaying = true
            syncVideoRouteProxyPlayback()
            updateSystemNowPlaying()
        }
    }

    func changeRate(by delta: Float) {
        setPlaybackRate(playbackRate + delta)
    }

    func setPlaybackRate(_ rate: Float, updateExternalState: Bool = true) {
        playbackRate = min(max(rate, 0.5), 2.5)
        if let audioPlayer {
            if isPlaying {
                audioPlayer.playImmediately(atRate: playbackRate)
                if updateExternalState {
                    syncAudioLocalMirrorPlayback()
                    syncAudioRouteProxyPlayback()
                }
            }
            if updateExternalState {
                updateSystemNowPlaying()
            }
            return
        }
        if let libMpvClient {
            libMpvClient.setDouble("speed", Double(playbackRate))
            if updateExternalState {
                syncVideoRouteProxyPlayback()
                updateSystemNowPlaying()
            }
            return
        }
    }

    private var effectiveMusicVolume: Float {
        min(max(volume * musicNormalizationGain * audioTransitionVolumeScale, 0), 1)
    }

    private func configureMusicOutput(for item: MediaItem, settings: AppSettings, isTrackTransition: Bool) {
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        musicNormalizationGain = MusicLoudnessGain.linearGain(
            mode: settings.musicLoudnessNormalization,
            trackGainDB: item.loudnessTrackGainDB,
            albumGainDB: item.loudnessAlbumGainDB,
            trackPeak: item.loudnessTrackPeak,
            albumPeak: item.loudnessAlbumPeak
        )
        musicTransitionMode = settings.musicTransitionMode
        musicSoftFadeDuration = min(max(settings.musicSoftFadeDuration, 0.3), 2)
        musicEqualizerEnabled = settings.musicEqualizerEnabled && !settings.musicEqualizerPreset.isFlat
        musicEqualizerGains = settings.musicEqualizerPreset.gainsDB
        audioTransitionVolumeScale = isTrackTransition && musicTransitionMode == .softFade ? 0 : 1
    }

    private func applyAudioOutputVolume() {
        let outputVolume = effectiveMusicVolume
        audioPlayer?.volume = outputVolume
        audioLocalMirrorPlayer?.volume = outputVolume
        audioRouteProxyPlayer?.volume = audioRouteProxyIsActive ? outputVolume : 0
    }

    private func startSoftFadeInIfNeeded(generation: Int) {
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        guard musicTransitionMode == .softFade, audioTransitionVolumeScale < 1 else {
            audioTransitionVolumeScale = 1
            applyAudioOutputVolume()
            return
        }

        let duration = musicSoftFadeDuration
        audioTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = max(Int(duration * 60), 1)
            for step in 1...steps {
                do {
                    try await Task.sleep(nanoseconds: 16_666_667)
                } catch {
                    return
                }
                // 代际变化（切歌/重新 configure）时提前退出。此处不必把 scale 复位为 1：
                // 任何让 generation 变化的路径都会经 configure / configureMusicOutput 重置 audioTransitionVolumeScale，
                // 因此中途残留的 <1 值必被下一首覆盖，不会出现音量卡在低位。
                guard self.playbackGeneration == generation else { return }
                let progress = Float(step) / Float(steps)
                self.audioTransitionVolumeScale = progress * progress * (3 - 2 * progress)
                self.applyAudioOutputVolume()
            }
            self.audioTransitionVolumeScale = 1
            self.applyAudioOutputVolume()
            self.audioTransitionTask = nil
        }
    }

    func setVolume(_ value: Float, remember: Bool = true) {
        let clamped = min(max(value, 0), 1)
        if clamped > 0 {
            volumeBeforeMute = clamped
        }
        if abs(volume - clamped) < 0.001, remember {
            onVolumeChange?(clamped)
            return
        }
        volume = clamped
        if audioPlayer != nil {
            applyAudioOutputVolume()
        }
        if let libMpvClient {
            let localVolume = (videoRouteProxyIsActive || videoRouteProxyIsAudibleProbing) ? 0 : volume
            libMpvClient.setDouble("volume", Double(localVolume * 100))
        }
        if let videoRouteProxyPlayer {
            videoRouteProxyPlayer.volume = videoRouteProxyIsActive ? volume : 0
        }
        if remember {
            onVolumeChange?(clamped)
        }
    }

    func setAudioSpectrumVisualizationActive(_ active: Bool) {
        audioSpectrumVisualizationActive = active
        if !active {
            audioSpectrumTask?.cancel()
            audioSpectrumTask = nil
        } else if isPlaying {
            refreshAudioSpectrumIfNeeded(at: currentTime)
        }
    }

    private func scheduleSeekSyncCorrection(for generation: Int) {
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = Task { @MainActor [weak self] in
            for delay in [80_000_000, 160_000_000, 260_000_000, 420_000_000, 680_000_000, 1_000_000_000, 1_400_000_000, 1_900_000_000] {
                do { try await Task.sleep(nanoseconds: UInt64(delay)) } catch { return }
                guard let self,
                      self.playbackGeneration == generation else { return }
                if let audioPlayer = self.audioPlayer {
                    let actualTime = audioPlayer.currentTime().seconds
                    if self.applyPlaybackClock(
                        actualTime,
                        generation: generation,
                        currentTolerance: 0.035,
                        lyricTolerance: 0.020
                    ) {
                        self.seekSyncRevision &+= 1
                    } else {
                        self.reissuePendingSeekIfNeeded(
                            observedTime: actualTime,
                            generation: generation,
                            audioPlayer: audioPlayer
                        )
                    }
                } else if let libMpvClient = self.libMpvClient,
                          let mpvTime = libMpvClient.getDouble("time-pos") {
                    let logicalTime = self.playerTimelineTime(for: mpvTime)
                    if self.applyPlaybackClock(
                        logicalTime,
                        generation: generation,
                        currentTolerance: 0.035,
                        lyricTolerance: 0.020
                    ) {
                        self.seekSyncRevision &+= 1
                    } else {
                        self.reissuePendingSeekIfNeeded(
                            observedTime: logicalTime,
                            generation: generation,
                            libMpvClient: libMpvClient
                        )
                    }
                }
            }
            self?.seekSyncCorrectionTask = nil
        }
    }

    @discardableResult
    private func beginTimelineSeek(to target: Double, generation: Int) -> Int {
        let existingScrub = seekState?.phase == .scrubbing ? seekState : nil
        let revision = existingScrub?.revision ?? nextSeekRevision()
        let originTime = existingScrub?.originTime ?? lyricTime
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        pendingTimelineSeek = PendingTimelineSeek(
            revision: revision,
            generation: generation,
            targetTime: target,
            originTime: originTime,
            startedAt: Date()
        )
        seekState = PlaybackSeekState(
            revision: revision,
            phase: .seeking,
            targetTime: target,
            originTime: originTime,
            resolvedTime: nil
        )
        currentTime = target
        seekSyncRevision &+= 1
        return revision
    }

    @discardableResult
    private func applyPlaybackClock(
        _ time: Double,
        generation: Int,
        currentTolerance: Double,
        lyricTolerance: Double,
        force: Bool = false
    ) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        let pendingBeforeClockUpdate = pendingTimelineSeek
        if !force, shouldHoldClockUpdateFromPendingSeek(time, generation: generation) {
            return false
        }
        if force {
            pendingTimelineSeek = nil
        }

        var changed = false
        if abs(currentTime - time) > currentTolerance {
            currentTime = time
            changed = true
        }
        if abs(lyricTime - time) > lyricTolerance || force {
            lyricTime = time
            changed = true
        }
        if let pending = pendingBeforeClockUpdate,
           pending.generation == generation,
           (pendingTimelineSeek == nil || force) {
            seekState = PlaybackSeekState(
                revision: pending.revision,
                phase: .settled,
                targetTime: pending.targetTime,
                originTime: pending.originTime,
                resolvedTime: time
            )
            scheduleSeekStateClear(revision: pending.revision)
            changed = true
        }
        return changed
    }

    private func scheduleSeekStateClear(revision: Int) {
        clearSeekStateTask?.cancel()
        clearSeekStateTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 900_000_000) } catch { return }
            guard let self,
                  self.seekState?.revision == revision,
                  self.seekState?.phase == .settled else { return }
            self.seekState = nil
            self.clearSeekStateTask = nil
        }
    }

    private func shouldHoldClockUpdateFromPendingSeek(_ time: Double, generation: Int) -> Bool {
        guard let pending = pendingTimelineSeek else { return false }
        guard pending.generation == generation else {
            pendingTimelineSeek = nil
            return false
        }

        let distanceFromTarget = abs(time - pending.targetTime)
        let distanceFromOrigin = abs(time - pending.originTime)
        let requestedDistance = abs(pending.targetTime - pending.originTime)
        let targetTolerance = item?.type == .music ? 0.30 : 0.24
        let originLeaveDistance = min(max(requestedDistance * 0.45, 0.12), 0.85)
        let didActuallyLeaveOrigin = requestedDistance <= 0.08 || distanceFromOrigin >= originLeaveDistance
        if distanceFromTarget <= targetTolerance, didActuallyLeaveOrigin {
            pendingTimelineSeek = nil
            return false
        }

        if Date().timeIntervalSince(pending.startedAt) < 3.8 {
            return true
        }

        pendingTimelineSeek = nil
        return false
    }

    private func reissuePendingSeekIfNeeded(
        observedTime: Double,
        generation: Int,
        audioPlayer: AVPlayer? = nil,
        libMpvClient: LibMpvClient? = nil
    ) {
        guard observedTime.isFinite,
              var pending = pendingTimelineSeek,
              pending.generation == generation,
              abs(observedTime - pending.targetTime) > 0.20,
              abs(pending.targetTime - pending.originTime) > 0.08,
              pending.reissueCount < 4 else { return }

        let now = Date()
        if let lastReissuedAt = pending.lastReissuedAt,
           now.timeIntervalSince(lastReissuedAt) < 0.48 {
            return
        }

        pending.reissueCount += 1
        pending.lastReissuedAt = now
        pendingTimelineSeek = pending

        if let audioPlayer {
            audioPlayer.seek(
                to: CMTime(seconds: pending.targetTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        } else if let libMpvClient {
            try? libMpvClient.command(["seek", "\(mpvTimelineTime(for: pending.targetTime))", "absolute", "exact"])
        }
    }

    func switchVideoQuality(to option: VideoStreamQualityOption) {
        guard item?.type != .music,
              let libMpvClient else { return }
        if option.appliesInPlace {
            libMpvClient.setString("vf", option.videoFilter ?? "")
            playbackTimelineOffset = 0
            activeVideoQualityOption = option
            statusMessage = nil
            updateBuffering(active: false, progress: nil)
            syncVideoRouteProxyPlayback()
            return
        }
        let resumeTime = max(currentTime, 0)
        let wasPlaying = isPlaying
        let targetURL = option.playbackURLString(startTime: resumeTime)
        filePath = targetURL
        playbackTimelineOffset = option.isOriginal ? 0 : resumeTime
        activeVideoQualityOption = option
        currentTime = resumeTime
        if let itemDuration = item?.duration, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        statusMessage = "正在切换到 \(option.label)。"
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        lastTrackRefreshDate = .distantPast
        do {
            libMpvClient.setString("vf", "")
            var loadCommand = ["loadfile", targetURL, "replace"]
            if option.isOriginal, resumeTime > 1 {
                loadCommand.append("start=\(String(format: "%.3f", resumeTime))")
            }
            try libMpvClient.command(loadCommand)
            libMpvClient.setDouble("volume", Double(volume * 100))
            libMpvClient.setDouble("speed", Double(playbackRate))
            if option.isOriginal, resumeTime > 1 {
                enforceQualityResumeTime(resumeTime, for: option)
            }
            libMpvClient.setFlag("pause", !wasPlaying)
            if let currentItem = item {
                prepareVideoRouteProxy(for: currentItem, filePath: targetURL)
            }
            syncVideoRouteProxyPlayback(probing: true)
        } catch {
            statusMessage = nil
            updateBuffering(active: false, progress: nil)
            fail("清晰度切换失败：\(error.localizedDescription)")
        }
    }

    private func reloadRemoteQualityStream(_ option: VideoStreamQualityOption, at target: Double, wasPlaying: Bool) {
        guard let libMpvClient else { return }
        let clampedTarget = min(max(target, 0), max(duration, 0))
        let targetURL = option.playbackURLString(startTime: clampedTarget)
        filePath = targetURL
        playbackTimelineOffset = clampedTarget > 1 ? clampedTarget : 0
        activeVideoQualityOption = option
        currentTime = clampedTarget
        statusMessage = "正在定位到 \(formatTime(clampedTarget))。"
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        lastTrackRefreshDate = .distantPast
        do {
            try libMpvClient.command(["loadfile", targetURL, "replace"])
            libMpvClient.setDouble("volume", Double(volume * 100))
            libMpvClient.setDouble("speed", Double(playbackRate))
            libMpvClient.setFlag("pause", !wasPlaying)
            if let currentItem = item {
                prepareVideoRouteProxy(for: currentItem, filePath: targetURL)
            }
            syncVideoRouteProxyPlayback(probing: true)
            updateSystemNowPlaying()
        } catch {
            statusMessage = nil
            fail("定位失败：\(error.localizedDescription)")
        }
    }

    private func enforceQualityResumeTime(_ resumeTime: Double, for option: VideoStreamQualityOption) {
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            for attempt in 0..<8 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(120_000_000 + attempt * 55_000_000))
                } catch {
                    return
                }
                guard let self,
                      self.playbackGeneration == generation,
                      self.activeVideoQualityOption?.id == option.id,
                      let libMpvClient = self.libMpvClient else { return }
                if self.currentTime >= resumeTime - 0.75 {
                    return
                }
                try? libMpvClient.command(["seek", "\(resumeTime)", "absolute", "keyframes"])
                self.currentTime = resumeTime
            }
        }
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            setVolume(0)
        } else {
            setVolume(max(volumeBeforeMute, 0.4))
        }
    }

    func enableAutoSubtitle() {
        if let libMpvClient {
            try? libMpvClient.command(["set", "sub-auto", "fuzzy"])
            try? libMpvClient.command(["rescan_external_files"])
            try? libMpvClient.command(["set", "sub-visibility", "yes"])
            subtitleAutoLoadEnabled = true
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func disableSubtitle() {
        if let libMpvClient {
            try? libMpvClient.command(["set", "sub-visibility", "no"])
            try? libMpvClient.command(["set", "sid", "no"])
            didApplyTrackPreference = true
            if let item { TrackPreferenceStore.setSubtitle(.off, for: item) }
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func toggleSubtitleVisibility() {
        if let libMpvClient {
            let visible = libMpvClient.getFlag("sub-visibility") ?? true
            libMpvClient.setFlag("sub-visibility", !visible)
            return
        }
    }

    func cycleSubtitle() {
        if let libMpvClient {
            try? libMpvClient.command(["set", "sub-visibility", "yes"])
            try? libMpvClient.command(["cycle", "sub"])
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func addExternalSubtitle(path: String?) {
        guard let path else { return }
        if let libMpvClient {
            try? libMpvClient.command(["sub-add", path, "select"])
            try? libMpvClient.command(["set", "sub-visibility", "yes"])
            subtitleAutoLoadEnabled = true
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func selectOrAddExternalSubtitle(path: String?) {
        guard let path else { return }
        if let existing = externalSubtitleTrack(for: path) {
            selectSubtitleTrack(existing.id)
        } else {
            addExternalSubtitle(path: path)
        }
    }

    func externalSubtitleTrack(for path: String?) -> MpvTrack? {
        guard let path else { return nil }
        let targetURL = URL(fileURLWithPath: path)
        return subtitleTracks.first { track in
            guard track.isExternal else { return false }
            if track.externalFilename == path { return true }
            if let externalFilename = track.externalFilename {
                return URL(fileURLWithPath: externalFilename).lastPathComponent == targetURL.lastPathComponent
            }
            return false
        }
    }

    func selectSubtitleTrack(_ id: Int) {
        if let libMpvClient {
            try? libMpvClient.command(["set", "sid", "\(id)"])
            try? libMpvClient.command(["set", "sub-visibility", "yes"])
            didApplyTrackPreference = true
            if let item, let language = subtitleTracks.first(where: { $0.id == id })?.language {
                TrackPreferenceStore.setSubtitle(.language(language), for: item)
            }
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func cycleAudioTrack() {
        if let libMpvClient {
            try? libMpvClient.command(["cycle", "audio"])
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func selectDefaultAudioTrack() {
        if let libMpvClient {
            try? libMpvClient.command(["set", "aid", "auto"])
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func selectAudioTrack(_ id: Int) {
        if let libMpvClient {
            try? libMpvClient.command(["set", "aid", "\(id)"])
            didApplyTrackPreference = true
            if let item, let language = audioTracks.first(where: { $0.id == id })?.language {
                TrackPreferenceStore.setAudioLanguage(language, for: item)
            }
            refreshTrackLists(from: libMpvClient, force: true)
            return
        }
    }

    func toggleFullscreen() {
        if libMpvClient != nil {
            PlayerWindowActions.toggleFullScreen()
            return
        }
    }

    func stepFrame(backward: Bool) {
        guard let libMpvClient else { return }
        try? libMpvClient.command([backward ? "frame-back-step" : "frame-step"])
    }

    func saveProgress(appState: AppState, reloadLibrary: Bool = true) {
        guard !didSaveProgress, let item else { return }
        didSaveProgress = true
        reportPlayback(.stopped, force: true)
        let savedPosition = item.type == .music ? 0 : currentTime
        let shouldReloadLibrary = item.type == .music ? false : reloadLibrary
        appState.updatePlayback(
            item: item,
            position: savedPosition,
            duration: duration > 0 ? duration : nil,
            reloadLibrary: shouldReloadLibrary
        )
        if let audioPlayer {
            audioPlayer.pause()
            audioLocalMirrorPlayer?.pause()
            audioRouteProxyPlayer?.pause()
            isPlaying = false
            updateSystemNowPlaying()
            return
        }
        if let libMpvClient {
            libMpvClient.setFlag("pause", true)
            isPlaying = false
            videoRouteProxyPlayer?.pause()
            updateSystemNowPlaying()
            return
        }
    }

    func teardown() {
        playbackGeneration += 1
        timer?.invalidate()
        timer = nil
        initialRedrawTask?.cancel()
        initialRedrawTask = nil
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        clearPreloadedMusicItem()
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        pendingTimelineSeek = nil
        seekState = nil
        removeAudioEndObserver()
        removeAudioExternalPlaybackObserver()
        audioRouteRefreshTask?.cancel()
        audioRouteRefreshTask = nil
        stopAudioLocalMirror()
        clearAudioRouteProxy()
        audioPlayer?.pause()
        audioPlayer = nil
        clearVideoRouteProxy()
        libMpvClient?.stopPlayback()
        libMpvClient = nil
        isPlaying = false
        isPreparing = false
        isReady = false
        hasVideoFrame = false
        videoAspectRatio = nil
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        audioSpectrumTask?.cancel()
        audioSpectrumTask = nil
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands
        playbackTimelineOffset = 0
        activeVideoQualityOption = nil
        updateBuffering(active: false, progress: nil)
        lastTrackRefreshDate = .distantPast
        stopSecurityScopedResource()
        SystemNowPlayingCenter.clear()
    }

    private func fail(_ message: String) {
        playbackGeneration += 1
        initialRedrawTask?.cancel()
        initialRedrawTask = nil
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        clearPreloadedMusicItem()
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        pendingTimelineSeek = nil
        seekState = nil
        removeAudioEndObserver()
        removeAudioExternalPlaybackObserver()
        audioRouteRefreshTask?.cancel()
        audioRouteRefreshTask = nil
        stopAudioLocalMirror()
        clearAudioRouteProxy()
        audioPlayer?.pause()
        audioPlayer = nil
        clearVideoRouteProxy()
        libMpvClient = nil
        isPreparing = false
        isReady = false
        isPlaying = false
        hasVideoFrame = false
        videoAspectRatio = nil
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        audioSpectrumTask?.cancel()
        audioSpectrumTask = nil
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands
        playbackTimelineOffset = 0
        activeVideoQualityOption = nil
        updateBuffering(active: false, progress: nil)
        lastTrackRefreshDate = .distantPast
        stopSecurityScopedResource()
        statusMessage = nil
        errorMessage = message
        SystemNowPlayingCenter.clear()
    }

    private func updateSystemNowPlaying() {
        SystemNowPlayingCenter.update(
            item: item,
            currentTime: currentTime,
            duration: duration,
            playbackRate: playbackRate,
            isPlaying: isPlaying
        )
    }

    func reportPlaybackStopped() {
        reportPlayback(.stopped, force: true)
    }

    private func reportPlayback(_ phase: PlayerPlaybackReport.Phase, force: Bool = false) {
        guard let item, item.metadataProvider == "Emby", item.externalID != nil else { return }
        let now = Date()
        if phase == .started {
            guard !didReportPlaybackStart else { return }
            didReportPlaybackStart = true
            lastPlaybackProgressReportDate = now
        } else {
            guard didReportPlaybackStart else { return }
            if phase == .progress, !force {
                guard now.timeIntervalSince(lastPlaybackProgressReportDate) >= 15 else { return }
            }
            if phase == .stopped {
                didReportPlaybackStart = false
            }
        }
        if phase == .progress {
            lastPlaybackProgressReportDate = now
        }
        onPlaybackReport?(
            PlayerPlaybackReport(
                phase: phase,
                item: item,
                position: max(currentTime, 0),
                duration: duration > 0 ? duration : item.duration,
                isPaused: !isPlaying
            )
        )
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = item?.type == .music ? 0.18 : 0.25
        let progressTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let audioPlayer = self.audioPlayer {
                    if let playerError = audioPlayer.currentItem?.error {
                        self.fail("音频播放失败：\(playerError.localizedDescription)")
                        return
                    }
                    let audioTime = audioPlayer.currentTime().seconds
                    if audioTime.isFinite, audioTime >= 0 {
                        // 进度条与歌词用同一更紧的容差，避免进度条比歌词慢半拍（两者锁步推进）。
                        _ = self.applyPlaybackClock(
                            audioTime,
                            generation: self.playbackGeneration,
                            currentTolerance: self.isPlaying ? 0.020 : 0.25,
                            lyricTolerance: 0.020
                        )
                        self.refreshAudioSpectrumIfNeeded(at: audioTime)
                    }
                    let audioDuration = audioPlayer.currentItem?.duration.seconds ?? 0
                    if audioDuration.isFinite, audioDuration > 0, abs(self.duration - audioDuration) > 0.05 {
                        self.duration = audioDuration
                    }
                    if self.duration > 0, self.currentTime >= self.duration - 0.2, self.isPlaying {
                        self.isPlaying = false
                        audioPlayer.pause()
                    }
                    self.reportPlayback(.progress)
                    return
                }
                if let libMpvClient = self.libMpvClient {
                    if let time = libMpvClient.getDouble("time-pos") {
                        let timelineTime = self.playerTimelineTime(for: time)
                        _ = self.applyPlaybackClock(
                            timelineTime,
                            generation: self.playbackGeneration,
                            currentTolerance: 0.08,
                            lyricTolerance: 0.035
                        )
                    }
                    if let duration = libMpvClient.getDouble("duration"), duration > 0 {
                        let logicalDuration = self.logicalDuration(fromPlaybackDuration: duration)
                        if abs(self.duration - logicalDuration) > 0.05 {
                            self.duration = logicalDuration
                        }
                    }
                    if let paused = libMpvClient.getFlag("pause"), self.isPlaying == paused {
                        self.isPlaying = !paused
                    }
                    if self.updateVideoAspectRatio(from: libMpvClient) {
                        self.hasVideoFrame = true
                    }
                    self.updateBufferingState(from: libMpvClient)
                    if self.statusMessage?.hasPrefix("正在切换到 ") == true,
                       !self.isBuffering {
                        self.statusMessage = nil
                    }
                    self.refreshTrackLists(from: libMpvClient)
                    self.reportPlayback(.progress)
                    return
                }
            }
        }
        timer = progressTimer
        RunLoop.main.add(progressTimer, forMode: .common)
    }

    private func playerTimelineTime(for playbackTime: Double) -> Double {
        guard playbackTimelineOffset > 0 else { return playbackTime }
        return playbackTimelineOffset + max(playbackTime, 0)
    }

    private func refreshAudioSpectrumIfNeeded(at time: Double) {
        guard audioSpectrumVisualizationActive,
              isPlaying,
              audioSpectrumTask == nil,
              // 性能：窗口正被拖动/缩放时跳过频谱的 AVAssetReader 解码（每 0.34s 一次的 PCM 解码+FFT 是
              // 播放期间持续的 CPU 开销，在无风扇机型上与拖窗合成抢资源）。跳过时频谱柱定格，拖动结束即恢复，
              // 拖动中肉眼不可见，零观感牺牲。
              !spectrumSuppressedDuringWindowDrag,
              item?.type == .music,
              item?.isRemoteResource != true,
              let filePath,
              Date().timeIntervalSince(lastAudioSpectrumSampleDate) > 0.34 else { return }
        lastAudioSpectrumSampleDate = Date()
        let generation = playbackGeneration
        audioSpectrumTask = Task { @MainActor [weak self] in
            let bands = await Task.detached(priority: .utility) {
                await AudioSpectrumAnalyzer.bands(filePath: filePath, time: time, bandCount: 5)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.item?.type == .music else { return }
            self.audioSpectrumBands = bands
            self.audioSpectrumTask = nil
        }
    }

    private func mpvTimelineTime(for absoluteTime: Double) -> Double {
        guard playbackTimelineOffset > 0 else { return absoluteTime }
        return max(absoluteTime - playbackTimelineOffset, 0)
    }

    private func logicalDuration(fromPlaybackDuration playbackDuration: Double) -> Double {
        if let itemDuration = item?.duration,
           itemDuration.isFinite,
           itemDuration > 0 {
            return itemDuration
        }
        guard playbackTimelineOffset > 0 else { return playbackDuration }
        return playbackTimelineOffset + playbackDuration
    }

    private func scheduleInitialVideoRedraws() {
        initialRedrawTask?.cancel()
        let generation = playbackGeneration
        initialRedrawTask = Task { @MainActor [weak self] in
            for _ in 0..<24 {
                guard let self,
                      self.playbackGeneration == generation,
                      self.libMpvClient != nil,
                      !self.hasVideoFrame else { return }
                self.renderView?.needsDisplay = true
                do {
                    try await Task.sleep(nanoseconds: 80_000_000)
                } catch {
                    return
                }
            }
            guard let self,
                  self.playbackGeneration == generation,
                  self.libMpvClient != nil,
                  !self.hasVideoFrame else { return }
            self.statusMessage = "正在等待视频首帧。"
            self.renderView?.needsDisplay = true
        }
    }

    private func updateVideoAspectRatio(from client: LibMpvClient) -> Bool {
        let width = client.getDouble("dwidth") ?? client.getDouble("width")
        let height = client.getDouble("dheight") ?? client.getDouble("height")
        guard let width, let height, width > 0, height > 0 else { return false }
        let aspect = CGFloat(width / height)
        guard aspect.isFinite, aspect > 0 else { return false }
        if let current = videoAspectRatio, abs(current - aspect) < 0.01 {
            return true
        }
        videoAspectRatio = aspect
        return true
    }

    private func updateBufferingState(from client: LibMpvClient) {
        let pausedForCache = client.getFlag("paused-for-cache") ?? false
        let cacheProgress = client.getDouble("cache-buffering-state")
        let isNetwork = item?.isRemoteResource == true
        let loading = isNetwork && isReady && currentTime < 0.35 && ((cacheProgress ?? 100) < 99)
        let buffering = pausedForCache || loading
        let progress: Double?
        if let cacheProgress, cacheProgress.isFinite {
            progress = min(max(cacheProgress, 0), 100)
        } else {
            progress = buffering ? 0 : nil
        }
        updateBuffering(active: buffering, progress: progress)
    }

    private func updateBuffering(active: Bool, progress: Double?) {
        let normalizedProgress = progress.map { min(max($0, 0), 100) }
        let oldProgress = lastBufferingState.progress
        let progressChanged: Bool
        if let normalizedProgress, let oldProgress {
            progressChanged = abs(normalizedProgress - oldProgress) >= 1
        } else {
            progressChanged = normalizedProgress != nil || oldProgress != nil
        }
        guard lastBufferingState.active != active || progressChanged else { return }
        lastBufferingState = (active, normalizedProgress)
        if isBuffering != active {
            isBuffering = active
        }
        if progressChanged {
            bufferProgress = normalizedProgress
        }
    }

    private func refreshTrackLists(from client: LibMpvClient, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTrackRefreshDate) > 1.0 else { return }
        lastTrackRefreshDate = now
        refreshChapterList(from: client)
        guard let count = client.getInt64("track-list/count"), count > 0 else {
            if !audioTracks.isEmpty { audioTracks = [] }
            if !subtitleTracks.isEmpty { subtitleTracks = [] }
            return
        }

        var audio: [MpvTrack] = []
        var subtitles: [MpvTrack] = []
        for index in 0..<Int(count) {
            guard let type = client.getString("track-list/\(index)/type"),
                  let id = client.getInt64("track-list/\(index)/id") else { continue }
            let track = MpvTrack(
                id: Int(id),
                type: MpvTrack.Kind(rawValue: type) ?? .unknown,
                title: client.getString("track-list/\(index)/title"),
                language: client.getString("track-list/\(index)/lang"),
                codec: client.getString("track-list/\(index)/codec"),
                isSelected: client.getFlag("track-list/\(index)/selected") ?? false,
                isExternal: client.getFlag("track-list/\(index)/external") ?? false,
                externalFilename: client.getString("track-list/\(index)/external-filename")
            )
            switch track.type {
            case .audio:
                audio.append(track)
            case .subtitle:
                subtitles.append(track)
            case .unknown:
                break
            }
        }
        if audioTracks != audio {
            audioTracks = audio
        }
        if subtitleTracks != subtitles {
            subtitleTracks = subtitles
        }
        applyTrackPreferenceIfNeeded(client: client)
    }

    /// A7：轨道列表就绪后，套用同剧集记忆的音轨/字幕语言（仅一次，且不覆盖用户手动选择）。
    private func applyTrackPreferenceIfNeeded(client: LibMpvClient) {
        guard !didApplyTrackPreference, let item else { return }
        guard !audioTracks.isEmpty || !subtitleTracks.isEmpty else { return }
        didApplyTrackPreference = true

        if let language = TrackPreferenceStore.audioLanguage(for: item),
           let track = audioTracks.first(where: { ($0.language ?? "") == language }),
           !track.isSelected {
            try? client.command(["set", "aid", "\(track.id)"])
        }

        if let preference = TrackPreferenceStore.subtitle(for: item) {
            switch preference {
            case .off:
                try? client.command(["set", "sub-visibility", "no"])
                try? client.command(["set", "sid", "no"])
            case .language(let language):
                if let track = subtitleTracks.first(where: { ($0.language ?? "") == language }),
                   !track.isSelected {
                    try? client.command(["set", "sid", "\(track.id)"])
                    try? client.command(["set", "sub-visibility", "yes"])
                }
            }
        }
    }

    private func refreshChapterList(from client: LibMpvClient) {
        guard let count = client.getInt64("chapter-list/count"), count > 0 else {
            if !chapters.isEmpty { chapters = [] }
            return
        }
        var next: [MpvChapter] = []
        next.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let playbackTime = client.getDouble("chapter-list/\(index)/time") else { continue }
            let title = client.getString("chapter-list/\(index)/title")
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "章节 \(index + 1)"
            next.append(
                MpvChapter(
                    id: index,
                    title: title,
                    time: playerTimelineTime(for: playbackTime)
                )
            )
        }
        if chapters != next {
            chapters = next
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

}

private enum AudioSpectrumAnalyzer {
    static let silenceBands: [CGFloat] = [0.18, 0.24, 0.20, 0.26, 0.21]

    static func bands(filePath: String, time: Double, bandCount: Int) async -> [CGFloat] {
        guard bandCount > 0 else { return [] }
        let url = URL(fileURLWithPath: filePath)
        guard url.isFileURL else { return silenceBands.prefixBands(bandCount) }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return silenceBands.prefixBands(bandCount)
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return silenceBands.prefixBands(bandCount) }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(time, 0), preferredTimescale: 600),
            duration: CMTime(seconds: 0.16, preferredTimescale: 600)
        )
        guard reader.startReading() else { return silenceBands.prefixBands(bandCount) }

        var samples: [Float] = []
        samples.reserveCapacity(4096)
        while let sampleBuffer = output.copyNextSampleBuffer(), samples.count < 4096 {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var floats = Array(repeating: Float.zero, count: byteCount / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: min(byteCount, buffer.count),
                    destination: buffer.baseAddress!
                )
            }
            guard status == noErr else { continue }
            samples.append(contentsOf: floats.prefix(max(0, 4096 - samples.count)))
        }
        reader.cancelReading()

        return normalizedFrequencyBands(from: samples, bandCount: bandCount)
    }

    private static func normalizedFrequencyBands(from rawSamples: [Float], bandCount: Int) -> [CGFloat] {
        guard rawSamples.count >= 64 else { return silenceBands.prefixBands(bandCount) }
        let sampleCount = min(1024, rawSamples.count)
        let step = max(rawSamples.count / sampleCount, 1)
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        var index = 0
        while index < rawSamples.count, samples.count < sampleCount {
            let value = Double(rawSamples[index])
            if value.isFinite {
                samples.append(min(max(value, -1), 1))
            }
            index += step
        }
        guard samples.count >= 64 else { return silenceBands.prefixBands(bandCount) }

        let mean = samples.reduce(0, +) / Double(samples.count)
        for index in samples.indices {
            let window = 0.5 - 0.5 * cos((2 * .pi * Double(index)) / Double(max(samples.count - 1, 1)))
            samples[index] = (samples[index] - mean) * window
        }

        let maxBin = max(min(samples.count / 2 - 1, 96), bandCount)
        let ranges = frequencyRanges(maxBin: maxBin, bandCount: bandCount)
        let magnitudes = ranges.map { range in
            var total = 0.0
            var count = 0
            for bin in range.lowerBound...range.upperBound {
                let angleBase = -2.0 * .pi * Double(bin) / Double(samples.count)
                var real = 0.0
                var imaginary = 0.0
                for (sampleIndex, sample) in samples.enumerated() {
                    let angle = angleBase * Double(sampleIndex)
                    real += sample * cos(angle)
                    imaginary += sample * sin(angle)
                }
                total += sqrt(real * real + imaginary * imaginary)
                count += 1
            }
            return count > 0 ? total / Double(count) : 0
        }

        let peak = max(magnitudes.max() ?? 0, 0.000_001)
        let values = magnitudes.map { magnitude -> CGFloat in
            let normalized = min(max(sqrt(magnitude / peak), 0), 1)
            return CGFloat(0.16 + normalized * 0.84)
        }
        return values.isEmpty ? silenceBands.prefixBands(bandCount) : values
    }

    private static func frequencyRanges(maxBin: Int, bandCount: Int) -> [ClosedRange<Int>] {
        guard bandCount > 0 else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var lower = 1
        for index in 0..<bandCount {
            let fraction = pow(Double(index + 1) / Double(bandCount), 1.55)
            let upper = max(lower, min(maxBin, Int((Double(maxBin) * fraction).rounded())))
            ranges.append(lower...upper)
            lower = min(upper + 1, maxBin)
        }
        return ranges
    }
}

private extension Array where Element == CGFloat {
    func prefixBands(_ count: Int) -> [CGFloat] {
        if self.count == count { return self }
        if self.count > count { return Array(prefix(count)) }
        return self + Array(repeating: last ?? 0.2, count: count - self.count)
    }
}

enum PlayerWindowActions {
    static func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    static func exitFullScreenIfNeeded() -> Bool {
        guard let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else {
            return false
        }
        window.toggleFullScreen(nil)
        return true
    }
}

final class ImmersivePlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct VideoPlayerWindowPresenter: NSViewRepresentable {
    @EnvironmentObject private var appState: AppState
    @Binding var item: MediaItem?

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.appState = appState

        guard let item, item.type != .music else {
            context.coordinator.closeWindow()
            return
        }
        let sourceScreen = nsView.window?.screen ?? NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen
        context.coordinator.present(item: item, settings: appState.settings, sourceScreen: sourceScreen)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var appState: AppState
        private var window: NSWindow?
        private var currentItemID: String?
        private var currentPredictedAspect: CGFloat?
        private var pendingAspectProbe: Task<Void, Never>?
        private var hasAppliedAspectCorrection = false
        private var minimumPlayerContentSize: NSSize?

        init(appState: AppState) {
            self.appState = appState
        }

        func present(item: MediaItem, settings: AppSettings, sourceScreen: NSScreen?) {
            if currentItemID == item.id, window != nil {
                let predictedAspect = currentPredictedAspect ?? VideoAspectRatioResolver.cachedAspectRatio(for: item) ?? 16.0 / 9.0
                let preferredSize = Self.preferredPlayerSize(
                    for: item,
                    settings: settings,
                    screen: sourceScreen,
                    aspectOverride: predictedAspect
                )
                resizeWindow(to: preferredSize, animate: false)
                window?.makeKeyAndOrderFront(nil)
                return
            }

            if currentItemID == item.id, pendingAspectProbe != nil {
                return
            }

            let shouldProbeMountedNetwork = RemoteVideoQualityPlanner.isMountedNetworkFile(for: item) &&
                VideoAspectRatioResolver.canProbeLocalFile(for: item)
            let cachedAspect = VideoAspectRatioResolver.cachedAspectRatio(for: item)
            if shouldProbeMountedNetwork || cachedAspect == nil {
                if VideoAspectRatioResolver.canProbeLocalFile(for: item) {
                    closeWindow(clearSelection: false)
                    currentItemID = item.id
                    currentPredictedAspect = cachedAspect
                    pendingAspectProbe?.cancel()
                    pendingAspectProbe = Task { @MainActor [weak self] in
                        let probed = await VideoAspectRatioResolver.probeLocalAspectRatio(filePath: item.filePath ?? "")
                        guard !Task.isCancelled,
                              let self,
                              self.currentItemID == item.id,
                              self.appState.activePlayerItem?.id == item.id else { return }
                        self.pendingAspectProbe = nil
                        self.openWindow(
                            for: item,
                            settings: settings,
                            sourceScreen: sourceScreen,
                            predictedAspect: probed ?? cachedAspect ?? 16.0 / 9.0
                        )
                    }
                    return
                }
                openWindow(
                    for: item,
                    settings: settings,
                    sourceScreen: sourceScreen,
                    predictedAspect: cachedAspect ?? 16.0 / 9.0
                )
                return
            }

            openWindow(
                for: item,
                settings: settings,
                sourceScreen: sourceScreen,
                predictedAspect: cachedAspect ?? 16.0 / 9.0
            )
        }

        private func openWindow(for item: MediaItem, settings: AppSettings, sourceScreen: NSScreen?, predictedAspect: CGFloat) {
            let preferredSize = Self.preferredPlayerSize(
                for: item,
                settings: settings,
                screen: sourceScreen,
                aspectOverride: predictedAspect
            )

            closeWindow(clearSelection: false)
            currentItemID = item.id
            currentPredictedAspect = predictedAspect
            hasAppliedAspectCorrection = false

            let window = ImmersivePlayerWindow(
                contentRect: Self.centeredContentRect(size: preferredSize, on: sourceScreen),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = item.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.collectionBehavior = [.fullScreenPrimary]
            let minimumContentSize = Self.minimumPlayerContentSize(for: item, aspectOverride: predictedAspect)
            applyMinimumContentSize(minimumContentSize, to: window)
            window.contentAspectRatio = preferredSize
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.delegate = self
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false

            let root = PlayerView(item: item, initialAspectRatio: predictedAspect) { [weak self] aspect in
                self?.applyVideoAspectRatio(aspect, for: item, settings: settings, sourceScreen: sourceScreen)
            }
            .environmentObject(appState)
            let hostingController = NSHostingController(rootView: root)
            if #available(macOS 13.0, *) {
                hostingController.sizingOptions = []
            }
            window.contentViewController = hostingController
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView?.layoutSubtreeIfNeeded()
            Self.centerWindow(window, on: sourceScreen)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak window] in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                Self.centerWindow(window, on: sourceScreen, tolerance: 3)
            }
            self.window = window
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard sender === window else { return true }
            let closedItemID = currentItemID
            closeWindow(clearSelection: false)
            clearActiveSelectionSoon(closedItemID: closedItemID)
            return false
        }

        private func resizeWindow(to contentSize: NSSize, animate: Bool) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let currentFrame = window.frame
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            window.contentAspectRatio = contentSize
            guard abs(window.contentLayoutRect.width - contentSize.width) > 1 ||
                    abs(window.contentLayoutRect.height - contentSize.height) > 1 else { return }
            let newOrigin = NSPoint(
                x: currentFrame.midX - frameSize.width / 2,
                y: currentFrame.midY - frameSize.height / 2
            )
            window.setFrame(NSRect(origin: newOrigin, size: frameSize), display: true, animate: animate)
        }

        private func applyVideoAspectRatio(_ aspect: CGFloat, for item: MediaItem, settings: AppSettings, sourceScreen: NSScreen?) {
            guard currentItemID == item.id,
                  let window,
                  !window.styleMask.contains(.fullScreen),
                  aspect.isFinite,
                  aspect > 0 else { return }
            let tolerance: CGFloat = RemoteVideoQualityPlanner.isMountedNetworkFile(for: item) ? 0.045 : 0.018
            if let currentPredictedAspect,
               abs(currentPredictedAspect - aspect) < tolerance {
                let stableSize = NSSize(width: max(window.contentLayoutRect.width, 1), height: max(window.contentLayoutRect.width, 1) / aspect)
                window.contentAspectRatio = stableSize
                let minimumContentSize = Self.minimumPlayerContentSize(for: item, aspectOverride: aspect)
                applyMinimumContentSize(minimumContentSize, to: window)
                hasAppliedAspectCorrection = true
                return
            }
            let preferredSize = Self.preferredPlayerSize(
                for: item,
                settings: settings,
                screen: sourceScreen,
                aspectOverride: aspect
            )
            let minimumContentSize = Self.minimumPlayerContentSize(for: item, aspectOverride: aspect)
            applyMinimumContentSize(minimumContentSize, to: window)
            resizeWindow(to: preferredSize, animate: hasAppliedAspectCorrection)
            currentPredictedAspect = aspect
            hasAppliedAspectCorrection = true
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            guard sender === window,
                  !sender.styleMask.contains(.fullScreen),
                  let minimumPlayerContentSize else {
                return frameSize
            }
            let proposedContent = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
            guard proposedContent.width < minimumPlayerContentSize.width ||
                    proposedContent.height < minimumPlayerContentSize.height else {
                return frameSize
            }

            let ratioSize = sender.contentAspectRatio
            let aspect = ratioSize.width > 0 && ratioSize.height > 0
                ? ratioSize.width / ratioSize.height
                : minimumPlayerContentSize.width / minimumPlayerContentSize.height
            var clampedContent = proposedContent
            if clampedContent.width < minimumPlayerContentSize.width {
                clampedContent.width = minimumPlayerContentSize.width
                clampedContent.height = max(clampedContent.height, clampedContent.width / aspect)
            }
            if clampedContent.height < minimumPlayerContentSize.height {
                clampedContent.height = minimumPlayerContentSize.height
                clampedContent.width = max(clampedContent.width, clampedContent.height * aspect)
            }
            return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContent)).size
        }

        func windowDidResize(_ notification: Notification) {
            guard let window, notification.object as AnyObject? === window else { return }
            clampPlayerWindowFrameIfNeeded(window)
        }

        func closeWindow(clearSelection: Bool = true) {
            pendingAspectProbe?.cancel()
            pendingAspectProbe = nil
            guard let window else {
                currentItemID = nil
                currentPredictedAspect = nil
                return
            }
            window.delegate = nil
            window.close()
            self.window = nil
            currentItemID = nil
            currentPredictedAspect = nil
            minimumPlayerContentSize = nil
            if clearSelection, appState.activePlayerItem?.type != .music {
                clearActiveSelectionSoon()
            }
        }

        func windowWillClose(_ notification: Notification) {
            pendingAspectProbe?.cancel()
            pendingAspectProbe = nil
            window = nil
            let closedItemID = currentItemID
            currentItemID = nil
            currentPredictedAspect = nil
            minimumPlayerContentSize = nil
            if appState.activePlayerItem?.type != .music {
                clearActiveSelectionSoon(closedItemID: closedItemID)
            }
        }

        private func applyMinimumContentSize(_ contentSize: NSSize, to window: NSWindow) {
            minimumPlayerContentSize = contentSize
            window.contentMinSize = contentSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            clampPlayerWindowFrameIfNeeded(window)
        }

        private func clampPlayerWindowFrameIfNeeded(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let minimumPlayerContentSize else { return }
            let currentContent = window.contentRect(forFrameRect: window.frame).size
            guard currentContent.width < minimumPlayerContentSize.width ||
                    currentContent.height < minimumPlayerContentSize.height else { return }

            var frameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumPlayerContentSize))
            frameRect.origin.x = window.frame.origin.x
            frameRect.origin.y = window.frame.maxY - frameRect.height
            window.setFrame(frameRect, display: true)
        }

        private func clearActiveSelectionSoon(closedItemID: String? = nil) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let closedItemID {
                    guard self.appState.activePlayerItem?.id == closedItemID else { return }
                }
                if self.appState.activePlayerItem?.type != .music {
                    self.appState.activePlayerItem = nil
                }
            }
        }

        private static func centeredContentRect(size: NSSize, on sourceScreen: NSScreen?) -> NSRect {
            let screen = sourceScreen ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else {
                return NSRect(origin: .zero, size: size)
            }
            let originX = visibleFrame.midX - size.width / 2
            let originY = visibleFrame.midY - size.height / 2
            let origin = NSPoint(
                x: min(max(originX, visibleFrame.minX), visibleFrame.maxX - size.width),
                y: min(max(originY, visibleFrame.minY), visibleFrame.maxY - size.height)
            )
            return NSRect(origin: origin, size: size)
        }

        private static func centerWindow(_ window: NSWindow, on sourceScreen: NSScreen?, tolerance: CGFloat = 0) {
            let screen = sourceScreen ?? NSScreen.main
            guard let visibleFrame = screen?.visibleFrame else {
                window.center()
                return
            }
            let frame = window.frame
            let originX = visibleFrame.midX - frame.width / 2
            let originY = visibleFrame.midY - frame.height / 2
            let origin = NSPoint(
                x: min(max(originX, visibleFrame.minX), visibleFrame.maxX - frame.width),
                y: min(max(originY, visibleFrame.minY), visibleFrame.maxY - frame.height)
            )
            if abs(window.frame.origin.x - origin.x) <= tolerance,
               abs(window.frame.origin.y - origin.y) <= tolerance {
                return
            }
            window.setFrameOrigin(origin)
        }

        private static func preferredPlayerSize(
            for item: MediaItem,
            settings: AppSettings,
            screen: NSScreen?,
            aspectOverride: CGFloat? = nil
        ) -> NSSize {
            let width = VideoWindowSizing.clampedPreferredWidth(settings.videoPlayerPreferredWidth, on: screen)
            let aspect = aspectOverride ?? videoAspectRatio(for: item)
            let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
            let visibleWidth = visibleFrame?.width ?? 1440
            let visibleHeight = visibleFrame?.height ?? 900
            let maxSize = NSSize(width: visibleWidth * 0.985, height: visibleHeight * 0.94)
            var finalSize = NSSize(width: width, height: width / aspect)
            let scale = min(1, maxSize.width / finalSize.width, maxSize.height / finalSize.height)
            if scale < 1 {
                finalSize.width *= scale
                finalSize.height *= scale
            }
            return finalSize
        }

        private static func minimumPlayerContentSize(for item: MediaItem, aspectOverride: CGFloat? = nil) -> NSSize {
            let aspect = aspectOverride ?? videoAspectRatio(for: item)
            let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
            // 控制条最大宽约 596，加上播放器左右 18pt 安全边和标题栏圆角余量，低于 680pt 时
            // 清晰度/音轨/音量/倍速等按钮会互相挤压；高度给底部两行控制条、锁定按钮和加载层留足空间。
            let minimumWidth = max(VideoWindowSizing.minimumControlSafeWidth, VideoWindowSizing.minimumControlSafeHeight * safeAspect)
            let minimumHeight = max(VideoWindowSizing.minimumControlSafeHeight, minimumWidth / safeAspect)
            return NSSize(width: minimumWidth, height: minimumHeight)
        }

        private static func videoAspectRatio(for item: MediaItem) -> CGFloat {
            VideoAspectRatioResolver.cachedAspectRatio(for: item) ?? 16.0 / 9.0
        }

    }
}

enum VideoAspectRatioResolver {
    static func cachedAspectRatio(for item: MediaItem) -> CGFloat? {
        aspectRatioFromResolution(item.resolution)
    }

    static func sizeFromResolution(_ resolution: String?) -> (width: Int, height: Int)? {
        guard let resolution else { return nil }
        let normalized = resolution
            .lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0 else { return nil }
        return (width, height)
    }

    static func canProbeLocalFile(for item: MediaItem) -> Bool {
        guard let filePath = item.filePath,
              !item.isRemoteResource,
              FileManager.default.fileExists(atPath: filePath) else {
            return false
        }
        return true
    }

    static func aspectRatioFromResolution(_ resolution: String?) -> CGFloat? {
        guard let size = sizeFromResolution(resolution) else { return nil }
        let width = Double(size.width)
        let height = Double(size.height)
        let aspect = CGFloat(width / height)
        guard aspect.isFinite, aspect > 0 else { return nil }
        return aspect
    }

    static func probeLocalAspectRatio(filePath: String) async -> CGFloat? {
        guard !filePath.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGFloat? in
            let url = URL(fileURLWithPath: filePath)
            let asset = AVURLAsset(url: url)
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                let width = abs(transformed.width)
                let height = abs(transformed.height)
                if width > 0, height > 0 {
                    let aspect = width / height
                    if aspect.isFinite, aspect > 0 {
                        return aspect
                    }
                }
            }
            return probeFFmpegAspectRatio(filePath: filePath)
        }.value
    }

    private static func probeFFmpegAspectRatio(filePath: String) -> CGFloat? {
        guard let ffmpegURL = ffmpegExecutableURL() else { return nil }
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-i", filePath]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        if let dar = firstMatch(in: output, pattern: #"DAR\s+([0-9]+):([0-9]+)"#),
           dar.count == 2,
           let width = Double(dar[0]),
           let height = Double(dar[1]),
           width > 0,
           height > 0 {
            let aspect = CGFloat(width / height)
            return aspect.isFinite && aspect > 0 ? aspect : nil
        }
        if let size = firstMatch(in: output, pattern: #"Video:.*? ([1-9][0-9]{2,5})x([1-9][0-9]{2,5})"#),
           size.count == 2,
           let width = Double(size[0]),
           let height = Double(size[1]),
           width > 0,
           height > 0 {
            let aspect = CGFloat(width / height)
            return aspect.isFinite && aspect > 0 ? aspect : nil
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    private static func ffmpegExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct SidecarSubtitleFile: Identifiable, Hashable, Sendable {
    let path: String
    let displayName: String
    let languageHint: String?

    var id: String { path }

    static func find(for item: MediaItem) -> [SidecarSubtitleFile] {
        guard let filePath = item.filePath, !item.isRemoteResource else { return [] }
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        let allowedExtensions = Set(["srt", "ass", "ssa", "vtt"])
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates: [(priority: Int, url: URL)] = files
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { subtitleURL in
                let stem = subtitleURL.deletingPathExtension().lastPathComponent
                let loweredStem = stem.lowercased()
                let priority: Int
                if loweredStem == base {
                    priority = 0
                } else if loweredStem.hasPrefix("\(base).") || loweredStem.hasPrefix("\(base)-") || loweredStem.hasPrefix("\(base)_") {
                    priority = 1
                } else if ["subtitle", "subtitles", "subs"].contains(loweredStem) {
                    priority = 2
                } else {
                    priority = 3
                }
                return (priority: priority, url: subtitleURL)
            }
            .filter { $0.priority < 3 }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
        return candidates
            .map { _, subtitleURL in
                let displayName = subtitleURL.lastPathComponent
                return SidecarSubtitleFile(
                    path: subtitleURL.path,
                    displayName: displayName,
                    languageHint: languageHint(from: displayName)
                )
            }
    }

    private static func languageHint(from fileName: String) -> String? {
        let lower = fileName.lowercased()
        if lower.contains(".zh") || lower.contains(".chs") || lower.contains("简") {
            return "中文"
        }
        if lower.contains(".cht") || lower.contains("繁") {
            return "繁体中文"
        }
        if lower.contains(".en") {
            return "英文"
        }
        if lower.contains(".jp") || lower.contains(".ja") {
            return "日文"
        }
        return nil
    }
}

struct SubtitleCue: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
    let path: String?
    let displayName: String

    static func loadSidecarSubtitles(for item: MediaItem) -> [SubtitleCue] {
        guard let filePath = item.filePath, !item.isRemoteResource else { return [] }
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let candidates = [
            directory.appendingPathComponent("\(base).srt"),
            directory.appendingPathComponent("\(base).vtt"),
            directory.appendingPathComponent("\(base).zh.srt"),
            directory.appendingPathComponent("\(base).chs.srt"),
            directory.appendingPathComponent("\(base).zh-Hans.srt"),
            directory.appendingPathComponent("subtitle.srt"),
            directory.appendingPathComponent("subtitles.srt")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let cues = parse(text, sourceURL: candidate)
                if !cues.isEmpty { return cues }
            }
            if let text = try? String(contentsOf: candidate, encoding: .unicode) {
                let cues = parse(text, sourceURL: candidate)
                if !cues.isEmpty { return cues }
            }
        }
        return []
    }

    private static func parse(_ text: String, sourceURL: URL?) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "WEBVTT", with: "")
        return normalized
            .components(separatedBy: "\n\n")
            .compactMap { parseBlock($0, sourceURL: sourceURL) }
            .sorted { $0.start < $1.start }
    }

    private static func parseBlock(_ block: String, sourceURL: URL?) -> SubtitleCue? {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
        let pieces = lines[timeLineIndex].components(separatedBy: "-->")
        guard pieces.count == 2,
              let start = parseTime(pieces[0]),
              let end = parseTime(pieces[1]),
              end > start else {
            return nil
        }
        let text = lines.dropFirst(timeLineIndex + 1)
            .joined(separator: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        guard !text.isEmpty else { return nil }
        return SubtitleCue(
            start: start,
            end: end,
            text: text,
            path: sourceURL?.path,
            displayName: sourceURL?.lastPathComponent ?? "外挂字幕"
        )
    }

    private static func parseTime(_ value: String) -> Double? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: " \t"))
            .first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = cleaned.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        let minutes = Double(parts.dropLast().last ?? "0") ?? 0
        let hours = parts.count > 2 ? (Double(parts.dropLast(2).last ?? "0") ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }
}
