import XCTest
@testable import MediaLibCore

final class VideoMetadataSidecarWriterTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testXMLContentEscapesFieldsAndUsesMovieRoot() {
        let item = MediaItem(id: "movie-1", type: .movie, title: "A & B")
        let update = MediaMetadataUpdate(
            title: "New <Title>",
            originalTitle: "Original \"Quoted\"",
            year: 2026,
            overview: "Plot with 'quotes' & symbols",
            rating: 8.5,
            externalID: "123&456",
            genre: "Drama > Action"
        )

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: update)

        XCTAssertTrue(xml.contains("<movie>"))
        XCTAssertTrue(xml.contains("<title>New &lt;Title&gt;</title>"))
        XCTAssertTrue(xml.contains("<originaltitle>Original &quot;Quoted&quot;</originaltitle>"))
        XCTAssertTrue(xml.contains("<plot>Plot with &apos;quotes&apos; &amp; symbols</plot>"))
        XCTAssertTrue(xml.contains("<uniqueid type=\"tmdb\">123&amp;456</uniqueid>"))
        XCTAssertTrue(xml.contains("<genre>Drama &gt; Action</genre>"))
    }

    func testXMLContentUsesTVShowRootForSeriesItemsAndFallsBackToItemTitle() {
        let item = MediaItem(id: "show-1", type: .anime, title: "Fallback Title")
        let update = MediaMetadataUpdate(year: 2025)

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: update)

        XCTAssertTrue(xml.contains("<tvshow>"))
        XCTAssertTrue(xml.contains("<title>Fallback Title</title>"))
        XCTAssertTrue(xml.contains("<year>2025</year>"))
    }

    func testXMLContentEscapesFallbackTitleAndOmitsNilOptionalTags() {
        let item = MediaItem(id: "movie-fallback", type: .movie, title: "Fallback & <Title>")

        let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: MediaMetadataUpdate())

        XCTAssertTrue(xml.contains("<title>Fallback &amp; &lt;Title&gt;</title>"))
        XCTAssertFalse(xml.contains("<originaltitle>"))
        XCTAssertFalse(xml.contains("<year>"))
        XCTAssertFalse(xml.contains("<plot>"))
        XCTAssertFalse(xml.contains("<rating>"))
        XCTAssertFalse(xml.contains("<genre>"))
        XCTAssertFalse(xml.contains("<uniqueid"))
    }

    func testXMLContentUsesTVShowRootForAllNonMovieVideoCollections() {
        for type in [MediaType.tvShow, .anime, .documentary, .variety, .homeVideo, .episode] {
            let item = MediaItem(id: "item-\(type.rawValue)", type: type, title: "Collection")

            let xml = VideoMetadataSidecarWriter.xmlContent(for: item, update: MediaMetadataUpdate())

            XCTAssertTrue(xml.contains("<tvshow>"), "Expected \(type) to use the tvshow root")
            XCTAssertTrue(xml.contains("</tvshow>"), "Expected \(type) to close the tvshow root")
        }
    }

    func testWritePersistsUTF8XML() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("movie.nfo")
        let item = MediaItem(id: "movie-2", type: .movie, title: "海边电影")
        let update = MediaMetadataUpdate(overview: "中文简介")

        let wrote = try await VideoMetadataSidecarWriter.write(item: item, update: update, to: targetURL)

        XCTAssertTrue(wrote)
        let xml = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertTrue(xml.contains("<title>海边电影</title>"))
        XCTAssertTrue(xml.contains("<plot>中文简介</plot>"))
    }

    func testWriteOverwritesExistingSidecar() async throws {
        let directory = try temporaryDirectory()
        let targetURL = directory.appendingPathComponent("movie.nfo")
        try "old".write(to: targetURL, atomically: true, encoding: .utf8)
        let item = MediaItem(id: "movie-4", type: .movie, title: "Replacement")

        let wrote = try await VideoMetadataSidecarWriter.write(
            item: item,
            update: MediaMetadataUpdate(rating: 9.25),
            to: targetURL
        )

        XCTAssertTrue(wrote)
        let xml = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertFalse(xml.contains("old"))
        XCTAssertTrue(xml.contains("<title>Replacement</title>"))
        XCTAssertTrue(xml.contains("<rating>9.25</rating>"))
    }

    func testWriteReturnsFalseWhenDirectoryIsNotWritableTarget() async throws {
        let targetURL = try temporaryDirectory()
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("movie.nfo")
        let item = MediaItem(id: "movie-3", type: .movie, title: "Missing")

        let wrote = try await VideoMetadataSidecarWriter.write(
            item: item,
            update: MediaMetadataUpdate(),
            to: targetURL
        )

        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoMetadataSidecarWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}
