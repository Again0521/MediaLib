import XCTest
import MediaLibCore
@testable import MediaLib

final class URLSourcePolicyTests: XCTestCase {
    func testNormalizedURLStringAcceptsSupportedMediaSchemesAndTrimsWhitespace() {
        XCTAssertEqual(
            URLSourcePolicy.normalizedURLString("  https://media.example/video.mp4  "),
            "https://media.example/video.mp4"
        )
        XCTAssertEqual(
            URLSourcePolicy.normalizedURLString("RTSP://camera.example/live"),
            "RTSP://camera.example/live"
        )
        XCTAssertEqual(
            URLSourcePolicy.normalizedURLString("srt://stream.example:9000"),
            "srt://stream.example:9000"
        )
    }

    func testNormalizedURLStringRejectsUnsupportedOrHostlessInputs() {
        XCTAssertNil(URLSourcePolicy.normalizedURLString(""))
        XCTAssertNil(URLSourcePolicy.normalizedURLString("not a url"))
        XCTAssertNil(URLSourcePolicy.normalizedURLString("file:///Users/test/movie.mp4"))
        XCTAssertNil(URLSourcePolicy.normalizedURLString("https:///missing-host.mp4"))
        XCTAssertNil(URLSourcePolicy.normalizedURLString("magnet:?xt=urn:btih:abc"))
    }

    func testDefaultTitleUsesLastPathComponentStemThenHostFallback() {
        XCTAssertEqual(
            URLSourcePolicy.defaultTitle(forURL: "https://media.example/path/Movie.Title.2026.mkv"),
            "Movie.Title.2026"
        )
        XCTAssertEqual(
            URLSourcePolicy.defaultTitle(forURL: "https://media.example/live/"),
            "live"
        )
        XCTAssertEqual(
            URLSourcePolicy.defaultTitle(forURL: "https://media.example/"),
            "media.example"
        )
        XCTAssertEqual(
            URLSourcePolicy.defaultTitle(forURL: ""),
            "URL 视频"
        )
    }

    func testDefaultTitlePreservesFoundationRelativeURLFallbackBehavior() {
        XCTAssertEqual(
            URLSourcePolicy.defaultTitle(forURL: "not a url"),
            "not a url"
        )
    }

    func testAddableURLCountDeduplicatesValidNormalizedLinks() {
        let raw = """
        https://media.example/a.mp4
        invalid
          https://media.example/a.mp4
        rtsp://camera.example/live
        file:///tmp/local.mp4
        """

        XCTAssertEqual(URLSourcePolicy.addableURLCount(in: raw), 2)
    }

    func testNormalizedMultilineURLsKeepsValidURLsInInputOrder() {
        let raw = """
        invalid
        https://media.example/a.mp4
        rtmp://live.example/channel
        """

        XCTAssertEqual(
            URLSourcePolicy.normalizedMultilineURLs(from: raw),
            [
                "https://media.example/a.mp4",
                "rtmp://live.example/channel"
            ]
        )
    }

    func testProbeItemsIncludesOnlyHTTPAndHTTPSPlayableURLs() {
        let items = [
            mediaItem(id: "https", filePath: "https://media.example/a.mp4"),
            mediaItem(id: "http", filePath: "http://media.example/b.mp4"),
            mediaItem(id: "uppercase", filePath: "HTTPS://media.example/c.mp4"),
            mediaItem(id: "rtsp", filePath: "rtsp://camera.example/live"),
            mediaItem(id: "local", filePath: "/Users/test/movie.mp4"),
            mediaItem(id: "missing", filePath: nil)
        ]

        let probeItems = URLSourcePolicy.probeItems(from: items)

        XCTAssertEqual(probeItems.map(\.id), ["https", "http", "uppercase"])
        XCTAssertEqual(probeItems.map { $0.url.absoluteString }, [
            "https://media.example/a.mp4",
            "http://media.example/b.mp4",
            "HTTPS://media.example/c.mp4"
        ])
    }

    private func mediaItem(id: String, filePath: String?) -> MediaItem {
        MediaItem(
            id: id,
            type: .homeVideo,
            title: id,
            sourcePath: URLSourcePolicy.mediaSourcePath,
            filePath: filePath
        )
    }
}
