import AppKit
import AVKit
import AVFoundation
import Combine
import MediaLibCore
import OpenGL.GL3
import SwiftUI
import UniformTypeIdentifiers

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

    static func usesFullScreenWidth(_ preferredWidth: Double, on screen: NSScreen? = nil) -> Bool {
        screenWidthRatio(for: preferredWidth, on: screen) >= maximumScreenWidthRatio - 0.001
    }
}

private final class MemoryAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "MediaLIB.memory-audio-resource-loader", qos: .userInitiated)

    private let data: Data
    private let preferredContentType: String

    init(fileURL: URL, data: Data) {
        self.data = data
        preferredContentType = UTType(filenameExtension: fileURL.pathExtension)?.identifier ?? UTType.data.identifier
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType(allowedTypes: info.allowedContentTypes)
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }

        if let request = loadingRequest.dataRequest {
            respond(to: request)
        }

        loadingRequest.finishLoading()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}

    private func contentType(allowedTypes: [String]?) -> String {
        guard let allowedTypes, !allowedTypes.isEmpty else {
            return preferredContentType
        }
        if allowedTypes.contains(preferredContentType) {
            return preferredContentType
        }
        return allowedTypes.first ?? preferredContentType
    }

    private func respond(to request: AVAssetResourceLoadingDataRequest) {
        let requestedOffset = max(Int(request.requestedOffset), 0)
        let currentOffset = max(Int(request.currentOffset), requestedOffset)
        let offset = min(max(currentOffset, requestedOffset), data.count)
        let requestedLength = request.requestsAllDataToEndOfResource
            ? data.count - offset
            : request.requestedLength
        let length = min(max(requestedLength, 0), max(data.count - offset, 0))
        guard length > 0 else { return }
        request.respond(with: data.subdata(in: offset..<(offset + length)))
    }
}

private struct MemoryAudioAsset {
    let asset: AVURLAsset
    let loader: MemoryAudioResourceLoader

    init(fileURL: URL, data: Data) {
        loader = MemoryAudioResourceLoader(fileURL: fileURL, data: data)
        let assetURL = Self.assetURL(for: fileURL)
        asset = AVURLAsset(
            url: assetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    private static func assetURL(for fileURL: URL) -> URL {
        let ext = fileURL.pathExtension.isEmpty ? "audio" : fileURL.pathExtension
        return URL(string: "medialib-memory-audio://track/\(UUID().uuidString).\(ext)")!
    }
}

/// 视频播放期间阻止显示器休眠/屏保（主流播放器的基本行为，此前缺失）。
/// 播放开始持锁、暂停或关闭窗口立即释放；只挂在视频 PlayerView 上，音乐不受影响。
@MainActor
final class VideoPlaybackSleepGuard: ObservableObject {
    private var activity: NSObjectProtocol?

    func update(isPlaying: Bool) {
        if isPlaying {
            begin()
        } else {
            end()
        }
    }

    func end() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    private func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "MediaLIB 正在播放视频"
        )
    }
}

enum PerceptualVolumeScale {
    /// 1.0 = 线性映射（滑杆位置 == 音量百分比），与 IINA/VLC 一致。
    /// 旧值 1.65 让低音量区占据过长滑程，「加 10% 听感却没变化」。
    /// 音乐与视频音量条都经由本刻度换算，保持两边手感一致。
    private static let exponent: Double = 1.0

    static func sliderValue(fromLinear volume: Double) -> Double {
        exponent == 1.0
            ? min(max(volume, 0), 1)
            : pow(min(max(volume, 0), 1), 1 / exponent)
    }

    static func linearVolume(fromSlider value: Double) -> Double {
        exponent == 1.0
            ? min(max(value, 0), 1)
            : pow(min(max(value, 0), 1), exponent)
    }

    static func adjustedVolume(_ volume: Float, direction: Int, sliderStep: Double = 0.055) -> Float {
        let slider = sliderValue(fromLinear: Double(volume))
        let nextSlider = min(max(slider + Double(direction) * sliderStep, 0), 1)
        return Float(linearVolume(fromSlider: nextSlider))
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

enum PlayerABLoopSelection: Equatable {
    case start(Double)
    case range(Double, Double)
    case cleared
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

enum RemoteVideoQualityPlanner {
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
        let resolution = item.resolution.flatMap { $0.isEmpty ? nil : $0 } ?? "原始分辨率"
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

private struct VideoControlPalette {
    var usesLightContent: Bool

    static let lightContent = VideoControlPalette(usesLightContent: true)
    static let darkContent = VideoControlPalette(usesLightContent: false)

    var primary: Color {
        usesLightContent ? .white.opacity(0.95) : .black.opacity(0.82)
    }

    var secondary: Color {
        usesLightContent ? .white.opacity(0.72) : .black.opacity(0.58)
    }

    var subdued: Color {
        usesLightContent ? .white.opacity(0.48) : .black.opacity(0.38)
    }

    var trackBase: Color {
        usesLightContent ? .white.opacity(0.18) : .black.opacity(0.16)
    }

    var trackProgress: Color {
        usesLightContent ? .white.opacity(0.82) : .black.opacity(0.68)
    }

    var materialFill: [Color] {
        usesLightContent
            ? [.white.opacity(0.24), .white.opacity(0.20)]
            : [.white.opacity(0.68), .white.opacity(0.60)]
    }

    var popoverFill: [Color] {
        usesLightContent
            ? [.white.opacity(0.28), .white.opacity(0.23)]
            : [.white.opacity(0.78), .white.opacity(0.68)]
    }

    var border: [Color] {
        usesLightContent
            ? [.white.opacity(0.34), .white.opacity(0.15)]
            : [.white.opacity(0.72), .black.opacity(0.16)]
    }

    var shadow: Color {
        usesLightContent ? .black.opacity(0.08) : .black.opacity(0.10)
    }

    var rowFill: Color {
        usesLightContent ? .white.opacity(0.045) : .black.opacity(0.040)
    }

    var selectedRowFill: Color {
        usesLightContent ? .white.opacity(0.16) : .black.opacity(0.11)
    }

    var rowStroke: Color {
        usesLightContent ? .white.opacity(0.065) : .black.opacity(0.075)
    }

    var selectedRowStroke: Color {
        usesLightContent ? .white.opacity(0.18) : .black.opacity(0.16)
    }

    var divider: Color {
        usesLightContent ? .white.opacity(0.14) : .black.opacity(0.12)
    }

    var choiceFill: Color {
        usesLightContent ? .white.opacity(0.12) : .black.opacity(0.07)
    }

    var choiceSelectedFill: Color {
        usesLightContent ? .white.opacity(0.82) : .black.opacity(0.72)
    }

    var choiceForeground: Color {
        usesLightContent ? .white.opacity(0.76) : .black.opacity(0.66)
    }

    var choiceSelectedForeground: Color {
        usesLightContent ? .black.opacity(0.78) : .white.opacity(0.94)
    }

    var controlKnob: Color {
        usesLightContent ? .white : .black.opacity(0.82)
    }

    var systemColorScheme: ColorScheme {
        usesLightContent ? .dark : .light
    }

    /// 设置类大弹层的不透明底色：盖住下方持续重绘的视频画面，
    /// 让 WindowServer 不再为实时 material 模糊逐帧采样（设置页掉帧根因）。
    var popoverOpaqueBase: Color {
        usesLightContent
            ? Color(red: 0.16, green: 0.17, blue: 0.19)
            : Color(red: 0.94, green: 0.95, blue: 0.96)
    }

    static func resolved(for item: MediaItem) async -> VideoControlPalette {
        guard let brightness = await VideoControlBrightnessSampler.posterBrightness(path: item.posterPath) else {
            return .darkContent
        }
        return brightness < 0.46 ? .lightContent : .darkContent
    }
}

private enum VideoControlBrightnessSampler {
    static func posterBrightness(path: String?) async -> Double? {
        guard let path, !path.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            guard let image = ArtworkImageCache.image(path: path, targetSize: CGSize(width: 36, height: 36)) else {
                return nil
            }
            return averageBrightness(of: image)
        }.value
    }

    private static func averageBrightness(of image: NSImage) -> Double? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = max(bitmap.pixelsWide, 1)
        let height = max(bitmap.pixelsHigh, 1)
        let samples = min(72, width * height)
        guard samples > 0 else { return nil }

        var total = 0.0
        var count = 0
        for index in 0..<samples {
            let x = (index * 37) % width
            let y = (index * 53) % height
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.08 else { continue }
            let luminance = 0.2126 * Double(color.redComponent)
                + 0.7152 * Double(color.greenComponent)
                + 0.0722 * Double(color.blueComponent)
            total += luminance
            count += 1
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }
}

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    var initialAspectRatio: CGFloat? = nil
    var onVideoAspectRatioChange: ((CGFloat) -> Void)? = nil

    @State private var controller = MpvPlayerController()
    @StateObject private var controlsAutoHide = PlayerControlsAutoHideCoordinator()
    @StateObject private var sleepGuard = VideoPlaybackSleepGuard()
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
    @State private var controlPalette = VideoControlPalette.darkContent
    @State private var contextMenuState: PlayerContextMenuState?
    @State private var playerToastMessage: String?
    @State private var playerToastTask: Task<Void, Never>?
    @State private var showingAdvancedSettings = false
    @State private var showingPlaybackInfo = false
    @State private var trackpadSeekAccumulator: Double = 0
    @State private var lastTrackpadPinchFullscreenDate = Date.distantPast
    /// 控制栏被右键主动隐藏后的短暂抑制窗口：避免右键抬起瞬间的微小鼠标移动又把控制栏弹回来。
    @State private var controlsRevealSuppressedUntil = Date.distantPast
    /// 长按快进键前的原倍速；非 nil 表示临时 3x 速览生效中。
    @State private var holdFastForwardPreviousRate: Float?
    /// 迷你悬浮窗模式下保存的原窗口 frame；非 nil 即处于迷你模式。
    @State private var miniModeRestoreFrame: NSRect?

    private var isMiniMode: Bool {
        miniModeRestoreFrame != nil
    }

    var body: some View {
        ZStack {
            playerBackdrop

            MpvPlayerView(controller: controller)
                .ignoresSafeArea()

            PlayerInteractionOverlay {
                if contextMenuState != nil {
                    dismissContextMenu()
                } else if controller.canControl {
                    controller.togglePlay()
                }
            } onDoubleClick: {
                handlePlayerDoubleClick()
            } onActivity: {
                showControlsTemporarily()
            } onSecondaryClick: { location in
                showContextMenu(at: location)
            } onTrackpadScroll: { gesture in
                handleTrackpadScroll(gesture)
            } onMagnify: { magnification in
                handleTrackpadMagnify(magnification)
            } onOtherMouseButton: { buttonNumber, location in
                handleOtherMouseButton(buttonNumber, at: location)
            }
            .ignoresSafeArea()

            PlayerPlaybackStatusLayer(controller: controller, item: item, palette: controlPalette)

            PlayerMarkerSkipLayer(
                controller: controller,
                markers: playbackMarkers,
                skipBehavior: appState.settings.videoMarkerSkipBehavior,
                palette: controlPalette
            )

            if !isMiniMode {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PlayerControlsBar(
                        controller: controller,
                        item: item,
                        sidecarSubtitles: sidecarSubtitles,
                        qualityOptions: qualityOptions,
                        selectedQualityID: $selectedQualityID,
                        previewMode: appState.settings.videoScrubberPreviewMode,
                        previewPrefersFFmpeg: previewUsesCoarseBuckets,
                        scrubberPreview: $scrubberPreview,
                        previewImage: previewImage,
                        previewIsLoading: previewIsLoading,
                        markers: playbackMarkers,
                        palette: controlPalette,
                        onSetMarkerBoundary: setMarkerBoundary,
                        onAddChapter: addManualChapter,
                        onAddBookmark: addBookmark,
                        onDeleteMarker: deleteMarker,
                        onAcceptMarker: acceptAutomaticMarker,
                        onRejectMarker: rejectAutomaticMarker,
                        onPlayAdjacent: playAdjacentVideo,
                        onPlayEpisode: playEpisodeFromList,
                        onEnterMiniMode: enterMiniMode,
                        onOpenAdvancedSettings: showAdvancedSettings
                    )
                    .onHover { hovering in
                        controlsHovered = hovering
                        if hovering {
                            controlsAutoHide.cancel()
                            if !controlsVisible, Date() >= controlsRevealSuppressedUntil {
                                withAnimation(AppMotion.fast) {
                                    controlsVisible = true
                                }
                            }
                        } else {
                            scheduleControlsAutoHide()
                        }
                    }
                    .background {
                        PlayerControlsBarSecondaryClickCatcher {
                            hideControlsBySecondaryClick()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(AppMotion.fast, value: controlsVisible)
            }

            if volumeHUDVisible {
                VStack {
                    Spacer(minLength: 0)
                    PlayerVolumeHUDLayer(controller: controller, palette: controlPalette)
                        .padding(.bottom, 78)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if !isMiniMode {
                HStack {
                    Spacer()
                    Button {
                        toggleControlsLock()
                    } label: {
                        Image(systemName: controlsLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(controlsLocked ? controlPalette.primary : controlPalette.secondary)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .playerGlass(cornerRadius: 19, palette: controlPalette)
                    .opacity(controlsVisible || controlsLocked ? 1 : 0)
                    .allowsHitTesting(controlsVisible || controlsLocked)
                    .padding(.trailing, 18)
                    Spacer(minLength: 0).frame(width: 0)
                }
                .frame(maxWidth: .infinity)
            }

            if isMiniMode {
                PlayerMiniModeOverlay(
                    controller: controller,
                    palette: controlPalette,
                    visible: controlsVisible,
                    onExit: exitMiniMode,
                    onClose: { close() }
                )
            }

            if let playerToastMessage {
                VStack {
                    PlayerToastLayer(message: playerToastMessage, palette: controlPalette)
                        .padding(.top, 58)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
            }

            if let contextMenuState {
                PlayerContextMenuOverlay(
                    state: contextMenuState,
                    controller: controller,
                    item: item,
                    sidecarSubtitles: sidecarSubtitles,
                    qualityOptions: qualityOptions,
                    selectedQualityID: $selectedQualityID,
                    markers: playbackMarkers,
                    palette: controlPalette,
                    onDismiss: dismissContextMenu,
                    onSetMarkerBoundary: setMarkerBoundary,
                    onAddChapter: addManualChapter,
                    onPlayAdjacent: playAdjacentVideo,
                    onOpenPlaybackInfo: showPlaybackInfo,
                    onEnterMiniMode: enterMiniMode,
                    onToast: showPlayerToast
                )
            }

            if showingAdvancedSettings {
                PlayerAdvancedSettingsOverlay(
                    controller: controller,
                    palette: controlPalette,
                    onDismiss: hideAdvancedSettings,
                    onOpenPlaybackInfo: showPlaybackInfo
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(20)
            }

            if showingPlaybackInfo {
                PlayerPlaybackInfoOverlay(
                    item: item,
                    controller: controller,
                    qualityOptions: qualityOptions,
                    selectedQualityID: selectedQualityID,
                    palette: controlPalette,
                    onDismiss: hidePlaybackInfo
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(24)
            }
        }
        .frame(
            minWidth: VideoWindowSizing.minimumControlSafeWidth,
            idealWidth: preferredSize.width,
            maxWidth: .infinity,
            minHeight: VideoWindowSizing.minimumControlSafeHeight,
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
            controller.onPlaybackFinished = {
                handleVideoPlaybackEnd()
            }
            controller.configure(item: item, settings: appState.settings)
            PlayerWindowActions.setAlwaysOnTop(appState.settings.videoPlayerAlwaysOnTop)
            loadPlaybackMarkers()
            loadAuxiliaryPlaybackMetadata()
            scheduleControlsAutoHide()
        }
        .onDisappear {
            controlsAutoHide.cancel()
            sleepGuard.end()
            volumeHUDTask?.cancel()
            previewLoadTask?.cancel()
            auxiliaryMetadataTask?.cancel()
            playerToastTask?.cancel()
            controller.onVolumeChange = nil
            controller.onPlaybackFinished = nil
            controller.teardown()
            controller.saveProgress(appState: appState, reloadLibrary: false)
            controller.onPlaybackReport = nil
        }
        .onReceive(controller.$isPlaying.removeDuplicates()) { playing in
            sleepGuard.update(isPlaying: playing)
        }
        .onChange(of: previewRequestKey) { _ in
            loadPreviewImage()
        }
        .onChange(of: appState.settings.videoScrubberPreviewMode) { _ in
            resetPreviewState()
        }
        .onChange(of: appState.settings.videoPlayerAlwaysOnTop) { enabled in
            PlayerWindowActions.setAlwaysOnTop(enabled)
        }
        .task(id: item.posterPath ?? item.id) {
            controlPalette = await VideoControlPalette.resolved(for: item)
        }
        .onChange(of: appState.playbackCommandRequest?.id) { _ in
            handlePlaybackCommand()
        }
        .onReceive(controller.$chapters.removeDuplicates()) { chapters in
            syncEmbeddedChapters(chapters)
        }
        .overlay {
            PlayerWindowChromeVisibilityLayer(controller: controller, controlsVisible: controlsVisible && !isMiniMode)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .overlay {
            PlayerVideoAspectRatioReporter(controller: controller, onChange: onVideoAspectRatioChange)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .background {
            if !showingAdvancedSettings {
                KeyCaptureView(
                    settings: appState.settings,
                    onKey: { action in
                        handleShortcutAction(action)
                    },
                    onSeekForwardHold: { holding in
                        if holding {
                            beginHoldFastForward()
                        } else {
                            endHoldFastForward()
                        }
                    }
                )
                .frame(width: 0, height: 0)
            }
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
                    AppColors.selectedGlassTint.opacity(0.16),
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
        guard appState.settings.videoScrubberPreviewMode.isEnabled,
              let scrubberPreview else { return nil }
        let bucket = VideoFramePreviewGenerator.bucket(for: scrubberPreview.time, duration: controller.duration, preferCoarse: previewUsesCoarseBuckets)
        return "\(item.id)-\(bucket)"
    }

    private var previewUsesCoarseBuckets: Bool {
        previewPrefersFFmpeg || appState.settings.videoScrubberPreviewMode.usesCoarseBuckets
    }

    private func close() {
        controller.teardown()
        appState.activePlayerItem = nil
        controller.saveProgress(appState: appState, reloadLibrary: false)
    }

    /// 鼠标中键（2）与侧键（3 后退 / 4 前进）按设置分发动作。
    private func handleOtherMouseButton(_ buttonNumber: Int, at location: CGPoint) {
        switch buttonNumber {
        case 2:
            switch appState.settings.videoMiddleClickAction {
            case .none:
                break
            case .playPause:
                guard controller.canControl else { return }
                controller.togglePlay()
            case .fullscreen:
                controller.toggleFullscreen()
            case .mute:
                guard controller.canControl else { return }
                controller.toggleMute()
            case .contextMenu:
                showContextMenu(at: location)
            }
        case 3, 4:
            let forward = buttonNumber == 4
            switch appState.settings.videoMouseBackForwardAction {
            case .none:
                break
            case .seek:
                guard controller.canControl else { return }
                controller.seek(by: (forward ? 1 : -1) * appState.settings.skipInterval)
            case .episode:
                playAdjacentVideo(direction: forward ? 1 : -1)
            }
        default:
            break
        }
    }

    /// 进入迷你悬浮窗：右下角小窗置顶续播，常规控制栏让位给迷你控制层。
    private func enterMiniMode() {
        guard miniModeRestoreFrame == nil else { return }
        let aspect = controller.videoAspectRatio ?? videoAspectRatio
        guard let previousFrame = PlayerWindowActions.enterMiniMode(aspect: aspect) else { return }
        dismissContextMenu()
        showingAdvancedSettings = false
        showingPlaybackInfo = false
        miniModeRestoreFrame = previousFrame
        withAnimation(AppMotion.fast) {
            controlsVisible = true
        }
        scheduleControlsAutoHide()
    }

    private func exitMiniMode() {
        guard let previousFrame = miniModeRestoreFrame else { return }
        miniModeRestoreFrame = nil
        PlayerWindowActions.exitMiniMode(
            restoring: previousFrame,
            alwaysOnTop: appState.settings.videoPlayerAlwaysOnTop
        )
        showControlsTemporarily()
    }

    /// 按住「快进」键：临时 3x 速览，松开恢复原倍速（不写入倍速记忆）。
    private func beginHoldFastForward() {
        guard holdFastForwardPreviousRate == nil, controller.canControl else { return }
        holdFastForwardPreviousRate = controller.playbackRate
        controller.setPlaybackRate(3.0, persistPreference: false)
        if !controller.isPlaying {
            controller.togglePlay()
        }
        showPlayerToast("3x 速览中，松开恢复")
    }

    private func endHoldFastForward() {
        guard let previousRate = holdFastForwardPreviousRate else { return }
        holdFastForwardPreviousRate = nil
        controller.setPlaybackRate(previousRate, persistPreference: false)
        showPlayerToast(String(format: "恢复 %.2fx", previousRate))
    }

    /// 视频播完（mpv eof-reached）后的行为：按设置自动下一集 / 停在结尾 / 关闭窗口。
    private func handleVideoPlaybackEnd() {
        switch appState.settings.videoPlaybackEndAction {
        case .nextEpisode:
            let queue = appState.videoQueue
            if let index = queue.firstIndex(where: { $0.id == item.id }),
               queue.indices.contains(index + 1) {
                playEpisodeFromList(queue[index + 1])
            }
        case .holdLastFrame:
            break
        case .closeWindow:
            close()
        }
    }

    private func playAdjacentVideo(direction: Int) {
        // 必须先确认目标存在再 teardown：越界时拆掉当前播放却没有新内容顶上，
        // 窗口会卡死在黑屏（原实现的真实 bug）。
        guard appState.hasAdjacentItem(to: item, direction: direction) else {
            showPlayerToast(direction > 0 ? "已经是最后一集" : "已经是第一集")
            return
        }
        controller.teardown()
        controller.saveProgress(appState: appState, reloadLibrary: false)
        appState.playAdjacent(to: item, direction: direction)
    }

    /// 从剧集列表点击某一集：先保存当前进度再切换，与上一集/下一集一致。
    private func playEpisodeFromList(_ episode: MediaItem) {
        guard episode.id != item.id else { return }
        controller.teardown()
        controller.saveProgress(appState: appState, reloadLibrary: false)
        appState.play(episode, preserveSelection: true)
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

    private func addBookmark(_ time: Double) {
        let bookmarkNumber = playbackMarkers.filter { $0.kind == .bookmark && $0.origin == .manual }.count + 1
        let marker = PlaybackMarker(
            mediaID: item.id,
            kind: .bookmark,
            title: "书签 \(bookmarkNumber)",
            startTime: time,
            origin: .manual
        )
        if appState.savePlaybackMarker(marker) != nil {
            loadPlaybackMarkers()
            showPlayerToast("已添加书签：\(formatLoopTime(time))")
        }
    }

    private func deleteMarker(_ marker: PlaybackMarker) {
        guard marker.origin == .manual else { return }
        appState.deletePlaybackMarker(marker)
        loadPlaybackMarkers()
    }

    private func acceptAutomaticMarker(_ marker: PlaybackMarker) {
        guard marker.origin == .automatic else { return }
        appState.reviewAutomaticPlaybackMarker(marker, accepted: true)
        loadPlaybackMarkers()
    }

    private func rejectAutomaticMarker(_ marker: PlaybackMarker) {
        guard marker.origin == .automatic else { return }
        appState.reviewAutomaticPlaybackMarker(marker, accepted: false)
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
        guard Date() >= controlsRevealSuppressedUntil else { return }
        if !controlsVisible {
            withAnimation(AppMotion.fast) {
                controlsVisible = true
            }
        }
        scheduleControlsAutoHide()
    }

    /// 控制栏上右键：立即隐藏控制栏。返回是否消费了这次右键
    /// （锁定时不隐藏、弹层打开时不响应，放行给原有右键逻辑）。
    private func hideControlsBySecondaryClick() -> Bool {
        guard controlsVisible, !controlsLocked,
              contextMenuState == nil, !showingAdvancedSettings, !showingPlaybackInfo else {
            return false
        }
        controlsAutoHide.cancel()
        controlsHovered = false
        controlsRevealSuppressedUntil = Date().addingTimeInterval(0.9)
        withAnimation(AppMotion.fast) {
            controlsVisible = false
        }
        return true
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

    private func showContextMenu(at location: CGPoint) {
        controlsAutoHide.cancel()
        if !controlsLocked, !controlsVisible {
            withAnimation(AppMotion.fast) {
                controlsVisible = true
            }
        }
        withAnimation(AppMotion.fast) {
            contextMenuState = PlayerContextMenuState(location: location)
        }
    }

    private func dismissContextMenu() {
        guard contextMenuState != nil else { return }
        withAnimation(AppMotion.fast) {
            contextMenuState = nil
        }
        scheduleControlsAutoHide()
    }

    private func showPlayerToast(_ message: String) {
        playerToastTask?.cancel()
        withAnimation(AppMotion.fast) {
            playerToastMessage = message
        }
        playerToastTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_800_000_000)
            } catch {
                return
            }
            withAnimation(AppMotion.standard) {
                playerToastMessage = nil
            }
        }
    }

    private func showAdvancedSettings() {
        dismissContextMenu()
        showingPlaybackInfo = false
        controlsAutoHide.cancel()
        withAnimation(AppMotion.standard) {
            showingAdvancedSettings = true
            // 设置大弹层已盖住画面，控制栏随即收起，关闭弹层后按需再唤出。
            controlsVisible = false
        }
    }

    private func hideAdvancedSettings() {
        withAnimation(AppMotion.standard) {
            showingAdvancedSettings = false
        }
        scheduleControlsAutoHide()
    }

    private func showPlaybackInfo() {
        dismissContextMenu()
        withAnimation(AppMotion.standard) {
            showingAdvancedSettings = false
            showingPlaybackInfo = true
            controlsVisible = true
        }
    }

    private func hidePlaybackInfo() {
        withAnimation(AppMotion.standard) {
            showingPlaybackInfo = false
        }
        scheduleControlsAutoHide()
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

    private func handleShortcutAction(_ action: VideoPlayerShortcutAction) {
        if contextMenuState != nil {
            dismissContextMenu()
            return
        }
        if showingPlaybackInfo {
            switch action {
            case .exitFullscreenOrClose, .showPlaybackInfo:
                hidePlaybackInfo()
                return
            default:
                break
            }
        }

        var shouldShowControls = true
        switch action {
        case .exitFullscreenOrClose:
            if !PlayerWindowActions.exitFullScreenIfNeeded() {
                close()
            }
        case .closeWindow:
            close()
        case .playPause:
            controller.togglePlay()
        case .previousEpisode:
            playAdjacentVideo(direction: -1)
        case .nextEpisode:
            playAdjacentVideo(direction: 1)
        case .restart:
            controller.restartFromBeginning()
        case .captureFrame:
            captureCurrentFrame()
        case .openExternal:
            appState.openExternally(item)
        case .cycleABLoopPoint:
            cycleABLoopPoint()
        case .clearABLoop:
            clearABLoop()
        case .toggleCurrentLoop:
            toggleCurrentLoop()
        case .showPlaybackInfo:
            showPlaybackInfo()
        case .seekBackward:
            controller.seek(by: -appState.settings.skipInterval)
        case .seekForward:
            controller.seek(by: appState.settings.skipInterval)
        case .seekBackwardSmall:
            controller.seek(by: -5)
        case .seekForwardSmall:
            controller.seek(by: 5)
        case .seekBackwardLarge:
            controller.seek(by: -60)
        case .seekForwardLarge:
            controller.seek(by: 60)
        case .seekBackwardTen:
            controller.seek(by: -10)
        case .seekForwardTen:
            controller.seek(by: 10)
        case .volumeUp:
            controller.setVolume(PerceptualVolumeScale.adjustedVolume(controller.volume, direction: 1))
            showVolumeHUD()
            shouldShowControls = false
        case .volumeDown:
            controller.setVolume(PerceptualVolumeScale.adjustedVolume(controller.volume, direction: -1))
            showVolumeHUD()
            shouldShowControls = false
        case .mute:
            controller.toggleMute()
            showVolumeHUD()
            shouldShowControls = false
        case .toggleFullscreen:
            controller.toggleFullscreen()
        case .goToBeginning:
            controller.seek(to: 0)
        case .goToEnd:
            controller.seek(to: max(controller.duration - 0.5, 0))
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
        case .audioDelayDown:
            updateVideoAudioDelay(appState.settings.videoDefaultAudioDelay - 0.1)
        case .audioDelayUp:
            updateVideoAudioDelay(appState.settings.videoDefaultAudioDelay + 0.1)
        case .subtitleDelayDown:
            updateVideoSubtitleDelay(appState.settings.videoDefaultSubtitleDelay - 0.1)
        case .subtitleDelayUp:
            updateVideoSubtitleDelay(appState.settings.videoDefaultSubtitleDelay + 0.1)
        case .subtitleSizeDown:
            updateVideoSubtitleScale(appState.settings.videoDefaultSubtitleScale - 0.05)
        case .subtitleSizeUp:
            updateVideoSubtitleScale(appState.settings.videoDefaultSubtitleScale + 0.05)
        case .subtitleMoveUp:
            updateVideoSubtitlePosition(appState.settings.videoDefaultSubtitlePosition - 4)
        case .subtitleMoveDown:
            updateVideoSubtitlePosition(appState.settings.videoDefaultSubtitlePosition + 4)
        case .cycleAspectRatio:
            cycleVideoAspectOverride()
        case .cycleCropMode:
            cycleVideoCropMode()
        case .cycleDeinterlaceMode:
            cycleVideoDeinterlaceMode()
        case .rotateVideoLeft:
            rotateVideo(clockwise: false)
        case .rotateVideoRight:
            rotateVideo(clockwise: true)
        case .subtitleCycle:
            controller.cycleSubtitle()
        case .subtitleToggle:
            controller.toggleSubtitleVisibility()
        case .audioCycle:
            controller.cycleAudioTrack()
        case .toggleMiniMode:
            if isMiniMode {
                exitMiniMode()
            } else {
                enterMiniMode()
            }
            shouldShowControls = false
        case .toggleControlsLock:
            toggleControlsLock()
            shouldShowControls = false
        case .showAdvancedSettings:
            showAdvancedSettings()
        case .seekTo0Percent, .seekTo10Percent, .seekTo20Percent, .seekTo30Percent, .seekTo40Percent,
             .seekTo50Percent, .seekTo60Percent, .seekTo70Percent, .seekTo80Percent, .seekTo90Percent:
            guard controller.duration > 0, let percent = action.seekPercentValue else { return }
            controller.seek(to: controller.duration * percent)
        }
        if shouldShowControls {
            showControlsTemporarily()
        }
    }

    private func captureCurrentFrame() {
        do {
            let url = try controller.captureCurrentVideoFrame(
                title: item.title,
                mode: appState.settings.videoScreenshotMode
            )
            showPlayerToast("截图已保存：\(url.lastPathComponent)")
        } catch {
            showPlayerToast("截图失败：\(error.localizedDescription)")
        }
    }

    private func cycleABLoopPoint() {
        let selection = controller.cycleABLoopPoint()
        switch selection {
        case .start(let start):
            showPlayerToast("A-B 循环：A 点 \(formatLoopTime(start))")
        case .range(let start, let end):
            showPlayerToast("A-B 循环：\(formatLoopTime(start)) - \(formatLoopTime(end))")
        case .cleared:
            showPlayerToast("A-B 循环已清除")
        }
    }

    private func clearABLoop() {
        controller.clearABLoop()
        showPlayerToast("A-B 循环已清除")
    }

    private func toggleCurrentLoop() {
        let enabled = !appState.settings.videoLoopCurrentItem
        appState.settings.videoLoopCurrentItem = enabled
        appState.saveSettings()
        controller.setLoopCurrentItem(enabled)
        showPlayerToast(enabled ? "已开启单片循环" : "已关闭单片循环")
    }

    private func updateVideoAudioDelay(_ value: Double) {
        let clamped = AppSettings.clampedVideoSyncDelay(value)
        appState.settings.videoDefaultAudioDelay = clamped
        appState.saveSettings()
        controller.setAudioDelay(clamped)
        showPlayerToast("音频延迟：\(syncDelayText(clamped))")
    }

    private func updateVideoSubtitleDelay(_ value: Double) {
        let clamped = AppSettings.clampedVideoSyncDelay(value)
        appState.settings.videoDefaultSubtitleDelay = clamped
        appState.saveSettings()
        controller.setSubtitleDelay(clamped)
        showPlayerToast("字幕延迟：\(syncDelayText(clamped))")
    }

    private func updateVideoSubtitleScale(_ value: Double) {
        let clamped = AppSettings.clampedVideoSubtitleScale(value)
        appState.settings.videoDefaultSubtitleScale = clamped
        appState.saveSettings()
        controller.setSubtitleScale(clamped)
        showPlayerToast("字幕大小：\(Int((clamped * 100).rounded()))%")
    }

    private func updateVideoSubtitlePosition(_ value: Double) {
        let clamped = AppSettings.clampedVideoSubtitlePosition(value)
        appState.settings.videoDefaultSubtitlePosition = clamped
        appState.saveSettings()
        controller.setSubtitlePosition(clamped)
        showPlayerToast("字幕位置：\(Int(clamped.rounded()))%")
    }

    private func cycleVideoAspectOverride() {
        let mode = nextMode(after: appState.settings.videoAspectOverride, in: VideoAspectOverride.allCases)
        appState.settings.videoAspectOverride = mode
        appState.saveSettings()
        controller.setAspectOverride(mode)
        showPlayerToast("画面比例：\(mode.displayName)")
    }

    private func cycleVideoCropMode() {
        let mode = nextMode(after: appState.settings.videoCropMode, in: VideoCropMode.allCases)
        appState.settings.videoCropMode = mode
        appState.saveSettings()
        controller.setCropMode(mode)
        showPlayerToast("黑边裁切：\(mode.displayName)")
    }

    private func cycleVideoDeinterlaceMode() {
        let mode = nextMode(after: appState.settings.videoDeinterlaceMode, in: VideoDeinterlaceMode.allCases)
        appState.settings.videoDeinterlaceMode = mode
        appState.saveSettings()
        controller.setDeinterlaceMode(mode)
        showPlayerToast("去隔行：\(mode.displayName)")
    }

    private func rotateVideo(clockwise: Bool) {
        let current = appState.settings.videoRotationMode
        let modes = VideoRotationMode.allCases
        guard let index = modes.firstIndex(of: current) else { return }
        let next = modes[(index + (clockwise ? 1 : modes.count - 1)) % modes.count]
        appState.settings.videoRotationMode = next
        appState.saveSettings()
        controller.setRotationMode(next)
        showPlayerToast("画面旋转：\(next.displayName)")
    }

    private func nextMode<T: Equatable>(after current: T, in modes: [T]) -> T {
        guard !modes.isEmpty,
              let index = modes.firstIndex(of: current) else {
            return modes[0]
        }
        return modes[(index + 1) % modes.count]
    }

    private func syncDelayText(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0.0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private func formatLoopTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func handleTrackpadScroll(_ gesture: PlayerTrackpadScrollGesture) {
        showControlsTemporarily()
        switch gesture {
        case .horizontal(let delta):
            guard appState.settings.videoTrackpadGesturesEnabled else { return }
            guard appState.settings.videoTrackpadHorizontalSeekEnabled else { return }
            trackpadSeekAccumulator += -delta * appState.settings.videoTrackpadGestureSensitivity.seekSecondsPerPoint
            guard abs(trackpadSeekAccumulator) >= 0.65 else { return }
            let seconds = min(max(trackpadSeekAccumulator, -8), 8)
            trackpadSeekAccumulator = 0
            controller.seek(by: seconds)
        case .vertical(let delta):
            guard appState.settings.videoTrackpadGesturesEnabled else { return }
            guard appState.settings.videoTrackpadVerticalVolumeEnabled else { return }
            let nextVolume = Double(controller.volume) + delta * appState.settings.videoTrackpadGestureSensitivity.volumePerPoint
            controller.setVolume(Float(min(max(nextVolume, 0), 1)))
            showVolumeHUD()
        case .mouseWheelVolume(let delta):
            guard appState.settings.videoMouseWheelVolumeEnabled else { return }
            let nextVolume = Double(controller.volume) + delta * 0.012
            controller.setVolume(Float(min(max(nextVolume, 0), 1)))
            showVolumeHUD()
        }
    }

    private func handlePlayerDoubleClick() {
        // 迷你悬浮窗里双击 = 还原窗口（对齐系统画中画习惯），而不是进全屏。
        if isMiniMode {
            exitMiniMode()
            return
        }
        guard appState.settings.videoDoubleClickFullscreen else { return }
        controller.toggleFullscreen()
        showControlsTemporarily()
    }

    private func handleTrackpadMagnify(_ magnification: CGFloat) {
        guard appState.settings.videoTrackpadGesturesEnabled,
              appState.settings.videoTrackpadPinchFullscreenEnabled,
              abs(magnification) >= 0.12 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTrackpadPinchFullscreenDate) > 0.85 else { return }
        lastTrackpadPinchFullscreenDate = now
        if isMiniMode {
            exitMiniMode()
            return
        }
        controller.toggleFullscreen()
        showControlsTemporarily()
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
        let previewMode = appState.settings.videoScrubberPreviewMode
        guard previewMode.isEnabled,
              let requestKey = previewRequestKey,
              let scrubberPreview,
              let filePath = item.filePath else {
            previewImage = nil
            previewIsLoading = false
            return
        }
        let time = scrubberPreview.time
        let itemID = item.id
        let prefersFFmpeg = previewUsesCoarseBuckets
        let duration = controller.duration
        if let cached = VideoFramePreviewGenerator.memoryCachedImage(itemID: itemID, time: time, duration: duration, preferFFmpeg: prefersFFmpeg) {
            previewImage = cached
            previewIsLoading = false
            if previewMode.allowsPrefetch {
                VideoFramePreviewGenerator.prefetchAround(
                    itemID: itemID,
                    filePath: filePath,
                    time: time,
                    duration: duration,
                    preferFFmpeg: prefersFFmpeg
                )
            }
            return
        }
        previewImage = nil
        previewIsLoading = true
        previewLoadTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: previewMode.requestDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.previewRequestKey == requestKey,
                  self.scrubberPreview != nil,
                  self.item.id == itemID else { return }
            for _ in 0..<2 where VideoFramePreviewGenerator.shouldDeferInteractiveRequest(
                itemID: itemID,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            ) {
                do {
                    try await Task.sleep(nanoseconds: 180_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.previewRequestKey == requestKey,
                      self.scrubberPreview != nil,
                      self.item.id == itemID else { return }
            }
            guard !VideoFramePreviewGenerator.shouldDeferInteractiveRequest(
                itemID: itemID,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            ) else {
                self.previewIsLoading = false
                return
            }
            let loaded = SendableVideoPreviewImage(await VideoFramePreviewGenerator.image(
                itemID: itemID,
                filePath: filePath,
                time: time,
                duration: duration,
                preferFFmpeg: prefersFFmpeg
            ))
            guard !Task.isCancelled,
                  self.previewRequestKey == requestKey,
                  self.scrubberPreview != nil,
                  self.item.id == itemID else { return }
            self.previewImage = loaded.image
            self.previewIsLoading = false
            if previewMode.allowsPrefetch {
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

    private func resetPreviewState() {
        previewLoadTask?.cancel()
        scrubberPreview = nil
        previewImage = nil
        previewIsLoading = false
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

private struct PlayerContextMenuControllerState: Equatable {
    let canControl: Bool
    let isPlaying: Bool
    let playbackRate: Float
    let currentTime: Double
    let duration: Double
    let audioTracks: [MpvTrack]
    let subtitleTracks: [MpvTrack]
    let subtitleAutoLoadEnabled: Bool
    let loopCurrentItem: Bool
    let abLoopStart: Double?
    let abLoopEnd: Double?
    let playbackStatusText: String

    @MainActor
    init(controller: MpvPlayerController) {
        let roundedTime = max(controller.currentTime.rounded(.down), 0)
        self.canControl = controller.canControl
        self.isPlaying = controller.isPlaying
        self.playbackRate = controller.playbackRate
        self.currentTime = roundedTime
        self.duration = controller.duration
        self.audioTracks = controller.audioTracks
        self.subtitleTracks = controller.subtitleTracks
        self.subtitleAutoLoadEnabled = controller.subtitleAutoLoadEnabled
        self.loopCurrentItem = controller.loopCurrentItem
        self.abLoopStart = controller.abLoopStart
        self.abLoopEnd = controller.abLoopEnd
        if controller.isPreparing {
            self.playbackStatusText = controller.statusMessage ?? "正在启动 libmpv 核心"
        } else if controller.errorMessage != nil {
            self.playbackStatusText = "libmpv 核心不可用"
        } else if controller.duration > 0 {
            self.playbackStatusText = "libmpv 内核 · \(Self.formatTime(roundedTime)) / \(Self.formatTime(controller.duration))"
        } else {
            self.playbackStatusText = "libmpv 内核"
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
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

private struct PlayerAudioTrackListState: Equatable {
    let audioTracks: [MpvTrack]
    let audioDevices: [MpvAudioDevice]
    let selectedAudioDeviceName: String

    @MainActor
    init(controller: MpvPlayerController) {
        self.audioTracks = controller.audioTracks
        self.audioDevices = controller.audioDevices
        self.selectedAudioDeviceName = controller.selectedAudioDeviceName
    }
}

private struct PlayerSubtitleTrackListState: Equatable {
    let subtitleTracks: [MpvTrack]
    let subtitleAutoLoadEnabled: Bool
    let secondarySubtitleID: Int?

    @MainActor
    init(controller: MpvPlayerController) {
        self.subtitleTracks = controller.subtitleTracks
        self.subtitleAutoLoadEnabled = controller.subtitleAutoLoadEnabled
        self.secondarySubtitleID = controller.secondarySubtitleID
    }

    /// 主字幕选中判定要排除第二字幕：mpv 的 track-list 里两者 selected 都为 true。
    func isPrimarySelected(_ track: MpvTrack) -> Bool {
        track.isSelected && track.id != secondarySubtitleID
    }
}

private struct PlayerPlaybackStatusLayer: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let item: MediaItem
    let palette: VideoControlPalette
    @StateObject private var status: PlayerControllerProjection<PlayerPlaybackStatusState>

    init(controller: MpvPlayerController, item: MediaItem, palette: VideoControlPalette) {
        self.controller = controller
        self.item = item
        self.palette = palette
        _status = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerPlaybackStatusState.init))
    }

    var body: some View {
        let state = status.value
        if let errorMessage = state.errorMessage {
            PlayerStatusOverlay(
                title: "内置播放器无法播放",
                systemImage: "play.slash",
                message: errorMessage,
                actionTitle: "用外部播放器打开",
                palette: palette
            ) {
                appState.openExternally(item)
            }
        } else if state.isPreparing || !state.isReady || state.isBuffering || state.isWaitingForVideoFrame {
            PlayerBufferingOverlay(
                title: state.isBuffering ? "正在缓冲" : "正在加载",
                progress: state.bufferProgress,
                message: state.statusMessage,
                palette: palette
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
    let palette: VideoControlPalette
    @StateObject private var volume: PlayerControllerProjection<Float>

    init(controller: MpvPlayerController, palette: VideoControlPalette) {
        self.palette = palette
        _volume = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.volume })
    }

    var body: some View {
        PlayerVolumeHUD(volume: volume.value, palette: palette)
    }
}

private struct PlayerControlsBar: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let item: MediaItem
    let sidecarSubtitles: [SidecarSubtitleFile]
    let qualityOptions: [VideoStreamQualityOption]
    @Binding var selectedQualityID: String?
    let previewMode: VideoScrubberPreviewMode
    let previewUsesCoarseBuckets: Bool
    @Binding var scrubberPreview: VideoScrubberPreview?
    let previewImage: NSImage?
    let previewIsLoading: Bool
    let markers: [PlaybackMarker]
    let palette: VideoControlPalette
    let onSetMarkerBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onAddBookmark: (Double) -> Void
    let onDeleteMarker: (PlaybackMarker) -> Void
    let onAcceptMarker: (PlaybackMarker) -> Void
    let onRejectMarker: (PlaybackMarker) -> Void
    let onPlayAdjacent: (Int) -> Void
    let onPlayEpisode: (MediaItem) -> Void
    let onEnterMiniMode: () -> Void
    let onOpenAdvancedSettings: () -> Void
    @StateObject private var timeline: PlayerControllerProjection<PlayerTimelineState>
    @StateObject private var transport: PlayerControllerProjection<PlayerTransportState>
    @State private var showingVolumePopover = false
    @State private var showingSubtitlePopover = false
    @State private var showingAudioPopover = false
    @State private var showingQualityPopover = false
    @State private var showingMarkerPopover = false
    @State private var showingSettingsPopover = false
    @State private var showingEpisodeListPopover = false

    init(
        controller: MpvPlayerController,
        item: MediaItem,
        sidecarSubtitles: [SidecarSubtitleFile],
        qualityOptions: [VideoStreamQualityOption],
        selectedQualityID: Binding<String?>,
        previewMode: VideoScrubberPreviewMode,
        previewPrefersFFmpeg: Bool,
        scrubberPreview: Binding<VideoScrubberPreview?>,
        previewImage: NSImage?,
        previewIsLoading: Bool,
        markers: [PlaybackMarker],
        palette: VideoControlPalette,
        onSetMarkerBoundary: @escaping (PlaybackMarker.Kind, Bool, Double) -> Void,
        onAddChapter: @escaping (Double) -> Void,
        onAddBookmark: @escaping (Double) -> Void,
        onDeleteMarker: @escaping (PlaybackMarker) -> Void,
        onAcceptMarker: @escaping (PlaybackMarker) -> Void,
        onRejectMarker: @escaping (PlaybackMarker) -> Void,
        onPlayAdjacent: @escaping (Int) -> Void,
        onPlayEpisode: @escaping (MediaItem) -> Void,
        onEnterMiniMode: @escaping () -> Void,
        onOpenAdvancedSettings: @escaping () -> Void
    ) {
        self.controller = controller
        self.item = item
        self.sidecarSubtitles = sidecarSubtitles
        self.qualityOptions = qualityOptions
        _selectedQualityID = selectedQualityID
        self.previewMode = previewMode
        self.previewUsesCoarseBuckets = previewPrefersFFmpeg
        _scrubberPreview = scrubberPreview
        self.previewImage = previewImage
        self.previewIsLoading = previewIsLoading
        self.markers = markers
        self.palette = palette
        self.onSetMarkerBoundary = onSetMarkerBoundary
        self.onAddChapter = onAddChapter
        self.onAddBookmark = onAddBookmark
        self.onDeleteMarker = onDeleteMarker
        self.onAcceptMarker = onAcceptMarker
        self.onRejectMarker = onRejectMarker
        self.onPlayAdjacent = onPlayAdjacent
        self.onPlayEpisode = onPlayEpisode
        self.onEnterMiniMode = onEnterMiniMode
        self.onOpenAdvancedSettings = onOpenAdvancedSettings
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
                    .foregroundStyle(palette.secondary)
                    .frame(width: 42, alignment: .trailing)

                VideoProgressScrubber(
                    currentTime: timelineState.currentTime,
                    duration: timelineState.duration,
                    enabled: timelineState.canControl && timelineState.duration > 0,
                    previewMode: previewMode,
                    coarsePreviewBuckets: previewUsesCoarseBuckets,
                    preview: $scrubberPreview,
                    previewImage: previewImage,
                    previewIsLoading: previewIsLoading,
                    markers: markers,
                    palette: palette,
                    onSeek: { controller.seek(to: $0) }
                )

                // 点击时长直接切换剩余/总时长（IINA/QuickTime 习惯），不必进设置。
                Button {
                    appState.settings.videoShowRemainingTime.toggle()
                    appState.saveSettings()
                } label: {
                    Text(trailingTimelineText(timelineState))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.secondary)
                        .frame(width: 50, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击切换剩余 / 总时长")
            }

            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    // 视频隔空播放按钮已移除：内置视频经 libmpv 渲染到自有 OpenGL 视图，
                    // AVRoutePicker 仅能驱动音频代理播放器，无法把画面投到外部设备，
                    // 点击只会在本机播放、造成误导。系统级整窗投屏可由 macOS“屏幕镜像”承担。
                    if appState.videoQueue.count > 1 {
                        episodeListButton
                    }
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
                .frame(width: 200, alignment: .leading)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button {
                        onPlayAdjacent(-1)
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .playerControlIcon(width: 27, height: 27, palette: palette)
                    }
                    .help("上一集")

                    Button {
                        controller.togglePlay()
                    } label: {
                        Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(palette.primary)
                            .frame(width: 44, height: 30)
                            .playerCapsuleControl(cornerRadius: 15, palette: palette)
                    }
                    // 空格由窗口级快捷键监听统一处理（默认映射到“播放/暂停”），
                    // 这里不再叠加 SwiftUI 的空格快捷键，避免一次空格触发两次切换。
                    .help("播放/暂停")
                    .disabled(!transportState.canControl)

                    Button {
                        onPlayAdjacent(1)
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .playerControlIcon(width: 27, height: 27, palette: palette)
                    }
                    .help("下一集")
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    volumeButton(volume: transportState.volume)
                        .disabled(!transportState.canControl)
                    settingsButton
                    Button {
                        onEnterMiniMode()
                    } label: {
                        Image(systemName: "pip.enter")
                            .playerControlIcon(palette: palette)
                    }
                    .help("迷你悬浮窗")
                    Button {
                        controller.toggleFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .playerControlIcon(palette: palette)
                    }
                    .help("全屏")
                }
                .frame(width: 200, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 568)
        .playerGlass(cornerRadius: 14, palette: palette)
        .padding(.bottom, 5)
    }

    private var subtitleButton: some View {
        Button {
            togglePopover {
                showingSubtitlePopover.toggle()
            }
        } label: {
            Image(systemName: "captions.bubble")
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSubtitlePopover, arrowEdge: .bottom) {
            PlayerSubtitlePopover(
                controller: controller,
                sidecarSubtitles: sidecarSubtitles,
                item: item,
                palette: palette
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
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAudioPopover, arrowEdge: .bottom) {
            PlayerAudioTrackPopover(controller: controller, palette: palette)
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
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingVolumePopover, arrowEdge: .bottom) {
            PlayerVolumePopover(controller: controller, palette: palette)
        }
        .help("音量")
    }

    private var episodeListButton: some View {
        Button {
            togglePopover {
                showingEpisodeListPopover.toggle()
            }
        } label: {
            Image(systemName: "list.triangle")
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingEpisodeListPopover, arrowEdge: .bottom) {
            PlayerEpisodeListPopover(currentItem: item, palette: palette) { episode in
                showingEpisodeListPopover = false
                onPlayEpisode(episode)
            }
        }
        .help("剧集列表")
    }

    private var settingsButton: some View {
        Button {
            togglePopover {
                showingSettingsPopover.toggle()
            }
        } label: {
            Image(systemName: "gearshape")
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSettingsPopover, arrowEdge: .bottom) {
            PlayerSettingsPopover(
                controller: controller,
                palette: palette
            ) {
                showingSettingsPopover = false
                onOpenAdvancedSettings()
            }
        }
        .help("播放器设置")
    }

    private func trailingTimelineText(_ state: PlayerTimelineState) -> String {
        guard appState.settings.videoShowRemainingTime,
              state.duration > 0,
              state.currentTime.isFinite else {
            return state.formattedDuration
        }
        return "-\(formatTimelineTime(max(state.duration - state.currentTime, 0)))"
    }

    private func formatTimelineTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
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
            .foregroundStyle(palette.primary)
            .frame(width: 58, height: 28)
            .playerCapsuleControl(cornerRadius: 14, palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingQualityPopover, arrowEdge: .bottom) {
            PlayerQualityPopover(
                options: qualityOptions,
                selectedID: selectedQualityID,
                palette: palette
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
                .playerControlIcon(palette: palette)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingMarkerPopover, arrowEdge: .bottom) {
            PlayerMarkerPopover(
                currentTime: currentTime,
                duration: duration,
                markers: markers,
                palette: palette,
                onSeek: { controller.seek(to: $0) },
                onSetBoundary: onSetMarkerBoundary,
                onAddChapter: onAddChapter,
                onAddBookmark: onAddBookmark,
                onDeleteMarker: onDeleteMarker,
                onAcceptMarker: onAcceptMarker,
                onRejectMarker: onRejectMarker
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

enum PlayerTrackpadScrollGesture: Equatable {
    case horizontal(Double)
    case vertical(Double)
    case mouseWheelVolume(Double)
}

struct PlayerInteractionOverlay: NSViewRepresentable {
    let onPrimaryClick: () -> Void
    let onDoubleClick: () -> Void
    let onActivity: () -> Void
    let onSecondaryClick: (CGPoint) -> Void
    let onTrackpadScroll: (PlayerTrackpadScrollGesture) -> Void
    let onMagnify: (CGFloat) -> Void
    /// 中键/侧键等额外鼠标键（buttonNumber：2 中键，3 后退，4 前进）。
    var onOtherMouseButton: ((Int, CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onPrimaryClick = onPrimaryClick
        view.onDoubleClick = onDoubleClick
        view.onActivity = onActivity
        view.onSecondaryClick = onSecondaryClick
        view.onTrackpadScroll = onTrackpadScroll
        view.onMagnify = onMagnify
        view.onOtherMouseButton = onOtherMouseButton
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.onPrimaryClick = onPrimaryClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onActivity = onActivity
        nsView.onSecondaryClick = onSecondaryClick
        nsView.onTrackpadScroll = onTrackpadScroll
        nsView.onMagnify = onMagnify
        nsView.onOtherMouseButton = onOtherMouseButton
    }

    final class InteractionView: NSView {
        var onPrimaryClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onActivity: (() -> Void)?
        var onSecondaryClick: ((CGPoint) -> Void)?
        var onTrackpadScroll: ((PlayerTrackpadScrollGesture) -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        var onOtherMouseButton: ((Int, CGPoint) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var didDragWindow = false
        private var dragStartEvent: NSEvent?
        private var pendingPrimaryClick: DispatchWorkItem?

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
            pendingPrimaryClick?.cancel()
            pendingPrimaryClick = nil
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
            if event.clickCount >= 2 {
                pendingPrimaryClick?.cancel()
                pendingPrimaryClick = nil
                onDoubleClick?()
                return
            }

            pendingPrimaryClick?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingPrimaryClick = nil
                self?.onPrimaryClick?()
            }
            pendingPrimaryClick = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
        }

        override func rightMouseDown(with event: NSEvent) {
            pendingPrimaryClick?.cancel()
            pendingPrimaryClick = nil
            onActivity?()
            onSecondaryClick?(swiftUILocation(for: event))
        }

        override func otherMouseDown(with event: NSEvent) {
            pendingPrimaryClick?.cancel()
            pendingPrimaryClick = nil
            onActivity?()
            if let onOtherMouseButton {
                onOtherMouseButton(event.buttonNumber, swiftUILocation(for: event))
            } else {
                onSecondaryClick?(swiftUILocation(for: event))
            }
        }

        override func scrollWheel(with event: NSEvent) {
            onActivity?()
            guard event.hasPreciseScrollingDeltas else {
                let deltaY = Double(event.scrollingDeltaY)
                if abs(deltaY) > 0.1 {
                    onTrackpadScroll?(.mouseWheelVolume(deltaY))
                } else {
                    super.scrollWheel(with: event)
                }
                return
            }

            let deltaX = Double(event.scrollingDeltaX)
            let deltaY = Double(event.scrollingDeltaY)
            if abs(deltaX) > abs(deltaY) * 1.18, abs(deltaX) > 0.35 {
                onTrackpadScroll?(.horizontal(deltaX))
            } else if abs(deltaY) > 0.35 {
                onTrackpadScroll?(.vertical(deltaY))
            }
        }

        override func magnify(with event: NSEvent) {
            onActivity?()
            onMagnify?(event.magnification)
        }

        private func swiftUILocation(for event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            return CGPoint(x: local.x, y: bounds.height - local.y)
        }
    }
}

/// 控制栏右键隐藏：控制条上的 SwiftUI 控件会吃掉直接命中的鼠标事件，
/// 所以这里不靠 AppKit 响应链，而是装一个窗口级 local 监听，
/// 只在右键落点位于宿主视图（控制条背景）范围内时回调；回调方返回是否消费该事件，
/// 未消费（例如控制条被锁定）则放行给画面右键菜单。宿主视图自身不参与命中测试，
/// 不会影响控制条按钮、进度条的正常点击。
struct PlayerControlsBarSecondaryClickCatcher: NSViewRepresentable {
    var onSecondaryClick: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onSecondaryClick: onSecondaryClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughHostView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSecondaryClick = onSecondaryClick
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class PassthroughHostView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var onSecondaryClick: () -> Bool
        private weak var hostView: NSView?
        private var monitor: Any?

        init(onSecondaryClick: @escaping () -> Bool) {
            self.onSecondaryClick = onSecondaryClick
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            hostView = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let hostView, let hostWindow = hostView.window,
                  event.window === hostWindow else { return event }
            let frameInWindow = hostView.convert(hostView.bounds, to: nil)
            guard frameInWindow.contains(event.locationInWindow) else { return event }
            return onSecondaryClick() ? nil : event
        }
    }
}

/// 迷你悬浮窗的极简控制层：播放/暂停、还原、关闭，随控制可见性淡入淡出。
private struct PlayerMiniModeOverlay: View {
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    let visible: Bool
    let onExit: () -> Void
    let onClose: () -> Void
    @StateObject private var transport: PlayerControllerProjection<PlayerTransportState>

    init(
        controller: MpvPlayerController,
        palette: VideoControlPalette,
        visible: Bool,
        onExit: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.palette = palette
        self.visible = visible
        self.onExit = onExit
        self.onClose = onClose
        _transport = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerTransportState.init))
    }

    var body: some View {
        let transportState = transport.value
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
                        .playerControlIcon(palette: palette)
                }
                .disabled(!transportState.canControl)
                .help("播放/暂停")

                Button {
                    onExit()
                } label: {
                    Image(systemName: "pip.exit")
                        .playerControlIcon(palette: palette)
                }
                .help("还原窗口")

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .playerControlIcon(palette: palette)
                }
                .help("关闭")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(AppMotion.fast, value: visible)
    }
}

private struct PlayerStatusOverlay: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let palette: VideoControlPalette
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(palette.secondary)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primary)

            Text(message)
                .font(.callout)
                .foregroundStyle(palette.secondary)
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
        .playerGlass(cornerRadius: 22, palette: palette)
    }
}

private struct PlayerBufferingOverlay: View {
    let title: String
    let progress: Double?
    let message: String?
    let palette: VideoControlPalette

    var body: some View {
        VStack(spacing: 10) {
            PlayerBufferingSpinner(palette: palette)
                .frame(width: 46, height: 46)

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.primary)

            Text(progressText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(palette.secondary)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(palette.subdued)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .playerGlass(cornerRadius: 22, palette: palette)
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
    let palette: VideoControlPalette
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.trackBase, lineWidth: 4)
            Circle()
                .trim(from: 0.06, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [
                            palette.subdued.opacity(0.34),
                            palette.primary,
                            palette.secondary.opacity(0.62)
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

private struct PlayerToastLayer: View {
    let message: String
    let palette: VideoControlPalette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.selectedGlassTint.opacity(0.96))
            Text(message)
                .foregroundStyle(palette.primary)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .playerGlass(cornerRadius: 16, palette: palette)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }
}

private struct PlayerContextMenuState: Equatable {
    let id = UUID()
    let location: CGPoint
}

private enum PlayerContextMenuSection: Hashable {
    case speed
    case audio
    case subtitle
    case quality
    case markers
    case window
    case settings
}

private struct PlayerContextMenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PlayerContextMenuOverlay: View {
    private let menuWidth: CGFloat = 312
    private let maximumMenuHeight: CGFloat = 540

    let state: PlayerContextMenuState
    let controller: MpvPlayerController
    let item: MediaItem
    let sidecarSubtitles: [SidecarSubtitleFile]
    let qualityOptions: [VideoStreamQualityOption]
    @Binding var selectedQualityID: String?
    let markers: [PlaybackMarker]
    let palette: VideoControlPalette
    let onDismiss: () -> Void
    let onSetMarkerBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onPlayAdjacent: (Int) -> Void
    let onOpenPlaybackInfo: () -> Void
    let onEnterMiniMode: () -> Void
    let onToast: (String) -> Void

    /// 菜单内容的自然高度，由 PlayerContextMenu 内容区上报；据此让菜单按内容自适应高度。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                PlayerContextMenu(
                    controller: controller,
                    item: item,
                    sidecarSubtitles: sidecarSubtitles,
                    qualityOptions: qualityOptions,
                    selectedQualityID: $selectedQualityID,
                    markers: markers,
                    palette: palette,
                    onDismiss: onDismiss,
                    onSetMarkerBoundary: onSetMarkerBoundary,
                    onAddChapter: onAddChapter,
                    onPlayAdjacent: onPlayAdjacent,
                    onOpenPlaybackInfo: onOpenPlaybackInfo,
                    onEnterMiniMode: onEnterMiniMode,
                    onToast: onToast
                )
                .frame(width: menuWidth)
                .frame(height: resolvedHeight(for: proxy.size))
                .position(menuPosition(in: proxy.size))
                .onPreferenceChange(PlayerContextMenuContentHeightKey.self) { height in
                    contentHeight = height
                }
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// 菜单允许的最大高度（受窗口高度约束）。内容更短时菜单会收缩到内容高度。
    private func heightCap(for size: CGSize) -> CGFloat {
        min(maximumMenuHeight, max(size.height - 24, 160))
    }

    /// 实际渲染高度：取「内容自然高度」与上限的较小值；内容尚未测得时先用上限，随后收缩。
    private func resolvedHeight(for size: CGSize) -> CGFloat {
        let cap = heightCap(for: size)
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }

    private func menuPosition(in size: CGSize) -> CGPoint {
        let menuHeight = resolvedHeight(for: size)
        let proposed = CGPoint(
            x: state.location.x + menuWidth / 2,
            y: state.location.y + menuHeight / 2
        )
        let minX = menuWidth / 2 + 12
        let maxX = max(minX, size.width - menuWidth / 2 - 12)
        let minY = menuHeight / 2 + 12
        let maxY = max(minY, size.height - menuHeight / 2 - 12)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }
}

private struct PlayerContextMenu: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let item: MediaItem
    let sidecarSubtitles: [SidecarSubtitleFile]
    let qualityOptions: [VideoStreamQualityOption]
    @Binding var selectedQualityID: String?
    let markers: [PlaybackMarker]
    let palette: VideoControlPalette
    let onDismiss: () -> Void
    let onSetMarkerBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onPlayAdjacent: (Int) -> Void
    let onOpenPlaybackInfo: () -> Void
    let onEnterMiniMode: () -> Void
    let onToast: (String) -> Void

    @StateObject private var player: PlayerControllerProjection<PlayerContextMenuControllerState>

    init(
        controller: MpvPlayerController,
        item: MediaItem,
        sidecarSubtitles: [SidecarSubtitleFile],
        qualityOptions: [VideoStreamQualityOption],
        selectedQualityID: Binding<String?>,
        markers: [PlaybackMarker],
        palette: VideoControlPalette,
        onDismiss: @escaping () -> Void,
        onSetMarkerBoundary: @escaping (PlaybackMarker.Kind, Bool, Double) -> Void,
        onAddChapter: @escaping (Double) -> Void,
        onPlayAdjacent: @escaping (Int) -> Void,
        onOpenPlaybackInfo: @escaping () -> Void,
        onEnterMiniMode: @escaping () -> Void,
        onToast: @escaping (String) -> Void
    ) {
        self.controller = controller
        self.item = item
        self.sidecarSubtitles = sidecarSubtitles
        self.qualityOptions = qualityOptions
        _selectedQualityID = selectedQualityID
        self.markers = markers
        self.palette = palette
        self.onDismiss = onDismiss
        self.onSetMarkerBoundary = onSetMarkerBoundary
        self.onAddChapter = onAddChapter
        self.onPlayAdjacent = onPlayAdjacent
        self.onOpenPlaybackInfo = onOpenPlaybackInfo
        self.onEnterMiniMode = onEnterMiniMode
        self.onToast = onToast
        _player = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerContextMenuControllerState.init))
    }

    var body: some View {
        let playerState = player.value
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PlayerContextMenuHeader(title: item.title, subtitle: playerState.playbackStatusText, palette: palette)

                PlayerContextMenuButton(title: "从头播放", systemImage: "backward.end.fill", palette: palette) {
                    performAndDismiss {
                        controller.restartFromBeginning()
                    }
                }
                .disabled(!playerState.canControl)

                PlayerContextMenuButton(title: "保存当前画面", systemImage: "camera.fill", value: "图片", palette: palette) {
                    performAndDismiss {
                        do {
                            let url = try controller.captureCurrentVideoFrame(
                                title: item.title,
                                mode: appState.settings.videoScreenshotMode
                            )
                            onToast("截图已保存：\(url.lastPathComponent)")
                        } catch {
                            onToast("截图失败：\(error.localizedDescription)")
                        }
                    }
                }
                .disabled(!playerState.canControl)

                PlayerContextMenuButton(title: "复制播放进度", systemImage: "doc.on.clipboard", value: formatTime(playerState.currentTime), palette: palette) {
                    performAndDismiss {
                        copyPlaybackProgress(playerState)
                    }
                }
                .disabled(!playerState.canControl)

                PlayerContextMenuDivider(palette: palette)
                PlayerContextMenuSectionHeader("循环", palette: palette)

                PlayerContextMenuToggle(
                    title: "单片循环",
                    systemImage: "repeat.1",
                    isOn: playerState.loopCurrentItem,
                    palette: palette
                ) {
                    let enabled = !playerState.loopCurrentItem
                    appState.settings.videoLoopCurrentItem = enabled
                    appState.saveSettings()
                    controller.setLoopCurrentItem(enabled)
                }

                PlayerContextMenuButton(
                    title: abLoopActionTitle(playerState),
                    systemImage: "arrow.triangle.2.circlepath",
                    value: abLoopValue(playerState),
                    palette: palette
                ) {
                    let selection = controller.cycleABLoopPoint()
                    onToast(abLoopToast(for: selection))
                }
                .disabled(!playerState.canControl)

                if playerState.abLoopStart != nil || playerState.abLoopEnd != nil {
                    PlayerContextMenuButton(title: "清除 A-B 循环", systemImage: "xmark.circle", palette: palette) {
                        performAndDismiss {
                            controller.clearABLoop()
                            onToast("A-B 循环已清除")
                        }
                    }
                }

                PlayerContextMenuDivider(palette: palette)

                PlayerContextMenuButton(title: "迷你悬浮窗", systemImage: "pip.enter", palette: palette) {
                    performAndDismiss(onEnterMiniMode)
                }

                PlayerContextMenuButton(title: "播放信息", systemImage: "info.circle", palette: palette) {
                    performAndDismiss(onOpenPlaybackInfo)
                }

                if canRevealInFinder {
                    PlayerContextMenuButton(title: "在访达中显示", systemImage: "folder", palette: palette) {
                        performAndDismiss(revealInFinder)
                    }
                }

                PlayerContextMenuButton(title: "用系统播放器打开", systemImage: "app.badge", palette: palette) {
                    performAndDismiss {
                        appState.openExternally(item)
                    }
                }
            }
            .padding(10)
            .background(
                GeometryReader { contentProxy in
                    Color.clear.preference(
                        key: PlayerContextMenuContentHeightKey.self,
                        value: contentProxy.size.height
                    )
                }
            )
        }
        .scrollIndicators(.never)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
    }

    private func performAndDismiss(_ action: () -> Void) {
        action()
        onDismiss()
    }

    private var canRevealInFinder: Bool {
        guard let path = item.filePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func revealInFinder() {
        guard let path = item.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyPlaybackProgress(_ state: PlayerContextMenuControllerState) {
        let text = state.duration > 0
            ? "\(formatTime(state.currentTime)) / \(formatTime(state.duration))"
            : formatTime(state.currentTime)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onToast("已复制播放进度：\(text)")
    }

    private func abLoopActionTitle(_ state: PlayerContextMenuControllerState) -> String {
        if state.abLoopStart == nil { return "设置 A 点" }
        if state.abLoopEnd == nil { return "设置 B 点" }
        return "重设 A 点"
    }

    private func abLoopValue(_ state: PlayerContextMenuControllerState) -> String? {
        guard let start = state.abLoopStart else { return nil }
        if let end = state.abLoopEnd {
            return "\(formatTime(start)) - \(formatTime(end))"
        }
        return "A \(formatTime(start))"
    }

    private func abLoopToast(for selection: PlayerABLoopSelection) -> String {
        switch selection {
        case .cleared:
            return "A-B 循环已清除"
        case .start(let start):
            return "A-B 循环：A 点 \(formatTime(start))"
        case .range(let start, let end):
            return "A-B 循环：\(formatTime(start)) - \(formatTime(end))"
        }
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

private struct PlayerContextMenuHeader: View {
    let title: String
    let subtitle: String
    let palette: VideoControlPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(palette.subdued)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct PlayerContextMenuButton: View {
    let title: String
    let systemImage: String
    var value: String? = nil
    var selected: Bool = false
    let palette: VideoControlPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? palette.primary : palette.secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let value, !value.isEmpty {
                    Text(value)
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.primary)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(selected ? palette.selectedRowFill : palette.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? palette.selectedRowStroke : palette.rowStroke, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PlayerContextMenuDisclosureButton: View {
    let title: String
    let systemImage: String
    let value: String?
    let isExpanded: Bool
    let palette: VideoControlPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
                        .lineLimit(1)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.subdued)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(isExpanded ? palette.selectedRowFill : palette.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isExpanded ? palette.selectedRowStroke : palette.rowStroke, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PlayerContextMenuToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let palette: VideoControlPalette
    let action: () -> Void

    var body: some View {
        PlayerContextMenuButton(
            title: title,
            systemImage: systemImage,
            value: isOn ? "开" : "关",
            selected: isOn,
            palette: palette,
            action: action
        )
    }
}

private struct PlayerContextMenuDivider: View {
    let palette: VideoControlPalette

    var body: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(height: 0.7)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
    }
}

private struct PlayerContextMenuSectionHeader: View {
    let title: String
    let palette: VideoControlPalette

    init(_ title: String, palette: VideoControlPalette) {
        self.title = title
        self.palette = palette
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(palette.subdued)
            .padding(.horizontal, 8)
            .padding(.top, 3)
    }
}

private struct PlayerContextMenuNote: View {
    let text: String
    let palette: VideoControlPalette

    init(_ text: String, palette: VideoControlPalette) {
        self.text = text
        self.palette = palette
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(palette.subdued)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

private struct PlayerGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let palette: VideoControlPalette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .background(
                shape.fill(
                    LinearGradient(
                        colors: palette.materialFill,
                        startPoint: .top,
                        endPoint: .bottom
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
                        colors: palette.border,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: palette.shadow, radius: 8, y: 3)
            .shadow(color: .white.opacity(0.07), radius: 1, y: -0.5)
    }
}

private struct PlayerAudioDeviceState: Equatable {
    let devices: [MpvAudioDevice]
    let selectedName: String

    @MainActor
    init(controller: MpvPlayerController) {
        self.devices = controller.audioDevices
        self.selectedName = controller.selectedAudioDeviceName
    }
}

private struct PlayerVolumePopover: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    @StateObject private var volume: PlayerControllerProjection<Float>
    @StateObject private var boost: PlayerControllerProjection<Double>
    @StateObject private var deviceState: PlayerControllerProjection<PlayerAudioDeviceState>
    @State private var draftVolume: Double = 0
    @State private var isEditing = false

    init(controller: MpvPlayerController, palette: VideoControlPalette) {
        self.controller = controller
        self.palette = palette
        _volume = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.volume })
        _boost = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.volumeBoost })
        _deviceState = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerAudioDeviceState.init))
    }

    private var visibleVolume: Double {
        isEditing ? draftVolume : PerceptualVolumeScale.sliderValue(fromLinear: Double(volume.value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: volume.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 22, height: 24)
                PlayerLinearSlider(value: Binding(get: {
                    visibleVolume
                }, set: { value in
                    draftVolume = value
                    controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: value)), remember: false)
                }), range: 0...1, palette: palette, isEditing: $isEditing) {
                    controller.setVolume(Float(PerceptualVolumeScale.linearVolume(fromSlider: draftVolume)), remember: true)
                }
                .frame(width: 248, height: 26)

                // 输出设备：音量条右侧的小按钮，弹出设备菜单。
                Menu {
                    Picker("输出设备", selection: Binding(get: {
                        deviceState.value.selectedName
                    }, set: { name in
                        controller.selectAudioDevice(name)
                    })) {
                        Text("系统默认").tag("auto")
                        ForEach(deviceState.value.devices.filter { $0.name != "auto" }) { device in
                            Text(device.displayName).tag(device.name)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "hifispeaker")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .help("输出设备")
            }

            HStack(spacing: 8) {
                Text("增强")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 22 + 8, alignment: .leading)
                PlayerChoiceGroup {
                    ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        PlayerChoiceButton(
                            title: value == 1.0 ? "关闭" : "\(Int((value * 100).rounded()))%",
                            selected: abs(boost.value - value) < 0.01,
                            palette: palette
                        ) {
                            controller.setVolumeBoost(value)
                            appState.settings.videoVolumeBoost = value
                            appState.saveSettings()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 338)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
        .onAppear {
            draftVolume = PerceptualVolumeScale.sliderValue(fromLinear: Double(volume.value))
            controller.refreshAudioDevices()
        }
        .onChange(of: volume.value) { volume in
            if !isEditing {
                draftVolume = PerceptualVolumeScale.sliderValue(fromLinear: Double(volume))
            }
        }
    }
}

/// 倍速滑杆（内联版）：现在内嵌在齿轮设置弹层里，不再单独占一个控制栏按钮。
private struct PlayerInlineSpeedControl: View {
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    @StateObject private var playbackRate: PlayerControllerProjection<Float>
    @State private var draftRate: Double = 1
    @State private var isEditing = false
    private let snapRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    init(controller: MpvPlayerController, palette: VideoControlPalette) {
        self.controller = controller
        self.palette = palette
        _playbackRate = StateObject(wrappedValue: PlayerControllerProjection(controller: controller) { $0.playbackRate })
    }

    private var visibleRate: Double {
        isEditing ? draftRate : Double(playbackRate.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                PlayerSnapSlider(
                    value: Binding(get: {
                        visibleRate
                    }, set: { value in
                        let snapped = snappedRate(Float(value))
                        draftRate = Double(snapped)
                        controller.setPlaybackRate(snapped, updateExternalState: false)
                    }),
                    range: 0.5...3.0,
                    snapValues: snapRates.map(Double.init),
                    palette: palette,
                    isEditing: $isEditing
                ) {
                    controller.setPlaybackRate(Float(draftRate), updateExternalState: true)
                }
                .frame(height: 28)

                Text(String(format: "%.2fx", visibleRate))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            PlayerSpeedTickLabels(
                currentRate: visibleRate,
                ticks: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0],
                range: 0.5...3.0,
                palette: palette
            )
            .frame(height: 16)
            .padding(.trailing, 51)
        }
        .onAppear {
            draftRate = Double(playbackRate.value)
        }
        .onChange(of: playbackRate.value) { rate in
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
        return min(max(value, 0.5), 3.0)
    }
}

private struct PlayerPlaybackInfoState: Equatable {
    let duration: Double
    let playbackRate: Float
    let volume: Float
    let audioTracks: [MpvTrack]
    let subtitleTracks: [MpvTrack]
    let loopCurrentItem: Bool
    let abLoopStart: Double?
    let abLoopEnd: Double?
    let aspectOverride: VideoAspectOverride
    let cropMode: VideoCropMode
    let deinterlaceMode: VideoDeinterlaceMode
    let rotationMode: VideoRotationMode

    @MainActor
    init(controller: MpvPlayerController) {
        self.duration = controller.duration
        self.playbackRate = controller.playbackRate
        self.volume = controller.volume
        self.audioTracks = controller.audioTracks
        self.subtitleTracks = controller.subtitleTracks
        self.loopCurrentItem = controller.loopCurrentItem
        self.abLoopStart = controller.abLoopStart
        self.abLoopEnd = controller.abLoopEnd
        self.aspectOverride = controller.aspectOverride
        self.cropMode = controller.cropMode
        self.deinterlaceMode = controller.deinterlaceMode
        self.rotationMode = controller.rotationMode
    }
}

private struct PlayerPlaybackInfoOverlay: View {
    let item: MediaItem
    let controller: MpvPlayerController
    let qualityOptions: [VideoStreamQualityOption]
    let selectedQualityID: String?
    let palette: VideoControlPalette
    let onDismiss: () -> Void
    @StateObject private var playerState: PlayerControllerProjection<PlayerPlaybackInfoState>

    init(
        item: MediaItem,
        controller: MpvPlayerController,
        qualityOptions: [VideoStreamQualityOption],
        selectedQualityID: String?,
        palette: VideoControlPalette,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.controller = controller
        self.qualityOptions = qualityOptions
        self.selectedQualityID = selectedQualityID
        self.palette = palette
        self.onDismiss = onDismiss
        _playerState = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerPlaybackInfoState.init))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                VStack(alignment: .leading, spacing: 14) {
                    header

                    Divider()
                        .overlay(palette.rowStroke)

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("类型", value: item.type.displayName, systemImage: item.type.systemImage)
                        infoRow("时长", value: durationText, systemImage: "clock")
                        infoRow("分辨率", value: cleanText(item.resolution, fallback: "未知"), systemImage: "rectangle.inset.filled")
                        infoRow("视频编码", value: cleanText(item.videoCodec, fallback: "未知"), systemImage: "film")
                        infoRow("音频编码", value: cleanText(item.audioCodec, fallback: "未知"), systemImage: "waveform")
                        infoRow("文件大小", value: fileSizeText, systemImage: "externaldrive")
                        infoRow("当前清晰度", value: qualityText, systemImage: "sparkles.tv")
                        infoRow("当前音轨", value: selectedAudioTrackText, systemImage: "speaker.wave.2")
                        infoRow("当前字幕", value: selectedSubtitleTrackText, systemImage: "captions.bubble")
                        infoRow("播放状态", value: playbackTuningText, systemImage: "slider.horizontal.3")
                        infoRow("循环", value: loopText, systemImage: "repeat")
                    }
                }
                .padding(18)
                .frame(width: min(max(proxy.size.width - 96, 520), 640))
                .playerPopoverGlass(palette: palette, liveMaterial: false)
                .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("播放信息", systemImage: "info.circle")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.primary)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 30, height: 30)
                    .playerCapsuleControl(cornerRadius: 15, palette: palette)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private func infoRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 104, alignment: .leading)

            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .padding(.horizontal, 9)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.choiceFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.rowStroke, lineWidth: 0.8)
                }
        }
    }

    private var durationText: String {
        let duration = playerState.value.duration > 0 ? playerState.value.duration : item.duration ?? 0
        return formatTime(duration)
    }

    private var fileSizeText: String {
        guard let fileSize = item.fileSize, fileSize > 0 else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    private var qualityText: String {
        if let selectedQualityID,
           let selected = qualityOptions.first(where: { $0.id == selectedQualityID }) {
            return selected.label
        }
        return qualityOptions.first?.label ?? "当前片源"
    }

    private var selectedAudioTrackText: String {
        playerState.value.audioTracks.first(where: \.isSelected)?.displayName ?? "自动"
    }

    private var selectedSubtitleTrackText: String {
        playerState.value.subtitleTracks.first(where: \.isSelected)?.displayName ?? "关闭"
    }

    private var playbackTuningText: String {
        var parts: [String] = []
        parts.append(rateText(playerState.value.playbackRate))
        parts.append("音量 \(Int((playerState.value.volume * 100).rounded()))%")
        if playerState.value.aspectOverride != .source {
            parts.append(playerState.value.aspectOverride.displayName)
        }
        if playerState.value.cropMode != .none {
            parts.append("裁切 \(playerState.value.cropMode.displayName)")
        }
        if playerState.value.deinterlaceMode != .off {
            parts.append("去隔行 \(playerState.value.deinterlaceMode.displayName)")
        }
        if playerState.value.rotationMode != .source {
            parts.append("旋转 \(playerState.value.rotationMode.displayName)")
        }
        return parts.joined(separator: " · ")
    }

    private var loopText: String {
        var parts: [String] = []
        if playerState.value.loopCurrentItem {
            parts.append("单片循环")
        }
        if let start = playerState.value.abLoopStart {
            if let end = playerState.value.abLoopEnd {
                parts.append("A-B \(formatTime(start)) - \(formatTime(end))")
            } else {
                parts.append("A 点 \(formatTime(start))")
            }
        }
        return parts.isEmpty ? "关闭" : parts.joined(separator: " · ")
    }

    private func cleanText(_ value: String?, fallback: String) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func rateText(_ rate: Float) -> String {
        if abs(rate - 1.0) < 0.001 { return "1x" }
        if abs(rate.rounded() - rate) < 0.001 { return String(format: "%.0fx", rate) }
        return String(format: "%.2fx", rate)
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

private enum PlayerAdvancedSettingsTab: String, CaseIterable, Identifiable {
    case playback
    case sync
    case video
    case subtitles
    case shortcuts
    case gestures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "播放"
        case .sync: return "音画同步"
        case .video: return "画面"
        case .subtitles: return "字幕"
        case .shortcuts: return "快捷键"
        case .gestures: return "触控板"
        }
    }

    var systemImage: String {
        switch self {
        case .playback: return "play.rectangle"
        case .sync: return "waveform.path.ecg"
        case .video: return "rectangle.inset.filled"
        case .subtitles: return "captions.bubble"
        case .shortcuts: return "keyboard"
        case .gestures: return "hand.draw"
        }
    }
}

private struct PlayerAdvancedSettingsOverlay: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    let onDismiss: () -> Void
    let onOpenPlaybackInfo: () -> Void
    @State private var selectedTab: PlayerAdvancedSettingsTab = .playback
    @State private var recordingAction: VideoPlayerShortcutAction?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.26)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                VStack(spacing: 0) {
                    header
                    Divider()
                        .overlay(palette.rowStroke)
                    HStack(alignment: .top, spacing: 0) {
                        sidebar
                        Divider()
                            .overlay(palette.rowStroke)
                        content
                    }
                }
                .frame(width: min(max(proxy.size.width - 92, 680), 900), height: min(max(proxy.size.height - 92, 500), 660))
                .playerPopoverGlass(palette: palette, liveMaterial: false)
                .shadow(color: .black.opacity(0.26), radius: 24, y: 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("播放器更多设置", systemImage: "slider.horizontal.3")
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primary)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 30, height: 30)
                    .playerCapsuleControl(cornerRadius: 15, palette: palette, liveMaterial: false)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(PlayerAdvancedSettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                    recordingAction = nil
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? palette.choiceSelectedForeground : palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selectedTab == tab ? palette.choiceSelectedFill : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 150)
    }

    private var content: some View {
        ScrollView {
            // LazyVStack：快捷键 tab 的分组数量多、行内控件密，懒加载避免一次性
            // 构建全部行（滑动掉帧来源之一）；其余 tab 内容块小，不受影响。
            LazyVStack(alignment: .leading, spacing: 16) {
                switch selectedTab {
                case .playback:
                    playbackSettings
                case .sync:
                    syncSettings
                case .video:
                    videoSettings
                case .subtitles:
                    subtitleStyleSettings
                case .shortcuts:
                    shortcutSettings
                case .gestures:
                    gestureSettings
                }
            }
            .padding(18)
        }
        .scrollIndicators(.automatic)
    }

    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            PlayerSettingsGroup(title: "窗口与时间轴", palette: palette) {
                // 当前窗口宽度直接拖拽窗口边缘调整；这里只决定下次启动的宽度策略。
                PlayerSettingToggleRow(
                    title: "启动窗口宽度",
                    systemImage: "arrow.left.and.right.square",
                    isOn: appState.settings.videoUseFixedLaunchWidth,
                    palette: palette
                ) {
                    appState.settings.videoUseFixedLaunchWidth.toggle()
                    appState.saveSettings()
                }

                if appState.settings.videoUseFixedLaunchWidth {
                    PlayerPercentSliderRow(
                        title: "启动宽度",
                        systemImage: "arrow.left.and.right",
                        palette: palette,
                        range: 0.45...1.0,
                        initialValue: AppSettings.clampedVideoLaunchWidthRatio(appState.settings.videoLaunchWidthRatio)
                    ) { ratio in
                        appState.settings.videoLaunchWidthRatio = AppSettings.clampedVideoLaunchWidthRatio(ratio)
                        appState.saveSettings()
                    }
                } else {
                    Text("不勾选时，每次打开视频都沿用你上次调整后的窗口大小。勾选后按这里设定的比例展开，100% 即占满屏幕。")
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PlayerSettingToggleRow(
                    title: "窗口置顶",
                    systemImage: "pin",
                    isOn: appState.settings.videoPlayerAlwaysOnTop,
                    palette: palette
                ) {
                    appState.settings.videoPlayerAlwaysOnTop.toggle()
                    appState.saveSettings()
                    PlayerWindowActions.setAlwaysOnTop(appState.settings.videoPlayerAlwaysOnTop)
                }

                PlayerSettingToggleRow(
                    title: "剩余时间",
                    systemImage: "clock.badge",
                    isOn: appState.settings.videoShowRemainingTime,
                    palette: palette
                ) {
                    appState.settings.videoShowRemainingTime.toggle()
                    appState.saveSettings()
                }

                PlayerSettingRow(title: "预览图", systemImage: "photo.on.rectangle.angled", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoScrubberPreviewMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoScrubberPreviewMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoScrubberPreviewMode = mode
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "截图内容", systemImage: "camera", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoScreenshotMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoScreenshotMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoScreenshotMode = mode
                                appState.saveSettings()
                            }
                        }
                    }
                }
            }

            PlayerSettingsGroup(title: "播放行为", palette: palette) {
                PlayerSettingRow(title: "默认倍速", systemImage: "speedometer", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            PlayerChoiceButton(
                                title: settingsRateTitle(rate),
                                selected: abs(appState.settings.defaultPlaybackRate - rate) < 0.001,
                                palette: palette
                            ) {
                                appState.settings.defaultPlaybackRate = rate
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "快进/快退", systemImage: "gobackward.5", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { seconds in
                            PlayerChoiceButton(
                                title: "\(Int(seconds))秒",
                                selected: abs(appState.settings.skipInterval - seconds) < 0.001,
                                palette: palette
                            ) {
                                appState.settings.skipInterval = seconds
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "恢复回退", systemImage: "gobackward", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach([0.0, 5.0, 10.0, 15.0, 30.0], id: \.self) { seconds in
                            PlayerChoiceButton(
                                title: seconds == 0 ? "关闭" : "\(Int(seconds))秒",
                                selected: abs(appState.settings.videoResumeRewindSeconds - seconds) < 0.001,
                                palette: palette
                            ) {
                                appState.settings.videoResumeRewindSeconds = AppSettings.clampedVideoResumeRewind(seconds)
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "片头片尾", systemImage: "forward.end", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoMarkerSkipBehavior.allCases) { behavior in
                            PlayerChoiceButton(
                                title: behavior.displayName,
                                selected: appState.settings.videoMarkerSkipBehavior == behavior,
                                palette: palette
                            ) {
                                appState.settings.videoMarkerSkipBehavior = behavior
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingToggleRow(
                    title: "记忆进度",
                    systemImage: "clock.arrow.circlepath",
                    isOn: appState.settings.rememberPlaybackPosition,
                    palette: palette
                ) {
                    appState.settings.rememberPlaybackPosition.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "记忆本片倍速",
                    systemImage: "speedometer",
                    isOn: appState.settings.videoRememberPlaybackRate,
                    palette: palette
                ) {
                    appState.settings.videoRememberPlaybackRate.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "启动音量",
                    systemImage: "speaker.wave.1",
                    isOn: appState.settings.videoUseLaunchVolume,
                    palette: palette
                ) {
                    appState.settings.videoUseLaunchVolume.toggle()
                    appState.saveSettings()
                }

                if appState.settings.videoUseLaunchVolume {
                    PlayerPercentSliderRow(
                        title: "音量设定",
                        systemImage: "speaker.wave.2",
                        palette: palette,
                        range: 0...1,
                        initialValue: AppSettings.clampedVideoLaunchVolume(appState.settings.videoLaunchVolume)
                    ) { value in
                        appState.settings.videoLaunchVolume = AppSettings.clampedVideoLaunchVolume(value)
                        appState.saveSettings()
                    }
                }

                PlayerSettingRow(title: "播放结束", systemImage: "forward.end", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoPlaybackEndAction.allCases) { action in
                            PlayerChoiceButton(
                                title: action.displayName,
                                selected: appState.settings.videoPlaybackEndAction == action,
                                palette: palette
                            ) {
                                appState.settings.videoPlaybackEndAction = action
                                appState.settings.autoPlayNextEpisode = action == .nextEpisode
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingToggleRow(
                    title: "自动标记已看",
                    systemImage: "checkmark.circle",
                    isOn: appState.settings.autoMarkWatched,
                    palette: palette
                ) {
                    appState.settings.autoMarkWatched.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "变调保护",
                    systemImage: "tuningfork",
                    isOn: appState.settings.videoPitchCorrectionEnabled,
                    palette: palette
                ) {
                    let enabled = !appState.settings.videoPitchCorrectionEnabled
                    appState.settings.videoPitchCorrectionEnabled = enabled
                    appState.saveSettings()
                    controller.setPitchCorrection(enabled)
                }
            }

            PlayerSettingsGroup(title: "音频均衡器", palette: palette) {
                PlayerSettingToggleRow(
                    title: "启用均衡器",
                    systemImage: "slider.vertical.3",
                    isOn: appState.settings.videoEqualizerEnabled,
                    palette: palette
                ) {
                    let enabled = !appState.settings.videoEqualizerEnabled
                    appState.settings.videoEqualizerEnabled = enabled
                    appState.saveSettings()
                    controller.setVideoEqualizer(enabled: enabled, preset: appState.settings.videoEqualizerPreset)
                }

                if appState.settings.videoEqualizerEnabled {
                    PlayerSettingRow(title: "预设", systemImage: "waveform", palette: palette) {
                        PlayerChoiceGroup {
                            ForEach(MusicEqualizerPreset.allCases) { preset in
                                PlayerChoiceButton(
                                    title: preset.displayName,
                                    selected: appState.settings.videoEqualizerPreset == preset,
                                    palette: palette
                                ) {
                                    appState.settings.videoEqualizerPreset = preset
                                    appState.saveSettings()
                                    controller.setVideoEqualizer(enabled: true, preset: preset)
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    private var shortcutSettings: some View {
        // Group 而非 VStack：让分组作为外层 LazyVStack 的直接子项参与懒加载。
        Group {
            HStack {
                Text("这些快捷键在视频播放窗口内有效。把一个按键设给新动作时，会自动从原来的动作上移除。")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    appState.settings.resetAllVideoKeyboardShortcuts()
                    appState.saveSettings()
                    recordingAction = nil
                } label: {
                    Label("恢复全部默认", systemImage: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .playerCapsuleControl(cornerRadius: 10, palette: palette, liveMaterial: false)
                }
                .buttonStyle(.plain)
            }

            // 不再用分组卡片包行：让每一行都是外层 LazyVStack 的直接懒加载子项
            // （嵌套 ForEach 会被懒容器展平），滚动时只构建可见行。
            ForEach(shortcutGroups, id: \.title) { group in
                Text(group.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.subdued)
                    .padding(.top, 8)
                ForEach(group.actions) { action in
                    PlayerShortcutSettingRow(
                        action: action,
                        shortcuts: appState.settings.resolvedVideoKeyboardShortcuts(for: action),
                        isRecording: recordingAction == action,
                        palette: palette,
                        conflictLookup: { shortcut in
                            appState.settings.videoPlayerShortcutConflict(for: shortcut, excluding: action)
                        },
                        onRecord: {
                            recordingAction = action
                        },
                        onClear: {
                            appState.settings.setVideoKeyboardShortcuts([], for: action)
                            appState.saveSettings()
                            recordingAction = nil
                        },
                        onReset: {
                            appState.settings.resetVideoKeyboardShortcut(for: action)
                            appState.saveSettings()
                            recordingAction = nil
                        },
                        onCancel: {
                            recordingAction = nil
                        },
                        onCapture: { shortcut in
                            appState.settings.setVideoKeyboardShortcuts([shortcut], for: action)
                            appState.saveSettings()
                            recordingAction = nil
                        }
                    )
                }
            }
        }
    }

    /// 字幕样式可选字体：常见中西文家族里实际安装的那部分。
    private static let subtitleFontChoices: [String] = {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        let preferred = [
            "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Songti SC", "Yuanti SC",
            "LXGW WenKai", "Helvetica Neue", "Avenir Next", "Georgia", "Arial"
        ]
        return preferred.filter { available.contains($0) }
    }()

    private var subtitleStyleSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            PlayerSettingsGroup(title: "字幕样式", palette: palette) {
                PlayerSettingRow(title: "字体", systemImage: "textformat", palette: palette) {
                    HStack {
                        Spacer(minLength: 0)
                        Menu {
                            Button("默认") {
                                updateSubtitleStyle { $0.fontName = nil }
                            }
                            Divider()
                            ForEach(Self.subtitleFontChoices, id: \.self) { family in
                                Button(family) {
                                    updateSubtitleStyle { $0.fontName = family }
                                }
                            }
                        } label: {
                            Text(appState.settings.videoSubtitleStyle.fontName ?? "默认")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.primary)
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.choiceFill)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(palette.rowStroke, lineWidth: 0.8)
                        }
                    }
                }

                PlayerSettingToggleRow(
                    title: "粗体",
                    systemImage: "bold",
                    isOn: appState.settings.videoSubtitleStyle.bold,
                    palette: palette
                ) {
                    updateSubtitleStyle { $0.bold.toggle() }
                }

                PlayerSettingRow(title: "颜色", systemImage: "paintpalette", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoSubtitleColorPreset.allCases) { preset in
                            PlayerChoiceButton(
                                title: preset.displayName,
                                selected: appState.settings.videoSubtitleStyle.colorPreset == preset,
                                palette: palette
                            ) {
                                updateSubtitleStyle { $0.colorPreset = preset }
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "描边", systemImage: "pencil.tip", palette: palette) {
                    PlayerAdjustmentControls(
                        valueText: String(format: "%.1f", appState.settings.videoSubtitleStyle.borderSize),
                        palette: palette,
                        onDecrement: {
                            updateSubtitleStyle { $0.borderSize = VideoSubtitleStyle.clampBorder($0.borderSize - 0.5) }
                        },
                        onReset: {
                            updateSubtitleStyle { $0.borderSize = 3 }
                        },
                        onIncrement: {
                            updateSubtitleStyle { $0.borderSize = VideoSubtitleStyle.clampBorder($0.borderSize + 0.5) }
                        }
                    )
                }

                PlayerSettingRow(title: "背景底", systemImage: "rectangle.fill.on.rectangle.fill", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach([(0.0, "关闭"), (0.25, "淡"), (0.45, "中"), (0.7, "深")], id: \.0) { value, label in
                            PlayerChoiceButton(
                                title: label,
                                selected: abs(appState.settings.videoSubtitleStyle.backgroundOpacity - value) < 0.01,
                                palette: palette
                            ) {
                                updateSubtitleStyle { $0.backgroundOpacity = value }
                            }
                        }
                    }
                }
            }

            Text("改动立刻能在画面上看到，并作为以后视频的默认字幕样式。字幕大小与位置在「音画同步」标签页调整。")
                .font(.caption2)
                .foregroundStyle(palette.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func updateSubtitleStyle(_ mutate: (inout VideoSubtitleStyle) -> Void) {
        var style = appState.settings.videoSubtitleStyle
        mutate(&style)
        appState.settings.videoSubtitleStyle = style
        appState.saveSettings()
        controller.setSubtitleStyle(style)
    }

    private var syncSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            PlayerSettingsGroup(title: "音画同步", palette: palette) {
                PlayerSettingRow(title: "音频延迟", systemImage: "speaker.wave.2", palette: palette) {
                    PlayerAdjustmentControls(
                        valueText: syncDelayText(appState.settings.videoDefaultAudioDelay),
                        palette: palette,
                        onDecrement: { setAudioDelay(appState.settings.videoDefaultAudioDelay - 0.1) },
                        onReset: { setAudioDelay(0) },
                        onIncrement: { setAudioDelay(appState.settings.videoDefaultAudioDelay + 0.1) }
                    )
                }

                PlayerSettingRow(title: "字幕延迟", systemImage: "captions.bubble", palette: palette) {
                    PlayerAdjustmentControls(
                        valueText: syncDelayText(appState.settings.videoDefaultSubtitleDelay),
                        palette: palette,
                        onDecrement: { setSubtitleDelay(appState.settings.videoDefaultSubtitleDelay - 0.1) },
                        onReset: { setSubtitleDelay(0) },
                        onIncrement: { setSubtitleDelay(appState.settings.videoDefaultSubtitleDelay + 0.1) }
                    )
                }

                PlayerSettingRow(title: "字幕大小", systemImage: "textformat.size", palette: palette) {
                    PlayerAdjustmentControls(
                        valueText: percentText(appState.settings.videoDefaultSubtitleScale),
                        palette: palette,
                        onDecrement: { setSubtitleScale(appState.settings.videoDefaultSubtitleScale - 0.05) },
                        onReset: { setSubtitleScale(1) },
                        onIncrement: { setSubtitleScale(appState.settings.videoDefaultSubtitleScale + 0.05) }
                    )
                }

                PlayerSettingRow(title: "字幕位置", systemImage: "arrow.up.and.down.text.horizontal", palette: palette) {
                    PlayerAdjustmentControls(
                        valueText: "\(Int(appState.settings.videoDefaultSubtitlePosition.rounded()))%",
                        palette: palette,
                        onDecrement: { setSubtitlePosition(appState.settings.videoDefaultSubtitlePosition - 4) },
                        onReset: { setSubtitlePosition(100) },
                        onIncrement: { setSubtitlePosition(appState.settings.videoDefaultSubtitlePosition + 4) }
                    )
                }
            }
        }
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            PlayerSettingsGroup(title: "画面显示", palette: palette) {
                PlayerSettingRow(title: "画面比例", systemImage: "aspectratio", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoAspectOverride.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoAspectOverride == mode,
                                palette: palette
                            ) {
                                appState.settings.videoAspectOverride = mode
                                appState.saveSettings()
                                controller.setAspectOverride(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "黑边裁切", systemImage: "crop", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoCropMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoCropMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoCropMode = mode
                                appState.saveSettings()
                                controller.setCropMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "去隔行", systemImage: "line.3.horizontal.decrease", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoDeinterlaceMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoDeinterlaceMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoDeinterlaceMode = mode
                                appState.saveSettings()
                                controller.setDeinterlaceMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "画面旋转", systemImage: "rotate.right", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoRotationMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoRotationMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoRotationMode = mode
                                appState.saveSettings()
                                controller.setRotationMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "镜像翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoFlipMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoFlipMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoFlipMode = mode
                                appState.saveSettings()
                                controller.setFlipMode(mode)
                            }
                        }
                    }
                }
            }

            PlayerSettingsGroup(title: "画面调整", palette: palette) {
                colorAdjustmentRow(title: "亮度", systemImage: "sun.max", keyPath: \.brightness)
                colorAdjustmentRow(title: "对比度", systemImage: "circle.lefthalf.filled", keyPath: \.contrast)
                colorAdjustmentRow(title: "饱和度", systemImage: "drop", keyPath: \.saturation)
                colorAdjustmentRow(title: "伽马", systemImage: "wand.and.rays", keyPath: \.gamma)
                colorAdjustmentRow(title: "色相", systemImage: "paintpalette", keyPath: \.hue)

                PlayerSettingRow(title: "锐化", systemImage: "triangle", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoSharpenMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoSharpenMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoSharpenMode = mode
                                appState.saveSettings()
                                controller.setSharpenMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "降噪", systemImage: "waveform.path", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoDenoiseMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoDenoiseMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoDenoiseMode = mode
                                appState.saveSettings()
                                controller.setDenoiseMode(mode)
                            }
                        }
                    }
                }
            }

            PlayerSettingsGroup(title: "播放性能", palette: palette) {
                PlayerSettingToggleRow(
                    title: "弱网内存缓冲",
                    systemImage: "memorychip",
                    isOn: appState.settings.videoMemoryBufferingEnabled,
                    palette: palette
                ) {
                    appState.settings.videoMemoryBufferingEnabled.toggle()
                    appState.saveSettings()
                    controller.setVideoMemoryBufferingEnabled(appState.settings.videoMemoryBufferingEnabled)
                }

                PlayerSettingRow(title: "硬件解码", systemImage: "cpu", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoHardwareDecodingMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoHardwareDecodingMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoHardwareDecodingMode = mode
                                appState.saveSettings()
                                controller.setHardwareDecodingMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "去色带", systemImage: "wand.and.stars", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoDebandMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoDebandMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoDebandMode = mode
                                appState.saveSettings()
                                controller.setDebandMode(mode)
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "HDR 映射", systemImage: "sun.max.trianglebadge.exclamationmark", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoToneMappingMode.allCases) { mode in
                            PlayerChoiceButton(
                                title: mode.displayName,
                                selected: appState.settings.videoToneMappingMode == mode,
                                palette: palette
                            ) {
                                appState.settings.videoToneMappingMode = mode
                                appState.saveSettings()
                                controller.setToneMappingMode(mode)
                            }
                        }
                    }
                }
            }
        }
    }

    private var gestureSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            PlayerSettingsGroup(title: "鼠标操作", palette: palette) {
                PlayerSettingToggleRow(
                    title: "双击全屏",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    isOn: appState.settings.videoDoubleClickFullscreen,
                    palette: palette
                ) {
                    appState.settings.videoDoubleClickFullscreen.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "滚轮音量",
                    systemImage: "scroll",
                    isOn: appState.settings.videoMouseWheelVolumeEnabled,
                    palette: palette
                ) {
                    appState.settings.videoMouseWheelVolumeEnabled.toggle()
                    appState.saveSettings()
                }

                PlayerSettingRow(title: "中键动作", systemImage: "computermouse", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoMiddleClickAction.allCases) { action in
                            PlayerChoiceButton(
                                title: action.displayName,
                                selected: appState.settings.videoMiddleClickAction == action,
                                palette: palette
                            ) {
                                appState.settings.videoMiddleClickAction = action
                                appState.saveSettings()
                            }
                        }
                    }
                }

                PlayerSettingRow(title: "侧键动作", systemImage: "computermouse.fill", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoSideButtonAction.allCases) { action in
                            PlayerChoiceButton(
                                title: action.displayName,
                                selected: appState.settings.videoMouseBackForwardAction == action,
                                palette: palette
                            ) {
                                appState.settings.videoMouseBackForwardAction = action
                                appState.saveSettings()
                            }
                        }
                    }
                }
            }

            PlayerSettingsGroup(title: "触控板手势", palette: palette) {
                PlayerSettingToggleRow(
                    title: "启用手势",
                    systemImage: "hand.draw",
                    isOn: appState.settings.videoTrackpadGesturesEnabled,
                    palette: palette
                ) {
                    appState.settings.videoTrackpadGesturesEnabled.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "横扫跳转",
                    systemImage: "arrow.left.and.right",
                    isOn: appState.settings.videoTrackpadHorizontalSeekEnabled,
                    palette: palette
                ) {
                    appState.settings.videoTrackpadHorizontalSeekEnabled.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "竖扫音量",
                    systemImage: "speaker.wave.2",
                    isOn: appState.settings.videoTrackpadVerticalVolumeEnabled,
                    palette: palette
                ) {
                    appState.settings.videoTrackpadVerticalVolumeEnabled.toggle()
                    appState.saveSettings()
                }

                PlayerSettingToggleRow(
                    title: "捏合全屏",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    isOn: appState.settings.videoTrackpadPinchFullscreenEnabled,
                    palette: palette
                ) {
                    appState.settings.videoTrackpadPinchFullscreenEnabled.toggle()
                    appState.saveSettings()
                }

                PlayerSettingRow(title: "灵敏度", systemImage: "dial.medium", palette: palette) {
                    PlayerChoiceGroup {
                        ForEach(VideoTrackpadGestureSensitivity.allCases) { sensitivity in
                            PlayerChoiceButton(
                                title: sensitivity.displayName,
                                selected: appState.settings.videoTrackpadGestureSensitivity == sensitivity,
                                palette: palette
                            ) {
                                appState.settings.videoTrackpadGestureSensitivity = sensitivity
                                appState.saveSettings()
                            }
                        }
                    }
                }
            }

            Text("在触控板上左右轻扫调进度、上下轻扫调音量；普通鼠标滚轮只用来调音量。捏合进出全屏默认关闭，避免误触。")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutGroups: [(title: String, actions: [VideoPlayerShortcutAction])] {
        ["播放", "跳转", "窗口与控制", "画面", "音画同步", "轨道"].compactMap { title in
            let actions = VideoPlayerShortcutAction.allCases.filter { $0.groupTitle == title }
            return actions.isEmpty ? nil : (title, actions)
        }
    }

    private var currentWidthRatio: Double {
        VideoWindowSizing.screenWidthRatio(for: appState.settings.videoPlayerPreferredWidth, on: NSApp.keyWindow?.screen)
    }

    private func settingsRateTitle(_ rate: Double) -> String {
        if abs(rate - 1.0) < 0.001 { return "1x" }
        if abs(rate.rounded() - rate) < 0.001 { return String(format: "%.0fx", rate) }
        return String(format: "%.2fx", rate)
    }

    private func setAudioDelay(_ value: Double) {
        let clamped = AppSettings.clampedVideoSyncDelay(value)
        appState.settings.videoDefaultAudioDelay = clamped
        appState.saveSettings()
        controller.setAudioDelay(clamped)
    }

    private func setSubtitleDelay(_ value: Double) {
        let clamped = AppSettings.clampedVideoSyncDelay(value)
        appState.settings.videoDefaultSubtitleDelay = clamped
        appState.saveSettings()
        controller.setSubtitleDelay(clamped)
    }

    private func setSubtitleScale(_ value: Double) {
        let clamped = AppSettings.clampedVideoSubtitleScale(value)
        appState.settings.videoDefaultSubtitleScale = clamped
        appState.saveSettings()
        controller.setSubtitleScale(clamped)
    }

    private func setSubtitlePosition(_ value: Double) {
        let clamped = AppSettings.clampedVideoSubtitlePosition(value)
        appState.settings.videoDefaultSubtitlePosition = clamped
        appState.saveSettings()
        controller.setSubtitlePosition(clamped)
    }

    private func syncDelayText(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0.0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func colorAdjustmentRow(
        title: String,
        systemImage: String,
        keyPath: WritableKeyPath<VideoColorAdjustments, Double>
    ) -> some View {
        let current = appState.settings.videoColorAdjustments[keyPath: keyPath]
        return PlayerSettingRow(title: title, systemImage: systemImage, palette: palette) {
            PlayerAdjustmentControls(
                valueText: colorValueText(current),
                palette: palette,
                onDecrement: { setColorComponent(keyPath, to: current - 5) },
                onReset: { setColorComponent(keyPath, to: 0) },
                onIncrement: { setColorComponent(keyPath, to: current + 5) }
            )
        }
    }

    private func setColorComponent(_ keyPath: WritableKeyPath<VideoColorAdjustments, Double>, to value: Double) {
        var adjustments = appState.settings.videoColorAdjustments
        adjustments[keyPath: keyPath] = VideoColorAdjustments.clamp(value)
        appState.settings.videoColorAdjustments = adjustments
        appState.saveSettings()
        controller.setColorAdjustments(adjustments)
    }

    private func colorValueText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 ? "0" : String(format: "%+d", rounded)
    }
}

private struct PlayerAdjustmentControls: View {
    let valueText: String
    let palette: VideoControlPalette
    let onDecrement: () -> Void
    let onReset: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            adjustmentButton(systemImage: "minus", help: "减少", action: onDecrement)

            Text(valueText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 76, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.choiceFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.rowStroke, lineWidth: 0.8)
                }

            adjustmentButton(systemImage: "arrow.counterclockwise", help: "恢复默认", action: onReset)
            adjustmentButton(systemImage: "plus", help: "增加", action: onIncrement)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func adjustmentButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.secondary)
                .frame(width: 28, height: 26)
                .playerCapsuleControl(cornerRadius: 8, palette: palette)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PlayerShortcutSettingRow: View {
    let action: VideoPlayerShortcutAction
    let shortcuts: [VideoKeyboardShortcut]
    let isRecording: Bool
    let palette: VideoControlPalette
    /// 返回与给定组合键冲突的其它动作（不含本行动作），无冲突则为 nil。
    let conflictLookup: (VideoKeyboardShortcut) -> VideoPlayerShortcutAction?
    let onRecord: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    let onCancel: () -> Void
    let onCapture: (VideoKeyboardShortcut) -> Void

    /// 录到一个已被其它动作占用的组合键时，先把它挂起等用户确认，而不是直接覆盖。
    @State private var pendingShortcut: VideoKeyboardShortcut?
    @State private var conflictAction: VideoPlayerShortcutAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(action.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 142, alignment: .leading)

                Text(shortcutText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(shortcuts.isEmpty ? palette.subdued : palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.choiceFill)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(palette.rowStroke, lineWidth: 0.8)
                    }

                HStack(spacing: 5) {
                    shortcutButton(title: isRecording ? "等待" : "记录", systemImage: "keyboard", action: onRecord)
                    shortcutButton(title: "清除", systemImage: "xmark", action: onClear)
                    shortcutButton(title: "默认", systemImage: "arrow.counterclockwise", action: onReset)
                }
            }

            if let pendingShortcut, let conflictAction {
                conflictBanner(shortcut: pendingShortcut, conflictAction: conflictAction)
            } else if isRecording {
                HStack(spacing: 8) {
                    Label("按下新的组合键", systemImage: "keyboard")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.primary)
                    Spacer()
                    Button("取消") {
                        clearPending()
                        onCancel()
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.choiceSelectedFill.opacity(0.72))
                }
                .overlay {
                    VideoShortcutRecorderView(onCapture: handleCapture)
                        .frame(width: 0, height: 0)
                }
            }
        }
        .onChange(of: isRecording) { recording in
            if !recording { clearPending() }
        }
    }

    private func handleCapture(_ shortcut: VideoKeyboardShortcut) {
        if let conflict = conflictLookup(shortcut) {
            pendingShortcut = shortcut
            conflictAction = conflict
        } else {
            clearPending()
            onCapture(shortcut)
        }
    }

    private func conflictBanner(shortcut: VideoKeyboardShortcut, conflictAction: VideoPlayerShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("“\(shortcut.displayName)” 已用于「\(conflictAction.displayName)」", systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("替换后将从「\(conflictAction.displayName)」移除该键")
                    .font(.caption2)
                    .foregroundStyle(palette.subdued)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 6)
                Button("替换") {
                    let target = shortcut
                    clearPending()
                    onCapture(target)
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(palette.primary)

                Button("取消") {
                    clearPending()
                    onCancel()
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.choiceSelectedFill.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(palette.selectedRowStroke, lineWidth: 0.8)
        }
        .overlay {
            // 冲突待确认期间继续监听按键，允许用户直接按另一个键改选。
            VideoShortcutRecorderView(onCapture: handleCapture)
                .frame(width: 0, height: 0)
        }
    }

    private func clearPending() {
        pendingShortcut = nil
        conflictAction = nil
    }

    private var shortcutText: String {
        let text = shortcuts.map(\.displayName).joined(separator: " / ")
        return text.isEmpty ? "未设置" : text
    }

    private func shortcutButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.secondary)
                .frame(width: 26, height: 24)
                .playerCapsuleControl(cornerRadius: 8, palette: palette, liveMaterial: false)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct PlayerSettingsPopover: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    let onOpenAdvancedSettings: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                Label("播放器设置", systemImage: "gearshape")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primary)

                PlayerSettingsGroup(title: "播放", palette: palette) {
                    PlayerSettingRow(title: "倍速", systemImage: "speedometer", palette: palette) {
                        PlayerInlineSpeedControl(controller: controller, palette: palette)
                    }

                    PlayerSettingToggleRow(
                        title: "弱网内存缓冲",
                        systemImage: "memorychip",
                        isOn: appState.settings.videoMemoryBufferingEnabled,
                        palette: palette
                    ) {
                        appState.settings.videoMemoryBufferingEnabled.toggle()
                        appState.saveSettings()
                        controller.setVideoMemoryBufferingEnabled(appState.settings.videoMemoryBufferingEnabled)
                    }
                }

                PlayerSettingsGroup(title: "窗口与时间轴", palette: palette) {
                    PlayerSettingToggleRow(
                        title: "窗口置顶",
                        systemImage: "pin",
                        isOn: appState.settings.videoPlayerAlwaysOnTop,
                        palette: palette
                    ) {
                        appState.settings.videoPlayerAlwaysOnTop.toggle()
                        appState.saveSettings()
                        PlayerWindowActions.setAlwaysOnTop(appState.settings.videoPlayerAlwaysOnTop)
                    }

                    PlayerSettingRow(title: "预览图", systemImage: "photo.on.rectangle.angled", palette: palette) {
                        PlayerChoiceGroup {
                            ForEach(VideoScrubberPreviewMode.allCases) { mode in
                                PlayerChoiceButton(
                                    title: mode.displayName,
                                    selected: appState.settings.videoScrubberPreviewMode == mode,
                                    palette: palette
                                ) {
                                    appState.settings.videoScrubberPreviewMode = mode
                                    appState.saveSettings()
                                }
                            }
                        }
                    }
                }

                PlayerSettingsGroup(title: "完整设置", palette: palette) {
                    Button {
                        onOpenAdvancedSettings()
                    } label: {
                        Label("打开内置播放器设置", systemImage: "slider.horizontal.3")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .playerCapsuleControl(cornerRadius: 10, palette: palette, liveMaterial: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
        }
        .frame(width: 420)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: true, vertical: false)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
        .transaction { $0.animation = nil }
    }
}

/// 百分比滑条行：拖动期间只改本地草稿，松手才提交到设置。
/// 直接绑定 appState.settings 会让每个拖动 tick 触发全 app 视图重算（滑条卡顿根因）。
private struct PlayerPercentSliderRow: View {
    let title: String
    let systemImage: String
    let palette: VideoControlPalette
    let range: ClosedRange<Double>
    let initialValue: Double
    let onCommit: (Double) -> Void

    @State private var draft: Double
    @State private var isEditing = false

    init(
        title: String,
        systemImage: String,
        palette: VideoControlPalette,
        range: ClosedRange<Double>,
        initialValue: Double,
        onCommit: @escaping (Double) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.palette = palette
        self.range = range
        self.initialValue = initialValue
        self.onCommit = onCommit
        _draft = State(initialValue: min(max(initialValue, range.lowerBound), range.upperBound))
    }

    var body: some View {
        PlayerSettingRow(title: title, systemImage: systemImage, palette: palette) {
            HStack(spacing: 9) {
                Slider(
                    value: $draft,
                    in: range,
                    step: 0.01,
                    onEditingChanged: { editing in
                        isEditing = editing
                        if !editing {
                            onCommit(draft)
                        }
                    }
                )
                .tint(palette.trackProgress)

                Text("\(Int((draft * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .onChange(of: initialValue) { value in
            if !isEditing {
                draft = min(max(value, range.lowerBound), range.upperBound)
            }
        }
    }
}

private struct PlayerSettingsGroup<Content: View>: View {
    let title: String
    var palette: VideoControlPalette = .lightContent
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.subdued)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

private struct PlayerSettingRow<Content: View>: View {
    /// 图标占位固定宽度：让每个 SF Symbol 在等宽槽内居中，使所有图标重心落在同一条竖线上。
    static var iconSlotWidth: CGFloat { 20 }
    /// 文字标签固定宽度：保证不同字数标题的首字落在同一条竖线上。
    static var labelWidth: CGFloat { 104 }

    let title: String
    let systemImage: String
    var palette: VideoControlPalette = .lightContent
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .frame(width: Self.iconSlotWidth, alignment: .center)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            content
        }
        .frame(minHeight: 28)
    }
}

private struct PlayerSettingToggleRow: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var palette: VideoControlPalette = .lightContent
    let action: () -> Void

    var body: some View {
        PlayerSettingRow(title: title, systemImage: systemImage, palette: palette) {
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(isOn ? palette.choiceSelectedFill : palette.choiceFill)
                            .overlay {
                                Capsule().stroke(isOn ? palette.selectedRowStroke : palette.rowStroke, lineWidth: 0.8)
                            }
                        Circle()
                            .fill(isOn ? palette.choiceSelectedForeground : palette.controlKnob)
                            .frame(width: 16, height: 16)
                            .padding(3)
                    }
                    .frame(width: 40, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PlayerChoiceGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct PlayerChoiceButton: View {
    let title: String
    let selected: Bool
    var palette: VideoControlPalette = .lightContent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(selected ? palette.choiceSelectedForeground : palette.choiceForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 9)
                .frame(minWidth: 44)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? palette.choiceSelectedFill : palette.choiceFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? palette.selectedRowStroke : palette.rowStroke, lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct PlayerSnapSlider: View {
    private static let knobSize: CGFloat = 24
    @Binding var value: Double
    let range: ClosedRange<Double>
    let snapValues: [Double]
    let palette: VideoControlPalette
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
                    .fill(palette.trackBase)
                    .frame(width: trackWidth, height: 6)
                    .offset(x: knobRadius)
                Capsule()
                    .fill(palette.trackProgress)
                    .frame(width: max(trackWidth * fraction, 0), height: 6)
                    .offset(x: knobRadius)
                ForEach(snapValues, id: \.self) { snap in
                    let snapFraction = CGFloat((snap - range.lowerBound) / (range.upperBound - range.lowerBound))
                    let snapActive = abs(value - snap) < 0.02
                    Circle()
                        .fill(snapActive ? palette.primary : palette.subdued)
                        .frame(width: snapActive ? 4.8 : 3.2, height: snapActive ? 4.8 : 3.2)
                        .position(x: knobRadius + trackWidth * snapFraction, y: 14)
                }
                Circle()
                    .fill(palette.controlKnob)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: palette.shadow, radius: 5, y: 1.5)
                    .overlay {
                        Circle().stroke(palette.border.first ?? palette.primary, lineWidth: 0.8)
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
    let palette: VideoControlPalette
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
                    .fill(palette.trackBase)
                    .overlay {
                        Capsule().stroke(palette.border.last ?? palette.subdued, lineWidth: 0.6)
                    }
                    .frame(width: trackWidth, height: 5.5)
                    .offset(x: knobRadius)

                Capsule()
                    .fill(palette.trackProgress)
                    .frame(width: max(trackWidth * fraction, 0), height: 5.5)
                    .offset(x: knobRadius)

                Circle()
                    .fill(palette.primary)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(color: palette.shadow, radius: 5, y: 1.5)
                    .overlay {
                        Circle().stroke(palette.border.first ?? palette.primary, lineWidth: 0.8)
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
    let palette: VideoControlPalette

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
                        .foregroundStyle(abs(currentRate - tick) < 0.01 ? palette.primary : palette.subdued)
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
    let skipBehavior: VideoMarkerSkipBehavior
    let palette: VideoControlPalette
    @State private var autoSkippedMarkerID: String?
    @StateObject private var timeline: PlayerControllerProjection<PlayerTimelineState>

    init(
        controller: MpvPlayerController,
        markers: [PlaybackMarker],
        skipBehavior: VideoMarkerSkipBehavior,
        palette: VideoControlPalette
    ) {
        self.controller = controller
        self.markers = markers
        self.skipBehavior = skipBehavior
        self.palette = palette
        _timeline = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerTimelineState.init))
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if skipBehavior == .prompt, let marker = activeMarker, let endTime = marker.endTime {
                Button {
                    controller.seek(to: endTime)
                } label: {
                    Label("跳过\(marker.kind.title)", systemImage: "forward.end.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .playerGlass(cornerRadius: 17, palette: palette)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 98)
            }
        }
        .animation(AppMotion.fast, value: activeMarker?.id)
        .onAppear {
            handleAutomaticSkip(for: activeMarker)
        }
        .onChange(of: activeMarker?.id) { _ in
            handleAutomaticSkip(for: activeMarker)
        }
    }

    private var activeMarker: PlaybackMarker? {
        markers.first {
            ($0.kind == .intro || $0.kind == .credits) &&
                $0.isAcceptedForPlayback &&
                $0.contains(timeline.value.currentTime)
        }
    }

    private func handleAutomaticSkip(for marker: PlaybackMarker?) {
        guard skipBehavior == .automatic,
              let marker,
              autoSkippedMarkerID != marker.id,
              let endTime = marker.endTime,
              endTime > timeline.value.currentTime else {
            if marker == nil {
                autoSkippedMarkerID = nil
            }
            return
        }
        autoSkippedMarkerID = marker.id
        controller.seek(to: endTime)
    }
}

private struct PlayerMarkerPopover: View {
    let currentTime: Double
    let duration: Double
    let markers: [PlaybackMarker]
    let palette: VideoControlPalette
    let onSeek: (Double) -> Void
    let onSetBoundary: (PlaybackMarker.Kind, Bool, Double) -> Void
    let onAddChapter: (Double) -> Void
    let onAddBookmark: (Double) -> Void
    let onDeleteMarker: (PlaybackMarker) -> Void
    let onAcceptMarker: (PlaybackMarker) -> Void
    let onRejectMarker: (PlaybackMarker) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Label("章节与播放标记", systemImage: "bookmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primary)

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
                        .playerCapsuleControl(cornerRadius: 9, palette: palette)
                }
                .buttonStyle(.plain)

                Button {
                    onAddBookmark(currentTime)
                } label: {
                    Label("在 \(formatTime(currentTime)) 添加书签", systemImage: "bookmark.circle")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .playerCapsuleControl(cornerRadius: 9, palette: palette)
                }
                .buttonStyle(.plain)

                Divider()
                    .background(palette.divider)

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
                                    selected: marker.contains(currentTime),
                                    palette: palette
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
                            if marker.isPendingReview {
                                Button {
                                    onAcceptMarker(marker)
                                } label: {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)
                                .help("采用自动标记")

                                Button {
                                    onRejectMarker(marker)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(.orange)
                                }
                                .buttonStyle(.plain)
                                .help("忽略自动标记")
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
        .playerPopoverGlass(palette: palette, liveMaterial: false)
        .transaction { $0.animation = nil }
    }

    private func markerAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .playerCapsuleControl(cornerRadius: 9, palette: palette)
        }
        .buttonStyle(.plain)
    }

    private func markerSubtitle(_ marker: PlaybackMarker) -> String {
        let origin: String
        switch marker.origin {
        case .embedded:
            origin = "内嵌章节"
        case .manual:
            origin = "手动标记"
        case .automatic:
            let confidence = marker.confidence.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            origin = marker.reviewStatus == .pending ? "待审核\(confidence)" : "自动标记\(confidence)"
        }
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

/// 播放器内剧集列表：展示当前视频队列（本集 + 之后的同系列剧集），
/// 点击任意一集切换播放；当前集高亮，打开时自动滚到当前集。
private struct PlayerEpisodeListPopover: View {
    @EnvironmentObject private var appState: AppState
    let currentItem: MediaItem
    let palette: VideoControlPalette
    let onSelect: (MediaItem) -> Void

    var body: some View {
        let queue = appState.videoQueue
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("剧集列表", systemImage: "list.triangle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primary)
                Spacer()
                Text("\(queue.count) 集")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.subdued)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(queue) { episode in
                            Button {
                                onSelect(episode)
                            } label: {
                                PlayerTrackRow(
                                    title: episode.title,
                                    subtitle: episodeSubtitle(episode),
                                    selected: episode.id == currentItem.id,
                                    palette: palette
                                )
                            }
                            .buttonStyle(.plain)
                            .id(episode.id)
                        }
                    }
                }
                .frame(maxHeight: 380)
                .transaction { $0.animation = nil }
                .onAppear {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(currentItem.id, anchor: .center)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
    }

    private func episodeSubtitle(_ episode: MediaItem) -> String? {
        var parts: [String] = []
        if let season = episode.seasonNumber, let number = episode.episodeNumber {
            parts.append(String(format: "S%02dE%02d", season, number))
        } else if let number = episode.episodeNumber {
            parts.append("第 \(number) 集")
        }
        if let duration = episode.duration, duration > 0 {
            parts.append("\(Int((duration / 60).rounded())) 分钟")
        }
        if episode.id == currentItem.id {
            parts.append("正在播放")
        } else if episode.watched {
            parts.append("已看")
        } else if episode.playProgress > 0.02 {
            parts.append("看到 \(Int((episode.playProgress * 100).rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct PlayerQualityPopover: View {
    let options: [VideoStreamQualityOption]
    let selectedID: String?
    let palette: VideoControlPalette
    let onSelect: (VideoStreamQualityOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("清晰度", systemImage: "slider.horizontal.2.square")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.primary)

            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    PlayerTrackRow(
                        title: option.label,
                        subtitle: option.detail,
                        selected: option.id == selectedID,
                        palette: palette
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
        .fixedSize(horizontal: true, vertical: true)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
    }
}

private struct PlayerAudioTrackPopover: View {
    let controller: MpvPlayerController
    let palette: VideoControlPalette
    @StateObject private var tracks: PlayerControllerProjection<PlayerAudioTrackListState>

    init(controller: MpvPlayerController, palette: VideoControlPalette) {
        self.controller = controller
        self.palette = palette
        _tracks = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerAudioTrackListState.init))
    }

    var body: some View {
        let state = tracks.value
        let audioTracks = state.audioTracks
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Label("音轨", systemImage: "waveform.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primary)

                Button {
                    controller.selectDefaultAudioTrack()
                } label: {
                    PlayerTrackRow(title: "自动选择", subtitle: "由播放器选择默认音轨", selected: audioTracks.allSatisfy { !$0.isSelected }, palette: palette)
                }
                .buttonStyle(.plain)

                if audioTracks.isEmpty {
                    Text("播放器暂未回传音轨列表。")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(audioTracks) { track in
                        Button {
                            controller.selectAudioTrack(track.id)
                        } label: {
                            PlayerTrackRow(
                                title: track.displayName,
                                subtitle: "ID \(track.id)",
                                selected: track.isSelected,
                                palette: palette
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: true, vertical: false)
        .playerPopoverGlass(palette: palette, liveMaterial: false)
        .transaction { $0.animation = nil }
    }
}

private struct PlayerSubtitlePopover: View {
    @EnvironmentObject private var appState: AppState
    let controller: MpvPlayerController
    let sidecarSubtitles: [SidecarSubtitleFile]
    let item: MediaItem
    let palette: VideoControlPalette
    @StateObject private var tracks: PlayerControllerProjection<PlayerSubtitleTrackListState>

    @State private var onlineResults: [OnlineSubtitleResult] = []
    @State private var isSearchingOnline = false
    @State private var onlineSearchError: String?
    @State private var downloadingID: String?
    @State private var downloadedIDs: Set<String> = []
    @State private var didAutoSearch = false

    init(
        controller: MpvPlayerController,
        sidecarSubtitles: [SidecarSubtitleFile],
        item: MediaItem,
        palette: VideoControlPalette
    ) {
        self.controller = controller
        self.sidecarSubtitles = sidecarSubtitles
        self.item = item
        self.palette = palette
        _tracks = StateObject(wrappedValue: PlayerControllerProjection(controller: controller, map: PlayerSubtitleTrackListState.init))
    }

    var body: some View {
        let trackState = tracks.value
        let embeddedSubtitleTracks = trackState.subtitleTracks.filter { !$0.isExternal }
        let externalSubtitleTracks = trackState.subtitleTracks.filter(\.isExternal)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Header
                Label("字幕", systemImage: "captions.bubble")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.primary)

                // Off + auto-load
                Button {
                    controller.disableSubtitle()
                } label: {
                    PlayerTrackRow(
                        title: "关闭字幕",
                        subtitle: nil,
                        selected: trackState.subtitleTracks.allSatisfy { !trackState.isPrimarySelected($0) },
                        palette: palette
                    )
                }
                .buttonStyle(.plain)

                Button {
                    controller.enableAutoSubtitle()
                } label: {
                    PlayerTrackRow(
                        title: "自动加载目录字幕",
                        subtitle: "扫描同目录字幕文件",
                        selected: trackState.subtitleAutoLoadEnabled,
                        palette: palette
                    )
                }
                .buttonStyle(.plain)

                Button {
                    presentSubtitleOpenPanel()
                } label: {
                    PlayerTrackRow(
                        title: "从文件加载…",
                        subtitle: "选择任意位置的字幕文件（srt / ass / vtt 等）",
                        selected: false,
                        palette: palette
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
                                selected: trackState.isPrimarySelected(track),
                                palette: palette
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Sidecar (local) tracks
                if !sidecarSubtitles.isEmpty || !externalSubtitleTracks.isEmpty {
                    playerPopoverSectionHeader("同目录字幕")
                    ForEach(sidecarSubtitles) { subtitle in
                        let matchedTrack = externalSubtitleTrack(for: subtitle.path, tracks: trackState.subtitleTracks)
                        Button {
                            controller.selectOrAddExternalSubtitle(path: subtitle.path)
                        } label: {
                            PlayerTrackRow(
                                title: subtitle.displayName,
                                subtitle: subtitle.languageHint,
                                selected: matchedTrack.map(trackState.isPrimarySelected) == true,
                                palette: palette
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
                            PlayerTrackRow(title: track.displayName, subtitle: "外挂字幕", selected: trackState.isPrimarySelected(track), palette: palette)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Secondary subtitle (双语对照，mpv secondary-sid，显示在画面顶部)
                if trackState.subtitleTracks.count > 1 {
                    playerPopoverSectionHeader("第二字幕（双语对照）")
                    Button {
                        controller.selectSecondarySubtitleTrack(nil)
                    } label: {
                        PlayerTrackRow(
                            title: "关闭第二字幕",
                            subtitle: nil,
                            selected: trackState.secondarySubtitleID == nil,
                            palette: palette
                        )
                    }
                    .buttonStyle(.plain)
                    ForEach(trackState.subtitleTracks.filter { !trackState.isPrimarySelected($0) }) { track in
                        Button {
                            controller.selectSecondarySubtitleTrack(track.id)
                        } label: {
                            PlayerTrackRow(
                                title: track.displayName,
                                subtitle: "显示在画面顶部",
                                selected: track.id == trackState.secondarySubtitleID,
                                palette: palette
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Online subtitle search section
                Divider()
                    .background(palette.divider)

                HStack(spacing: 6) {
                    Text("在线字幕")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                    Text("· Podnapisi" + (appState.settings.openSubtitlesAPIKey?.isEmpty == false ? " · OpenSubtitles" : ""))
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
                    Spacer()
                    if isSearchingOnline {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(palette.secondary)
                    } else {
                        Button {
                            Task { await searchOnlineSubtitles() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重新搜索")
                    }
                }

                if let error = onlineSearchError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
                        .padding(.top, 2)
                } else if onlineResults.isEmpty && !isSearchingOnline {
                    Text("暂无在线字幕结果")
                        .font(.caption2)
                        .foregroundStyle(palette.subdued)
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
        .playerPopoverGlass(palette: palette, liveMaterial: false)
        .transaction { $0.animation = nil }
        .onAppear {
            guard !didAutoSearch else { return }
            didAutoSearch = true
            Task { await searchOnlineSubtitles() }
        }
    }

    /// 手动加载任意位置的字幕文件（mpv `sub-add` 并立即选中）。
    private func presentSubtitleOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要加载的字幕文件"
        panel.allowedContentTypes = ["srt", "ass", "ssa", "sub", "vtt", "sup", "idx", "smi"]
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            controller.addExternalSubtitle(path: url.path)
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
                        ProgressView().scaleEffect(0.65).tint(palette.secondary)
                    } else if isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.primary)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(palette.subdued)
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
                        .foregroundStyle(palette.subdued)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .background(
                isDownloaded
                    ? palette.selectedRowFill
                    : palette.rowFill,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if isDownloaded {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(palette.selectedRowStroke, lineWidth: 0.7)
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
            .background(palette.divider)
            .padding(.vertical, 2)
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.secondary)
    }

    private func externalSubtitleTrack(for path: String?, tracks: [MpvTrack]) -> MpvTrack? {
        guard let path else { return nil }
        let targetURL = URL(fileURLWithPath: path)
        return tracks.first { track in
            guard track.isExternal else { return false }
            if track.externalFilename == path { return true }
            if let externalFilename = track.externalFilename {
                return URL(fileURLWithPath: externalFilename).lastPathComponent == targetURL.lastPathComponent
            }
            return false
        }
    }
}

private struct PlayerTrackRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    var palette: VideoControlPalette = .lightContent

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? palette.primary : palette.subdued)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(selected ? palette.selectedRowFill : palette.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? palette.selectedRowStroke : palette.rowStroke, lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PlayerVolumeHUD: View {
    let volume: Float
    let palette: VideoControlPalette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.primary)
            GeometryReader { proxy in
                let width = proxy.size.width * CGFloat(volume)
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.trackBase)
                    Capsule().fill(palette.trackProgress).frame(width: width)
                }
            }
            .frame(width: 128, height: 6)
            Text("\(Int((volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .playerGlass(cornerRadius: 18, palette: palette)
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
    let previewMode: VideoScrubberPreviewMode
    let coarsePreviewBuckets: Bool
    @Binding var preview: VideoScrubberPreview?
    let previewImage: NSImage?
    let previewIsLoading: Bool
    let markers: [PlaybackMarker]
    let palette: VideoControlPalette
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
                    .fill(palette.trackBase)
                    .frame(height: 6)
                Capsule()
                    .fill(enabled ? palette.trackProgress : palette.subdued)
                    .frame(width: progressWidth, height: 6)
                ForEach(markers.filter { ($0.kind == .intro || $0.kind == .credits) && $0.isCompleteRange && $0.isAcceptedForPlayback }) { marker in
                    let startFraction = duration > 0 ? min(max(marker.startTime / duration, 0), 1) : 0
                    let endFraction = duration > 0 ? min(max((marker.endTime ?? marker.startTime) / duration, 0), 1) : 0
                    Capsule()
                        .fill(marker.kind == .intro ? Color.cyan.opacity(0.62) : Color.orange.opacity(0.62))
                        .frame(width: max(width * CGFloat(endFraction - startFraction), 2), height: 6)
                        .offset(x: width * CGFloat(startFraction))
                }
                ForEach(markers.filter(\.isAcceptedForPlayback)) { marker in
                    let markerFraction = duration > 0 ? min(max(marker.startTime / duration, 0), 1) : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.primary.opacity(marker.kind == .chapter ? 0.82 : 0.96))
                        .frame(width: 2, height: marker.kind == .chapter ? 9 : 11)
                        .offset(x: min(max(width * CGFloat(markerFraction) - 1, 0), max(width - 2, 0)))
                }
                Circle()
                    .fill(palette.primary)
                    .frame(width: isDragging ? 13 : 10, height: isDragging ? 13 : 10)
                    .shadow(color: palette.shadow, radius: 3, y: 1)
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
                        isLoading: previewIsLoading,
                        showsFrame: previewMode.isEnabled,
                        palette: palette
                    )
                    .offset(
                        x: min(max(preview.x - 82, 0), max(width - 164, 0)),
                        y: previewMode.isEnabled ? -106 : -44
                    )
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
                            forcePreview: false,
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
                        forcePreview: false,
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
        forcePreview: Bool,
        updateDraftTime: Bool
    ) {
        let target = Double(location.x / max(width, 1)) * duration
        if updateDraftTime {
            draftTime = target
        }
        guard previewMode.isEnabled else {
            let now = Date()
            guard PointerHoverThrottle.shouldUpdate(
                from: lastPreviewLocation,
                previousUpdate: lastPreviewUpdate,
                to: location,
                now: now,
                minInterval: previewMode.hoverMinimumInterval,
                minDistance: CGFloat(previewMode.hoverMinimumDistance)
            ) else { return }
            lastPreviewUpdate = now
            lastPreviewLocation = location
            preview = VideoScrubberPreview(time: target, x: location.x)
            return
        }
        let bucket = VideoFramePreviewGenerator.bucket(for: target, duration: duration, preferCoarse: coarsePreviewBuckets)
        if !forcePreview {
            let now = Date()
            guard bucket != lastPreviewBucket ||
                    PointerHoverThrottle.shouldUpdate(
                        from: lastPreviewLocation,
                        previousUpdate: lastPreviewUpdate,
                        to: location,
                        now: now,
                        minInterval: previewMode.hoverMinimumInterval,
                        minDistance: CGFloat(previewMode.hoverMinimumDistance)
                    ) else { return }
            lastPreviewUpdate = now
        } else {
            lastPreviewUpdate = Date()
        }
        lastPreviewLocation = location
        lastPreviewBucket = bucket
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
    let showsFrame: Bool
    let palette: VideoControlPalette

    var body: some View {
        VStack(spacing: 5) {
            if showsFrame {
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
                                .foregroundStyle(palette.secondary)
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
                                    Color.white.opacity(0.12)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
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
            }

            Text(PlayerProgressPreviewBubble.format(time))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(palette.primary)
        }
        .padding(showsFrame ? 7 : 9)
        .playerGlass(cornerRadius: showsFrame ? 13 : 11, palette: palette)
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

private struct SendableVideoPreviewImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

private extension View {
    /// `liveMaterial: false` 用于设置类大弹层：实时 material 叠在逐帧重绘的
    /// 视频 OpenGL 画面上会让 WindowServer 每帧重算模糊（设置页卡顿/掉帧根因），
    /// 改为不透明底色 + 同样的渐变面，观感接近但合成成本固定。
    @ViewBuilder
    func playerPopoverGlass(palette: VideoControlPalette = .lightContent, liveMaterial: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = self
            .foregroundStyle(palette.primary)
            .tint(palette.primary)
            .environment(\.colorScheme, palette.systemColorScheme)
        let filled = Group {
            if liveMaterial {
                base
                    .background(.thinMaterial, in: shape)
                    .background(
                        shape.fill(
                            LinearGradient(
                                colors: palette.popoverFill,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            } else {
                base
                    .background(
                        shape.fill(
                            LinearGradient(
                                colors: palette.popoverFill,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
                    .background(shape.fill(palette.popoverOpaqueBase))
            }
        }
        filled
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity(0.34), lineWidth: 0.9)
                    .blur(radius: 0.5)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: palette.border,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: palette.shadow, radius: 9, y: 4)
            .shadow(color: .white.opacity(0.07), radius: 1, y: -0.5)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private extension View {
    func playerGlass(cornerRadius: CGFloat, palette: VideoControlPalette = .lightContent) -> some View {
        modifier(PlayerGlassModifier(cornerRadius: cornerRadius, palette: palette))
    }

    func playerControlIcon(width: CGFloat = 28, height: CGFloat = 28, palette: VideoControlPalette = .lightContent) -> some View {
        self
            .font(.system(size: 13, weight: .semibold))
            .frame(width: width, height: height)
            .background {
                ZStack {
                    Circle().fill(.thinMaterial)
                    Circle().fill(
                        LinearGradient(
                            colors: palette.materialFill,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: palette.border,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: palette.shadow, radius: 2, y: 1)
    }

    /// `liveMaterial: false`：去掉每个按钮自带的实时 material 与模糊阴影。
    /// 快捷键设置页每行 3 个这种按钮、共约百个，逐个实时模糊是滑动掉帧的主因。
    func playerCapsuleControl(cornerRadius: CGFloat, palette: VideoControlPalette = .lightContent, liveMaterial: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    if liveMaterial {
                        shape.fill(.thinMaterial)
                    }
                    shape.fill(
                        LinearGradient(
                            colors: palette.materialFill,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: palette.border,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .shadow(color: liveMaterial ? palette.shadow : .clear, radius: liveMaterial ? 3 : 0, y: liveMaterial ? 1 : 0)
    }
}

struct MpvPlayerView: NSViewRepresentable {
    let controller: MpvPlayerController

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

    /// 把当前已渲染的一帧读成 PNG（窗口所见，含字幕）。
    /// libmpv 渲染 API 下截图命令不可用时由控制器走此兜底。
    func captureFramePNGData() -> Data? {
        guard let context = openGLContext else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        context.makeCurrentContext()
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        glReadBuffer(GLenum(GL_FRONT))
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glReadPixels(0, 0, GLsizei(pixelWidth), GLsizei(pixelHeight), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelWidth * 4,
            bitsPerPixel: 32
        ), let buffer = rep.bitmapData else { return nil }
        // OpenGL 原点在左下角，逐行翻转写入位图。
        let rowBytes = pixelWidth * 4
        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<pixelHeight {
                memcpy(buffer + row * rowBytes, base + (pixelHeight - 1 - row) * rowBytes, rowBytes)
            }
        }
        return rep.representation(using: .png, properties: [:])
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

/// 音频输出设备（mpv `audio-device-list` 条目）。
struct MpvAudioDevice: Identifiable, Hashable {
    let name: String
    let deviceDescription: String

    var id: String { name }

    var displayName: String {
        deviceDescription.isEmpty ? name : deviceDescription
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
        let memoryAsset: MemoryAudioAsset?
    }

    private struct PreparedMusicPlayerItem {
        let playerItem: AVPlayerItem
        let memoryAsset: MemoryAudioAsset?
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
    @Published var audioDelay: Double = 0
    @Published var subtitleDelay: Double = 0
    @Published var subtitleScale: Double = 1
    @Published var subtitlePosition: Double = 100
    @Published var aspectOverride: VideoAspectOverride = .source
    @Published var cropMode: VideoCropMode = .none
    @Published var deinterlaceMode: VideoDeinterlaceMode = .off
    @Published var rotationMode: VideoRotationMode = .source
    @Published var hardwareDecodingMode: VideoHardwareDecodingMode = .safe
    @Published var debandMode: VideoDebandMode = .off
    @Published var flipMode: VideoFlipMode = .none
    @Published var sharpenMode: VideoSharpenMode = .off
    @Published var denoiseMode: VideoDenoiseMode = .off
    @Published var toneMappingMode: VideoToneMappingMode = .auto
    @Published var videoEqualizerEnabled = false
    @Published var videoEqualizerPreset: MusicEqualizerPreset = .flat
    /// 第二字幕轨道（mpv `secondary-sid`），nil 表示关闭。
    @Published var secondarySubtitleID: Int?
    /// 可用音频输出设备（mpv `audio-device-list`）。
    @Published var audioDevices: [MpvAudioDevice] = []
    /// 当前音频输出设备名（mpv `audio-device`），"auto" 为系统默认。
    @Published var selectedAudioDeviceName: String = "auto"
    @Published var loopCurrentItem = false
    @Published var abLoopStart: Double?
    @Published var abLoopEnd: Double?
    @Published var colorAdjustments: VideoColorAdjustments = .neutral
    @Published var pitchCorrectionEnabled = true
    /// 字幕样式（字体/粗体/颜色/描边/背景），仅 libmpv 视频路径生效。
    @Published var subtitleStyle: VideoSubtitleStyle = .standard
    /// 视频音量增强倍率 1.0…2.0，仅 libmpv 视频路径生效（AVPlayer 音乐路径上限 1.0）。
    @Published var volumeBoost: Double = 1.0
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

#if DEBUG
    @MainActor
    func injectMusicVisualDebugState(
        currentTime: Double,
        duration: Double,
        isPlaying: Bool
    ) {
        errorMessage = nil
        statusMessage = nil
        isPreparing = false
        isReady = true
        hasVideoFrame = false
        self.isPlaying = isPlaying
        self.duration = max(duration, 1)
        let clampedTime = min(max(currentTime, 0), self.duration)
        self.currentTime = clampedTime
        lyricTime = clampedTime
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands.enumerated().map { index, _ in
            let phase = Double(index) * 0.62 + clampedTime * 0.42
            return CGFloat(0.24 + 0.58 * (0.5 + 0.5 * sin(phase)))
        }
    }
#endif

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
    /// 视频 EOF（keep-open 停在最后一帧）只通知一次；用户回拖后复位。
    private var didNotifyPlaybackEnd = false
    /// 音乐到达结尾、已通知一次「播放完成」（驱动自动下一曲）；切歌/重播时复位。
    private var didReachAudioEnd = false
    /// 是否按系列/影片记忆倍速（configure 时从设置读取）。
    private var rememberPlaybackRateEnabled = false
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
    /// 清晰度档位写入的基础 vf（缩放），与翻转/锐化/降噪一起经 rebuildVideoFilterChain 合成。
    private var baseVideoFilter: String?
    private var videoMemoryBufferingEnabled = true
    private var initialRedrawTask: Task<Void, Never>?
    private var audioSpectrumTask: Task<Void, Never>?
    private var audioTransitionTask: Task<Void, Never>?
    private var musicMemoryLoadTask: Task<Void, Never>?
    private var musicPreloadTask: Task<Void, Never>?
    private var preloadedMusicItem: PreloadedMusicItem?
    private var currentMemoryAudioAsset: MemoryAudioAsset?
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
        didNotifyPlaybackEnd = false
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
        rememberPlaybackRateEnabled = settings.videoRememberPlaybackRate && item.type != .music
        if rememberPlaybackRateEnabled, let rememberedRate = TrackPreferenceStore.playbackRate(for: item) {
            playbackRate = Float(min(max(rememberedRate, 0.5), 3.0))
        } else {
            playbackRate = Float(settings.defaultPlaybackRate)
        }
        applyVideoAdjustmentDefaults(settings)
        keepLocalAudioWithAirPlay = false
        if item.type != .music, settings.videoUseLaunchVolume {
            volume = Float(AppSettings.clampedVideoLaunchVolume(settings.videoLaunchVolume))
        } else {
            volume = Float(settings.rememberedVolume(for: item.type))
        }
        volumeBeforeMute = max(volume, 0.4)
        volumeBoost = item.type == .music ? 1.0 : AppSettings.clampedVideoVolumeBoost(settings.videoVolumeBoost)
        configureMusicOutput(for: item, settings: settings, isTrackTransition: false)
        videoAspectRatio = nil
        audioTracks = []
        subtitleTracks = []
        chapters = []
        subtitleAutoLoadEnabled = false
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands
        playbackTimelineOffset = 0
        activeVideoQualityOption = nil
        baseVideoFilter = nil
        currentMemoryAudioAsset = nil
        updateBuffering(active: false, progress: nil)
        lastTrackRefreshDate = .distantPast

        guard let filePath = item.filePath,
              item.isRemoteResource || FileManager.default.fileExists(atPath: filePath) else {
            fail("媒体文件不存在，可能是 NAS 未挂载、移动硬盘断开，或文件已被移动。")
            return
        }
        self.filePath = filePath
        duration = item.duration ?? 0
        if item.type == .music {
            currentTime = 0
        } else if settings.rememberPlaybackPosition {
            let savedPosition = max(item.playPosition, 0)
            let rewind = AppSettings.clampedVideoResumeRewind(settings.videoResumeRewindSeconds)
            currentTime = savedPosition > 10 ? max(savedPosition - rewind, 0) : savedPosition
        } else {
            currentTime = 0
        }
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
        let nextURL = URL(fileURLWithPath: nextPath)
        musicPreloadTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let prepared = try await self.prepareMusicPlayerItem(url: nextURL, preloaded: true)
                prepared.playerItem.preferredForwardBufferDuration = self.preferredMusicPreloadBufferDuration(for: nextItem)
                guard !Task.isCancelled,
                      self.playbackGeneration == generation,
                      self.audioPlayer === player,
                      self.item?.id != nextItem.id else { return }
                let playerItem = prepared.playerItem
                guard player.canInsert(playerItem, after: player.items().last) else { return }
                player.insert(playerItem, after: player.items().last)
                self.preloadedMusicItem = PreloadedMusicItem(
                    itemID: nextItem.id,
                    filePath: nextPath,
                    playerItem: playerItem,
                    memoryAsset: prepared.memoryAsset
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
                volume: volume * Float(volumeBoost),
                speed: playbackRate,
                hardwareDecodingMode: hardwareDecodingMode,
                networkMemoryBufferingEnabled: videoMemoryBufferingEnabled
            ) { [weak renderView] in
                renderView?.needsDisplay = true
            }
            try client.loadFile(filePath)
            applyVideoAdjustments(to: client)
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
        if url.isFileURL {
            statusMessage = "正在将歌曲载入内存。"
            musicMemoryLoadTask?.cancel()
            musicMemoryLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let prepared = try await self.prepareMusicPlayerItem(url: url)
                    guard !Task.isCancelled,
                          self.playbackGeneration == generation,
                          self.audioPlayer == nil,
                          self.libMpvClient == nil else { return }
                    self.musicMemoryLoadTask = nil
                    self.installInitialNativeAudioPlayer(
                        playerItem: prepared.playerItem,
                        generation: generation,
                        memoryAsset: prepared.memoryAsset
                    )
                } catch {
                    guard self.playbackGeneration == generation else { return }
                    self.fail("音频内存缓存失败：\(error.localizedDescription)")
                }
            }
            return
        }

        let playerItem = makeAudioPlayerItem(url: url)
        installInitialNativeAudioPlayer(playerItem: playerItem, generation: generation, memoryAsset: nil)
    }

    private func installInitialNativeAudioPlayer(
        playerItem: AVPlayerItem,
        generation: Int,
        memoryAsset: MemoryAudioAsset?
    ) {
        currentMemoryAudioAsset = memoryAsset
        let player = AVQueuePlayer(items: [playerItem])
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        player.volume = effectiveMusicVolume

        observeAudioEnd(for: playerItem, generation: generation)
        observeAudioExternalPlayback(for: player)

        didReachAudioEnd = false
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

    private func switchNativeAudio(
        to nextItem: MediaItem,
        settings: AppSettings,
        preparedOverride: PreparedMusicPlayerItem? = nil
    ) {
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

        if preparedOverride == nil,
           queuedPreload == nil,
           !nextItem.isRemoteResource,
           url.isFileURL {
            let loadGeneration = playbackGeneration
            musicMemoryLoadTask?.cancel()
            player.pause()
            audioLocalMirrorPlayer?.pause()
            audioRouteProxyPlayer?.pause()
            isPlaying = false
            isPreparing = true
            statusMessage = "正在将歌曲载入内存。"
            updateSystemNowPlaying()
            musicMemoryLoadTask = Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                do {
                    let prepared = try await self.prepareMusicPlayerItem(url: url)
                    guard !Task.isCancelled,
                          self.playbackGeneration == loadGeneration,
                          self.audioPlayer === player else { return }
                    self.musicMemoryLoadTask = nil
                    self.switchNativeAudio(to: nextItem, settings: settings, preparedOverride: prepared)
                } catch {
                    guard self.playbackGeneration == loadGeneration else { return }
                    self.fail("音频内存缓存失败：\(error.localizedDescription)")
                }
            }
            return
        }

        reportPlayback(.stopped, force: true)
        didReachAudioEnd = false
        playbackGeneration += 1
        let generation = playbackGeneration
        removeAudioEndObserver()
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        musicMemoryLoadTask?.cancel()
        musicMemoryLoadTask = nil
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

        let playerItem = queuedPreload?.playerItem ?? preparedOverride?.playerItem ?? makeAudioPlayerItem(url: url)
        currentMemoryAudioAsset = queuedPreload?.memoryAsset ?? preparedOverride?.memoryAsset
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

    private nonisolated static func loadMusicFileData(fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL)
        }.value
    }

    private func prepareMusicPlayerItem(
        url: URL,
        preloaded: Bool = false,
        applyEqualizer: Bool = true
    ) async throws -> PreparedMusicPlayerItem {
        guard url.isFileURL else {
            return PreparedMusicPlayerItem(
                playerItem: makeAudioPlayerItem(url: url, applyEqualizer: applyEqualizer),
                memoryAsset: nil
            )
        }

        let data = try await Self.loadMusicFileData(fileURL: url)
        try Task.checkCancellation()
        let memoryAsset = MemoryAudioAsset(fileURL: url, data: data)
        let playable = try await memoryAsset.asset.load(.isPlayable)
        guard playable else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try await memoryAsset.asset.load(.duration)
        let playerItem = makeAudioPlayerItem(
            asset: memoryAsset.asset,
            isLocal: true,
            preloaded: preloaded,
            applyEqualizer: applyEqualizer
        )
        return PreparedMusicPlayerItem(playerItem: playerItem, memoryAsset: memoryAsset)
    }

    private func makeAudioAsset(url: URL, preferPreciseTiming: Bool) -> AVURLAsset {
        guard preferPreciseTiming, url.isFileURL else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
    }

    private func makeAudioPlayerItem(
        url: URL,
        applyEqualizer: Bool = true,
        preferPreciseTiming: Bool? = nil
    ) -> AVPlayerItem {
        let usePreciseTiming = preferPreciseTiming ?? (item?.type == .music)
        return makeAudioPlayerItem(
            asset: makeAudioAsset(url: url, preferPreciseTiming: usePreciseTiming),
            isLocal: url.isFileURL,
            applyEqualizer: applyEqualizer
        )
    }

    private func makeAudioPlayerItem(asset: AVAsset, isLocal: Bool, preloaded: Bool = false, applyEqualizer: Bool = true) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: asset)
        if isLocal {
            playerItem.preferredForwardBufferDuration = preloaded ? 120 : 0
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

    private func preferredMusicPreloadBufferDuration(for item: MediaItem) -> TimeInterval {
        guard let duration = item.duration, duration.isFinite, duration > 0 else {
            return 120
        }
        return min(max(duration, 60), 240)
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
        libMpvClient.setDouble("volume", Double(localVolume * 100) * volumeBoost)
    }

    /// 设置视频音量增强倍率（1.0…2.0），立即作用到当前 libmpv 输出。
    func setVolumeBoost(_ boost: Double) {
        volumeBoost = AppSettings.clampedVideoVolumeBoost(boost)
        applyVideoLocalVolumeForRouteState()
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

    private func syncAudioRouteProxyPlayback(probing: Bool = false, timelineTime: Double? = nil) {
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
        let syncTime = timelineTime ?? currentTime
        proxy.seek(
            to: CMTime(seconds: max(syncTime, 0), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
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
                self.notifyAudioPlaybackFinishedOnce()
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

    private func syncAudioLocalMirrorPlayback(timelineTime: Double? = nil) {
        guard let mirror = audioLocalMirrorPlayer else { return }
        mirror.volume = effectiveMusicVolume
        let syncTime = timelineTime ?? currentTime
        mirror.seek(
            to: CMTime(seconds: max(syncTime, 0), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
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
        let target = item?.type == .music
            ? clampedTimelineTime(seconds)
            : min(max(seconds, 0), max(duration, 0))
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
            audioPlayer.currentItem?.cancelPendingSeeks()
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
                    guard self.isSeekClockSettled(actualTime, target: target) else {
                        self.reissuePendingSeekIfNeeded(
                            observedTime: actualTime,
                            generation: generation,
                            audioPlayer: audioPlayer
                        )
                        self.scheduleSeekSyncCorrection(for: generation)
                        return
                    }
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
            syncAudioLocalMirrorPlayback(timelineTime: target)
            syncAudioRouteProxyPlayback(timelineTime: target)
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
        min(max(seconds, 0), max(seekableDuration, 0))
    }

    private var seekableDuration: Double {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return nativeAudioItemDuration ?? 0
    }

    private var nativeAudioItemDuration: Double? {
        guard let itemDuration = audioPlayer?.currentItem?.duration.seconds,
              itemDuration.isFinite,
              itemDuration > 0 else { return nil }
        return itemDuration
    }

    @discardableResult
    private func refreshNativeAudioDuration() -> Double {
        var resolvedDuration = duration.isFinite && duration > 0 ? duration : 0
        if resolvedDuration <= 0, let itemDuration = nativeAudioItemDuration {
            resolvedDuration = itemDuration
        }
        if resolvedDuration > 0, abs(duration - resolvedDuration) > 0.05 {
            duration = resolvedDuration
        }
        return resolvedDuration
    }

    private func nextSeekRevision() -> Int {
        (seekState?.revision ?? 0) &+ 1
    }

    /// 音乐播放到结尾的唯一出口：保证一首歌只触发一次自动下一曲。
    /// 只由 `AVPlayerItemDidPlayToEndTime` 这类真实播放结束事件驱动，不再让进度条
    /// duration 阈值猜测结尾，避免 VBR/错误元数据把歌曲提前切到下一首。
    private func notifyAudioPlaybackFinishedOnce() {
        guard !didReachAudioEnd else { return }
        didReachAudioEnd = true
        onPlaybackFinished?()
    }

    func restartFromBeginning() {
        currentTime = 0
        lyricTime = 0
        didReachAudioEnd = false
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

    func setPlaybackRate(_ rate: Float, updateExternalState: Bool = true, persistPreference: Bool = true) {
        playbackRate = min(max(rate, 0.5), 3.0)
        if persistPreference, rememberPlaybackRateEnabled, let item, item.type != .music {
            TrackPreferenceStore.setPlaybackRate(Double(playbackRate), for: item)
        }
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

    private func applyVideoAdjustmentDefaults(_ settings: AppSettings) {
        audioDelay = AppSettings.clampedVideoSyncDelay(settings.videoDefaultAudioDelay)
        subtitleDelay = AppSettings.clampedVideoSyncDelay(settings.videoDefaultSubtitleDelay)
        subtitleScale = AppSettings.clampedVideoSubtitleScale(settings.videoDefaultSubtitleScale)
        subtitlePosition = AppSettings.clampedVideoSubtitlePosition(settings.videoDefaultSubtitlePosition)
        aspectOverride = settings.videoAspectOverride
        cropMode = settings.videoCropMode
        deinterlaceMode = settings.videoDeinterlaceMode
        rotationMode = settings.videoRotationMode
        hardwareDecodingMode = settings.videoHardwareDecodingMode
        debandMode = settings.videoDebandMode
        flipMode = settings.videoFlipMode
        sharpenMode = settings.videoSharpenMode
        denoiseMode = settings.videoDenoiseMode
        toneMappingMode = settings.videoToneMappingMode
        videoMemoryBufferingEnabled = settings.videoMemoryBufferingEnabled
        videoEqualizerEnabled = settings.videoEqualizerEnabled
        videoEqualizerPreset = settings.videoEqualizerPreset
        secondarySubtitleID = nil
        loopCurrentItem = settings.videoLoopCurrentItem
        colorAdjustments = settings.videoColorAdjustments
        pitchCorrectionEnabled = settings.videoPitchCorrectionEnabled
        subtitleStyle = settings.videoSubtitleStyle
        abLoopStart = nil
        abLoopEnd = nil
    }

    private func applyVideoAdjustments(to client: LibMpvClient) {
        client.setDouble("audio-delay", audioDelay)
        client.setDouble("sub-delay", subtitleDelay)
        client.setDouble("sub-scale", subtitleScale)
        client.setDouble("sub-pos", subtitlePosition)
        client.setString("video-aspect-override", aspectOverride.mpvValue)
        client.setDouble("panscan", cropMode.panscanValue)
        client.setString("deinterlace", deinterlaceMode.mpvValue)
        client.setString("video-rotate", rotationMode.mpvValue)
        client.setString("hwdec", hardwareDecodingMode.mpvValue)
        applyDebandMode(to: client)
        applyColorAdjustments(to: client)
        applySubtitleStyle(to: client)
        rebuildVideoFilterChain(to: client)
        rebuildAudioFilterChain(to: client)
        client.setString("tone-mapping", toneMappingMode.rawValue)
        client.setFlag("audio-pitch-correction", pitchCorrectionEnabled)
        client.setString("loop-file", loopCurrentItem ? "inf" : "no")
        client.setNetworkMemoryBufferingEnabled(videoMemoryBufferingEnabled)
        applyABLoop(to: client)
    }

    /// 统一合成 vf 链：清晰度档位的缩放滤镜在最前，之后依次是翻转、锐化、降噪。
    /// vf 是单一字符串属性，任何一处直接 set 都会覆盖其它滤镜，必须统一从这里重建。
    private func rebuildVideoFilterChain(to client: LibMpvClient) {
        var filters: [String] = []
        if let qualityFilter = baseVideoFilter, !qualityFilter.isEmpty {
            filters.append(qualityFilter)
        }
        filters.append(contentsOf: flipMode.mpvFilters)
        if let sharpen = sharpenMode.mpvFilter {
            filters.append(sharpen)
        }
        if let denoise = denoiseMode.mpvFilter {
            filters.append(denoise)
        }
        client.setString("vf", filters.joined(separator: ","))
    }

    func setFlipMode(_ mode: VideoFlipMode) {
        flipMode = mode
        if let client = libMpvClient {
            rebuildVideoFilterChain(to: client)
        }
    }

    func setSharpenMode(_ mode: VideoSharpenMode) {
        sharpenMode = mode
        if let client = libMpvClient {
            rebuildVideoFilterChain(to: client)
        }
    }

    func setDenoiseMode(_ mode: VideoDenoiseMode) {
        denoiseMode = mode
        if let client = libMpvClient {
            rebuildVideoFilterChain(to: client)
        }
    }

    func setToneMappingMode(_ mode: VideoToneMappingMode) {
        toneMappingMode = mode
        libMpvClient?.setString("tone-mapping", mode.rawValue)
    }

    func setVideoMemoryBufferingEnabled(_ enabled: Bool) {
        videoMemoryBufferingEnabled = enabled
        libMpvClient?.setNetworkMemoryBufferingEnabled(enabled)
    }

    /// 视频音频均衡器（lavfi firequalizer，按音乐均衡器同一组 5 段预设）。
    func setVideoEqualizer(enabled: Bool, preset: MusicEqualizerPreset) {
        videoEqualizerEnabled = enabled
        videoEqualizerPreset = preset
        if let client = libMpvClient {
            rebuildAudioFilterChain(to: client)
        }
    }

    private func rebuildAudioFilterChain(to client: LibMpvClient) {
        guard videoEqualizerEnabled, !videoEqualizerPreset.isFlat else {
            client.setString("af", "")
            return
        }
        let frequencies: [Double] = [60, 230, 910, 3600, 14000]
        let entries = zip(frequencies, videoEqualizerPreset.gainsDB)
            .map { String(format: "entry(%.0f,%.1f)", $0, $1) }
            .joined(separator: ";")
        client.setString("af", "lavfi=[firequalizer=gain_entry='\(entries)']")
    }

    private func applySubtitleStyle(to client: LibMpvClient) {
        client.setString("sub-font", subtitleStyle.fontName ?? "sans-serif")
        client.setFlag("sub-bold", subtitleStyle.bold)
        client.setString("sub-color", subtitleStyle.colorPreset.mpvColor)
        client.setDouble("sub-border-size", subtitleStyle.borderSize)
        // mpv 颜色为 #AARRGGBB；不透明度 0 时给全透明背景等价于关闭背景底。
        let backgroundAlpha = Int((VideoSubtitleStyle.clampBackground(subtitleStyle.backgroundOpacity) * 255).rounded())
        client.setString("sub-back-color", String(format: "#%02X000000", backgroundAlpha))
    }

    func setSubtitleStyle(_ style: VideoSubtitleStyle) {
        subtitleStyle = style
        if let client = libMpvClient {
            applySubtitleStyle(to: client)
        }
    }

    private func applyColorAdjustments(to client: LibMpvClient) {
        client.setDouble("brightness", colorAdjustments.brightness)
        client.setDouble("contrast", colorAdjustments.contrast)
        client.setDouble("saturation", colorAdjustments.saturation)
        client.setDouble("gamma", colorAdjustments.gamma)
        client.setDouble("hue", colorAdjustments.hue)
    }

    func setColorAdjustments(_ adjustments: VideoColorAdjustments) {
        colorAdjustments = adjustments
        if let client = libMpvClient {
            applyColorAdjustments(to: client)
        }
    }

    func setPitchCorrection(_ enabled: Bool) {
        pitchCorrectionEnabled = enabled
        libMpvClient?.setFlag("audio-pitch-correction", enabled)
    }

    func setAudioDelay(_ value: Double) {
        audioDelay = AppSettings.clampedVideoSyncDelay(value)
        libMpvClient?.setDouble("audio-delay", audioDelay)
    }

    func setSubtitleDelay(_ value: Double) {
        subtitleDelay = AppSettings.clampedVideoSyncDelay(value)
        libMpvClient?.setDouble("sub-delay", subtitleDelay)
    }

    func setSubtitleScale(_ value: Double) {
        subtitleScale = AppSettings.clampedVideoSubtitleScale(value)
        libMpvClient?.setDouble("sub-scale", subtitleScale)
    }

    func setSubtitlePosition(_ value: Double) {
        subtitlePosition = AppSettings.clampedVideoSubtitlePosition(value)
        libMpvClient?.setDouble("sub-pos", subtitlePosition)
    }

    func setAspectOverride(_ mode: VideoAspectOverride) {
        aspectOverride = mode
        libMpvClient?.setString("video-aspect-override", mode.mpvValue)
    }

    func setCropMode(_ mode: VideoCropMode) {
        cropMode = mode
        libMpvClient?.setDouble("panscan", mode.panscanValue)
    }

    func setDeinterlaceMode(_ mode: VideoDeinterlaceMode) {
        deinterlaceMode = mode
        libMpvClient?.setString("deinterlace", mode.mpvValue)
    }

    func setRotationMode(_ mode: VideoRotationMode) {
        rotationMode = mode
        libMpvClient?.setString("video-rotate", mode.mpvValue)
    }

    func setHardwareDecodingMode(_ mode: VideoHardwareDecodingMode) {
        hardwareDecodingMode = mode
        libMpvClient?.setString("hwdec", mode.mpvValue)
    }

    func setDebandMode(_ mode: VideoDebandMode) {
        debandMode = mode
        guard let libMpvClient else { return }
        applyDebandMode(to: libMpvClient)
    }

    private func applyDebandMode(to client: LibMpvClient) {
        client.setFlag("deband", debandMode.isEnabled)
        client.setDouble("deband-threshold", debandMode.threshold)
        client.setDouble("deband-range", debandMode.range)
        client.setDouble("deband-grain", debandMode.grain)
    }

    func setLoopCurrentItem(_ enabled: Bool) {
        loopCurrentItem = enabled
        libMpvClient?.setString("loop-file", enabled ? "inf" : "no")
    }

    @discardableResult
    func cycleABLoopPoint() -> PlayerABLoopSelection {
        let time = clampedTimelineTime(currentTime)
        if abLoopStart == nil || (abLoopStart != nil && abLoopEnd != nil) {
            setABLoop(start: time, end: nil)
            return .start(time)
        }
        guard let start = abLoopStart else {
            setABLoop(start: time, end: nil)
            return .start(time)
        }
        if time <= start + 0.20 {
            setABLoop(start: time, end: nil)
            return .start(time)
        }
        setABLoop(start: start, end: time)
        return .range(start, time)
    }

    func clearABLoop() {
        setABLoop(start: nil, end: nil)
    }

    private func setABLoop(start: Double?, end: Double?) {
        abLoopStart = start
        abLoopEnd = end
        guard let libMpvClient else { return }
        applyABLoop(to: libMpvClient)
    }

    private func applyABLoop(to client: LibMpvClient) {
        if let abLoopStart {
            client.setDouble("ab-loop-a", abLoopStart)
        } else {
            client.setString("ab-loop-a", "no")
        }
        if let abLoopEnd {
            client.setDouble("ab-loop-b", abLoopEnd)
        } else {
            client.setString("ab-loop-b", "no")
        }
    }

    func cycleAspectOverride() {
        setAspectOverride(nextMode(after: aspectOverride, in: VideoAspectOverride.allCases))
    }

    func cycleCropMode() {
        setCropMode(nextMode(after: cropMode, in: VideoCropMode.allCases))
    }

    func cycleDeinterlaceMode() {
        setDeinterlaceMode(nextMode(after: deinterlaceMode, in: VideoDeinterlaceMode.allCases))
    }

    func rotateVideo(clockwise: Bool) {
        let modes = VideoRotationMode.allCases
        guard let index = modes.firstIndex(of: rotationMode) else {
            setRotationMode(clockwise ? .clockwise90 : .counterclockwise90)
            return
        }
        let delta = clockwise ? 1 : modes.count - 1
        setRotationMode(modes[(index + delta) % modes.count])
    }

    private func nextMode<T: CaseIterable & Equatable>(after current: T, in modes: T.AllCases) -> T where T.AllCases: RandomAccessCollection, T.AllCases.Index == Int {
        guard !modes.isEmpty,
              let index = modes.firstIndex(of: current) else {
            return modes[modes.startIndex]
        }
        return modes[(index + 1) % modes.count]
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
            libMpvClient.setDouble("volume", Double(localVolume * 100) * volumeBoost)
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
        let targetTolerance = item?.type == .music ? 0.08 : 0.24
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

    private func isSeekClockSettled(_ time: Double, target: Double) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        let targetTolerance = item?.type == .music ? 0.08 : 0.24
        if abs(time - target) <= targetTolerance {
            return true
        }
        guard item?.type != .music else { return false }
        guard duration.isFinite, duration > 0 else { return false }
        let nearEndTolerance = 0.35
        return target >= duration - nearEndTolerance && time >= duration - nearEndTolerance
    }

    private func reissuePendingSeekIfNeeded(
        observedTime: Double,
        generation: Int,
        audioPlayer: AVPlayer? = nil,
        libMpvClient: LibMpvClient? = nil
    ) {
        guard observedTime.isFinite,
              var pending = pendingTimelineSeek,
              pending.generation == generation else { return }
        let reissueTolerance = item?.type == .music ? 0.08 : 0.20
        guard abs(observedTime - pending.targetTime) > reissueTolerance,
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
            baseVideoFilter = option.videoFilter
            rebuildVideoFilterChain(to: libMpvClient)
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
            baseVideoFilter = nil
            rebuildVideoFilterChain(to: libMpvClient)
            var loadCommand = ["loadfile", targetURL, "replace"]
            if option.isOriginal, resumeTime > 1 {
                loadCommand.append("start=\(String(format: "%.3f", resumeTime))")
            }
            try libMpvClient.command(loadCommand)
            libMpvClient.setDouble("volume", Double(volume * 100) * volumeBoost)
            libMpvClient.setDouble("speed", Double(playbackRate))
            applyVideoAdjustments(to: libMpvClient)
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
            libMpvClient.setDouble("volume", Double(volume * 100) * volumeBoost)
            libMpvClient.setDouble("speed", Double(playbackRate))
            applyVideoAdjustments(to: libMpvClient)
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

    /// 选择第二字幕轨道（mpv `secondary-sid`，双语对照），nil 表示关闭。
    func selectSecondarySubtitleTrack(_ id: Int?) {
        guard let libMpvClient else { return }
        if let id {
            try? libMpvClient.command(["set", "secondary-sid", "\(id)"])
            try? libMpvClient.command(["set", "secondary-sub-visibility", "yes"])
            secondarySubtitleID = id
        } else {
            try? libMpvClient.command(["set", "secondary-sid", "no"])
            secondarySubtitleID = nil
        }
        refreshTrackLists(from: libMpvClient, force: true)
    }

    /// 刷新音频输出设备列表与当前选中设备（mpv `audio-device-list` / `audio-device`）。
    func refreshAudioDevices() {
        guard let libMpvClient else {
            audioDevices = []
            return
        }
        selectedAudioDeviceName = libMpvClient.getString("audio-device") ?? "auto"
        guard let json = libMpvClient.getString("audio-device-list"),
              let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            audioDevices = []
            return
        }
        let devices = entries.compactMap { entry -> MpvAudioDevice? in
            guard let name = entry["name"] as? String else { return nil }
            return MpvAudioDevice(name: name, deviceDescription: (entry["description"] as? String) ?? "")
        }
        if audioDevices != devices {
            audioDevices = devices
        }
    }

    func selectAudioDevice(_ name: String) {
        guard let libMpvClient else { return }
        selectedAudioDeviceName = name
        libMpvClient.setString("audio-device", name)
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

    func captureCurrentVideoFrame(title: String, mode: VideoScreenshotMode) throws -> URL {
        guard let libMpvClient else {
            throw PlayerScreenshotError.unavailable
        }
        let folder = try Self.screenshotDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let targetURL = folder.appendingPathComponent(Self.screenshotFilename(title: title))
        do {
            try libMpvClient.command(["screenshot-to-file", targetURL.path, mode.mpvArgument])
            return targetURL
        } catch {
            // vo=libmpv 渲染 API 未开 advanced-control 时 screenshot 命令会报不支持；
            // 兜底直接从渲染视图读出当前画面（即窗口所见，含字幕）。
            guard let imageData = renderView?.captureFramePNGData() else {
                throw error
            }
            try imageData.write(to: targetURL)
            return targetURL
        }
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

    private enum PlayerScreenshotError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "当前播放器不支持截图"
            }
        }
    }

    private static func screenshotDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return base.appendingPathComponent("MediaLIB 截图", isDirectory: true)
    }

    private static func screenshotFilename(title: String) -> String {
        let cleanedTitle = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = cleanedTitle.isEmpty ? "视频截图" : String(cleanedTitle.prefix(64))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(safeTitle) \(formatter.string(from: Date())).png"
    }

    func teardown() {
        playbackGeneration += 1
        timer?.invalidate()
        timer = nil
        initialRedrawTask?.cancel()
        initialRedrawTask = nil
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        musicMemoryLoadTask?.cancel()
        musicMemoryLoadTask = nil
        clearPreloadedMusicItem()
        currentMemoryAudioAsset = nil
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
        baseVideoFilter = nil
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
        musicMemoryLoadTask?.cancel()
        musicMemoryLoadTask = nil
        clearPreloadedMusicItem()
        currentMemoryAudioAsset = nil
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
        baseVideoFilter = nil
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
                    let effectiveDuration = self.refreshNativeAudioDuration()
                    // 往回拖出结尾区后允许再次判定结束。
                    if self.didReachAudioEnd, effectiveDuration > 0, audioTime.isFinite,
                       audioTime < effectiveDuration - 1.0 {
                        self.didReachAudioEnd = false
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
                    // keep-open=yes：EOF 停在最后一帧并置 eof-reached，由播放结束行为接管；
                    // 用户回拖后 eof-reached 复位，可再次触发。
                    if let eofReached = libMpvClient.getFlag("eof-reached") {
                        if eofReached, !self.didNotifyPlaybackEnd, self.duration > 0 {
                            self.didNotifyPlaybackEnd = true
                            self.onPlaybackFinished?()
                        } else if !eofReached, self.didNotifyPlaybackEnd {
                            self.didNotifyPlaybackEnd = false
                        }
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
        let secondary = client.getInt64("secondary-sid").map(Int.init)
        if secondarySubtitleID != secondary {
            secondarySubtitleID = secondary
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

    static func setAlwaysOnTop(_ enabled: Bool) {
        guard let window = NSApp.keyWindow else { return }
        window.level = enabled ? .floating : .normal
    }

    static func exitFullScreenIfNeeded() -> Bool {
        guard let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else {
            return false
        }
        window.toggleFullScreen(nil)
        return true
    }

    /// 进入迷你悬浮窗：缩到屏幕右下角的小窗、置顶、跨空间显示、隐藏红黄绿按钮。
    /// 返回进入前的窗口 frame 供恢复；全屏或非播放器窗口返回 nil。
    static func enterMiniMode(aspect: CGFloat) -> NSRect? {
        // 不能用 keyWindow：从齿轮弹层点「进入」时 key 窗口还是 NSPopover 的宿主窗口。
        guard let window = NSApp.windows
                .compactMap({ $0 as? ImmersivePlayerWindow })
                .first(where: { !$0.isMiniMode && $0.isVisible }),
              !window.styleMask.contains(.fullScreen) else { return nil }
        let previousFrame = window.frame
        window.isMiniMode = true

        let safeAspect = max(aspect, 0.01)
        let contentSize = NSSize(width: 380, height: (380 / safeAspect).rounded())
        let miniMinimum = NSSize(width: 240, height: (240 / safeAspect).rounded())
        window.contentMinSize = miniMinimum
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: miniMinimum)).size
        window.contentAspectRatio = contentSize
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        // 不用带动画的 setFrame：动画分步触发 windowWillResize/最小尺寸约束，
        // 会在中途被旧的 680pt 内容下限顶住，落点变宽出黑边。
        window.setContentSize(contentSize)
        let visibleFrame = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - window.frame.width - 16,
            y: visibleFrame.minY + 16
        ))
        return previousFrame
    }

    static func exitMiniMode(restoring frame: NSRect, alwaysOnTop: Bool) {
        guard let window = NSApp.windows.compactMap({ $0 as? ImmersivePlayerWindow }).first(where: \.isMiniMode) else { return }
        window.isMiniMode = false
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior.remove(.canJoinAllSpaces)
        let restoredMinimum = NSSize(
            width: VideoWindowSizing.minimumControlSafeWidth,
            height: VideoWindowSizing.minimumControlSafeHeight
        )
        window.contentMinSize = restoredMinimum
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: restoredMinimum)).size
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = false
        }
        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
    }

    static func resizeCurrentWindow(toContentSize contentSize: NSSize, animate: Bool = false) {
        guard let window = NSApp.keyWindow,
              !window.styleMask.contains(.fullScreen),
              contentSize.width.isFinite,
              contentSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else { return }
        var targetContentSize = contentSize
        if let visibleFrame = window.screen?.visibleFrame {
            let maxFrameSize = NSSize(
                width: max(visibleFrame.width - 20, 1),
                height: max(visibleFrame.height - 20, 1)
            )
            let proposedFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
            let scale = min(maxFrameSize.width / max(proposedFrameSize.width, 1), maxFrameSize.height / max(proposedFrameSize.height, 1), 1)
            targetContentSize = NSSize(width: targetContentSize.width * scale, height: targetContentSize.height * scale)
        }
        let currentFrame = window.frame
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
        window.contentAspectRatio = targetContentSize
        let origin = NSPoint(
            x: currentFrame.midX - frameSize.width / 2,
            y: currentFrame.midY - frameSize.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: animate)
    }
}

final class ImmersivePlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// 迷你悬浮窗模式：presenter 的最小尺寸钳制与窗口 chrome 显示在该模式下让路。
    var isMiniMode = false
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
                // 复用已有窗口时不要按设置重设尺寸：updateNSView 在任意 appState 变化时都会
                // 走到这里，按「偏好宽度+屏高 94% 上限」重算会把用户刚拖大的窗口缩回去
                // （拖宽→保存设置→触发本方法→等比收缩，即“拖动后自动缩放回去”的根因）。
                window?.level = settings.videoPlayerAlwaysOnTop ? .floating : .normal
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
            // 不透明黑底：播放器内容本就是全幅黑底视频，透明窗口会让 WindowServer
            // 整个播放期间都多合成一层桌面背景，造成系统级（包括桌面光标）的流畅度损耗。
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = true
            window.level = settings.videoPlayerAlwaysOnTop ? .floating : .normal
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
            // ★ 关键：assign contentViewController 时 AppKit 会把窗口缩到 SwiftUI 视图的
            // fittingSize（PlayerView 用 idealWidth + maxWidth:.infinity、无 minWidth，
            // 压缩尺寸近乎为 0，于是窗口每次都开得很小）。这里在 VC 赋值「之后」把目标
            // 内容尺寸显式钉回去，覆盖 fitting 尺寸——启动宽度/记忆宽度才会真正生效。
            window.setContentSize(preferredSize)
            window.contentAspectRatio = preferredSize
            window.contentView?.layoutSubtreeIfNeeded()
            Self.centerWindow(window, on: sourceScreen)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak window] in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                // 再钉一次：SwiftUI 首帧布局可能在本回合后才回灌 fitting 尺寸。
                let currentWidth = window.contentView?.frame.width ?? preferredSize.width
                if abs(currentWidth - preferredSize.width) > 2 {
                    window.setContentSize(preferredSize)
                }
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
                  (window as? ImmersivePlayerWindow)?.isMiniMode != true,
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
                  (sender as? ImmersivePlayerWindow)?.isMiniMode != true,
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

        /// 拖拽窗口边缘就是「调整窗口宽度」的唯一入口：松手后把内容宽度记为
        /// 偏好宽度，只影响下次打开视频时的默认窗口大小（当前窗口即所见即所得）。
        func windowDidEndLiveResize(_ notification: Notification) {
            guard let window, notification.object as AnyObject? === window,
                  !window.styleMask.contains(.fullScreen),
                  (window as? ImmersivePlayerWindow)?.isMiniMode != true else { return }
            let width = window.contentLayoutRect.width
            guard width >= VideoWindowSizing.minimumPreferredWidth else { return }
            appState.settings.videoPlayerPreferredWidth = Double(width)
            appState.saveSettings()
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
                  (window as? ImmersivePlayerWindow)?.isMiniMode != true,
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
            let visibleFrameWidth = (screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
            // 勾选「启动窗口宽度」按比例取屏宽（1.0 = 占满）；否则用记忆的上次拖拽宽度。
            let width: CGFloat
            let widthIsFullScreen: Bool
            if settings.videoUseFixedLaunchWidth {
                let ratio = AppSettings.clampedVideoLaunchWidthRatio(settings.videoLaunchWidthRatio)
                width = visibleFrameWidth * CGFloat(ratio)
                widthIsFullScreen = ratio >= 0.999
            } else {
                width = VideoWindowSizing.clampedPreferredWidth(settings.videoPlayerPreferredWidth, on: screen)
                widthIsFullScreen = VideoWindowSizing.usesFullScreenWidth(settings.videoPlayerPreferredWidth, on: screen)
            }
            let aspect = aspectOverride ?? videoAspectRatio(for: item)
            let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
            let visibleWidth = visibleFrame?.width ?? 1440
            let visibleHeight = visibleFrame?.height ?? 900
            // 固定启动宽度时宽度优先：高度允许用满可用区域，否则 94% 高度上限
            // 会把 16:9 的「100% 宽」窗口等比缩小、永远占不满屏幕宽。
            let maxSize = NSSize(
                width: visibleWidth * (widthIsFullScreen ? 1.0 : 0.985),
                height: visibleHeight * (settings.videoUseFixedLaunchWidth ? 1.0 : 0.94)
            )
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
