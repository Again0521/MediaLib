import XCTest
@testable import MediaLibCore

final class MediaScannerFileCatalogIOTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaScannerFileCatalogIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testFullScanEnumeratesAndReadsFileSizesOnBlockingIOQueue() async throws {
        let sourceURL = tempDirectory.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let mediaURL = sourceURL.appendingPathComponent("small.mp4")
        let recorder = RecordingMediaScannerFileCatalog(
            sourceFiles: [mediaURL],
            fileSizes: [mediaURL.path: 1]
        )
        let scanner = try makeScanner(fileCatalog: recorder.catalog())

        let summary = await scanner.scan(
            source: source(path: sourceURL.path, minimumFileSize: 100),
            settings: AppSettings(),
            progress: { _ in }
        )

        XCTAssertEqual(summary.scannedFiles, 1)
        XCTAssertEqual(summary.skippedFiles, 1)
        XCTAssertEqual(summary.importedItems, 0)
        XCTAssertEqual(recorder.operationNames.sorted(), ["fileSize", "mediaFilesInSource"])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testIncrementalScanPathClassificationAndSidecarRefreshRunOnBlockingIOQueue() async throws {
        let sourceURL = tempDirectory.appendingPathComponent("Source", isDirectory: true)
        let changedDirectory = sourceURL.appendingPathComponent("Season 1", isDirectory: true)
        let sidecarURL = sourceURL.appendingPathComponent("Movie.nfo")
        try FileManager.default.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
        let recorder = RecordingMediaScannerFileCatalog(
            pathKinds: [
                changedDirectory.path: .directory,
                sidecarURL.path: .missing
            ],
            rootFiles: [
                changedDirectory.path: [],
                sourceURL.path: []
            ]
        )
        let scanner = try makeScanner(fileCatalog: recorder.catalog())

        let summary = await scanner.scanChanges(
            source: source(path: sourceURL.path),
            changedPaths: [changedDirectory.path, sidecarURL.path],
            settings: AppSettings(),
            progress: { _ in }
        )

        XCTAssertEqual(summary.scannedFiles, 0)
        XCTAssertEqual(summary.importedItems, 0)
        XCTAssertEqual(recorder.operationCount(named: "pathKind"), 2)
        XCTAssertEqual(recorder.operationCount(named: "mediaFilesAtRoot"), 2)
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testPhotoScanReadsImageMetadataOnBlockingIOQueue() async throws {
        let sourceURL = tempDirectory.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let photoURL = sourceURL.appendingPathComponent("photo.jpg")
        let capturedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = RecordingMediaScannerFileCatalog(
            sourceFiles: [photoURL],
            fileSizes: [photoURL.path: 10],
            photoMetadata: [
                photoURL.path: MediaScannerPhotoMetadata(
                    capturedDate: capturedDate,
                    imagePixelSize: "120x80"
                )
            ]
        )
        let scanner = try makeScanner(fileCatalog: recorder.catalog())

        let summary = await scanner.scan(
            source: source(path: sourceURL.path, mediaType: .photo),
            settings: AppSettings(),
            progress: { _ in }
        )

        XCTAssertEqual(summary.scannedFiles, 1)
        XCTAssertEqual(summary.skippedFiles, 0)
        XCTAssertEqual(summary.importedItems, 1)
        XCTAssertEqual(recorder.operationCount(named: "photoMetadata"), 1)
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    private func makeScanner(fileCatalog: MediaScannerFileCatalog) throws -> MediaScanner {
        let dbURL = tempDirectory.appendingPathComponent("MediaScanner.sqlite")
        let database = try DatabaseManager(url: dbURL)
        return MediaScanner(
            thumbnailGenerator: nil,
            mediaRepository: MediaRepository(database: database),
            fileCatalog: fileCatalog
        )
    }

    private func source(
        path: String,
        mediaType: MediaType = .movie,
        minimumFileSize: Int64 = 0
    ) -> MediaSource {
        MediaSource(
            name: "Source",
            path: path,
            mediaType: mediaType,
            minimumFileSize: minimumFileSize,
            readNFO: false,
            preferLocalArtwork: false,
            screenshotFallbackEnabled: false
        )
    }
}

private final class RecordingMediaScannerFileCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceFiles: [URL]
    private let pathKinds: [String: MediaScannerPathKind]
    private let rootFiles: [String: [URL]]
    private let fileSizes: [String: Int64]
    private let photoMetadata: [String: MediaScannerPhotoMetadata]
    private var records: [(name: String, onBlockingIOQueue: Bool)] = []

    init(
        sourceFiles: [URL] = [],
        pathKinds: [String: MediaScannerPathKind] = [:],
        rootFiles: [String: [URL]] = [:],
        fileSizes: [String: Int64] = [:],
        photoMetadata: [String: MediaScannerPhotoMetadata] = [:]
    ) {
        self.sourceFiles = sourceFiles
        self.pathKinds = pathKinds
        self.rootFiles = rootFiles
        self.fileSizes = fileSizes
        self.photoMetadata = photoMetadata
    }

    var operationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.name)
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !records.isEmpty && records.allSatisfy(\.onBlockingIOQueue)
    }

    func operationCount(named name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.name == name }.count
    }

    func catalog() -> MediaScannerFileCatalog {
        MediaScannerFileCatalog(
            mediaFilesInSource: { [self] _ in
                record("mediaFilesInSource")
                return sourceFiles
            },
            mediaFilesAtRoot: { [self] root, _, _ in
                record("mediaFilesAtRoot")
                return rootFiles[root.path] ?? []
            },
            pathKind: { [self] path in
                record("pathKind")
                return pathKinds[path] ?? .missing
            },
            fileSize: { [self] url in
                record("fileSize")
                return fileSizes[url.path] ?? 0
            },
            photoMetadata: { [self] url, _ in
                record("photoMetadata")
                return photoMetadata[url.path] ?? MediaScannerPhotoMetadata(
                    capturedDate: Date(timeIntervalSince1970: 0),
                    imagePixelSize: nil
                )
            }
        )
    }

    private func record(_ name: String) {
        lock.lock()
        records.append((name, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        lock.unlock()
    }
}
