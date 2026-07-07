import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级本地 NFO 解析提取与乱码大文件防挂起专项】
/// 审计目标：验证 `LocalMetadataService` 在扫描和解析本地影视目录下的 `.nfo` 文件时，
/// 预编译的正则规则能否精准提取中日韩多语种标题、年份与剧情简介（支持 <plot> 和 <overview> 双标签）；
/// 并确保当遭遇数 MB 大小的异常乱码 NFO 或嵌套标签文件时，正则匹配不会发生 ReDoS 灾难性回溯卡死。
/// 对应报告问题 ID：TC-SCAN-010 / RISK-07
final class LocalMetadataServiceAuditTests: XCTestCase {
    private var tempDir: URL!
    private var service: LocalMetadataService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMetaAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = LocalMetadataService()
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试标准 Kodi / Emby 格式的 NFO 文件多字段完美提取
    func testParseStandardNFOExtractsTitleYearAndOverview() throws {
        let nfoContent = """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <movie>
            <title>流浪地球 2 (The Wandering Earth II)</title>
            <originaltitle>Liu Lang Di Qiu 2</originaltitle>
            <year>2023</year>
            <plot>太阳即将毁灭，人类在地球表面建造出巨大的推进器...</plot>
        </movie>
        """
        
        let nfoURL = tempDir.appendingPathComponent("movie.nfo")
        try nfoContent.write(to: nfoURL, atomically: true, encoding: .utf8)
        
        let videoURL = tempDir.appendingPathComponent("movie.mp4")
        let meta = service.metadata(for: videoURL, readNFO: true, preferLocalArtwork: false)
        
        XCTAssertEqual(meta.title, "流浪地球 2 (The Wandering Earth II)")
        XCTAssertEqual(meta.originalTitle, "Liu Lang Di Qiu 2")
        XCTAssertEqual(meta.year, 2023)
        XCTAssertEqual(meta.overview, "太阳即将毁灭，人类在地球表面建造出巨大的推进器...")
    }

    /// 测试 overview 标签优先级与本地封面图片自动寻找
    func testOverviewTagAndPreferLocalArtworkMatching() throws {
        let nfoContent = """
        <movie>
            <title>Avatar</title>
            <overview>On the lush alien world of Pandora...</overview>
        </movie>
        """
        let nfoURL = tempDir.appendingPathComponent("avatar.nfo")
        try nfoContent.write(to: nfoURL, atomically: true, encoding: .utf8)
        
        // 在目录中创建模拟的海报文件
        let posterURL = tempDir.appendingPathComponent("poster.jpg")
        try Data(repeating: 0xFF, count: 100).write(to: posterURL)
        
        let videoURL = tempDir.appendingPathComponent("avatar.mkv")
        let meta = service.metadata(for: videoURL, readNFO: true, preferLocalArtwork: true)
        
        XCTAssertEqual(meta.title, "Avatar")
        XCTAssertEqual(meta.overview, "On the lush alien world of Pandora...")
        XCTAssertEqual(meta.posterPath, posterURL.path, "preferLocalArtwork 为 true 时应自动配对目录下的 poster.jpg")
    }

    func testPlotTakesPrecedenceOverOverviewAndInvalidYearIsIgnored() throws {
        let nfoContent = """
        <movie>
            <title>边界电影</title>
            <year>20XX</year>
            <plot>plot 字段优先</plot>
            <overview>overview 只作为兜底</overview>
        </movie>
        """
        try nfoContent.write(to: tempDir.appendingPathComponent("movie.nfo"), atomically: true, encoding: .utf8)

        let meta = service.metadata(
            for: tempDir.appendingPathComponent("movie.mp4"),
            readNFO: true,
            preferLocalArtwork: false
        )

        XCTAssertEqual(meta.title, "边界电影")
        XCTAssertNil(meta.year)
        XCTAssertEqual(meta.overview, "plot 字段优先")
    }

    func testReadNFOFalseSkipsTextMetadataButStillHonorsLocalArtworkPreference() throws {
        try """
        <movie>
            <title>Should Not Be Read</title>
            <year>2024</year>
        </movie>
        """.write(to: tempDir.appendingPathComponent("movie.nfo"), atomically: true, encoding: .utf8)
        let posterURL = tempDir.appendingPathComponent("cover.webp")
        let backdropURL = tempDir.appendingPathComponent("fanart.png")
        try Data([0x01]).write(to: posterURL)
        try Data([0x02]).write(to: backdropURL)

        let meta = service.metadata(
            for: tempDir.appendingPathComponent("movie.mp4"),
            readNFO: false,
            preferLocalArtwork: true
        )

        XCTAssertNil(meta.title)
        XCTAssertNil(meta.year)
        XCTAssertEqual(meta.posterPath, posterURL.path)
        XCTAssertEqual(meta.backdropPath, backdropURL.path)
    }

    func testPreferLocalArtworkFalseDoesNotReturnExistingArtworkFiles() throws {
        try Data([0xFF]).write(to: tempDir.appendingPathComponent("poster.jpg"))
        try Data([0xEE]).write(to: tempDir.appendingPathComponent("background.heic"))

        let meta = service.metadata(
            for: tempDir.appendingPathComponent("movie.mp4"),
            readNFO: false,
            preferLocalArtwork: false
        )

        XCTAssertNil(meta.posterPath)
        XCTAssertNil(meta.backdropPath)
    }

    func testNearVideoNFOCandidatePriorityUsesMovieThenTVShowThenVideoSpecific() throws {
        try """
        <movie>
            <title>Movie Candidate</title>
        </movie>
        """.write(to: tempDir.appendingPathComponent("movie.nfo"), atomically: true, encoding: .utf8)
        try """
        <tvshow>
            <title>TV Candidate</title>
        </tvshow>
        """.write(to: tempDir.appendingPathComponent("tvshow.nfo"), atomically: true, encoding: .utf8)
        try """
        <movie>
            <title>Video Specific Candidate</title>
        </movie>
        """.write(to: tempDir.appendingPathComponent("episode.nfo"), atomically: true, encoding: .utf8)

        let meta = service.metadata(
            for: tempDir.appendingPathComponent("episode.mkv"),
            readNFO: true,
            preferLocalArtwork: false
        )

        XCTAssertEqual(meta.title, "Movie Candidate")
    }

    func testNearVideoNFOPrefersVideoSpecificWhenSharedFilesAreAbsent() throws {
        try """
        <movie>
            <title>Video Specific Candidate</title>
            <overview>Sidecar next to the media file.</overview>
        </movie>
        """.write(to: tempDir.appendingPathComponent("episode.nfo"), atomically: true, encoding: .utf8)

        let meta = service.metadata(
            for: tempDir.appendingPathComponent("episode.mkv"),
            readNFO: true,
            preferLocalArtwork: false
        )

        XCTAssertEqual(meta.title, "Video Specific Candidate")
        XCTAssertEqual(meta.overview, "Sidecar next to the media file.")
    }

    /// 测试读取 2MB 包含海量特殊标记与乱码的异常 NFO 文件不会产生 ReDoS 卡死
    func testLargeMaliciousNFOFileDoesNotCauseReDoSHang() throws {
        let largeJunk = String(repeating: "<title>Broken Tag No Close ", count: 50000) // ~1.2MB
        let nfoURL = tempDir.appendingPathComponent("malicious.nfo")
        try largeJunk.write(to: nfoURL, atomically: true, encoding: .utf8)
        
        let videoURL = tempDir.appendingPathComponent("malicious.mp4")
        
        let startTime = Date()
        let meta = service.metadata(for: videoURL, readNFO: true, preferLocalArtwork: false)
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertTrue(elapsed < 1.5, "遇到畸形超大 NFO 文件时，预编译正则不能发生灾难性回溯卡住线程")
        XCTAssertNil(meta.title, "破损无闭合的标签不应提取出垃圾字符串")
    }

    func testAsyncMetadataMatchesSyncResultAndRunsFileLookupsOnBlockingIOQueue() async throws {
        let nfoContent = """
        <movie>
            <title>Async Local Metadata</title>
            <year>2026</year>
            <overview>Loaded through the blocking I/O executor.</overview>
        </movie>
        """
        try nfoContent.write(to: tempDir.appendingPathComponent("movie.nfo"), atomically: true, encoding: .utf8)
        let posterURL = tempDir.appendingPathComponent("poster.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: posterURL)

        let recordingFileManager = BlockingIORecordingFileManager()
        let asyncService = LocalMetadataService(fileManager: recordingFileManager)
        let videoURL = tempDir.appendingPathComponent("async.mp4")

        let syncMeta = asyncService.metadata(for: videoURL, readNFO: true, preferLocalArtwork: true)
        let asyncMeta = await asyncService.metadataAsync(for: videoURL, readNFO: true, preferLocalArtwork: true)

        XCTAssertEqual(asyncMeta.title, syncMeta.title)
        XCTAssertEqual(asyncMeta.year, syncMeta.year)
        XCTAssertEqual(asyncMeta.overview, syncMeta.overview)
        XCTAssertEqual(asyncMeta.posterPath, posterURL.path)
        XCTAssertTrue(recordingFileManager.didObserveBlockingIOQueue)
    }

    func testAsyncDirectoryMetadataReadsTVShowNFOBeforeMovieNFO() async throws {
        try """
        <movie>
            <title>Movie Fallback</title>
        </movie>
        """.write(to: tempDir.appendingPathComponent("movie.nfo"), atomically: true, encoding: .utf8)
        try """
        <tvshow>
            <title>Series Title</title>
            <year>2025</year>
        </tvshow>
        """.write(to: tempDir.appendingPathComponent("tvshow.nfo"), atomically: true, encoding: .utf8)

        let meta = await service.metadataAsync(forDirectory: tempDir, readNFO: true, preferLocalArtwork: false)

        XCTAssertEqual(meta.title, "Series Title")
        XCTAssertEqual(meta.year, 2025)
    }
}

private final class BlockingIORecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var observedBlockingIOQueue = false

    var didObserveBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedBlockingIOQueue
    }

    override func fileExists(atPath path: String) -> Bool {
        if BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue() {
            lock.lock()
            observedBlockingIOQueue = true
            lock.unlock()
        }
        return super.fileExists(atPath: path)
    }
}
