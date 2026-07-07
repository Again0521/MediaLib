import Combine
import Foundation
import MediaLibCore   // TimedLyricLine 等已下沉至 Core

// 从 MusicPlayerView.swift 物理拆出（零行为变化）：歌词「当前行 / 逐字进度」投影观察者及其状态类型。
// 这是「拖动后歌词正确落点 + 逐字卡拉OK」的核心隔离逻辑：订阅 MpvPlayerController 的 $lyricTime/$seekState，
// 经 TimedLyricLine.playbackPosition/progress 算出 Equatable 小状态后去重，只驱动歌词叶子视图。
// 仅搬位置，去重/seek 相位/桶量化语义一字未改。原为 MusicPlayerView.swift 内的 private 类型，拆出后改为模块内部可见；
// 消费它们的视图（MusicActiveKaraokeLyricLine / KaraokeLyricLine 等）仍在 MusicPlayerView，跨文件引用安全。
// TimedLyricLine / PlaybackSeekState 已下沉至 MediaLibCore，MpvPlayerController 仍在 App 层。
enum LyricLineHighlightMode: Equatable {
    case normal
    case fullLineDuringSeek
}

struct MusicLyricRenderState: Equatable {
    var activeLineIndex: Int?
    var seekState: MusicLyricSeekRenderState?

    var isSeekPreviewActive: Bool {
        guard let phase = seekState?.phase else { return false }
        return phase == .scrubbing
    }
}

struct MusicLyricSeekRenderState {
    var revision: Int
    var phase: PlaybackSeekState.Phase
    var targetLineIndex: Int?
    var presentationTime: Double
}

extension MusicLyricSeekRenderState: Equatable {
    static func == (lhs: MusicLyricSeekRenderState, rhs: MusicLyricSeekRenderState) -> Bool {
        lhs.revision == rhs.revision &&
        lhs.phase == rhs.phase &&
        lhs.targetLineIndex == rhs.targetLineIndex
    }
}

@MainActor
final class MusicLyricRenderObserver: ObservableObject {
    @Published private(set) var state: MusicLyricRenderState
    private weak var controller: MpvPlayerController?
    private var timedLyrics: [TimedLyricLine]
    private var cancellable: AnyCancellable?
    private(set) var latestLyricTime: Double
    private(set) var latestSeekState: PlaybackSeekState?

    init(controller: MpvPlayerController, timedLyrics: [TimedLyricLine]) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        latestLyricTime = controller.lyricTime
        latestSeekState = controller.seekState
        state = Self.makeState(
            lyricTime: controller.lyricTime,
            seekState: controller.seekState,
            timedLyrics: timedLyrics
        )
        cancellable = Publishers.CombineLatest(
            controller.$lyricTime,
            controller.$seekState
        ).sink { [weak self] lyricTime, seekState in
            guard let self else { return }
            latestLyricTime = lyricTime
            latestSeekState = seekState
            let nextState = Self.makeState(
                lyricTime: lyricTime,
                seekState: seekState,
                timedLyrics: self.timedLyrics
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    func updateTimedLyrics(_ timedLyrics: [TimedLyricLine]) {
        self.timedLyrics = timedLyrics
        let nextState = Self.makeState(
            lyricTime: latestLyricTime,
            seekState: latestSeekState,
            timedLyrics: timedLyrics
        )
        if nextState != state {
            state = nextState
        }
    }

    private static func makeState(
        lyricTime: Double,
        seekState: PlaybackSeekState?,
        timedLyrics: [TimedLyricLine]
    ) -> MusicLyricRenderState {
        let isSeekPreviewActive: Bool
        if let phase = seekState?.phase {
            isSeekPreviewActive = phase == .scrubbing
        } else {
            isSeekPreviewActive = false
        }
        let selectionTime = isSeekPreviewActive ? (seekState?.presentationTime ?? lyricTime) : max(lyricTime, 0)
        let activeLineIndex = TimedLyricLine.playbackPosition(in: timedLyrics, at: selectionTime)?.lineIndex
        let seekRenderState = seekState.map { state in
            let renderTime: Double
            switch state.phase {
            case .scrubbing:
                renderTime = state.presentationTime
            case .seeking:
                renderTime = max(lyricTime, 0)
            case .settled:
                renderTime = state.resolvedTime ?? max(lyricTime, 0)
            }
            let targetLineIndex = state.phase == .seeking
                ? nil
                : TimedLyricLine.playbackPosition(in: timedLyrics, at: renderTime)?.lineIndex
            return MusicLyricSeekRenderState(
                revision: state.revision,
                phase: state.phase,
                targetLineIndex: targetLineIndex,
                presentationTime: renderTime
            )
        }
        return MusicLyricRenderState(
            activeLineIndex: activeLineIndex,
            seekState: seekRenderState
        )
    }
}

struct MusicLyricActiveLineProgressState: Equatable {
    var displayTime: Double
    var progress: Double
    var wordProgressBucket: Int
    var highlightMode: LyricLineHighlightMode

    static func == (lhs: MusicLyricActiveLineProgressState, rhs: MusicLyricActiveLineProgressState) -> Bool {
        lhs.wordProgressBucket == rhs.wordProgressBucket &&
        lhs.highlightMode == rhs.highlightMode
    }
}

@MainActor
final class MusicLyricActiveLineProgressObserver: ObservableObject {
    @Published private(set) var state: MusicLyricActiveLineProgressState
    private weak var controller: MpvPlayerController?
    private var timedLyrics: [TimedLyricLine]
    private var index: Int
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController, timedLyrics: [TimedLyricLine], index: Int) {
        self.controller = controller
        self.timedLyrics = timedLyrics
        self.index = index
        state = Self.makeState(
            timedLyrics: timedLyrics,
            index: index,
            lyricTime: controller.lyricTime,
            seekState: controller.seekState
        )
        cancellable = Publishers.CombineLatest(
            controller.$lyricTime,
            controller.$seekState
        ).sink { [weak self] lyricTime, seekState in
            guard let self else { return }
            let nextState = Self.makeState(
                timedLyrics: self.timedLyrics,
                index: self.index,
                lyricTime: lyricTime,
                seekState: seekState
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    func configure(timedLyrics: [TimedLyricLine], index: Int) {
        self.timedLyrics = timedLyrics
        self.index = index
        guard let controller else { return }
        let nextState = Self.makeState(
            timedLyrics: timedLyrics,
            index: index,
            lyricTime: controller.lyricTime,
            seekState: controller.seekState
        )
        state = nextState
    }

    private static func makeState(
        timedLyrics: [TimedLyricLine],
        index: Int,
        lyricTime: Double,
        seekState: PlaybackSeekState?
    ) -> MusicLyricActiveLineProgressState {
        let isSeekPreviewActive: Bool
        if let phase = seekState?.phase {
            isSeekPreviewActive = phase == .scrubbing
        } else {
            isSeekPreviewActive = false
        }
        let displayTime = isSeekPreviewActive ? (seekState?.presentationTime ?? lyricTime) : lyricTime
        let progress = timedLyrics.indices.contains(index)
            ? TimedLyricLine.progress(in: timedLyrics, index: index, currentTime: displayTime)
            : 0
        let bucket = Int((min(max(progress, 0), 1) * 180).rounded())
        let highlightMode: LyricLineHighlightMode = isSeekPreviewActive ? .fullLineDuringSeek : .normal
        return MusicLyricActiveLineProgressState(
            displayTime: displayTime,
            progress: progress,
            wordProgressBucket: bucket,
            highlightMode: highlightMode
        )
    }
}
