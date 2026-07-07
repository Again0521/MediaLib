import Combine
import Foundation
import MediaLibCore

// 从 MusicPlayerView.swift 物理拆出（零行为变化）：音乐展开页的进度/音量/状态「投影观察者」。
// 它们订阅 MpvPlayerController 的高频 @Published，按 Equatable 小状态去重后只驱动对应叶子视图，
// 是高频刷新隔离的核心机制（勿改其去重/容差语义）。原为 MusicPlayerView.swift 内的 private 类型，
// 拆出后改为模块内部可见；seek 展示时间由 MediaLibCore 的 PlaybackClockPolicy 统一计算。
// MpvPlayerController 在 App 层，PlaybackSeekState 已下沉至 MediaLibCore。
struct MusicExpandedStatusState: Equatable {
    let errorMessage: String?
    let isPreparing: Bool
}

struct MusicExpandedProgressState: Equatable {
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let canControl: Bool
    let formattedCurrentTime: String
    let formattedDuration: String
}

@MainActor
final class MusicExpandedProgressStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedProgressState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest4(
            controller.$currentTime,
            controller.$duration,
            controller.$isPreparing,
            controller.$errorMessage
        )
        .combineLatest(Publishers.CombineLatest(controller.$isPlaying, controller.$seekState))
        .sink { [weak self] progressState, playbackState in
            guard let self else { return }
            let (currentTime, duration, isPreparing, errorMessage) = progressState
            let (isPlaying, seekState) = playbackState
            let nextState = Self.makeState(
                currentTime: currentTime,
                duration: duration,
                isPlaying: isPlaying,
                isPreparing: isPreparing,
                errorMessage: errorMessage,
                seekState: seekState
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedProgressState {
        makeState(
            currentTime: controller.currentTime,
            duration: controller.duration,
            isPlaying: controller.isPlaying,
            isPreparing: controller.isPreparing,
            errorMessage: controller.errorMessage,
            seekState: controller.seekState
        )
    }

    private static func makeState(
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        isPreparing: Bool,
        errorMessage: String?,
        seekState: PlaybackSeekState?
    ) -> MusicExpandedProgressState {
        let displayTime = PlaybackClockPolicy.displayTime(currentTime: currentTime, seekState: seekState)
        return MusicExpandedProgressState(
            currentTime: displayTime,
            duration: duration,
            isPlaying: isPlaying,
            canControl: errorMessage == nil && !isPreparing,
            formattedCurrentTime: formatTime(displayTime),
            formattedDuration: duration > 0 ? formatTime(duration) : "--:--"
        )
    }

    private static func formatTime(_ seconds: Double) -> String {
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

struct MusicExpandedVolumeState: Equatable {
    let volume: Float
    let canControl: Bool
}

@MainActor
final class MusicExpandedVolumeStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedVolumeState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest3(
            controller.$volume,
            controller.$isPreparing,
            controller.$errorMessage
        ).sink { [weak self] volume, isPreparing, errorMessage in
            guard let self else { return }
            let nextState = MusicExpandedVolumeState(
                volume: volume,
                canControl: errorMessage == nil && !isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedVolumeState {
        MusicExpandedVolumeState(
            volume: controller.volume,
            canControl: controller.canControl
        )
    }
}

@MainActor
final class MusicExpandedStatusStateObserver: ObservableObject {
    @Published private(set) var state: MusicExpandedStatusState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest(
            controller.$errorMessage,
            controller.$isPreparing
        ).sink { [weak self] errorMessage, isPreparing in
            guard let self else { return }
            let nextState = MusicExpandedStatusState(
                errorMessage: errorMessage,
                isPreparing: isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicExpandedStatusState {
        MusicExpandedStatusState(
            errorMessage: controller.errorMessage,
            isPreparing: controller.isPreparing
        )
    }
}
