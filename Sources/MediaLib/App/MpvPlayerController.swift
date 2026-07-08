import AppKit
import AVKit
import AVFoundation
import Combine
import Foundation
import MediaLibCore
import SwiftUI

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
        let clampedTime = PlaybackTimelinePolicy.clampedTime(currentTime, duration: self.duration)
        self.currentTime = clampedTime
        lyricTime = clampedTime
        audioSpectrumBands = AudioSpectrumAnalyzer.silenceBands.enumerated().map { index, _ in
            // 拆成显式 Double 中间量：避免部分 Swift 编译器对这条嵌套表达式
            // 「unable to type-check in reasonable time」而构建失败（CI 旧 SDK 上复现）。
            let phase: Double = Double(index) * 0.62 + clampedTime * 0.42
            let normalized: Double = 0.5 + 0.5 * sin(phase)
            let scaled: Double = 0.24 + 0.58 * normalized
            return CGFloat(scaled)
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
    private var videoPlaybackEngine: VideoPlaybackEngine?
    private var videoTrackSelectionEngine: VideoTrackSelectionEngine?
    private var videoFrameCommandEngine: VideoFrameCommandEngine?
    private var videoLoopCommandEngine: VideoLoopCommandEngine?
    private var videoAudioDeviceReader: VideoAudioDeviceReading?
    private var mpvSnapshotReader: MpvVideoSnapshotReader?
    private var mpvSnapshotReadInFlight = false
    private var pendingForcedTrackSnapshot = false
    private var trackSnapshotRefreshCount = 0
    private var chapterSnapshotRefreshCount = 0
    private var audioPlayer: AVQueuePlayer?
    private var musicPlaybackEngine: MusicPlaybackEngine?
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
    private weak var renderView: (any MpvRenderSurface)?
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
    private var preferredSubtitleLanguage = "zh-CN"
    private var lastTrackRefreshDate = Date.distantPast
    private var lastDurationSnapshotDate = Date.distantPast
    private var lastVideoAspectSnapshotDate = Date.distantPast
    private var lastBufferingSnapshotDate = Date.distantPast
    private var lastChapterSnapshotDate = Date.distantPast
    private var deferredTrackRefreshTask: Task<Void, Never>?
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
    private var pendingTimelineSeek: PendingPlaybackSeek?
    private var audioSpectrumVisualizationActive = false
    private var lastAudioSpectrumSampleDate = Date.distantPast
    private var musicNormalizationGain: Float = 1
    private var musicTransitionMode: MusicTransitionMode = .immediate
    private var musicSoftFadeDuration: Double = 0.8
    // EQ：仅当启用且预设非纯平时才给音乐 AVPlayerItem 挂 MTAudioProcessingTap；变更下一首生效。
    private var musicEqualizerEnabled = false
    private var musicEqualizerGains: [Double] = MusicEqualizerPreset.flat.gainsDB
    private var audioTransitionVolumeScale: Float = 1
    private var musicOutputRecoveryTask: Task<Void, Never>?
    private(set) var spectrumSuppressedDuringWindowDrag = false
    /// 拖动/seek 进行中临时挂起频谱解码（与拖窗抑制独立，松手即恢复）。
    private var spectrumSuppressedDuringSeek = false
    /// 网络源（http 流 / 网络挂载盘）的卡顿恢复观察者：缓冲见底自动续播，避免「播着播着没声」。
    private var audioTimeControlObservation: NSKeyValueObservation?
    private var audioBufferEmptyObservation: NSKeyValueObservation?
    private var audioLikelyToKeepUpObservation: NSKeyValueObservation?
    /// 当前音频源是否为网络源（决定缓冲策略与卡顿恢复是否启用）。
    private var currentAudioSourceIsNetwork = false

    /// 频谱是否应当因任何交互（拖窗或拖动进度条）而暂停解码。
    private var spectrumSuppressedDuringInteraction: Bool {
        spectrumSuppressedDuringWindowDrag || spectrumSuppressedDuringSeek
    }

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
        preferredSubtitleLanguage = settings.subtitleLanguage.isEmpty ? "zh-CN" : settings.subtitleLanguage
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
        resetVideoSnapshotDates()
        deferredTrackRefreshTask?.cancel()
        deferredTrackRefreshTask = nil

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
        let nextIsNetwork = isNetworkMountedFileURL(nextURL)
        musicPreloadTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let prepared = try await self.prepareMusicPlayerItem(url: nextURL, preloaded: true)
                // 本地内存源可大幅前向缓冲；网络挂载盘只预读受控提前量，避免预缓冲整首歌占满网络。
                prepared.playerItem.preferredForwardBufferDuration = nextIsNetwork
                    ? MusicPlaybackBufferPolicy.preferredForwardBufferDuration(isNetwork: true, preloaded: true)
                    : self.preferredMusicPreloadBufferDuration(for: nextItem)
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

    func attach(to view: any MpvRenderSurface) {
        renderView = view
        if item?.type != .music, isPreparing, libMpvClient == nil {
            startMpv()
        }
    }

    func detach(from view: any MpvRenderSurface) {
        if renderView === view {
            renderView = nil
        }
    }

    private func startMpv() {
        guard libMpvClient == nil, let filePath else { return }
        guard let renderView, renderView.isSurfaceInWindow, let openGLContext = renderView.mpvGLContext else {
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
                renderView?.requestRedraw()
            }
            let engine = MpvVideoPlaybackEngine(transport: client)
            let trackEngine = MpvVideoTrackSelectionEngine(transport: client)
            let frameCommandEngine = MpvVideoFrameCommandEngine(transport: client)
            let loopCommandEngine = MpvVideoLoopCommandEngine(transport: client)
            let audioDeviceReader = MpvVideoAudioDeviceReader(transport: client)
            try engine.loadFile(filePath)
            applyVideoAdjustments(to: client, loopCommandEngine: loopCommandEngine)
            libMpvClient = client
            videoPlaybackEngine = engine
            videoTrackSelectionEngine = trackEngine
            videoFrameCommandEngine = frameCommandEngine
            videoLoopCommandEngine = loopCommandEngine
            videoAudioDeviceReader = audioDeviceReader
            mpvSnapshotReader = MpvVideoSnapshotReader(handle: client.makePropertyReadHandle())
            mpvSnapshotReadInFlight = false
            pendingForcedTrackSnapshot = false
            renderView.installRenderHandle(client.makeRenderCallHandle())
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

    func render(width: Int, height: Int, fbo: Int = 0, flipY: Bool = true) {
        libMpvClient?.render(width: width, height: height, fbo: fbo, flipY: flipY)
    }

    func requestVideoSurfaceRedraw() {
        renderView?.requestRedraw()
    }

    private func startNativeAudio() {
        guard let filePath else { return }
        guard let url = audioURL(for: filePath, isRemote: item?.isRemoteResource == true) else {
            fail("音频路径不可用。")
            return
        }

        let generation = playbackGeneration
        if url.isFileURL {
            let isNetwork = isNetworkMountedFileURL(url)
            statusMessage = isNetwork ? "正在从网络载入歌曲。" : "正在将歌曲载入内存。"
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
                        memoryAsset: prepared.memoryAsset,
                        isNetwork: isNetwork
                    )
                } catch {
                    guard self.playbackGeneration == generation else { return }
                    self.fail("音频载入失败：\(error.localizedDescription)")
                }
            }
            return
        }

        let playerItem = makeAudioPlayerItem(url: url)
        installInitialNativeAudioPlayer(playerItem: playerItem, generation: generation, memoryAsset: nil, isNetwork: true)
    }

    private func installInitialNativeAudioPlayer(
        playerItem: AVPlayerItem,
        generation: Int,
        memoryAsset: MemoryAudioAsset?,
        isNetwork: Bool
    ) {
        currentMemoryAudioAsset = memoryAsset
        let player = AVQueuePlayer(items: [playerItem])
        let musicEngine = AVQueueMusicPlaybackEngine(
            transport: AVQueueMusicPlayerTransport(player: player)
        )
        player.allowsExternalPlayback = true
        applyAudioStallPolicy(to: player, isNetwork: isNetwork)
        player.actionAtItemEnd = .advance
        musicEngine.setVolume(effectiveMusicVolume)
        musicEngine.setMuted(false)

        observeAudioEnd(for: playerItem, generation: generation)
        observeAudioExternalPlayback(for: player)
        installAudioStallRecovery(for: player, isNetwork: isNetwork)

        didReachAudioEnd = false
        audioPlayer = player
        musicPlaybackEngine = musicEngine
        isPreparing = false
        isReady = true
        isPlaying = false
        statusMessage = nil
        updateSystemNowPlaying()
        configureMusicRouteProxyIfNeeded()

        let startSeconds = max(currentTime, 0)
        if startSeconds > 0 {
            musicEngine.seek(to: startSeconds) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.playbackGeneration == generation,
                          self.audioPlayer === player,
                          player.currentItem === playerItem else { return }
                    self.musicPlaybackEngine?.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                    self.scheduleMusicOutputRecovery(generation: generation, shouldPlay: true)
                    self.updateSystemNowPlaying()
                    self.reportPlayback(.started, force: true)
                }
            }
        } else {
            musicEngine.playImmediately(atRate: playbackRate)
            isPlaying = true
            scheduleMusicOutputRecovery(generation: generation, shouldPlay: true)
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
            musicPlaybackEngine?.pause()
            audioLocalMirrorPlayer?.pause()
            audioRouteProxyPlayer?.pause()
            isPlaying = false
            isPreparing = true
            // 网络挂载盘走流式（prepareMusicPlayerItem 内部不再整文件进内存），文案据此区分。
            statusMessage = isNetworkMountedFileURL(url) ? "正在从网络载入歌曲。" : "正在将歌曲载入内存。"
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
                    self.fail("音频载入失败：\(error.localizedDescription)")
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
        musicOutputRecoveryTask?.cancel()
        musicOutputRecoveryTask = nil
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
            musicPlaybackEngine?.pause()
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

        let isNetwork = audioSourceIsNetwork(item: nextItem, url: url)
        let playerItem = queuedPreload?.playerItem ?? preparedOverride?.playerItem ?? makeAudioPlayerItem(url: url, isNetwork: isNetwork)
        currentMemoryAudioAsset = queuedPreload?.memoryAsset ?? preparedOverride?.memoryAsset
        observeAudioEnd(for: playerItem, generation: generation)
        player.allowsExternalPlayback = true
        applyAudioStallPolicy(to: player, isNetwork: isNetwork)
        installAudioStallRecovery(for: player, isNetwork: isNetwork)
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
        normalizeMusicPlaybackOutput(generation: generation, shouldPlay: false)
        updateSystemNowPlaying()
        configureMusicRouteProxyIfNeeded()

        let startSeconds = max(currentTime, 0)
        if alreadyAdvancedToPreload {
            isPlaying = player.rate > 0
            if !isPlaying {
                musicPlaybackEngine?.playImmediately(atRate: playbackRate)
                isPlaying = true
            }
            startSoftFadeInIfNeeded(generation: generation)
            scheduleMusicOutputRecovery(generation: generation, shouldPlay: true)
            updateSystemNowPlaying()
            reportPlayback(.started, force: true)
            startTimer()
            return
        }
        if startSeconds > 0 {
            musicPlaybackEngine?.seek(to: startSeconds) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.playbackGeneration == generation,
                          self.audioPlayer === player,
                          player.currentItem === playerItem else { return }
                    self.musicPlaybackEngine?.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                    self.startSoftFadeInIfNeeded(generation: generation)
                    self.scheduleMusicOutputRecovery(generation: generation, shouldPlay: true)
                    self.updateSystemNowPlaying()
                    self.reportPlayback(.started, force: true)
                }
            }
        } else {
            musicPlaybackEngine?.playImmediately(atRate: playbackRate)
            isPlaying = true
            startSoftFadeInIfNeeded(generation: generation)
            scheduleMusicOutputRecovery(generation: generation, shouldPlay: true)
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

    nonisolated static func loadMusicFileData(fileURL: URL) async throws -> Data {
        try await BlockingIOExecutor.run {
            try Data(contentsOf: fileURL)
        }
    }

    private func prepareMusicPlayerItem(
        url: URL,
        preloaded: Bool = false,
        applyEqualizer: Bool = true
    ) async throws -> PreparedMusicPlayerItem {
        guard url.isFileURL else {
            return PreparedMusicPlayerItem(
                playerItem: makeAudioPlayerItem(url: url, applyEqualizer: applyEqualizer, isNetwork: true),
                memoryAsset: nil
            )
        }

        // 网络挂载盘（NAS/SMB/AFP）：不整文件进内存，直接渐进式流式起播。
        // 用非精确时序避免起播前扫描整个远端文件；前向缓冲交给流式策略。
        if isNetworkMountedFileURL(url) {
            let asset = makeAudioAsset(url: url, preferPreciseTiming: false)
            let playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard playable else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let playerItem = makeAudioPlayerItem(
                asset: asset,
                isLocal: true,
                preloaded: preloaded,
                applyEqualizer: applyEqualizer,
                isNetwork: true
            )
            return PreparedMusicPlayerItem(playerItem: playerItem, memoryAsset: nil)
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
        preferPreciseTiming: Bool? = nil,
        isNetwork: Bool = false
    ) -> AVPlayerItem {
        // 网络源不做精确时序（会在起播前扫描整段），用容差时序换即时起播。
        let usePreciseTiming = preferPreciseTiming ?? MusicPlaybackBufferPolicy.prefersPreciseTiming(
            isNetwork: isNetwork,
            isMusic: item?.type == .music
        )
        return makeAudioPlayerItem(
            asset: makeAudioAsset(url: url, preferPreciseTiming: usePreciseTiming),
            isLocal: url.isFileURL,
            applyEqualizer: applyEqualizer,
            isNetwork: isNetwork
        )
    }

    private func makeAudioPlayerItem(asset: AVAsset, isLocal: Bool, preloaded: Bool = false, applyEqualizer: Bool = true, isNetwork: Bool = false) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: asset)
        if isNetwork {
            // 网络挂载盘的流式 file 项：给足前向缓冲，配合 waitToMinimizeStalling 自动重缓冲。
            playerItem.preferredForwardBufferDuration = MusicPlaybackBufferPolicy.preferredForwardBufferDuration(
                isNetwork: true,
                preloaded: preloaded
            )
        } else if isLocal {
            playerItem.preferredForwardBufferDuration = MusicPlaybackBufferPolicy.preferredForwardBufferDuration(
                isNetwork: false,
                preloaded: preloaded
            )
        } else {
            playerItem.preferredForwardBufferDuration = 2
        }
        // 仅在启用且非纯平时挂 EQ；失败则保持原样（透传），不影响播放。
        // 仅对本地文件挂 EQ：makeAudioMix 内部会同步访问 asset.tracks，远端资源在主线程同步取轨会阻塞 UI；
        // EQ 主要面向本地高保真，远端/网络流跳过以规避主线程卡顿。
        if applyEqualizer, musicEqualizerEnabled, isLocal, !isNetwork {
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

    /// file:// 是否落在网络挂载盘（SMB/AFP/NFS 的 /Volumes/...）。
    /// 网络挂载盘不走「整文件读进内存」——那会在切歌路径上同步下载整首歌，
    /// 大体积 hi-res 文件在 NAS 上要等几十 MB 的网络往返；改为渐进式流式起播。
    private func isNetworkMountedFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal {
            return !isLocal
        }
        // 取不到卷信息时按本地处理，保持旧行为。
        return false
    }

    /// 该音频源是否为网络源（http 流，或网络挂载盘文件）。决定缓冲与卡顿恢复策略。
    private func audioSourceIsNetwork(item: MediaItem?, url: URL) -> Bool {
        if item?.isRemoteResource == true { return true }
        return isNetworkMountedFileURL(url)
    }

    /// 按音频源类型设置 AVQueuePlayer 的停顿策略：
    /// 本地内存源关闭 waitToMinimizeStalling 以求即时起播；网络源开启，
    /// 让缓冲见底时自动停顿重缓冲并恢复，而不是「时钟继续走但没声音」。
    private func applyAudioStallPolicy(to player: AVPlayer, isNetwork: Bool) {
        player.automaticallyWaitsToMinimizeStalling = MusicPlaybackBufferPolicy
            .automaticallyWaitsToMinimizeStalling(isNetwork: isNetwork)
    }

    /// 安装网络源卡顿恢复：监听 timeControlStatus / 缓冲空 / 可续播，
    /// 缓冲见底时显示缓冲态，备好后自动续播——根治「下一首播着播着没声」。
    private func installAudioStallRecovery(for player: AVQueuePlayer, isNetwork: Bool) {
        removeAudioStallRecovery()
        currentAudioSourceIsNetwork = isNetwork
        guard isNetwork else { return }

        audioTimeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.audioPlayer === observed else { return }
                switch observed.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    if self.isPlaying {
                        self.updateBuffering(active: true, progress: nil)
                    }
                case .playing:
                    self.updateBuffering(active: false, progress: nil)
                case .paused:
                    break
                @unknown default:
                    break
                }
            }
        }

        audioBufferEmptyObservation = player.observe(\.currentItem?.isPlaybackBufferEmpty, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.audioPlayer === observed else { return }
                if observed.currentItem?.isPlaybackBufferEmpty == true, self.isPlaying {
                    self.updateBuffering(active: true, progress: nil)
                }
            }
        }

        audioLikelyToKeepUpObservation = player.observe(\.currentItem?.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.audioPlayer === observed else { return }
                guard observed.currentItem?.isPlaybackLikelyToKeepUp == true else { return }
                self.updateBuffering(active: false, progress: nil)
                // 标记为播放中但实际停在缓冲：缓冲恢复后主动续播，覆盖 paused 残留。
                if self.isPlaying, observed.timeControlStatus != .playing {
                    observed.playImmediately(atRate: self.playbackRate)
                }
            }
        }
    }

    private func removeAudioStallRecovery() {
        audioTimeControlObservation = nil
        audioBufferEmptyObservation = nil
        audioLikelyToKeepUpObservation = nil
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
        guard item?.type != .music, let videoPlaybackEngine else { return }
        let localVolume = (videoRouteProxyIsActive || videoRouteProxyIsAudibleProbing) ? 0 : volume
        videoPlaybackEngine.setVolume(localVolume, boost: volumeBoost)
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
                musicPlaybackEngine?.pause()
                audioLocalMirrorPlayer?.pause()
                audioRouteProxyPlayer?.pause()
                isPlaying = false
            } else {
                musicPlaybackEngine?.playImmediately(atRate: playbackRate)
                syncAudioLocalMirrorPlayback()
                syncAudioRouteProxyPlayback()
                isPlaying = true
            }
            updateSystemNowPlaying()
            reportPlayback(.progress, force: true)
            return
        }
        if let videoPlaybackEngine {
            let shouldPlay = !isPlaying
            isPlaying = shouldPlay
            videoPlaybackEngine.setPaused(!shouldPlay)
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
            : PlaybackTimelinePolicy.clampedTime(seconds, duration: duration)
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
        guard PlaybackSeekCoordinator.canCancelScrubbing(currentState: seekState) else { return }
        seekState = nil
        spectrumSuppressedDuringSeek = false
        currentTime = lyricTime
        seekSyncRevision &+= 1
    }

    private func updateScrubbing(to seconds: Double, createIfNeeded: Bool) {
        let target = clampedTimelineTime(seconds)
        guard let transition = PlaybackSeekCoordinator.scrubbingTransition(
            currentState: seekState,
            targetTime: target,
            fallbackOriginTime: lyricTime,
            createIfNeeded: createIfNeeded
        ) else { return }
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        pendingTimelineSeek = nil
        spectrumSuppressedDuringSeek = true
        seekState = transition.state
    }

    private func commitTimelineSeek(to target: Double) {
        let generation = playbackGeneration
        spectrumSuppressedDuringSeek = true
        let seekRevision = beginTimelineSeek(to: target, generation: generation)
        if let audioPlayer {
            guard let musicPlaybackEngine else { return }
            scheduleSeekSyncCorrection(for: generation)
            audioPlayer.currentItem?.cancelPendingSeeks()
            musicPlaybackEngine.seek(to: target) { [weak self, weak audioPlayer] finished in
                Task { @MainActor in
                    guard let self,
                          let audioPlayer,
                          self.audioPlayer === audioPlayer else { return }
                    let actualTime = finished ? self.musicPlaybackEngine?.currentTimeSeconds : nil
                    let decision = PlaybackSeekCommandPolicy.completionDecision(
                        finished: finished,
                        observedTime: actualTime,
                        targetTime: target,
                        expectedGeneration: generation,
                        currentGeneration: self.playbackGeneration,
                        expectedRevision: seekRevision,
                        currentRevision: self.seekState?.revision,
                        duration: self.duration,
                        mediaKind: self.playbackTimelineMediaKind
                    )
                    switch decision {
                    case .ignore:
                        return
                    case .scheduleCorrection:
                        self.scheduleSeekSyncCorrection(for: generation)
                        return
                    case .reissue:
                        if let actualTime {
                            self.reissuePendingSeekIfNeeded(
                                observedTime: actualTime,
                                generation: generation,
                                musicPlaybackEngine: self.musicPlaybackEngine
                            )
                        }
                        self.scheduleSeekSyncCorrection(for: generation)
                        return
                    case .settle:
                        guard let actualTime else {
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
            }
            syncAudioLocalMirrorPlayback(timelineTime: target)
            syncAudioRouteProxyPlayback(timelineTime: target)
            updateSystemNowPlaying()
            return
        }
        if let videoPlaybackEngine {
            if let activeVideoQualityOption,
               !activeVideoQualityOption.appliesInPlace,
               !activeVideoQualityOption.isOriginal,
               playbackTimelineOffset > 0,
               target < playbackTimelineOffset - 0.5 {
                reloadRemoteQualityStream(activeVideoQualityOption, at: target, wasPlaying: isPlaying)
                return
            }
            try? videoPlaybackEngine.seek(toMpvTime: mpvTimelineTime(for: target), precision: .exact)
            syncVideoRouteProxyPlayback()
            updateSystemNowPlaying()
            scheduleSeekSyncCorrection(for: playbackGeneration)
            return
        }
    }

    private func clampedTimelineTime(_ seconds: Double) -> Double {
        PlaybackTimelinePolicy.clampedTime(seconds, duration: seekableDuration)
    }

    private var seekableDuration: Double {
        if duration.isFinite, duration > 0 {
            return duration
        }
        return nativeAudioItemDuration ?? 0
    }

    private var playbackTimelineMediaKind: PlaybackTimelineMediaKind {
        item?.type == .music ? .music : .video
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
            musicPlaybackEngine?.seekToStart { [weak self, weak audioPlayer] _ in
                Task { @MainActor in
                    guard let self, let audioPlayer, self.audioPlayer === audioPlayer else { return }
                    self.musicPlaybackEngine?.playImmediately(atRate: self.playbackRate)
                    self.syncAudioLocalMirrorPlayback()
                    self.syncAudioRouteProxyPlayback()
                    self.isPlaying = true
                    self.updateSystemNowPlaying()
                }
            }
            return
        }
        if let videoPlaybackEngine {
            try? videoPlaybackEngine.seek(toMpvTime: 0, precision: .exact)
            videoPlaybackEngine.setPaused(false)
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
        if audioPlayer != nil {
            if isPlaying {
                musicPlaybackEngine?.playImmediately(atRate: playbackRate)
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
        if let videoPlaybackEngine {
            videoPlaybackEngine.setPlaybackRate(playbackRate)
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

    private func applyVideoAdjustments(
        to client: LibMpvClient,
        loopCommandEngine: VideoLoopCommandEngine? = nil
    ) {
        applyTimingAdjustments(to: client)
        applyVideoPlaybackProperties(to: client)
        applyDebandMode(to: client)
        applyColorAdjustments(to: client)
        applySubtitleStyle(to: client)
        rebuildVideoFilterChain(to: client)
        rebuildAudioFilterChain(to: client)
        applyToneMapping(to: client)
        applyPitchCorrection(to: client)
        let loopCommandEngine = loopCommandEngine ?? videoLoopCommandEngine
        loopCommandEngine?.setLoopCurrentItem(loopCurrentItem)
        client.setNetworkMemoryBufferingEnabled(videoMemoryBufferingEnabled)
        loopCommandEngine?.setABLoop(start: abLoopStart, end: abLoopEnd)
    }

    private func applyVideoPlaybackProperties(to client: LibMpvClient) {
        for property in VideoPlaybackPropertyPolicy.playbackProperties(
            aspectOverride: aspectOverride,
            cropMode: cropMode,
            deinterlaceMode: deinterlaceMode,
            rotationMode: rotationMode,
            hardwareDecodingMode: hardwareDecodingMode
        ) {
            apply(property, to: client)
        }
    }

    private func apply(_ property: VideoPlaybackProperty, to client: LibMpvClient) {
        switch property {
        case let .string(property):
            apply(property, to: client)
        case let .double(property):
            apply(property, to: client)
        }
    }

    private func apply(_ property: VideoPlaybackStringProperty, to client: LibMpvClient) {
        client.setString(property.name, property.value)
    }

    private func apply(_ property: VideoPlaybackDoubleProperty, to client: LibMpvClient) {
        client.setDouble(property.name, property.value)
    }

    private func applyTimingAdjustments(to client: LibMpvClient) {
        for property in VideoTimingAdjustmentPolicy.properties(
            audioDelay: audioDelay,
            subtitleDelay: subtitleDelay,
            subtitleScale: subtitleScale,
            subtitlePosition: subtitlePosition
        ) {
            apply(property, to: client)
        }
    }

    private func apply(_ property: VideoTimingAdjustmentProperty, to client: LibMpvClient) {
        client.setDouble(property.name, property.value)
    }

    private func applyPitchCorrection(to client: LibMpvClient) {
        apply(VideoPitchCorrectionPolicy.property(enabled: pitchCorrectionEnabled), to: client)
    }

    private func apply(_ property: VideoPitchCorrectionProperty, to client: LibMpvClient) {
        client.setFlag(property.name, property.enabled)
    }

    /// 统一合成 vf 链：清晰度档位的缩放滤镜在最前，之后依次是翻转、锐化、降噪。
    /// vf 是单一字符串属性，任何一处直接 set 都会覆盖其它滤镜，必须统一从这里重建。
    private func rebuildVideoFilterChain(to client: LibMpvClient) {
        apply(
            VideoFilterChainPolicy.property(
                baseVideoFilter: baseVideoFilter,
                flipMode: flipMode,
                sharpenMode: sharpenMode,
                denoiseMode: denoiseMode
            ),
            to: client
        )
    }

    private func apply(_ property: VideoFilterChainProperty, to client: LibMpvClient) {
        client.setString(property.name, property.value)
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
        if let client = libMpvClient {
            apply(VideoToneMappingPolicy.property(for: mode), to: client)
        }
    }

    func setVideoMemoryBufferingEnabled(_ enabled: Bool) {
        videoMemoryBufferingEnabled = enabled
        libMpvClient?.setNetworkMemoryBufferingEnabled(enabled)
    }

    /// 视频音频均衡器（按音乐均衡器同一组 5 段预设）。
    func setVideoEqualizer(enabled: Bool, preset: MusicEqualizerPreset) {
        videoEqualizerEnabled = enabled
        videoEqualizerPreset = preset
        if let client = libMpvClient {
            rebuildAudioFilterChain(to: client)
        }
    }

    private func rebuildAudioFilterChain(to client: LibMpvClient) {
        apply(VideoAudioFilterPolicy.property(enabled: videoEqualizerEnabled, preset: videoEqualizerPreset), to: client)
    }

    private func apply(_ property: VideoAudioFilterProperty, to client: LibMpvClient) {
        client.setString(property.name, property.value)
    }

    private func applyToneMapping(to client: LibMpvClient) {
        apply(VideoToneMappingPolicy.property(for: toneMappingMode), to: client)
    }

    private func apply(_ property: VideoToneMappingProperty, to client: LibMpvClient) {
        client.setString(property.name, property.value)
    }

    private func applySubtitleStyle(to client: LibMpvClient) {
        for property in VideoSubtitleStylePolicy.playbackProperties(for: subtitleStyle) {
            apply(property, to: client)
        }
    }

    private func apply(_ property: VideoSubtitleStyleProperty, to client: LibMpvClient) {
        switch property {
        case let .string(name, value):
            client.setString(name, value)
        case let .flag(name, value):
            client.setFlag(name, value)
        case let .double(name, value):
            client.setDouble(name, value)
        }
    }

    func setSubtitleStyle(_ style: VideoSubtitleStyle) {
        subtitleStyle = style
        if let client = libMpvClient {
            applySubtitleStyle(to: client)
        }
    }

    private func applyColorAdjustments(to client: LibMpvClient) {
        for property in VideoColorAdjustmentPolicy.properties(for: colorAdjustments) {
            client.setDouble(property.name, property.value)
        }
    }

    func setColorAdjustments(_ adjustments: VideoColorAdjustments) {
        colorAdjustments = adjustments
        if let client = libMpvClient {
            applyColorAdjustments(to: client)
        }
    }

    func setPitchCorrection(_ enabled: Bool) {
        pitchCorrectionEnabled = enabled
        if let client = libMpvClient {
            apply(VideoPitchCorrectionPolicy.property(enabled: enabled), to: client)
        }
    }

    func setAudioDelay(_ value: Double) {
        audioDelay = AppSettings.clampedVideoSyncDelay(value)
        if let client = libMpvClient {
            apply(VideoTimingAdjustmentPolicy.audioDelayProperty(audioDelay), to: client)
        }
    }

    func setSubtitleDelay(_ value: Double) {
        subtitleDelay = AppSettings.clampedVideoSyncDelay(value)
        if let client = libMpvClient {
            apply(VideoTimingAdjustmentPolicy.subtitleDelayProperty(subtitleDelay), to: client)
        }
    }

    func setSubtitleScale(_ value: Double) {
        subtitleScale = AppSettings.clampedVideoSubtitleScale(value)
        if let client = libMpvClient {
            apply(VideoTimingAdjustmentPolicy.subtitleScaleProperty(subtitleScale), to: client)
        }
    }

    func setSubtitlePosition(_ value: Double) {
        subtitlePosition = AppSettings.clampedVideoSubtitlePosition(value)
        if let client = libMpvClient {
            apply(VideoTimingAdjustmentPolicy.subtitlePositionProperty(subtitlePosition), to: client)
        }
    }

    func setAspectOverride(_ mode: VideoAspectOverride) {
        aspectOverride = mode
        if let client = libMpvClient {
            apply(VideoPlaybackPropertyPolicy.aspectOverrideProperty(for: mode), to: client)
        }
    }

    func setCropMode(_ mode: VideoCropMode) {
        cropMode = mode
        if let client = libMpvClient {
            apply(VideoPlaybackPropertyPolicy.cropPanscanProperty(for: mode), to: client)
        }
    }

    func setDeinterlaceMode(_ mode: VideoDeinterlaceMode) {
        deinterlaceMode = mode
        if let client = libMpvClient {
            apply(VideoPlaybackPropertyPolicy.deinterlaceProperty(for: mode), to: client)
        }
    }

    func setRotationMode(_ mode: VideoRotationMode) {
        rotationMode = mode
        if let client = libMpvClient {
            apply(VideoPlaybackPropertyPolicy.rotationProperty(for: mode), to: client)
        }
    }

    func setHardwareDecodingMode(_ mode: VideoHardwareDecodingMode) {
        hardwareDecodingMode = mode
        if let client = libMpvClient {
            apply(VideoPlaybackPropertyPolicy.hardwareDecodingProperty(for: mode), to: client)
        }
    }

    func setDebandMode(_ mode: VideoDebandMode) {
        debandMode = mode
        guard let libMpvClient else { return }
        applyDebandMode(to: libMpvClient)
    }

    private func applyDebandMode(to client: LibMpvClient) {
        for property in VideoDebandPolicy.playbackProperties(for: debandMode) {
            apply(property, to: client)
        }
    }

    private func apply(_ property: VideoDebandProperty, to client: LibMpvClient) {
        switch property {
        case let .flag(name, value):
            client.setFlag(name, value)
        case let .double(name, value):
            client.setDouble(name, value)
        }
    }

    func setLoopCurrentItem(_ enabled: Bool) {
        loopCurrentItem = enabled
        videoLoopCommandEngine?.setLoopCurrentItem(enabled)
    }

    @discardableResult
    func cycleABLoopPoint() -> PlayerABLoopSelection {
        let time = clampedTimelineTime(currentTime)
        let selection = PlaybackABLoopPolicy.cycleSelection(
            currentTime: time,
            start: abLoopStart,
            end: abLoopEnd
        )
        switch selection {
        case .start(let start):
            setABLoop(start: start, end: nil)
        case .range(let start, let end):
            setABLoop(start: start, end: end)
        case .cleared:
            setABLoop(start: nil, end: nil)
        }
        return selection
    }

    func clearABLoop() {
        setABLoop(start: nil, end: nil)
    }

    private func setABLoop(start: Double?, end: Double?) {
        abLoopStart = start
        abLoopEnd = end
        videoLoopCommandEngine?.setABLoop(start: start, end: end)
    }

    func cycleAspectOverride() {
        setAspectOverride(CyclicModePolicy.next(after: aspectOverride, in: VideoAspectOverride.allCases))
    }

    func cycleCropMode() {
        setCropMode(CyclicModePolicy.next(after: cropMode, in: VideoCropMode.allCases))
    }

    func cycleDeinterlaceMode() {
        setDeinterlaceMode(CyclicModePolicy.next(after: deinterlaceMode, in: VideoDeinterlaceMode.allCases))
    }

    func rotateVideo(clockwise: Bool) {
        let mode = clockwise
            ? CyclicModePolicy.next(after: rotationMode, in: VideoRotationMode.allCases)
            : CyclicModePolicy.previous(after: rotationMode, in: VideoRotationMode.allCases)
        setRotationMode(mode)
    }

    private var effectiveMusicVolume: Float {
        MusicOutputPolicy.effectiveVolume(
            baseVolume: volume,
            normalizationGain: musicNormalizationGain,
            transitionScale: audioTransitionVolumeScale
        )
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
        musicSoftFadeDuration = MusicOutputPolicy.clampedSoftFadeDuration(settings.musicSoftFadeDuration)
        musicEqualizerEnabled = settings.musicEqualizerEnabled && !settings.musicEqualizerPreset.isFlat
        musicEqualizerGains = settings.musicEqualizerPreset.gainsDB
        audioTransitionVolumeScale = MusicOutputPolicy.initialTransitionScale(
            isTrackTransition: isTrackTransition,
            mode: musicTransitionMode
        )
    }

    private func applyAudioOutputVolume() {
        let outputVolume = effectiveMusicVolume
        musicPlaybackEngine?.setVolume(outputVolume)
        audioLocalMirrorPlayer?.volume = outputVolume
        audioRouteProxyPlayer?.volume = audioRouteProxyIsActive ? outputVolume : 0
    }

    private func normalizeMusicPlaybackOutput(generation: Int, shouldPlay: Bool) {
        guard playbackGeneration == generation,
              item?.type == .music,
              let player = audioPlayer else { return }
        musicPlaybackEngine?.setMuted(false)
        applyAudioOutputVolume()
        if keepLocalAudioWithAirPlay {
            syncAudioLocalMirrorPlayback()
            syncAudioRouteProxyPlayback()
        } else {
            stopAudioLocalMirror()
            audioRouteProxyPlayer?.pause()
            audioRouteProxyPlayer?.isMuted = true
        }
        guard shouldPlay, player.currentItem != nil else { return }
        if player.rate == 0 {
            musicPlaybackEngine?.playImmediately(atRate: playbackRate)
        }
        isPlaying = true
    }

    private func scheduleMusicOutputRecovery(generation: Int, shouldPlay: Bool) {
        musicOutputRecoveryTask?.cancel()
        musicOutputRecoveryTask = Task { @MainActor [weak self] in
            for delay in [140_000_000, 720_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, self.playbackGeneration == generation else { return }
                self.normalizeMusicPlaybackOutput(generation: generation, shouldPlay: shouldPlay)
            }
            self?.musicOutputRecoveryTask = nil
        }
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
            let steps = MusicOutputPolicy.softFadeStepCount(duration: duration)
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
                self.audioTransitionVolumeScale = MusicOutputPolicy.softFadeScale(step: step, totalSteps: steps)
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
        if let videoPlaybackEngine {
            let localVolume = (videoRouteProxyIsActive || videoRouteProxyIsAudibleProbing) ? 0 : volume
            videoPlaybackEngine.setVolume(localVolume, boost: volumeBoost)
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
                            musicPlaybackEngine: self.musicPlaybackEngine
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
                            videoPlaybackEngine: self.videoPlaybackEngine
                        )
                    }
                }
            }
            self?.seekSyncCorrectionTask = nil
        }
    }

    @discardableResult
    private func beginTimelineSeek(to target: Double, generation: Int) -> Int {
        let transition = PlaybackSeekCoordinator.seekingTransition(
            currentState: seekState,
            targetTime: target,
            fallbackOriginTime: lyricTime
        )
        clearSeekStateTask?.cancel()
        clearSeekStateTask = nil
        seekSyncCorrectionTask?.cancel()
        seekSyncCorrectionTask = nil
        pendingTimelineSeek = PendingPlaybackSeek(
            revision: transition.revision,
            generation: generation,
            targetTime: transition.targetTime,
            originTime: transition.originTime,
            startedAt: Date()
        )
        seekState = transition.state
        seekSyncRevision &+= 1
        return transition.revision
    }

    @discardableResult
    private func applyPlaybackClock(
        _ time: Double,
        generation: Int,
        currentTolerance: Double,
        lyricTolerance: Double,
        force: Bool = false
    ) -> Bool {
        guard let decision = PlaybackClockSnapshotPolicy.decision(
            observedTime: time,
            currentTime: currentTime,
            lyricTime: lyricTime,
            currentTolerance: currentTolerance,
            lyricTolerance: lyricTolerance,
            force: force,
            pendingSeek: pendingTimelineSeek,
            generation: generation,
            now: Date(),
            mediaKind: playbackTimelineMediaKind
        ) else { return false }

        guard case let .apply(snapshot) = decision else {
            return false
        }

        pendingTimelineSeek = snapshot.pendingSeek
        let update = snapshot.clockUpdate
        var changed = false
        if update.didChangeCurrentTime {
            currentTime = update.currentTime
            changed = true
        }
        if update.didChangeLyricTime {
            lyricTime = update.lyricTime
            changed = true
        }
        if let settledState = snapshot.settledSeekState {
            seekState = settledState
            scheduleSeekStateClear(revision: settledState.revision)
            spectrumSuppressedDuringSeek = false
            changed = true
        }
        return changed
    }

    private func scheduleSeekStateClear(revision: Int) {
        clearSeekStateTask?.cancel()
        spectrumSuppressedDuringSeek = false
        clearSeekStateTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 900_000_000) } catch { return }
            guard let self,
                  self.seekState?.revision == revision,
                  self.seekState?.phase == .settled else { return }
            self.seekState = nil
            self.clearSeekStateTask = nil
        }
    }

    private func reissuePendingSeekIfNeeded(
        observedTime: Double,
        generation: Int,
        musicPlaybackEngine: MusicPlaybackEngine? = nil,
        videoPlaybackEngine: VideoPlaybackEngine? = nil
    ) {
        guard let intent = PlaybackSeekCommandPolicy.reissueIntent(
            pending: pendingTimelineSeek,
            observedTime: observedTime,
            generation: generation,
            now: Date(),
            mediaKind: playbackTimelineMediaKind
        ) else { return }
        pendingTimelineSeek = intent.pending

        if let musicPlaybackEngine {
            musicPlaybackEngine.seek(to: intent.targetTime) { _ in }
        } else if let videoPlaybackEngine {
            try? videoPlaybackEngine.seek(toMpvTime: mpvTimelineTime(for: intent.targetTime), precision: .exact)
        }
    }

    func switchVideoQuality(to option: VideoStreamQualityOption) {
        guard item?.type != .music,
              let libMpvClient,
              let videoPlaybackEngine else { return }
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
        resetVideoSnapshotDates()
        deferredTrackRefreshTask?.cancel()
        deferredTrackRefreshTask = nil
        do {
            baseVideoFilter = nil
            rebuildVideoFilterChain(to: libMpvClient)
            try videoPlaybackEngine.loadReplacing(
                path: targetURL,
                startTime: option.isOriginal && resumeTime > 1 ? resumeTime : nil
            )
            videoPlaybackEngine.setVolume(volume, boost: volumeBoost)
            videoPlaybackEngine.setPlaybackRate(playbackRate)
            applyVideoAdjustments(to: libMpvClient)
            if option.isOriginal, resumeTime > 1 {
                enforceQualityResumeTime(resumeTime, for: option)
            }
            videoPlaybackEngine.setPaused(!wasPlaying)
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
        guard let libMpvClient, let videoPlaybackEngine else { return }
        let clampedTarget = PlaybackTimelinePolicy.clampedTime(target, duration: duration)
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
        resetVideoSnapshotDates()
        deferredTrackRefreshTask?.cancel()
        deferredTrackRefreshTask = nil
        do {
            try videoPlaybackEngine.loadReplacing(path: targetURL, startTime: nil)
            videoPlaybackEngine.setVolume(volume, boost: volumeBoost)
            videoPlaybackEngine.setPlaybackRate(playbackRate)
            applyVideoAdjustments(to: libMpvClient)
            videoPlaybackEngine.setPaused(!wasPlaying)
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
                      let videoPlaybackEngine = self.videoPlaybackEngine else { return }
                if self.currentTime >= resumeTime - 0.75 {
                    return
                }
                try? videoPlaybackEngine.seek(toMpvTime: resumeTime, precision: .keyframes)
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
        if let videoTrackSelectionEngine {
            videoTrackSelectionEngine.enableAutoSubtitle()
            subtitleAutoLoadEnabled = true
            scheduleVideoSnapshotRead(forceTrackRefresh: true)
            return
        }
    }

    func disableSubtitle() {
        if let libMpvClient, let videoTrackSelectionEngine {
            videoTrackSelectionEngine.disableSubtitle()
            didApplyTrackPreference = true
            if let item { TrackPreferenceStore.setSubtitle(.off, for: item) }
            markPrimarySubtitleSelection(nil)
            scheduleDeferredTrackListRefresh(from: libMpvClient)
            return
        }
    }

    func toggleSubtitleVisibility() {
        if let videoTrackSelectionEngine {
            videoTrackSelectionEngine.toggleSubtitleVisibility()
            return
        }
    }

    func refreshVideoTrackMetadata() {
        guard libMpvClient != nil else { return }
        scheduleVideoSnapshotRead(forceTrackRefresh: true)
    }

    func cycleSubtitle() {
        if let videoTrackSelectionEngine {
            videoTrackSelectionEngine.cycleSubtitle()
            scheduleVideoSnapshotRead(forceTrackRefresh: true)
            return
        }
    }

    func addExternalSubtitle(path: String?) {
        guard let path else { return }
        if let videoTrackSelectionEngine {
            videoTrackSelectionEngine.addExternalSubtitle(path: path)
            subtitleAutoLoadEnabled = true
            scheduleVideoSnapshotRead(forceTrackRefresh: true)
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
        if let libMpvClient, let videoTrackSelectionEngine {
            videoTrackSelectionEngine.selectSubtitleTrack(id)
            didApplyTrackPreference = true
            if let item, let language = subtitleTracks.first(where: { $0.id == id })?.language {
                TrackPreferenceStore.setSubtitle(.language(language), for: item)
            }
            markPrimarySubtitleSelection(id)
            scheduleDeferredTrackListRefresh(from: libMpvClient)
            return
        }
    }

    /// 选择第二字幕轨道（mpv `secondary-sid`，双语对照），nil 表示关闭。
    func selectSecondarySubtitleTrack(_ id: Int?) {
        guard let libMpvClient, let videoTrackSelectionEngine else { return }
        videoTrackSelectionEngine.selectSecondarySubtitleTrack(id)
        markSecondarySubtitleSelection(id)
        scheduleDeferredTrackListRefresh(from: libMpvClient)
    }

    /// 刷新音频输出设备列表与当前选中设备（mpv `audio-device-list` / `audio-device`）。
    func refreshAudioDevices() {
        guard let videoAudioDeviceReader else {
            audioDevices = []
            return
        }
        let snapshot = videoAudioDeviceReader.readSnapshot()
        selectedAudioDeviceName = snapshot.selectedDeviceName
        if audioDevices != snapshot.devices {
            audioDevices = snapshot.devices
        }
    }

    func selectAudioDevice(_ name: String) {
        guard let videoTrackSelectionEngine else { return }
        selectedAudioDeviceName = name
        videoTrackSelectionEngine.selectAudioDevice(name)
    }

    func cycleAudioTrack() {
        if let videoTrackSelectionEngine {
            videoTrackSelectionEngine.cycleAudioTrack()
            scheduleVideoSnapshotRead(forceTrackRefresh: true)
            return
        }
    }

    func selectDefaultAudioTrack() {
        if let libMpvClient, let videoTrackSelectionEngine {
            videoTrackSelectionEngine.selectDefaultAudioTrack()
            markAudioTrackSelection(nil)
            scheduleDeferredTrackListRefresh(from: libMpvClient)
            return
        }
    }

    func selectAudioTrack(_ id: Int) {
        if let libMpvClient, let videoTrackSelectionEngine {
            videoTrackSelectionEngine.selectAudioTrack(id)
            didApplyTrackPreference = true
            if let item, let language = audioTracks.first(where: { $0.id == id })?.language {
                TrackPreferenceStore.setAudioLanguage(language, for: item)
            }
            markAudioTrackSelection(id)
            scheduleDeferredTrackListRefresh(from: libMpvClient)
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
        videoFrameCommandEngine?.stepFrame(backward: backward)
    }

    func captureCurrentVideoFrame(title: String, mode: VideoScreenshotMode) throws -> URL {
        guard let videoFrameCommandEngine else {
            throw PlayerScreenshotError.unavailable
        }
        let folder = try Self.screenshotDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let targetURL = folder.appendingPathComponent(Self.screenshotFilename(title: title))
        do {
            try videoFrameCommandEngine.captureCurrentFrame(to: targetURL, mode: mode)
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
        if audioPlayer != nil {
            musicPlaybackEngine?.pause()
            audioLocalMirrorPlayer?.pause()
            audioRouteProxyPlayer?.pause()
            isPlaying = false
            updateSystemNowPlaying()
            return
        }
        if let videoPlaybackEngine {
            videoPlaybackEngine.setPaused(true)
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

    private func stopMpvSnapshotReader() {
        mpvSnapshotReadInFlight = false
        pendingForcedTrackSnapshot = false
        mpvSnapshotReader?.invalidateAndDrain()
        mpvSnapshotReader = nil
    }

    private func resetVideoSnapshotDates() {
        lastTrackRefreshDate = .distantPast
        lastDurationSnapshotDate = .distantPast
        lastVideoAspectSnapshotDate = .distantPast
        lastBufferingSnapshotDate = .distantPast
        lastChapterSnapshotDate = .distantPast
        trackSnapshotRefreshCount = 0
        chapterSnapshotRefreshCount = 0
    }

    func teardown() {
        playbackGeneration += 1
        timer?.invalidate()
        timer = nil
        initialRedrawTask?.cancel()
        initialRedrawTask = nil
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        musicOutputRecoveryTask?.cancel()
        musicOutputRecoveryTask = nil
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
        removeAudioStallRecovery()
        currentAudioSourceIsNetwork = false
        spectrumSuppressedDuringSeek = false
        audioRouteRefreshTask?.cancel()
        audioRouteRefreshTask = nil
        stopAudioLocalMirror()
        clearAudioRouteProxy()
        musicPlaybackEngine?.pause()
        audioPlayer = nil
        musicPlaybackEngine = nil
        clearVideoRouteProxy()
        stopMpvSnapshotReader()
        videoPlaybackEngine?.stopPlayback()
        // 必须在 libMpvClient 释放（连带释放渲染上下文）之前排空 Metal 独立渲染队列，
        // 否则队列里还在跑的渲染调用可能访问已释放的上下文（见 installRenderHandle 文档）。
        renderView?.installRenderHandle(nil)
        videoAudioDeviceReader = nil
        videoLoopCommandEngine = nil
        videoFrameCommandEngine = nil
        videoTrackSelectionEngine = nil
        videoPlaybackEngine = nil
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
        resetVideoSnapshotDates()
        deferredTrackRefreshTask?.cancel()
        deferredTrackRefreshTask = nil
        stopSecurityScopedResource()
        SystemNowPlayingCenter.clear()
    }

    private func fail(_ message: String) {
        playbackGeneration += 1
        initialRedrawTask?.cancel()
        initialRedrawTask = nil
        audioTransitionTask?.cancel()
        audioTransitionTask = nil
        musicOutputRecoveryTask?.cancel()
        musicOutputRecoveryTask = nil
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
        removeAudioStallRecovery()
        currentAudioSourceIsNetwork = false
        spectrumSuppressedDuringSeek = false
        audioRouteRefreshTask?.cancel()
        audioRouteRefreshTask = nil
        stopAudioLocalMirror()
        clearAudioRouteProxy()
        musicPlaybackEngine?.pause()
        audioPlayer = nil
        musicPlaybackEngine = nil
        clearVideoRouteProxy()
        stopMpvSnapshotReader()
        // 同上：先排空 Metal 独立渲染队列再释放 libMpvClient。
        renderView?.installRenderHandle(nil)
        videoAudioDeviceReader = nil
        videoLoopCommandEngine = nil
        videoFrameCommandEngine = nil
        videoTrackSelectionEngine = nil
        videoPlaybackEngine = nil
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
        resetVideoSnapshotDates()
        deferredTrackRefreshTask?.cancel()
        deferredTrackRefreshTask = nil
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

    private func scheduleVideoSnapshotRead(forceTrackRefresh: Bool = false) {
        guard let reader = mpvSnapshotReader else { return }
        if forceTrackRefresh {
            pendingForcedTrackSnapshot = true
        }
        guard !mpvSnapshotReadInFlight else { return }

        let now = Date()
        let includeDuration = duration <= 0 ||
            now.timeIntervalSince(lastDurationSnapshotDate) > 2.0
        let includeAspect = !hasVideoFrame ||
            now.timeIntervalSince(lastVideoAspectSnapshotDate) > 2.0
        let includeBuffering = isBuffering ||
            item?.isRemoteResource == true ||
            statusMessage?.hasPrefix("正在切换到 ") == true ||
            statusMessage?.hasPrefix("正在定位到 ") == true ||
            now.timeIntervalSince(lastBufferingSnapshotDate) > 1.0
        let forceTracks = pendingForcedTrackSnapshot
        let includeTracks = forceTracks ||
            now.timeIntervalSince(lastTrackRefreshDate) > periodicTrackRefreshInterval()
        let includeChapters = includeTracks && shouldIncludeChapterSnapshot(now: now)
        if includeDuration {
            lastDurationSnapshotDate = now
        }
        if includeAspect {
            lastVideoAspectSnapshotDate = now
        }
        if includeBuffering {
            lastBufferingSnapshotDate = now
        }
        if includeTracks {
            lastTrackRefreshDate = now
            trackSnapshotRefreshCount += 1
        }
        if includeChapters {
            lastChapterSnapshotDate = now
            chapterSnapshotRefreshCount += 1
        }
        pendingForcedTrackSnapshot = false
        mpvSnapshotReadInFlight = true
        let request = MpvVideoSnapshotRequest(
            includeDuration: includeDuration,
            includeAspect: includeAspect,
            includeBuffering: includeBuffering,
            includeTracks: includeTracks,
            includeChapters: includeChapters
        )
        let generation = playbackGeneration
        let timelineOffset = playbackTimelineOffset
        reader.read(request: request, timelineOffset: timelineOffset) { [weak self, weak reader] snapshot in
            guard let self else { return }
            self.mpvSnapshotReadInFlight = false
            guard self.playbackGeneration == generation,
                  let reader,
                  self.mpvSnapshotReader === reader,
                  self.libMpvClient != nil else { return }
            self.applyVideoSnapshot(snapshot)
            if self.pendingForcedTrackSnapshot {
                self.scheduleVideoSnapshotRead()
            }
        }
    }

    private func applyVideoSnapshot(_ snapshot: MpvVideoSnapshot) {
        if let time = snapshot.playbackTime {
            _ = applyPlaybackClock(
                time,
                generation: playbackGeneration,
                currentTolerance: 0.08,
                lyricTolerance: 0.035
            )
        }
        if let duration = snapshot.duration, duration > 0 {
            let logicalDuration = logicalDuration(fromPlaybackDuration: duration)
            if abs(self.duration - logicalDuration) > 0.05 {
                self.duration = logicalDuration
            }
        }
        if let paused = snapshot.paused, isPlaying == paused {
            isPlaying = !paused
        }
        if let eofReached = snapshot.eofReached {
            if eofReached, !didNotifyPlaybackEnd, duration > 0 {
                didNotifyPlaybackEnd = true
                onPlaybackFinished?()
            } else if !eofReached, didNotifyPlaybackEnd {
                didNotifyPlaybackEnd = false
            }
        }
        if let aspect = snapshot.aspect,
           applyVideoAspectSnapshot(aspect) {
            hasVideoFrame = true
        }
        if let buffering = snapshot.buffering {
            applyBufferingSnapshot(buffering)
        }
        if statusMessage?.hasPrefix("正在切换到 ") == true,
           !isBuffering {
            statusMessage = nil
        }
        if let chapters = snapshot.chapters, self.chapters != chapters {
            self.chapters = chapters
        }
        if let tracks = snapshot.tracks {
            applyTrackSnapshot(tracks: tracks, secondarySubtitleID: snapshot.secondarySubtitleID)
        }
        reportPlayback(.progress)
    }

    private func applyVideoAspectSnapshot(_ snapshot: MpvVideoAspectSnapshot) -> Bool {
        let normalizedRotation = ((snapshot.sourceRotation % 360) + 360) % 360

        let displayAspect = snapshot.displayWidth.flatMap { width in
            snapshot.displayHeight.flatMap { height in
                width > 0 && height > 0 ? CGFloat(width / height) : nil
            }
        }
        let rotatedCodedAspect = snapshot.codedWidth.flatMap { width in
            snapshot.codedHeight.flatMap { height -> CGFloat? in
                guard width > 0, height > 0 else { return nil }
                let swapsAxes = normalizedRotation == 90 || normalizedRotation == 270
                return swapsAxes ? CGFloat(height / width) : CGFloat(width / height)
            }
        }
        let aspect: CGFloat?
        if let displayAspect, let rotatedCodedAspect,
           normalizedRotation == 90 || normalizedRotation == 270,
           abs(displayAspect - rotatedCodedAspect) > 0.04 {
            aspect = rotatedCodedAspect
        } else {
            aspect = displayAspect ?? rotatedCodedAspect
        }
        guard let aspect, aspect.isFinite, aspect > 0 else { return false }
        if let current = videoAspectRatio, abs(current - aspect) < 0.01 {
            return true
        }
        videoAspectRatio = aspect
        return true
    }

    private func applyBufferingSnapshot(_ snapshot: MpvVideoBufferingSnapshot) {
        let isNetwork = item?.isRemoteResource == true
        let loading = isNetwork && isReady && currentTime < 0.35 && ((snapshot.cacheProgress ?? 100) < 99)
        let buffering = snapshot.pausedForCache || loading
        let progress: Double?
        if let cacheProgress = snapshot.cacheProgress, cacheProgress.isFinite {
            progress = min(max(cacheProgress, 0), 100)
        } else {
            progress = buffering ? 0 : nil
        }
        updateBuffering(active: buffering, progress: progress)
    }

    private func applyTrackSnapshot(tracks: [MpvTrack], secondarySubtitleID: Int?) {
        let audio = tracks.filter { $0.type == .audio }
        let subtitles = tracks.filter { $0.type == .subtitle }
        if audioTracks != audio {
            audioTracks = audio
        }
        if subtitleTracks != subtitles {
            subtitleTracks = subtitles
        }
        if self.secondarySubtitleID != secondarySubtitleID {
            self.secondarySubtitleID = secondarySubtitleID
        }
        if let client = libMpvClient {
            applyTrackPreferenceIfNeeded(client: client)
        }
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
                if self.libMpvClient != nil {
                    self.scheduleVideoSnapshotRead()
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
              // 拖动中肉眼不可见，零观感牺牲。拖动进度条/seek 期间同样跳过，避免与 seek 解码抢 NAS I/O 造成转圈。
              !spectrumSuppressedDuringInteraction,
              item?.type == .music,
              item?.isRemoteResource != true,
              // 网络挂载盘：频谱每 0.34s 重开远端文件解码会持续占用 NAS I/O，
              // 与播放/切歌抢带宽。网络源直接跳过频谱（装饰性，柱状定格无感）。
              !currentAudioSourceIsNetwork,
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
                self.renderView?.requestRedraw()
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
            self.renderView?.requestRedraw()
        }
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

    private func periodicTrackRefreshInterval() -> TimeInterval {
        if trackSnapshotRefreshCount < 12 {
            return 0.5
        }
        if !didApplyTrackPreference {
            return 10.0
        }
        return 30.0
    }

    private func shouldIncludeChapterSnapshot(now: Date) -> Bool {
        if chapterSnapshotRefreshCount < 3 {
            return true
        }
        return now.timeIntervalSince(lastChapterSnapshotDate) > 30.0
    }

    private func scheduleDeferredTrackListRefresh(from client: LibMpvClient) {
        deferredTrackRefreshTask?.cancel()
        let generation = playbackGeneration
        deferredTrackRefreshTask = Task { @MainActor [weak self, weak client] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self,
                  let client,
                  self.playbackGeneration == generation,
                  self.libMpvClient === client else { return }
            self.scheduleVideoSnapshotRead(forceTrackRefresh: true)
            self.deferredTrackRefreshTask = nil
        }
    }

    private func markAudioTrackSelection(_ id: Int?) {
        let next = audioTracks.map { track in
            track.withSelection(track.id == id)
        }
        if next != audioTracks {
            audioTracks = next
        }
    }

    private func markPrimarySubtitleSelection(_ id: Int?) {
        if secondarySubtitleID == id {
            secondarySubtitleID = nil
        }
        let next = subtitleTracks.map { track in
            let selected = track.id == id || track.id == secondarySubtitleID
            return track.withSelection(selected)
        }
        if next != subtitleTracks {
            subtitleTracks = next
        }
    }

    private func markSecondarySubtitleSelection(_ id: Int?) {
        let previousSecondaryID = secondarySubtitleID
        secondarySubtitleID = id
        let next = subtitleTracks.map { track in
            let wasPreviousSecondary = track.id == previousSecondaryID
            let selected = (track.isSelected && !wasPreviousSecondary) || track.id == id
            return track.withSelection(selected)
        }
        if next != subtitleTracks {
            subtitleTracks = next
        }
    }

    /// A7：轨道列表就绪后，套用同剧集记忆的音轨/字幕语言（仅一次，且不覆盖用户手动选择）。
    private func applyTrackPreferenceIfNeeded(client: LibMpvClient) {
        guard !didApplyTrackPreference, let item else { return }
        guard !audioTracks.isEmpty || !subtitleTracks.isEmpty else { return }
        guard let videoTrackSelectionEngine else { return }
        didApplyTrackPreference = true
        var didIssueTrackCommand = false

        if let language = TrackPreferenceStore.audioLanguage(for: item),
           let track = TrackLanguageMatcher.bestTrack(in: audioTracks, matching: language),
           !track.isSelected {
            videoTrackSelectionEngine.selectAudioTrack(track.id)
            markAudioTrackSelection(track.id)
            didIssueTrackCommand = true
        }

        if let preference = TrackPreferenceStore.subtitle(for: item) {
            switch preference {
            case .off:
                videoTrackSelectionEngine.disableSubtitle()
                markPrimarySubtitleSelection(nil)
                didIssueTrackCommand = true
            case .language(let language):
                if let track = TrackLanguageMatcher.bestTrack(in: subtitleTracks, matching: language),
                   !track.isSelected {
                    videoTrackSelectionEngine.selectSubtitleTrack(track.id)
                    markPrimarySubtitleSelection(track.id)
                    didIssueTrackCommand = true
                }
            }
        } else if let track = TrackLanguageMatcher.bestTrack(in: subtitleTracks, matching: preferredSubtitleLanguage),
                  !track.isSelected {
            videoTrackSelectionEngine.selectSubtitleTrack(track.id)
            markPrimarySubtitleSelection(track.id)
            didIssueTrackCommand = true
        }

        if didIssueTrackCommand {
            scheduleDeferredTrackListRefresh(from: client)
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
