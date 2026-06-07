import Foundation

enum VideoCacheDownloadControlError: LocalizedError {
    case cancelled
    case paused
    case invalidHTTPStatus(Int)
    case missingTemporaryFile

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "缓存任务已取消。"
        case .paused:
            return "缓存任务已暂停。"
        case .invalidHTTPStatus(let status):
            return "服务器返回 \(status)，缓存失败。"
        case .missingTemporaryFile:
            return "下载完成后没有找到临时文件。"
        }
    }
}

final class VideoCacheDownloadController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        let fraction: Double?
        let receivedBytes: Int64
        let expectedBytes: Int64
        let resumedBytes: Int64
    }

    private let lock = NSLock()
    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var progressHandler: (@Sendable (Progress) -> Void)?
    private var terminalError: Error?
    private var isPaused = false
    private var isCancelled = false
    private var resumedByteCount: Int64 = 0
    private var expectedByteCount: Int64 = -1
    private var lastProgress: Progress?

    override init() {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
    }

    func download(
        from remoteURL: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.progressHandler = progress
            self.terminalError = nil
            self.isPaused = false
            self.isCancelled = false
            let resumeData = self.resumeData
            if let resumeData {
                self.resumedByteCount = max(self.resumedByteCount, Self.resumeByteCount(from: resumeData), self.lastProgress?.receivedBytes ?? 0)
            } else {
                self.resumedByteCount = 0
                self.expectedByteCount = -1
                self.lastProgress = nil
            }
            let initialProgress = self.lastProgress
            let task: URLSessionDownloadTask
            if let resumeData {
                task = self.session.downloadTask(withResumeData: resumeData)
            } else {
                task = self.session.downloadTask(with: remoteURL)
            }
            self.activeTask = task
            lock.unlock()
            if let initialProgress {
                progress(initialProgress)
            }
            task.resume()
        }
    }

    func pause() {
        lock.lock()
        guard !isPaused, !isCancelled else {
            lock.unlock()
            return
        }
        isPaused = true
        terminalError = VideoCacheDownloadControlError.paused
        let task = activeTask
        activeTask = nil
        lock.unlock()

        task?.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            if let data {
                self.resumeData = data
                self.resumedByteCount = max(
                    self.resumedByteCount,
                    Self.resumeByteCount(from: data),
                    self.lastProgress?.receivedBytes ?? 0
                )
            }
            self.resumeContinuationIfNeeded(error: VideoCacheDownloadControlError.paused)
            self.lock.unlock()
        })
        if task == nil {
            lock.lock()
            resumeContinuationIfNeeded(error: VideoCacheDownloadControlError.paused)
            lock.unlock()
        }
    }

    func resume(from remoteURL: URL, progress: @escaping @Sendable (Progress) -> Void) async throws -> (URL, URLResponse) {
        try await download(from: remoteURL, progress: progress)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        isPaused = false
        resumeData = nil
        resumedByteCount = 0
        expectedByteCount = -1
        lastProgress = nil
        terminalError = VideoCacheDownloadControlError.cancelled
        let task = activeTask
        activeTask = nil
        lock.unlock()

        task?.cancel()
        lock.lock()
        resumeContinuationIfNeeded(error: VideoCacheDownloadControlError.cancelled)
        lock.unlock()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let baseBytes = max(resumedByteCount, 0)
        let reportedExpected = totalBytesExpectedToWrite
        let reportedWritten = max(totalBytesWritten, 0)
        let reportsAbsoluteBytes = baseBytes > 0 && reportedWritten >= baseBytes
        let cumulativeReceived = reportsAbsoluteBytes ? reportedWritten : baseBytes + reportedWritten
        let cumulativeExpected = Self.cumulativeExpectedBytes(
            reportedExpected: reportedExpected,
            baseBytes: baseBytes,
            cumulativeReceived: cumulativeReceived,
            previousExpected: expectedByteCount
        )
        if cumulativeExpected > 0 {
            expectedByteCount = cumulativeExpected
        }
        let progress = Progress(
            fraction: cumulativeExpected > 0
                ? Double(cumulativeReceived) / Double(cumulativeExpected)
                : nil,
            receivedBytes: cumulativeReceived,
            expectedBytes: cumulativeExpected,
            resumedBytes: baseBytes
        )
        lastProgress = progress
        let handler = progressHandler
        lock.unlock()
        handler?(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.activeTask = nil
        self.resumeData = nil
        self.resumedByteCount = 0
        self.expectedByteCount = -1
        self.lastProgress = nil
        lock.unlock()
        guard let continuation else { return }

        do {
            let stableURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaLibVideoCache-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: stableURL)
            let response = downloadTask.response ?? Self.fallbackResponse(for: downloadTask)
            continuation.resume(returning: (stableURL, response))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
            resumedByteCount = max(resumedByteCount, Self.resumeByteCount(from: data), lastProgress?.receivedBytes ?? 0)
        }
        let reportedError = terminalError ?? error
        resumeContinuationIfNeeded(error: reportedError)
        activeTask = nil
        lock.unlock()
    }

    private func resumeContinuationIfNeeded(error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    private static func fallbackResponse(for task: URLSessionDownloadTask) -> URLResponse {
        let url = task.originalRequest?.url ?? URL(fileURLWithPath: "/")
        return URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    private static func cumulativeExpectedBytes(
        reportedExpected: Int64,
        baseBytes: Int64,
        cumulativeReceived: Int64,
        previousExpected: Int64
    ) -> Int64 {
        guard reportedExpected > 0 else {
            return previousExpected > 0 ? max(previousExpected, cumulativeReceived) : reportedExpected
        }
        if previousExpected > 0, previousExpected >= cumulativeReceived {
            return previousExpected
        }
        guard baseBytes > 0 else {
            return max(reportedExpected, cumulativeReceived)
        }
        if reportedExpected >= cumulativeReceived {
            return max(reportedExpected, cumulativeReceived)
        }
        return max(baseBytes + reportedExpected, cumulativeReceived)
    }

    private static func resumeByteCount(from data: Data) -> Int64 {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return 0
        }
        let keys = [
            "NSURLSessionResumeBytesReceived",
            "_kCFURLSessionResumeBytesReceived",
            "NSURLSessionResumeInfoBytesReceived"
        ]
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return max(number.int64Value, 0)
            }
            if let string = dictionary[key] as? String, let value = Int64(string) {
                return max(value, 0)
            }
        }
        return 0
    }
}
