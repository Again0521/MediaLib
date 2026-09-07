import XCTest
@testable import MediaLibCore

final class VideoMetadataSidecarPolicyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMetadataSidecarPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testTwoMoviesInOneDirectoryWriteIndependentSidecarsAndRescanTheirOwnMetadata() async throws {
        let movieAURL = root.appendingPathComponent("A.mkv")
        let movieBURL = root.appendingPathComponent("B.mp4")
        let bytesA = Data([0x01, 0x02, 0x03])
        let bytesB = Data([0x04, 0x05, 0x06])
        try bytesA.write(to: movieAURL)
        try bytesB.write(to: movieBURL)
        let source = writableSource()
        let movieA = MediaItem(id: "a", type: .movie, title: "A", filePath: movieAURL.path)
        let movieB = MediaItem(id: "b", type: .movie, title: "B", filePath: movieBURL.path)

        let targetA = try target(for: movieA, source: source)
        let targetB = try target(for: movieB, source: source)
        XCTAssertEqual(targetA, root.appendingPathComponent("A.nfo"))
        XCTAssertEqual(targetB, root.appendingPathComponent("B.nfo"))
        XCTAssertNotEqual(targetA, targetB)

        _ = try await VideoMetadataSidecarWriter.writeSafely(
            item: movieA,
            update: MediaMetadataUpdate(title: "Movie A", overview: "Plot A"),
            to: targetA
        )
        _ = try await VideoMetadataSidecarWriter.writeSafely(
            item: movieB,
            update: MediaMetadataUpdate(title: "Movie B", overview: "Plot B"),
            to: targetB
        )

        let metadataService = LocalMetadataService()
        XCTAssertEqual(metadataService.metadata(for: movieAURL, readNFO: true, preferLocalArtwork: false).title, "Movie A")
        XCTAssertEqual(metadataService.metadata(for: movieBURL, readNFO: true, preferLocalArtwork: false).title, "Movie B")

        let database = try DatabaseManager(url: root.appendingPathComponent("rescan.sqlite"))
        let repository = MediaRepository(database: database)
        let scanner = MediaScanner(thumbnailGenerator: nil, mediaRepository: repository)
        var scanSource = source
        scanSource.readNFO = true
        scanSource.minimumFileSize = 0
        let summary = await scanner.scan(source: scanSource, settings: AppSettings(), progress: { _ in })
        XCTAssertEqual(summary.errors, [])
        XCTAssertEqual(summary.importedItems, 2)
        XCTAssertEqual(Set(try repository.fetchAll().map(\.title)), ["Movie A", "Movie B"])

        XCTAssertEqual(try Data(contentsOf: movieAURL), bytesA)
        XCTAssertEqual(try Data(contentsOf: movieBURL), bytesB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("movie.nfo").path))
    }

    func testSpecificSidecarWinsWithoutMigratingOrDeletingLegacyMovieNFO() async throws {
        let movieURL = root.appendingPathComponent("Feature.mkv")
        try Data([0x00]).write(to: movieURL)
        let legacyURL = root.appendingPathComponent("movie.nfo")
        let legacy = "<movie><title>Legacy Directory Title</title><legacy>keep</legacy></movie>"
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let item = MediaItem(id: "feature", type: .movie, title: "Feature", filePath: movieURL.path)
        let targetURL = try target(for: item, source: writableSource())

        _ = try await VideoMetadataSidecarWriter.writeSafely(
            item: item,
            update: MediaMetadataUpdate(title: "Specific Title"),
            to: targetURL
        )

        let metadata = LocalMetadataService().metadata(for: movieURL, readNFO: true, preferLocalArtwork: false)
        XCTAssertEqual(metadata.title, "Specific Title")
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), legacy)
    }

    func testMultiSeasonSeriesResolvesOnlyTheCommonShowRoot() throws {
        let showRoot = root.appendingPathComponent("Example Show", isDirectory: true)
        let seasonOne = showRoot.appendingPathComponent("Season 1", isDirectory: true)
        let seasonTwo = showRoot.appendingPathComponent("Season 2", isDirectory: true)
        try FileManager.default.createDirectory(at: seasonOne, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seasonTwo, withIntermediateDirectories: true)
        let episodes = [
            MediaItem(id: "e1", type: .episode, title: "Show", filePath: seasonOne.appendingPathComponent("Show.S01E01.mkv").path),
            MediaItem(id: "e2", type: .episode, title: "Show", filePath: seasonTwo.appendingPathComponent("Show.S02E01.mkv").path)
        ]
        let show = MediaItem(id: "show", type: .tvShow, title: "Example Show")

        XCTAssertEqual(
            VideoMetadataSidecarPolicy.resolveTarget(
                for: show,
                source: writableSource(),
                childItems: episodes,
                vaultUnlocked: false
            ),
            .target(showRoot.appendingPathComponent("tvshow.nfo"))
        )
    }

    func testSeriesOwnershipUnknownAtSourceRootOrAcrossDifferentShows() throws {
        let source = writableSource()
        let show = MediaItem(id: "show", type: .tvShow, title: "Unknown")
        let rootEpisode = MediaItem(
            id: "root-episode",
            type: .episode,
            title: "Unknown",
            filePath: root.appendingPathComponent("Unknown.S01E01.mkv").path
        )
        XCTAssertEqual(
            VideoMetadataSidecarPolicy.resolveTarget(
                for: show,
                source: source,
                childItems: [rootEpisode],
                vaultUnlocked: false
            ),
            .skipped(.ownershipUnknown)
        )

        let first = root.appendingPathComponent("Show A", isDirectory: true)
            .appendingPathComponent("A.S01E01.mkv")
        let second = root.appendingPathComponent("Show B", isDirectory: true)
            .appendingPathComponent("B.S01E01.mkv")
        let mixed = [
            MediaItem(id: "a", type: .episode, title: "A", filePath: first.path),
            MediaItem(id: "b", type: .episode, title: "B", filePath: second.path)
        ]
        XCTAssertEqual(
            VideoMetadataSidecarPolicy.resolveTarget(
                for: show,
                source: source,
                childItems: mixed,
                vaultUnlocked: false
            ),
            .skipped(.ownershipUnknown)
        )
    }

    func testAuthorizationGatesWriteBackRemoteSourcesVaultAndEscapedPaths() throws {
        let movieURL = root.appendingPathComponent("Movie.mkv")
        try Data([0x01]).write(to: movieURL)
        let item = MediaItem(id: "movie", type: .movie, title: "Movie", filePath: movieURL.path)

        var disabled = writableSource()
        disabled.preferMetadataWriteToSource = false
        XCTAssertEqual(resolve(item, source: disabled), .skipped(.writeBackDisabled))

        let remote = MediaSource(
            name: "Remote",
            path: "emby://server/library",
            preferMetadataWriteToSource: true
        )
        XCTAssertEqual(resolve(item, source: remote), .skipped(.unsupportedSource))

        var vault = writableSource()
        vault.mediaType = .privateCollection
        let privateItem = MediaItem(id: "private", type: .privateCollection, title: "Private", filePath: movieURL.path)
        XCTAssertEqual(resolve(privateItem, source: vault, vaultUnlocked: false), .skipped(.vaultLocked))
        XCTAssertEqual(resolve(privateItem, source: vault, vaultUnlocked: true), .target(root.appendingPathComponent("Movie.nfo")))

        let outsideURL = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data([0x02]).write(to: outsideURL)
        let outsideItem = MediaItem(id: "outside", type: .movie, title: "Outside", filePath: outsideURL.path)
        XCTAssertEqual(resolve(outsideItem, source: writableSource()), .skipped(.outsideAuthorizedRoot))
    }

    func testDisabledRemoteAndLockedVaultWriteRequestsDoNotTouchSourceDirectory() async throws {
        let movieURL = root.appendingPathComponent("Guarded.mkv")
        try Data([0x10, 0x11]).write(to: movieURL)
        let item = MediaItem(id: "guarded", type: .movie, title: "Guarded", filePath: movieURL.path)
        let targetURL = root.appendingPathComponent("Guarded.nfo")

        var disabled = writableSource()
        disabled.preferMetadataWriteToSource = false
        let disabledOutcome = try await VideoMetadataSidecarPolicy.writeIfAllowed(
            item: item,
            update: MediaMetadataUpdate(title: "Blocked"),
            source: disabled,
            vaultUnlocked: true
        )
        XCTAssertEqual(disabledOutcome, .skipped(.writeBackDisabled))

        let remote = MediaSource(
            name: "Remote",
            path: "emby://server/library",
            preferMetadataWriteToSource: true
        )
        let remoteOutcome = try await VideoMetadataSidecarPolicy.writeIfAllowed(
            item: item,
            update: MediaMetadataUpdate(title: "Blocked"),
            source: remote,
            vaultUnlocked: true
        )
        XCTAssertEqual(remoteOutcome, .skipped(.unsupportedSource))

        var vault = writableSource()
        vault.mediaType = .privateCollection
        let privateItem = MediaItem(
            id: "private-guarded",
            type: .privateCollection,
            title: "Private",
            filePath: movieURL.path
        )
        let vaultOutcome = try await VideoMetadataSidecarPolicy.writeIfAllowed(
            item: privateItem,
            update: MediaMetadataUpdate(title: "Blocked"),
            source: vault,
            vaultUnlocked: false
        )
        XCTAssertEqual(vaultOutcome, .skipped(.vaultLocked))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertEqual(try Data(contentsOf: movieURL), Data([0x10, 0x11]))
    }

    func testSymlinkedMediaCannotEscapeAuthorizedSourceRoot() throws {
        let outsideURL = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).mkv")
        let linkedURL = root.appendingPathComponent("linked.mkv")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data([0x03]).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outsideURL)
        let item = MediaItem(id: "linked", type: .movie, title: "Linked", filePath: linkedURL.path)

        XCTAssertEqual(resolve(item, source: writableSource()), .skipped(.outsideAuthorizedRoot))
    }

    private func writableSource() -> MediaSource {
        MediaSource(
            name: "Local",
            path: root.path,
            mediaType: .movie,
            preferMetadataWriteToSource: true
        )
    }

    private func resolve(
        _ item: MediaItem,
        source: MediaSource,
        vaultUnlocked: Bool = false
    ) -> VideoMetadataSidecarTargetResolution {
        VideoMetadataSidecarPolicy.resolveTarget(
            for: item,
            source: source,
            vaultUnlocked: vaultUnlocked
        )
    }

    private func target(for item: MediaItem, source: MediaSource) throws -> URL {
        let resolution = resolve(item, source: source)
        guard case let .target(url) = resolution else {
            throw XCTSkip("Expected a writable sidecar target, got \(resolution)")
        }
        return url
    }
}
