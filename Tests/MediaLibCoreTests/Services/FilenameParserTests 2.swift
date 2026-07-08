import XCTest
@testable import MediaLibCore

// 文件名解析回归测试（审查报告 10 高价值用例）：FilenameParser 是纯函数式的扫描入口，
// 历史发生过「剧集/电影识别错」「TMDB 匹配不上」事故；以下用例锁定其当前行为，作为后续重构的安全网。
final class FilenameParserTests: XCTestCase {
    private let parser = FilenameParser()

    // MARK: - 扩展名识别

    func testVideoExtensionDetection() {
        XCTAssertTrue(parser.isVideoFile(URL(fileURLWithPath: "/m/clip.mkv")))
        XCTAssertTrue(parser.isVideoFile(URL(fileURLWithPath: "/m/clip.MP4")))   // 大小写无关
        XCTAssertFalse(parser.isVideoFile(URL(fileURLWithPath: "/m/clip.txt")))
        XCTAssertFalse(parser.isVideoFile(URL(fileURLWithPath: "/m/clip.flac")))
    }

    func testAudioExtensionDetection() {
        XCTAssertTrue(parser.isAudioFile(URL(fileURLWithPath: "/m/song.flac")))
        XCTAssertTrue(parser.isAudioFile(URL(fileURLWithPath: "/m/song.mp3")))
        XCTAssertFalse(parser.isAudioFile(URL(fileURLWithPath: "/m/song.mkv")))
    }

    func testImageExtensionDetection() {
        XCTAssertTrue(parser.isImageFile(URL(fileURLWithPath: "/p/pic.jpg")))
        XCTAssertTrue(parser.isImageFile(URL(fileURLWithPath: "/p/pic.HEIC")))
        XCTAssertFalse(parser.isImageFile(URL(fileURLWithPath: "/p/pic.mp4")))
    }

    // MARK: - 电影

    func testParsesMovieWithYearAndStripsReleaseNoise() {
        let url = URL(fileURLWithPath: "/Movies/Inception.2010.1080p.BluRay.x265.mkv")
        let result = parser.parse(url: url, preferredType: .movie)
        XCTAssertEqual(result.kind, .movie)
        XCTAssertEqual(result.year, 2010)
        XCTAssertEqual(result.title, "Inception")   // 年份/分辨率/压制标记被清洗
        XCTAssertNil(result.seasonNumber)
        XCTAssertNil(result.episodeNumber)
    }

    func testParsesMovieWithoutYear() {
        let url = URL(fileURLWithPath: "/Movies/SomeIndependentFilm.mkv")
        let result = parser.parse(url: url, preferredType: .movie)
        XCTAssertEqual(result.kind, .movie)
        XCTAssertNil(result.year)
        XCTAssertEqual(result.title, "SomeIndependentFilm")
    }

    // MARK: - 剧集

    func testParsesEpisodeSxxExx() {
        let url = URL(fileURLWithPath: "/TV/Breaking Bad/Breaking Bad.S02E07.mkv")
        let result = parser.parse(url: url, preferredType: .tvShow)
        XCTAssertEqual(result.kind, .episode)
        XCTAssertEqual(result.seasonNumber, 2)
        XCTAssertEqual(result.episodeNumber, 7)
        XCTAssertEqual(result.title, "Breaking Bad")
    }

    func testDetectsEpisodeEvenWithAutoType() {
        // .auto 不应把明显的 SxxExx 误判为电影。
        let url = URL(fileURLWithPath: "/TV/The Wire/The Wire.S03E11.mkv")
        let result = parser.parse(url: url, preferredType: .auto)
        XCTAssertEqual(result.kind, .episode)
        XCTAssertEqual(result.seasonNumber, 3)
        XCTAssertEqual(result.episodeNumber, 11)
    }

    func testParsesChineseSeasonEpisode() {
        let url = URL(fileURLWithPath: "/剧集/某剧/某剧 第2季第05集.mkv")
        let result = parser.parse(url: url, preferredType: .tvShow)
        XCTAssertEqual(result.kind, .episode)
        XCTAssertEqual(result.seasonNumber, 2)
        XCTAssertEqual(result.episodeNumber, 5)
    }

    func testParsesEPPatternDefaultsToSeasonOne() {
        let url = URL(fileURLWithPath: "/Anime/ShowName/ShowName.EP12.mkv")
        let result = parser.parse(url: url, preferredType: .tvShow)
        XCTAssertEqual(result.kind, .episode)
        XCTAssertEqual(result.episodeNumber, 12)
        XCTAssertEqual(result.seasonNumber, 1)   // 无季信息回落到第 1 季
    }
}
