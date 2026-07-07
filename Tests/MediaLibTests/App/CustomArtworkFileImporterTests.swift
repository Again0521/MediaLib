import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class CustomArtworkFileImporterTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testImportArtworkCreatesDirectoryCopiesFileAndRemovesOlderSameKindFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("cover.PNG")
        try Data([0xCA, 0xFE]).write(to: sourceURL)
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let stalePoster = thumbnailsDirectory.appendingPathComponent("movie-1-custom-poster-1.png")
        let staleBackdrop = thumbnailsDirectory.appendingPathComponent("movie-1-custom-backdrop-1.png")
        let otherPoster = thumbnailsDirectory.appendingPathComponent("movie-2-custom-poster-1.png")
        try Data([0x00]).write(to: stalePoster)
        try Data([0x01]).write(to: staleBackdrop)
        try Data([0x02]).write(to: otherPoster)

        let importedURL = try await CustomArtworkFileImporter.importArtwork(
            itemID: "movie-1",
            sourceURL: sourceURL,
            thumbnailsDirectory: thumbnailsDirectory,
            kind: .poster,
            timestamp: 123
        )

        XCTAssertEqual(importedURL.lastPathComponent, "movie-1-custom-poster-123.png")
        XCTAssertEqual(try Data(contentsOf: importedURL), Data([0xCA, 0xFE]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePoster.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleBackdrop.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherPoster.path))
    }

    func testImportArtworkDoesNotRemoveDirectoriesThatMatchOldArtworkPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        let thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("cover.PNG")
        try Data([0xCA, 0xFE]).write(to: sourceURL)
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let stalePoster = thumbnailsDirectory.appendingPathComponent("movie-1-custom-poster-1.png")
        let matchingDirectory = thumbnailsDirectory.appendingPathComponent("movie-1-custom-poster-folder.png", isDirectory: true)
        try Data([0x00]).write(to: stalePoster)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: matchingDirectory.appendingPathComponent("nested.txt"))

        let importedURL = try await CustomArtworkFileImporter.importArtwork(
            itemID: "movie-1",
            sourceURL: sourceURL,
            thumbnailsDirectory: thumbnailsDirectory,
            kind: .poster,
            timestamp: 124
        )

        XCTAssertEqual(importedURL.lastPathComponent, "movie-1-custom-poster-124.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePoster.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingDirectory.appendingPathComponent("nested.txt").path))
    }

    func testImportArtworkUsesJPGFallbackForExtensionlessSource() async throws {
        let directory = try makeTemporaryDirectory()
        let thumbnailsDirectory = directory.appendingPathComponent("Nested/Thumbnails", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("cover")
        try Data([0x10, 0x20]).write(to: sourceURL)

        let importedURL = try await CustomArtworkFileImporter.importArtwork(
            itemID: "movie-1",
            sourceURL: sourceURL,
            thumbnailsDirectory: thumbnailsDirectory,
            kind: .backdrop,
            timestamp: 456
        )

        XCTAssertEqual(importedURL.lastPathComponent, "movie-1-custom-backdrop-456.jpg")
        XCTAssertEqual(try Data(contentsOf: importedURL), Data([0x10, 0x20]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailsDirectory.path))
    }

    func testImportArtworkSanitizesUnsafeItemIDAndKeepsDestinationInsideThumbnailsDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("cover.JPG")
        try Data([0xAB, 0xCD]).write(to: sourceURL)

        let importedURL = try await CustomArtworkFileImporter.importArtwork(
            itemID: "server:id/1",
            sourceURL: sourceURL,
            thumbnailsDirectory: thumbnailsDirectory,
            kind: .poster,
            timestamp: 789
        )

        XCTAssertEqual(importedURL.deletingLastPathComponent(), thumbnailsDirectory)
        XCTAssertEqual(importedURL.lastPathComponent, "server-id-1-custom-poster-789.jpg")
        XCTAssertEqual(try Data(contentsOf: importedURL), Data([0xAB, 0xCD]))
    }

    func testImportArtworkRunsInjectedFileOperationsThroughBlockingIOQueue() async throws {
        let thumbnailsDirectory = URL(fileURLWithPath: "/tmp/CustomArtworkFileImporterTests/Thumbnails", isDirectory: true)
        let sourceURL = URL(fileURLWithPath: "/tmp/CustomArtworkFileImporterTests/source.PNG")
        let stalePoster = thumbnailsDirectory.appendingPathComponent("movie-1-custom-poster-1.png")
        let staleBackdrop = thumbnailsDirectory.appendingPathComponent("movie-1-custom-backdrop-1.png")
        let otherPoster = thumbnailsDirectory.appendingPathComponent("movie-2-custom-poster-1.png")
        let recorder = RecordingCustomArtworkFileIO(existingURLs: [
            stalePoster,
            staleBackdrop,
            otherPoster
        ])

        let importedURL = try await CustomArtworkFileImporter.importArtwork(
            itemID: "movie-1",
            sourceURL: sourceURL,
            thumbnailsDirectory: thumbnailsDirectory,
            kind: .poster,
            timestamp: 321,
            io: recorder.io()
        )

        let expectedURL = thumbnailsDirectory.appendingPathComponent("movie-1-custom-poster-321.png")
        XCTAssertEqual(importedURL, expectedURL)
        XCTAssertEqual(recorder.operationNames, [
            "createDirectory",
            "contentsOfDirectory",
            "isRegularFile",
            "removeItem",
            "copyItem"
        ])
        XCTAssertEqual(recorder.createdDirectories, [thumbnailsDirectory])
        XCTAssertEqual(recorder.removedURLs, [stalePoster])
        XCTAssertEqual(recorder.copies.map(\.source), [sourceURL])
        XCTAssertEqual(recorder.copies.map(\.destination), [expectedURL])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testImportArtworkPropagatesCopyFailureFromInjectedIO() async throws {
        struct CopyFailed: Error {}
        let thumbnailsDirectory = URL(fileURLWithPath: "/tmp/CustomArtworkFileImporterTests/Thumbnails", isDirectory: true)
        let sourceURL = URL(fileURLWithPath: "/tmp/CustomArtworkFileImporterTests/missing.png")
        let io = CustomArtworkFileIO(
            createDirectory: { _ in },
            contentsOfDirectory: { _ in [] },
            isRegularFile: { _ in true },
            removeItem: { _ in },
            copyItem: { _, _ in throw CopyFailed() }
        )

        do {
            _ = try await CustomArtworkFileImporter.importArtwork(
                itemID: "movie-1",
                sourceURL: sourceURL,
                thumbnailsDirectory: thumbnailsDirectory,
                kind: .poster,
                timestamp: 654,
                io: io
            )
            XCTFail("Expected custom artwork copy to fail")
        } catch is CopyFailed {
            // Expected.
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomArtworkFileImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }
}

private final class RecordingCustomArtworkFileIO: @unchecked Sendable {
    private let lock = NSLock()
    private let existingURLs: [URL]
    private let regularURLs: Set<URL>
    private var operations: [(name: String, onBlockingIOQueue: Bool)] = []
    private var directories: [URL] = []
    private var removals: [URL] = []
    private var copyRecords: [(source: URL, destination: URL)] = []

    init(existingURLs: [URL], regularURLs: Set<URL>? = nil) {
        self.existingURLs = existingURLs
        self.regularURLs = regularURLs ?? Set(existingURLs)
    }

    var operationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return operations.map(\.name)
    }

    var createdDirectories: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return directories
    }

    var removedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return removals
    }

    var copies: [(source: URL, destination: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return copyRecords
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operations.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !operations.isEmpty && operations.allSatisfy(\.onBlockingIOQueue)
    }

    func io() -> CustomArtworkFileIO {
        CustomArtworkFileIO(
            createDirectory: { [self] directory in
                record("createDirectory")
                lock.lock()
                directories.append(directory)
                lock.unlock()
            },
            contentsOfDirectory: { [self] _ in
                record("contentsOfDirectory")
                return existingURLs
            },
            isRegularFile: { [self] url in
                record("isRegularFile")
                return regularURLs.contains(url)
            },
            removeItem: { [self] url in
                record("removeItem")
                lock.lock()
                removals.append(url)
                lock.unlock()
            },
            copyItem: { [self] source, destination in
                record("copyItem")
                lock.lock()
                copyRecords.append((source, destination))
                lock.unlock()
            }
        )
    }

    private func record(_ name: String) {
        lock.lock()
        operations.append((
            name: name,
            onBlockingIOQueue: BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()
        ))
        lock.unlock()
    }
}
