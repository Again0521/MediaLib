import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class MetadataSearchServiceArtworkTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testMaterializedMetadataUpdateWritesRemotePosterThroughBlockingIOQueue() async throws {
        let directory = try makeTemporaryDirectory()
        let posterURL = "https://image.example.test/poster.PNG?size=large"
        let posterData = Data([0x89, 0x50, 0x4E, 0x47])
        let network = RecordingMetadataArtworkNetwork(responses: [
            posterURL: .init(statusCode: 200, data: posterData)
        ])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "tmdb:movie/42",
            provider: "TMDB",
            title: "Movie",
            posterPath: posterURL
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "item:1",
            artworkDirectory: directory
        )

        let expectedURL = directory.appendingPathComponent("item-1-tmdb-movie-42-poster.png")
        XCTAssertEqual(update.posterPath, expectedURL.path)
        XCTAssertNil(update.backdropPath)
        XCTAssertEqual(network.requestedURLs, [posterURL])
        XCTAssertEqual(recorder.createdDirectories, [directory])
        XCTAssertEqual(recorder.writes.map(\.url), [expectedURL])
        XCTAssertEqual(recorder.writes.map(\.data), [posterData])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
    }

    func testMaterializedMetadataUpdateTrimsRemoteArtworkURLBeforeDownloading() async throws {
        let directory = try makeTemporaryDirectory()
        let posterURL = "https://image.example.test/poster.jpg"
        let network = RecordingMetadataArtworkNetwork(responses: [
            posterURL: .init(statusCode: 200, data: Data("poster".utf8))
        ])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "tmdb:movie:trimmed",
            provider: "TMDB",
            title: "Movie",
            posterPath: " \n\(posterURL)\t"
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "movie-trimmed",
            artworkDirectory: directory
        )

        let expectedURL = directory.appendingPathComponent("movie-trimmed-tmdb-movie-trimmed-poster.jpg")
        XCTAssertEqual(update.posterPath, expectedURL.path)
        XCTAssertEqual(network.requestedURLs, [posterURL])
        XCTAssertEqual(recorder.writes.map(\.url), [expectedURL])
    }

    func testMaterializedMetadataUpdateUsesJPGFallbackAndSanitizedFilename() async throws {
        let directory = try makeTemporaryDirectory()
        let backdropURL = "https://cdn.example.test/artwork"
        let network = RecordingMetadataArtworkNetwork(responses: [
            backdropURL: .init(statusCode: 200, data: Data("image".utf8))
        ])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "itunes/album?abc",
            provider: "iTunes",
            title: "Album",
            backdropPath: backdropURL
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "source: item 1",
            artworkDirectory: directory
        )

        let expectedURL = directory.appendingPathComponent("source--item-1-itunes-album-abc-backdrop.jpg")
        XCTAssertEqual(update.backdropPath, expectedURL.path)
        XCTAssertEqual(recorder.writes.map(\.url), [expectedURL])
    }

    func testMaterializedMetadataUpdateDoesNotWriteWhenRemoteArtworkReturnsHTTPError() async throws {
        let directory = try makeTemporaryDirectory()
        let posterURL = "https://image.example.test/missing.jpg"
        let network = RecordingMetadataArtworkNetwork(responses: [
            posterURL: .init(statusCode: 404, data: Data("not found".utf8))
        ])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "tmdb:404",
            provider: "TMDB",
            title: "Missing",
            posterPath: posterURL
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "missing-item",
            artworkDirectory: directory
        )

        XCTAssertNil(update.posterPath)
        XCTAssertEqual(network.requestedURLs, [posterURL])
        XCTAssertTrue(recorder.createdDirectories.isEmpty)
        XCTAssertTrue(recorder.writes.isEmpty)
    }

    func testMaterializedMetadataUpdatePreservesNonHTTPArtworkWithoutNetworkOrFileIO() async throws {
        let directory = try makeTemporaryDirectory()
        let network = RecordingMetadataArtworkNetwork(responses: [:])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "local:1",
            provider: "Local",
            title: "Local",
            posterPath: "smb://nas.local/art/poster.webp",
            backdropPath: "/Volumes/Media/http-cache/backdrop.jpg"
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "local-item",
            artworkDirectory: directory
        )

        XCTAssertEqual(update.posterPath, "smb://nas.local/art/poster.webp")
        XCTAssertEqual(update.backdropPath, "/Volumes/Media/http-cache/backdrop.jpg")
        XCTAssertTrue(network.requestedURLs.isEmpty)
        XCTAssertTrue(recorder.createdDirectories.isEmpty)
        XCTAssertTrue(recorder.writes.isEmpty)
    }

    func testMaterializedMetadataUpdatePreservesEmbeddedPosterAndStillDownloadsBackdrop() async throws {
        let directory = try makeTemporaryDirectory()
        let posterURL = "https://image.example.test/poster.jpg"
        let backdropURL = "https://image.example.test/backdrop.webp"
        let network = RecordingMetadataArtworkNetwork(responses: [
            posterURL: .init(statusCode: 200, data: Data("poster".utf8)),
            backdropURL: .init(statusCode: 200, data: Data("backdrop".utf8))
        ])
        let recorder = RecordingMetadataArtworkIO()
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: recorder.io()
        )
        let result = MetadataSearchResult(
            id: "tmdb:movie:99",
            provider: "TMDB",
            title: "Movie",
            posterPath: posterURL,
            backdropPath: backdropURL
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "movie-99",
            artworkDirectory: directory,
            preserveEmbeddedPoster: true
        )

        let expectedBackdropURL = directory.appendingPathComponent("movie-99-tmdb-movie-99-backdrop.webp")
        XCTAssertNil(update.posterPath)
        XCTAssertEqual(update.backdropPath, expectedBackdropURL.path)
        XCTAssertEqual(network.requestedURLs, [backdropURL])
        XCTAssertEqual(recorder.writes.map(\.url), [expectedBackdropURL])
    }

    func testMaterializedMetadataUpdateReturnsNilWhenArtworkWriteFails() async throws {
        struct WriteFailed: Error {}
        let directory = try makeTemporaryDirectory()
        let posterURL = "https://image.example.test/poster.jpg"
        let network = RecordingMetadataArtworkNetwork(responses: [
            posterURL: .init(statusCode: 200, data: Data("poster".utf8))
        ])
        let service = MetadataSearchService(
            artworkDataLoader: network.loader(),
            artworkIO: MetadataSearchService.ArtworkIO(
                createDirectory: { _ in },
                write: { _, _ in throw WriteFailed() }
            )
        )
        let result = MetadataSearchResult(
            id: "tmdb:write-failed",
            provider: "TMDB",
            title: "Write Failed",
            posterPath: posterURL
        )

        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: "write-failed",
            artworkDirectory: directory
        )

        XCTAssertNil(update.posterPath)
        XCTAssertEqual(network.requestedURLs, [posterURL])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataSearchServiceArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}

private final class RecordingMetadataArtworkNetwork: @unchecked Sendable {
    struct Response {
        var statusCode: Int
        var data: Data
    }

    private let queue = DispatchQueue(label: "MetadataSearchServiceArtworkTests.network")
    private let responses: [String: Response]
    private var requests: [String] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    var requestedURLs: [String] {
        queue.sync { requests }
    }

    func loader() -> MetadataSearchService.ArtworkDataLoader {
        { [self] request in
            let url = try XCTUnwrap(request.url)
            let absoluteString = url.absoluteString
            queue.sync {
                requests.append(absoluteString)
            }
            let stub = responses[absoluteString] ?? Response(statusCode: 404, data: Data())
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (stub.data, response)
        }
    }
}

private final class RecordingMetadataArtworkIO: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryRecords: [(url: URL, onBlockingIOQueue: Bool)] = []
    private var writeRecords: [(data: Data, url: URL, onBlockingIOQueue: Bool)] = []

    var createdDirectories: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return directoryRecords.map(\.url)
    }

    var writes: [(data: Data, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return writeRecords.map { ($0.data, $0.url) }
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return directoryRecords.contains { $0.onBlockingIOQueue } || writeRecords.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        let operations = directoryRecords.map(\.onBlockingIOQueue) + writeRecords.map(\.onBlockingIOQueue)
        return !operations.isEmpty && operations.allSatisfy { $0 }
    }

    func io() -> MetadataSearchService.ArtworkIO {
        MetadataSearchService.ArtworkIO(
            createDirectory: { [self] url in
                lock.lock()
                directoryRecords.append((
                    url: url,
                    onBlockingIOQueue: BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()
                ))
                lock.unlock()
            },
            write: { [self] data, url in
                lock.lock()
                writeRecords.append((
                    data: data,
                    url: url,
                    onBlockingIOQueue: BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()
                ))
                lock.unlock()
            }
        )
    }
}
