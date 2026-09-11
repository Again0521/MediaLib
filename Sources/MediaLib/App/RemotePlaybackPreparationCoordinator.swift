import Foundation
import MediaLibCore

/// 一次远程播放准备请求的全部不可变输入。
///
/// `sourceID` 同时是权限/生命周期边界：来源被删除时，属于该来源的在途请求必须失效。
struct RemotePlaybackPreparationRequest: Sendable, Equatable {
    let item: MediaItem
    let sourceID: String
    let preserveSelection: Bool
}

/// 只允许最新远程播放准备请求打开播放器。
///
/// 网络鉴权和 URL 刷新由调用者注入；本类型只拥有 pending task、generation 与来源级取消，
/// 不依赖 `AppState`、窗口或具体远程服务实现。
@MainActor
final class RemotePlaybackPreparationCoordinator {
    typealias Prepare = @MainActor @Sendable (RemotePlaybackPreparationRequest) async throws -> MediaItem

    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var pendingRequest: RemotePlaybackPreparationRequest?

    deinit {
        task?.cancel()
    }

    func start(
        _ request: RemotePlaybackPreparationRequest,
        prepare: @escaping Prepare,
        apply: @escaping @MainActor (MediaItem, RemotePlaybackPreparationRequest) -> Void,
        failure: @escaping @MainActor (Error, RemotePlaybackPreparationRequest) -> Void
    ) {
        generation += 1
        let requestGeneration = generation
        task?.cancel()
        pendingRequest = request
        task = Task { @MainActor [weak self] in
            do {
                let preparedItem = try await prepare(request)
                guard let self,
                      !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                self.finish(requestGeneration: requestGeneration)
                apply(preparedItem, request)
            } catch is CancellationError {
                self?.finish(requestGeneration: requestGeneration)
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.finish(requestGeneration: requestGeneration)
                failure(error, request)
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pendingRequest = nil
    }

    @discardableResult
    func cancel(sourceID: String) -> Bool {
        guard pendingRequest?.sourceID == sourceID else { return false }
        cancel()
        return true
    }

    private func finish(requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        task = nil
        pendingRequest = nil
    }
}
