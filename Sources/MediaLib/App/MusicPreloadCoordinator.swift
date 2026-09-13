import Foundation

/// The identity of one speculative next-track preparation. The player and
/// generation are part of the key so a reused item ID cannot cross sessions.
struct MusicPreloadRequest: Equatable {
    let currentItemID: String
    let nextItemID: String
    let nextPath: String
    let playbackGeneration: Int
    let playerIdentity: ObjectIdentifier
}

/// Owns only the pending preparation task and its freshness boundary.
/// AVQueuePlayer mutation and security-scoped file access stay with the player.
@MainActor
final class MusicPreloadCoordinator<Request: Equatable, Prepared> {
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var pendingRequest: Request?

    deinit {
        task?.cancel()
    }

    func start(
        _ request: Request,
        prepare: @escaping @MainActor () async throws -> Prepared,
        apply: @escaping @MainActor (Prepared) -> Void
    ) {
        guard pendingRequest != request else { return }
        generation &+= 1
        let requestGeneration = generation
        task?.cancel()
        pendingRequest = request
        task = Task { @MainActor [weak self] in
            defer { self?.finish(requestGeneration: requestGeneration) }
            do {
                let prepared = try await prepare()
                guard let self,
                      !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                apply(prepared)
            } catch {
                // Preloading is opportunistic. The active track remains usable.
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        pendingRequest = nil
    }

    private func finish(requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        task = nil
        pendingRequest = nil
    }
}
