import Foundation

public struct ScanProgressPublishPolicy: Sendable {
    public var minimumInterval: TimeInterval
    public var minimumItemCount: Int
    public var targetStepDivisor: Int

    private var lastPublishDate = Date.distantPast
    private var lastProcessedFiles = -1

    public init(
        minimumInterval: TimeInterval = 0.18,
        minimumItemCount: Int = 8,
        targetStepDivisor: Int = 220
    ) {
        self.minimumInterval = minimumInterval
        self.minimumItemCount = minimumItemCount
        self.targetStepDivisor = targetStepDivisor
    }

    public mutating func reset() {
        lastPublishDate = .distantPast
        lastProcessedFiles = -1
    }

    public mutating func shouldPublish(_ progress: ScanProgress, now: Date = Date()) -> Bool {
        let isTerminal = progress.status != "running" ||
            progress.errorMessage != nil ||
            progress.processedFiles >= progress.totalFiles
        let isFirst = lastProcessedFiles < 0 || progress.processedFiles == 0
        let divisor = max(targetStepDivisor, 1)
        let step = max(minimumItemCount, max(progress.totalFiles, 1) / divisor)
        let advancedEnough = progress.processedFiles - lastProcessedFiles >= step
        let waitedEnough = now.timeIntervalSince(lastPublishDate) >= minimumInterval

        guard isTerminal || isFirst || advancedEnough || waitedEnough else {
            return false
        }

        lastPublishDate = now
        lastProcessedFiles = progress.processedFiles
        return true
    }
}

public struct FractionalProgressPublishPolicy: Sendable {
    public var minimumInterval: TimeInterval
    public var minimumProgressStep: Double

    private var lastPublishDate = Date.distantPast
    private var lastProgress = -1.0

    public init(
        minimumInterval: TimeInterval = 0.18,
        minimumProgressStep: Double = 0.01
    ) {
        self.minimumInterval = minimumInterval
        self.minimumProgressStep = minimumProgressStep
    }

    public mutating func reset() {
        lastPublishDate = .distantPast
        lastProgress = -1
    }

    public mutating func shouldPublish(_ progress: Double, now: Date = Date()) -> Bool {
        let clamped = Self.clampedProgress(progress)
        let isTerminal = clamped >= 1
        let advancedEnough = clamped - lastProgress >= minimumProgressStep
        let waitedEnough = now.timeIntervalSince(lastPublishDate) >= minimumInterval
        guard isTerminal || advancedEnough || waitedEnough else { return false }
        lastProgress = clamped
        lastPublishDate = now
        return true
    }

    static func clampedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}
