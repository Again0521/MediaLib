import Combine
import Foundation
import MediaLibCore

// 从 MusicPlayerView.swift 物理拆出（零行为变化）：迷你（收起态）播放条的进度/传输投影观察者。
// 与展开页观察者同样的高频刷新隔离机制：订阅 MpvPlayerController 的 @Published，按 Equatable 小状态去重。
// 复用 MediaLibCore 的 PlaybackClockPolicy，避免迷你条理解 seek phase。
// MpvPlayerController 在 App 层，PlaybackSeekState 已下沉至 MediaLibCore。仅搬位置，不改去重/换算语义。
struct MusicMiniCollapsedProgressState: Equatable {
    var progress: Double
    var progressBucket: Int
    var isEnabled: Bool
}

@MainActor
final class MusicMiniCollapsedProgressObserver: ObservableObject {
    @Published private(set) var state: MusicMiniCollapsedProgressState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest3(
            controller.$currentTime,
            controller.$duration,
            controller.$seekState
        ).sink { [weak self] currentTime, duration, seekState in
            guard let self else { return }
            let next = Self.makeState(currentTime: currentTime, duration: duration, seekState: seekState)
            guard next != self.state else { return }
            self.state = next
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicMiniCollapsedProgressState {
        makeState(currentTime: controller.currentTime, duration: controller.duration, seekState: controller.seekState)
    }

    private static func makeState(currentTime: Double, duration: Double, seekState: PlaybackSeekState?) -> MusicMiniCollapsedProgressState {
        let displayTime = PlaybackClockPolicy.displayTime(
            currentTime: currentTime,
            seekState: seekState
        )
        let progress: Double
        if duration.isFinite, duration > 0, displayTime.isFinite {
            progress = min(max(displayTime / duration, 0), 1)
        } else {
            progress = 0
        }
        return MusicMiniCollapsedProgressState(
            progress: progress,
            progressBucket: Int((progress * 360).rounded()),
            isEnabled: duration > 0
        )
    }
}

struct MusicMiniTransportState: Equatable {
    let isPlaying: Bool
    let canControl: Bool
    let isPreparing: Bool
}

@MainActor
final class MusicMiniTransportStateObserver: ObservableObject {
    @Published private(set) var state: MusicMiniTransportState
    private weak var controller: MpvPlayerController?
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        self.controller = controller
        state = Self.makeState(from: controller)
        cancellable = Publishers.CombineLatest3(
            controller.$isPlaying,
            controller.$isPreparing,
            controller.$errorMessage
        ).sink { [weak self] isPlaying, isPreparing, errorMessage in
            guard let self else { return }
            let nextState = MusicMiniTransportState(
                isPlaying: isPlaying,
                canControl: errorMessage == nil && !isPreparing,
                isPreparing: isPreparing
            )
            guard nextState != self.state else { return }
            self.state = nextState
        }
    }

    private static func makeState(from controller: MpvPlayerController) -> MusicMiniTransportState {
        MusicMiniTransportState(
            isPlaying: controller.isPlaying,
            canControl: controller.canControl,
            isPreparing: controller.isPreparing
        )
    }
}
