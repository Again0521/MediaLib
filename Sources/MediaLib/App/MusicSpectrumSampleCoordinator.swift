import CoreGraphics
import Foundation

/// Owns one optional spectrum decode. Cancelling a track or view session makes
/// the slot immediately reusable, even if the old AVAssetReader finishes late.
@MainActor
final class MusicSpectrumSampleCoordinator {
    private var task: Task<Void, Never>?
    private var revision = 0

    var isSampling: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    func start(
        sample: @escaping @MainActor () async -> [CGFloat],
        apply: @escaping @MainActor ([CGFloat]) -> Void
    ) {
        guard task == nil else { return }
        revision &+= 1
        let sampleRevision = revision
        task = Task { @MainActor [weak self] in
            defer { self?.finish(revision: sampleRevision) }
            let bands = await sample()
            guard let self,
                  !Task.isCancelled,
                  self.revision == sampleRevision else { return }
            apply(bands)
        }
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
    }

    private func finish(revision: Int) {
        guard self.revision == revision else { return }
        task = nil
    }
}
