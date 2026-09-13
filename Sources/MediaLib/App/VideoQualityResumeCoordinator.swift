import Foundation

/// One original-quality stream load and the timeline position it must resume.
/// A new load may reuse the same quality ID, so the full stream identity matters.
struct VideoQualityResumeRequest: Equatable {
    let playbackGeneration: Int
    let optionID: String
    let playbackURL: String
    let targetTime: Double
    let engineIdentity: ObjectIdentifier
}

/// Owns the bounded seek retries after an original-quality stream replacement.
/// Only the active request may issue a command; the player still owns its engine.
@MainActor
final class VideoQualityResumeCoordinator {
    private var task: Task<Void, Never>?
    private var revision = 0
    private(set) var pendingRequest: VideoQualityResumeRequest?

    deinit {
        task?.cancel()
    }

    func start(
        _ request: VideoQualityResumeRequest,
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        isCurrent: @escaping @MainActor () -> Bool,
        observedTime: @escaping @MainActor () -> Double?,
        seek: @escaping @MainActor (Double) -> Void
    ) {
        cancel()
        let requestRevision = revision
        pendingRequest = request
        task = Task { @MainActor [weak self] in
            defer { self?.finish(revision: requestRevision) }
            for attempt in 0..<8 {
                do {
                    try await sleep(UInt64(120_000_000 + attempt * 55_000_000))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.revision == requestRevision,
                      isCurrent(),
                      let actualTime = observedTime(),
                      actualTime.isFinite else { return }
                if actualTime >= request.targetTime - 0.75 { return }
                seek(request.targetTime)
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
