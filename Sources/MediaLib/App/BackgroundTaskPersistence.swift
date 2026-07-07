import Foundation
import MediaLibCore

enum BackgroundTaskPersistence {
    struct IO: @unchecked Sendable {
        let read: (URL) throws -> Data
        let write: (Data, URL) throws -> Void

        static let fileSystem = IO(
            read: { url in
                try Data(contentsOf: url)
            },
            write: { data, url in
                try data.write(to: url, options: [.atomic])
            }
        )
    }

    struct LoadFailure: Sendable {
        let operation: String
        let path: String
        let message: String
    }

    enum LoadResult: Sendable {
        case missingURL
        case loaded([BackgroundTaskSnapshot])
        case failed(LoadFailure)

        var tasks: [BackgroundTaskSnapshot]? {
            if case let .loaded(tasks) = self {
                return tasks
            }
            return nil
        }
    }

    static let persistedLimit = 60

    static func persistedSnapshot(from tasks: [BackgroundTaskSnapshot]) -> [BackgroundTaskSnapshot] {
        Array(tasks.prefix(persistedLimit))
    }

    static func encodedData(for tasks: [BackgroundTaskSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(persistedSnapshot(from: tasks))
    }

    static func decodedTasks(from data: Data) throws -> [BackgroundTaskSnapshot] {
        try JSONDecoder().decode([BackgroundTaskSnapshot].self, from: data)
    }

    static func load(from url: URL?) async -> [BackgroundTaskSnapshot]? {
        await load(from: url, io: .fileSystem)
    }

    static func load(from url: URL?, io: IO) async -> [BackgroundTaskSnapshot]? {
        await loadResult(from: url, io: io).tasks
    }

    static func loadResult(from url: URL?, io: IO) async -> LoadResult {
        await BlockingIOExecutor.run {
            guard let url else {
                return .missingURL
            }

            let data: Data
            do {
                data = try io.read(url)
            } catch {
                return .failed(LoadFailure(operation: "read", path: url.path, message: error.localizedDescription))
            }

            do {
                return .loaded(try decodedTasks(from: data))
            } catch {
                return .failed(LoadFailure(operation: "decode", path: url.path, message: error.localizedDescription))
            }
        }
    }

    static func write(_ tasks: [BackgroundTaskSnapshot], to url: URL) async throws {
        try await write(tasks, to: url, io: .fileSystem)
    }

    static func write(_ tasks: [BackgroundTaskSnapshot], to url: URL, io: IO) async throws {
        try await BlockingIOExecutor.run {
            let data = try encodedData(for: tasks)
            try io.write(data, url)
        }
    }
}

final class BackgroundTaskPersistenceScheduler {
    typealias Writer = @Sendable ([BackgroundTaskSnapshot], URL) async throws -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void
    private static let defaultWriter: Writer = { tasks, url in
        try await BackgroundTaskPersistence.write(tasks, to: url)
    }

    private let debounceNanoseconds: UInt64
    private let writer: Writer
    private let onError: ErrorHandler
    private var task: Task<Void, Never>?

    init(
        debounceNanoseconds: UInt64 = 350_000_000,
        writer: @escaping Writer = BackgroundTaskPersistenceScheduler.defaultWriter,
        onError: @escaping ErrorHandler = { _ in }
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.writer = writer
        self.onError = onError
    }

    deinit {
        cancel()
    }

    func schedule(_ snapshots: [BackgroundTaskSnapshot], to url: URL, immediate: Bool = false) {
        task?.cancel()
        let persisted = BackgroundTaskPersistence.persistedSnapshot(from: snapshots)
        let delay = immediate ? 0 : debounceNanoseconds
        let writer = writer
        let onError = onError
        task = Task {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            do {
                try await writer(persisted, url)
            } catch {
                guard !Task.isCancelled else { return }
                onError(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
