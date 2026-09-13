import Foundation

/// Identifies an active music load, including a replacement requested while
/// the same player generation is still preparing an earlier track.
struct MusicPlaybackLoadRequest: Equatable {
    let itemID: String
    let path: String
    let playbackGeneration: Int
    let playerIdentity: ObjectIdentifier?
}

/// Owns preparation of the actively requested song. Unlike speculative
/// preloading, only the current request may surface a preparation failure.
@MainActor
final class MusicPlaybackLoadCoordinator<Prepared> {
    private var task: Task<Void, Never>?
    private var revision = 0
    private(set) var pendingRequest: MusicPlaybackLoadRequest?

    deinit {
        task?.cancel()
    }

    func start(
        _ request: MusicPlaybackLoadRequest,
        prepare: @escaping @MainActor () async throws -> Prepared,
        apply: @escaping @MainActor (Prepared) -> Void,
        fail: @escaping @MainActor (Error) -> Void
    ) {
        cancel()
        let requestRevision = revision
        pendingRequest = request
        task = Task { @MainActor [weak self] in
            defer { self?.finish(revision: requestRevision) }
            do {
                let prepared = try await prepare()
                guard let self,
                      !Task.isCancelled,
                      self.revision == requestRevision else { return }
                apply(prepared)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.revision == requestRevision else { return }
                fail(error)
            }
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
        pendingRequest = nil
    }

    private func finish(revision: Int) {
        guard self.revision == revision else { return }
        task = nil
        pendingRequest = nil
    }
}
