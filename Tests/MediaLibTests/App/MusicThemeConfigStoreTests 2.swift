import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class MusicThemeConfigStoreTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        MusicThemeConfigStore.directoryOverrideForTesting = nil
        MusicThemeConfig.active = MusicThemeConfig()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testAsyncWriteLoadAndReloadRoundTripsInjectedTemplate() async throws {
        let directory = try makeTemporaryDirectory()
        MusicThemeConfigStore.directoryOverrideForTesting = directory
        var config = MusicThemeConfig()
        config.visual.radius.card = 48
        config.visual.controls.expandedHeight = 136

        try await MusicThemeConfigStore.writeTemplateAsync(config)

        let fileURL = directory.appendingPathComponent(MusicThemeConfigStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = await MusicThemeConfigStore.loadFromFileAsync()
        XCTAssertEqual(loaded, config)

        MusicThemeConfig.active = MusicThemeConfig()
        let reloaded = await MusicThemeConfigStore.reloadAsync()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(MusicThemeConfig.active, config)
    }

    func testAsyncReloadResetsActiveForMissingAndCorruptedFiles() async throws {
        let directory = try makeTemporaryDirectory()
        MusicThemeConfigStore.directoryOverrideForTesting = directory
        var custom = MusicThemeConfig()
        custom.visual.radius.card = 52
        MusicThemeConfig.active = custom

        let missingReloaded = await MusicThemeConfigStore.reloadAsync()

        XCTAssertFalse(missingReloaded)
        XCTAssertEqual(MusicThemeConfig.active, MusicThemeConfig())

        try "{\"visual\":".write(
            to: directory.appendingPathComponent(MusicThemeConfigStore.fileName),
            atomically: true,
            encoding: .utf8
        )
        MusicThemeConfig.active = custom

        let corruptedReloaded = await MusicThemeConfigStore.reloadAsync()

        XCTAssertFalse(corruptedReloaded)
        XCTAssertEqual(MusicThemeConfig.active, MusicThemeConfig())
    }

    func testAsyncResetRewritesDefaultTemplate() async throws {
        let directory = try makeTemporaryDirectory()
        MusicThemeConfigStore.directoryOverrideForTesting = directory
        var config = MusicThemeConfig()
        config.visual.radius.card = 64
        try await MusicThemeConfigStore.writeTemplateAsync(config)
        MusicThemeConfig.active = config

        await MusicThemeConfigStore.resetToDefaultsAsync()

        let fileURL = directory.appendingPathComponent(MusicThemeConfigStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(MusicThemeConfig.active, MusicThemeConfig())
        let loaded = await MusicThemeConfigStore.loadFromFileAsync()
        XCTAssertEqual(loaded, MusicThemeConfig())
    }

    func testAsyncLoadDeepMergesPartialJSONAndClampsUnsafeNumbers() async throws {
        let directory = try makeTemporaryDirectory()
        MusicThemeConfigStore.directoryOverrideForTesting = directory
        let json = """
        {
          "visual": {
            "radius": {
              "card": 44
            },
            "glow": {
              "minReach": 1e120
            }
          }
        }
        """
        try json.write(
            to: directory.appendingPathComponent(MusicThemeConfigStore.fileName),
            atomically: true,
            encoding: .utf8
        )

        let loaded = await MusicThemeConfigStore.loadFromFileAsync()

        XCTAssertEqual(loaded?.visual.radius.card, 44)
        XCTAssertEqual(loaded?.visual.radius.control, MusicThemeConfig().visual.radius.control)
        XCTAssertEqual(loaded?.visual.glow.minReach, 1e11)
    }

    func testAsyncIOInjectionRunsFileOperationsOnBlockingIOQueue() async throws {
        let recorder = RecordingMusicThemeConfigIO()
        var config = MusicThemeConfig()
        config.visual.radius.card = 58
        config.visual.controls.expandedHeight = 148

        try await MusicThemeConfigStore.writeTemplateAsync(config, io: recorder.io())
        let loaded = await MusicThemeConfigStore.loadFromFileAsync(io: recorder.io())
        let reloaded = await MusicThemeConfigStore.reloadAsync(io: recorder.io())
        await MusicThemeConfigStore.resetToDefaultsAsync(io: recorder.io())
        let afterReset = await MusicThemeConfigStore.loadFromFileAsync(io: recorder.io())

        XCTAssertEqual(loaded, config)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(MusicThemeConfig.active, MusicThemeConfig())
        XCTAssertEqual(afterReset, MusicThemeConfig())
        XCTAssertTrue(recorder.eventNames.contains("write"))
        XCTAssertTrue(recorder.eventNames.contains("read"))
        XCTAssertTrue(recorder.eventNames.contains("remove"))
        XCTAssertTrue(recorder.eventsOffBlockingIOQueue.isEmpty)
    }

    func testEnsureTemplateFileAsyncDoesNotOverwriteExistingInjectedFile() async throws {
        var custom = MusicThemeConfig()
        custom.visual.radius.card = 72
        let recorder = RecordingMusicThemeConfigIO(initialData: try JSONEncoder().encode(custom))

        let url = try await MusicThemeConfigStore.ensureTemplateFileAsync(MusicThemeConfig(), io: recorder.io())
        let loaded = await MusicThemeConfigStore.loadFromFileAsync(io: recorder.io())

        XCTAssertEqual(url?.lastPathComponent, MusicThemeConfigStore.fileName)
        XCTAssertEqual(loaded, custom)
        XCTAssertEqual(recorder.writeCount, 0)
        XCTAssertTrue(recorder.eventNames.contains("exists"))
        XCTAssertTrue(recorder.eventsOffBlockingIOQueue.isEmpty)
    }

    func testBootstrapWithInjectedIOMaterializesDefaultTemplateWhenMissing() throws {
        let recorder = RecordingMusicThemeConfigIO()
        var custom = MusicThemeConfig()
        custom.visual.radius.card = 88
        MusicThemeConfig.active = custom

        MusicThemeConfigStore.bootstrap(io: recorder.io())

        XCTAssertEqual(MusicThemeConfig.active, MusicThemeConfig())
        XCTAssertEqual(recorder.writeCount, 1)
        XCTAssertEqual(MusicThemeConfigStore.loadFromFile(io: recorder.io()), MusicThemeConfig())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicThemeConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }
}

private final class RecordingMusicThemeConfigIO: @unchecked Sendable {
    private struct Event {
        var name: String
        var onBlockingIOQueue: Bool
    }

    private let lock = NSLock()
    private let url = URL(fileURLWithPath: "/tmp/music-theme.json")
    private var storedData: Data?
    private var events: [Event] = []
    private var writes = 0

    init(initialData: Data? = nil) {
        self.storedData = initialData
    }

    var eventNames: [String] {
        snapshot().map(\.name)
    }

    var eventsOffBlockingIOQueue: [String] {
        snapshot()
            .filter { !$0.onBlockingIOQueue }
            .map(\.name)
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func io() -> MusicThemeConfigStore.IO {
        MusicThemeConfigStore.IO(
            resolveFileURL: {
                self.record("resolve")
                return self.url
            },
            fileExists: { _ in
                self.record("exists")
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.storedData != nil
            },
            read: { _ in
                self.record("read")
                self.lock.lock()
                defer { self.lock.unlock() }
                guard let storedData = self.storedData else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return storedData
            },
            write: { data, _ in
                self.record("write")
                self.lock.lock()
                self.storedData = data
                self.writes += 1
                self.lock.unlock()
            },
            remove: { _ in
                self.record("remove")
                self.lock.lock()
                self.storedData = nil
                self.lock.unlock()
            }
        )
    }

    private func record(_ name: String) {
        let event = Event(
            name: name,
            onBlockingIOQueue: BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()
        )
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
