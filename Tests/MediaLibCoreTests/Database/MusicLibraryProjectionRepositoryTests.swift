import XCTest
@testable import MediaLibCore

final class MusicLibraryProjectionRepositoryTests: XCTestCase {
    private var dbURL: URL!
    private var database: DatabaseManager!
    private var mediaRepository: MediaRepository!
    private var projectionRepository: MusicLibraryProjectionRepository!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-projection-\(UUID().uuidString).sqlite")
        database = try DatabaseManager(url: dbURL)
        mediaRepository = MediaRepository(database: database)
        projectionRepository = MusicLibraryProjectionRepository(database: database)
    }

    override func tearDownWithError() throws {
        projectionRepository = nil
        mediaRepository = nil
        database = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    func testNeedsBackfillWhenSongsExistButProjectionIsEmpty() throws {
        try mediaRepository.upsert(track(id: "song-1", title: "Intro", artist: "A", album: "First"))

        XCTAssertTrue(try projectionRepository.needsBackfill())
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .bootstrap)
    }

    func testRebuildCreatesAlbumAndArtistProjection() async throws {
        try mediaRepository.upsert(track(id: "song-1", title: "B", artist: "A", album: "First", trackNumber: 2, favorite: true, playCount: 3))
        try mediaRepository.upsert(track(id: "song-2", title: "A", artist: "A", album: "First", trackNumber: 1, playCount: 2))
        try mediaRepository.upsert(track(id: "song-3", title: "Solo", artist: "B", album: "Other", playCount: 1))

        let result = try await projectionRepository.rebuildAll()
        XCTAssertEqual(result.musicItemCount, 3)
        XCTAssertEqual(result.albumCount, 2)
        XCTAssertEqual(result.artistCount, 2)

        let snapshot = try projectionRepository.fetchSnapshot()
        let first = try XCTUnwrap(snapshot.albums.first { $0.title == "First" })
        XCTAssertEqual(first.artist, "A")
        XCTAssertEqual(first.trackCount, 2)
        XCTAssertEqual(first.favoriteCount, 1)
        XCTAssertEqual(first.playCount, 5)
        XCTAssertTrue(first.trackIDs.isEmpty)
        XCTAssertEqual(try projectionRepository.albumTrackIDs(albumID: first.id), ["song-2", "song-1"])

        let artist = try XCTUnwrap(snapshot.artists.first { $0.name == "A" })
        XCTAssertEqual(artist.trackCount, 2)
        XCTAssertEqual(artist.albumCount, 1)
        XCTAssertTrue(artist.trackIDs.isEmpty)
        XCTAssertEqual(try projectionRepository.artistTrackIDs(artistID: artist.id), ["song-2", "song-1"])
        XCTAssertFalse(try projectionRepository.needsBackfill())
    }

    func testRebuildIgnoresNegativeDurationsInAlbumTotals() async throws {
        try mediaRepository.upsert(track(id: "valid", title: "Valid", artist: "A", album: "First", duration: 180))
        try mediaRepository.upsert(track(id: "negative", title: "Negative", artist: "A", album: "First", duration: -90))

        _ = try await projectionRepository.rebuildAll()

        let snapshot = try projectionRepository.fetchSnapshot()
        let album = try XCTUnwrap(snapshot.albums.first { $0.title == "First" })
        XCTAssertEqual(album.totalDuration, 180)
        XCTAssertEqual(album.trackCount, 2)
    }

    func testRebuildAndSnapshotNormalizeNegativePlayCounts() async throws {
        try mediaRepository.upsert(track(id: "valid", title: "Valid", artist: "A", album: "First", playCount: 4))
        try mediaRepository.upsert(track(id: "negative", title: "Negative", artist: "A", album: "First", playCount: 0))
        try database.execute(
            "UPDATE media_items SET play_count = ? WHERE id = ?",
            bindings: [.int(-9), .text("negative")]
        )

        _ = try await projectionRepository.rebuildAll()

        var snapshot = try projectionRepository.fetchSnapshot()
        var album = try XCTUnwrap(snapshot.albums.first { $0.title == "First" })
        var artist = try XCTUnwrap(snapshot.artists.first { $0.name == "A" })
        XCTAssertEqual(album.playCount, 4)
        XCTAssertEqual(artist.playCount, 4)

        try database.execute("UPDATE music_album_index SET play_count = ?", bindings: [.int(-3)])
        try database.execute("UPDATE music_artist_index SET play_count = ?", bindings: [.int(-5)])

        snapshot = try projectionRepository.fetchSnapshot()
        album = try XCTUnwrap(snapshot.albums.first { $0.title == "First" })
        artist = try XCTUnwrap(snapshot.artists.first { $0.name == "A" })
        XCTAssertEqual(album.playCount, 0)
        XCTAssertEqual(artist.playCount, 0)
    }

    func testRebuildMergesCaseAndDiacriticVariantsWithoutUniqueConstraintFailure() async throws {
        try mediaRepository.upsert(track(id: "song-1", title: "One", artist: "Beyonce", album: "Lemonade"))
        try mediaRepository.upsert(track(id: "song-2", title: "Two", artist: "Beyoncé", album: "LÉMONADE"))
        try mediaRepository.upsert(track(id: "song-3", title: "Three", artist: "beyonce", album: "lemonade"))

        let result = try await projectionRepository.rebuildAll()
        XCTAssertEqual(result.musicItemCount, 3)
        XCTAssertEqual(result.albumCount, 1)
        XCTAssertEqual(result.artistCount, 1)

        let snapshot = try projectionRepository.fetchSnapshot()
        let album = try XCTUnwrap(snapshot.albums.first)
        XCTAssertEqual(album.trackCount, 3)
        XCTAssertEqual(try projectionRepository.albumTrackIDs(albumID: album.id), ["song-1", "song-3", "song-2"])
        let artist = try XCTUnwrap(snapshot.artists.first)
        XCTAssertEqual(artist.trackCount, 3)
        XCTAssertEqual(try projectionRepository.artistTrackIDs(artistID: artist.id), ["song-1", "song-3", "song-2"])
    }

    func testMetadataChangesUseIncrementalMaintenanceAfterBootstrap() async throws {
        try mediaRepository.upsert(track(id: "song-1", title: "Intro", artist: "A", album: "First"))
        _ = try await projectionRepository.rebuildAll()
        XCTAssertFalse(try projectionRepository.needsBackfill())
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .none)

        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try mediaRepository.updateMetadata(
            id: "song-1",
            metadata: MediaMetadataUpdate(album: "Second")
        )

        XCTAssertFalse(try projectionRepository.needsBackfill())
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .incremental)

        let result = try await projectionRepository.synchronizeIncremental()
        XCTAssertEqual(result.affectedAlbumCount, 2)
        XCTAssertEqual(result.affectedArtistCount, 1)
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .none)

        let snapshot = try projectionRepository.fetchSnapshot()
        XCTAssertNil(snapshot.albums.first { $0.title == "First" })
        let second = try XCTUnwrap(snapshot.albums.first { $0.title == "Second" })
        XCTAssertEqual(second.trackCount, 1)
        XCTAssertEqual(try projectionRepository.albumTrackIDs(albumID: second.id), ["song-1"])
    }

    func testNewTracksUseIncrementalMaintenanceAfterBootstrap() async throws {
        try mediaRepository.upsert(track(id: "song-1", title: "Intro", artist: "A", album: "First"))
        _ = try await projectionRepository.rebuildAll()

        try mediaRepository.upsert(track(id: "song-2", title: "Outro", artist: "A", album: "First", trackNumber: 2))

        XCTAssertEqual(try projectionRepository.maintenancePlan(), .incremental)
        let result = try await projectionRepository.synchronizeIncremental()
        XCTAssertEqual(result.affectedAlbumCount, 1)
        XCTAssertEqual(result.affectedArtistCount, 1)

        let snapshot = try projectionRepository.fetchSnapshot()
        let album = try XCTUnwrap(snapshot.albums.first { $0.title == "First" })
        XCTAssertEqual(album.trackCount, 2)
        XCTAssertEqual(try projectionRepository.albumTrackIDs(albumID: album.id), ["song-1", "song-2"])
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .none)
    }

    func testDeletedTracksUseIncrementalMaintenanceAfterBootstrap() async throws {
        try mediaRepository.upsert(track(id: "song-1", title: "Intro", artist: "A", album: "First"))
        _ = try await projectionRepository.rebuildAll()

        try mediaRepository.deleteItems(filePath: "/music/song-1.mp3")

        XCTAssertEqual(try projectionRepository.maintenancePlan(), .incremental)
        let result = try await projectionRepository.synchronizeIncremental()
        XCTAssertEqual(result.affectedAlbumCount, 1)
        XCTAssertEqual(result.affectedArtistCount, 1)

        let snapshot = try projectionRepository.fetchSnapshot()
        XCTAssertTrue(snapshot.albums.isEmpty)
        XCTAssertTrue(snapshot.artists.isEmpty)
        XCTAssertEqual(try projectionRepository.maintenancePlan(), .none)
    }

    private func track(
        id: String,
        title: String,
        artist: String?,
        album: String?,
        trackNumber: Int? = nil,
        favorite: Bool = false,
        playCount: Int = 0,
        duration: Double = 180
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: .music,
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            posterPath: "/covers/\(id).jpg",
            sourcePath: "/music",
            filePath: "/music/\(id).mp3",
            duration: duration,
            playCount: playCount,
            favorite: favorite,
            metadataProvider: "Embedded"
        )
    }
}
