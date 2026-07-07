import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级音乐标签草稿清洗与批量修改专项】
/// 审计目标：验证 `MusicTagDraft` 在接收来自外部用户输入或刮削器返回的标签数据时，
/// 能否把前后冗余空格、空字串自愈清洗为真正的 nil，避免在写入 ID3/FLAC 文件时留下脏标签或破损字段；
/// 并确保在转换为 `MediaMetadataUpdate` 结构时各个核心字段百分百精确映射，不发生属性错位。
/// 对应报告问题 ID：TC-SCAN-005 / RISK-07
final class MusicTagEditingServiceAuditTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    /// 测试标签草稿自动清理空字符串和首尾空格
    func testMusicTagDraftCleansWhitespaceAndEmptyStringsToNil() {
        let draft = MusicTagDraft(
            title: "   Song Title With Spaces   \t",
            artist: "",
            album: "  \n  ",
            genre: "Rock",
            trackNumber: 5,
            year: 1999,
            lyrics: "   ",
            artworkPath: "/path/to/art.jpg   ",
            externalID: "  tt1234567  ",
            metadataProvider: ""
        )
        
        XCTAssertEqual(draft.title, "Song Title With Spaces")
        XCTAssertNil(draft.artist, "纯空字符串必须被自动清洗降级为 nil")
        XCTAssertNil(draft.album, "仅包含换行或空格的字串必须被归零为 nil")
        XCTAssertEqual(draft.genre, "Rock")
        XCTAssertEqual(draft.trackNumber, 5)
        XCTAssertEqual(draft.year, 1999)
        XCTAssertNil(draft.lyrics)
        XCTAssertEqual(draft.artworkPath, "/path/to/art.jpg")
        XCTAssertEqual(draft.externalID, "tt1234567")
        XCTAssertNil(draft.metadataProvider)
    }

    /// 测试从 MediaItem 创建草稿与生成更新对象的属性绝对一致性
    func testMusicTagDraftMediaMetadataUpdateMappingPrecision() {
        var item = MediaItem(id: "music-item-01", type: .music, title: "Original Title")
        item.artist = "Original Artist"
        item.album = "Original Album"
        item.trackNumber = 12
        item.year = 2024
        item.posterPath = "/path/to/poster.png"
        item.externalID = "ext-999"
        
        let draft = MusicTagDraft(item: item, lyrics: "Here are some lyrics...")
        let update = draft.metadataUpdate
        
        XCTAssertEqual(update.title, "Original Title")
        XCTAssertEqual(update.artist, "Original Artist")
        XCTAssertEqual(update.album, "Original Album")
        XCTAssertEqual(update.trackNumber, 12)
        XCTAssertEqual(update.year, 2024)
        XCTAssertEqual(update.posterPath, "/path/to/poster.png")
        XCTAssertEqual(update.externalID, "ext-999")
    }

    func testWriteRunsFileReplacementOnBlockingIOQueueAndRestoresOriginalAttributes() async throws {
        let directory = try makeTemporaryDirectory()
        let inputURL = directory.appendingPathComponent("song.mp3")
        try Data("original-audio".utf8).write(to: inputURL)
        let originalModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644)), .modificationDate: originalModificationDate],
            ofItemAtPath: inputURL.path
        )

        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            ffmpegRunner: { _, arguments, timeout in
                XCTAssertTrue(BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue())
                XCTAssertEqual(timeout, 90)
                guard let outputPath = arguments.last else {
                    return (false, "missing output")
                }
                do {
                    try Data("tagged-audio".utf8).write(to: URL(fileURLWithPath: outputPath))
                    return (true, "")
                } catch {
                    return (false, error.localizedDescription)
                }
            }
        )

        let report = try await service.write(
            MusicTagDraft(title: "  Updated Song  ", artist: "Artist"),
            to: makeMusicItem(fileURL: inputURL)
        )

        XCTAssertEqual(report.filePath, inputURL.path)
        XCTAssertEqual(report.updatedFieldCount, 2)
        XCTAssertNil(report.warning)
        XCTAssertEqual(try Data(contentsOf: inputURL), Data("tagged-audio".utf8))

        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let restoredPermissions = (restoredAttributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(restoredPermissions, 0o644)
        let restoredDate = try XCTUnwrap(restoredAttributes[.modificationDate] as? Date)
        XCTAssertLessThan(abs(restoredDate.timeIntervalSince(originalModificationDate)), 1.0)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("medialib-tag") }
        XCTAssertTrue(leftovers.isEmpty, "临时标签文件和备份文件必须在成功替换后清理干净")
    }

    func testWriteFallsBackToTextTagsWhenArtworkEmbeddingFails() async throws {
        let directory = try makeTemporaryDirectory()
        let inputURL = directory.appendingPathComponent("song.mp3")
        let artworkURL = directory.appendingPathComponent("cover.jpg")
        try Data("original-audio".utf8).write(to: inputURL)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: artworkURL)
        let recorder = FFmpegCallRecorder()

        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            ffmpegRunner: { _, arguments, _ in
                XCTAssertTrue(BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue())
                recorder.append(arguments)
                if arguments.contains(artworkURL.path) {
                    return (false, "cannot embed artwork")
                }
                guard let outputPath = arguments.last else {
                    return (false, "missing output")
                }
                do {
                    try Data("text-only-tags".utf8).write(to: URL(fileURLWithPath: outputPath))
                    return (true, "")
                } catch {
                    return (false, error.localizedDescription)
                }
            }
        )

        let report = try await service.write(
            MusicTagDraft(title: "Song", artworkPath: artworkURL.path),
            to: makeMusicItem(fileURL: inputURL)
        )

        XCTAssertEqual(report.updatedFieldCount, 1)
        XCTAssertEqual(report.warning, "封面写入失败，已只写入文字标签。")
        XCTAssertEqual(try Data(contentsOf: inputURL), Data("text-only-tags".utf8))
        let calls = recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains(artworkURL.path))
        XCTAssertFalse(calls[1].contains(artworkURL.path))
    }

    func testWriteSkipsUppercaseHTTPArtworkURLEvenWhenMatchingRelativeFileExists() async throws {
        let directory = try makeTemporaryDirectory()
        let originalWorkingDirectory = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory)
        }

        let inputURL = directory.appendingPathComponent("song.mp3")
        try Data("original-audio".utf8).write(to: inputURL)

        let misleadingArtworkURL = URL(fileURLWithPath: "HTTP://assets.example/cover.jpg")
        try FileManager.default.createDirectory(
            at: misleadingArtworkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: misleadingArtworkURL)
        let recorder = FFmpegCallRecorder()

        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            ffmpegRunner: { _, arguments, _ in
                XCTAssertTrue(BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue())
                recorder.append(arguments)
                XCTAssertFalse(arguments.contains(misleadingArtworkURL.path))
                guard let outputPath = arguments.last else {
                    return (false, "missing output")
                }
                do {
                    try Data("tagged-audio".utf8).write(to: URL(fileURLWithPath: outputPath))
                    return (true, "")
                } catch {
                    return (false, error.localizedDescription)
                }
            }
        )

        let report = try await service.write(
            MusicTagDraft(title: "Song", artworkPath: "HTTP://assets.example/cover.jpg"),
            to: makeMusicItem(fileURL: inputURL)
        )

        XCTAssertEqual(report.updatedFieldCount, 1)
        XCTAssertNil(report.warning)
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testWriteWithEmptyDraftReturnsWarningWithoutResolvingFFmpeg() async throws {
        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: {
                XCTFail("空草稿没有可写字段时不应解析 ffmpeg")
                return nil
            },
            ffmpegRunner: { _, _, _ in
                XCTFail("空草稿没有可写字段时不应进入写入 runner")
                return (false, "unexpected")
            }
        )

        let item = MediaItem(id: "empty", type: .music, title: "Empty", filePath: "/tmp/empty.mp3")
        let report = try await service.write(MusicTagDraft(), to: item)

        XCTAssertEqual(report.filePath, "/tmp/empty.mp3")
        XCTAssertEqual(report.updatedFieldCount, 0)
        XCTAssertEqual(report.warning, "没有可写入的标签字段。")
    }

    func testCanWriteFileTagsRejectsWhitespaceOnlyLocalPath() {
        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            ffmpegRunner: { _, _, _ in
                XCTFail("canWriteFileTags 不应进入写入 runner")
                return (false, "unexpected")
            }
        )

        let item = MediaItem(id: "blank-path", type: .music, title: "Blank Path", filePath: " \n\t ")

        XCTAssertFalse(service.canWriteFileTags(for: item))
    }

    func testWriteRejectsWhitespaceOnlyLocalPathBeforeResolvingFFmpeg() async {
        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: {
                XCTFail("纯空白本地路径必须在解析 ffmpeg 之前被拒绝")
                return nil
            },
            ffmpegRunner: { _, _, _ in
                XCTFail("纯空白本地路径不应进入写入 runner")
                return (false, "unexpected")
            }
        )

        do {
            _ = try await service.write(
                MusicTagDraft(title: "Song"),
                to: MediaItem(id: "blank-path", type: .music, title: "Blank Path", filePath: " \n\t ")
            )
            XCTFail("预期抛出 missingFile")
        } catch MusicTagEditingError.missingFile {
            // Expected.
        } catch {
            XCTFail("捕获到了非预期的错误类型：\(error)")
        }
    }

    func testWriteRejectsUnsupportedFormatBeforeResolvingFFmpeg() async {
        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: {
                XCTFail("不支持的扩展名必须在解析 ffmpeg 之前被拒绝")
                return nil
            },
            ffmpegRunner: { _, _, _ in
                XCTFail("不支持的扩展名不应进入写入 runner")
                return (false, "unexpected")
            }
        )

        do {
            _ = try await service.write(
                MusicTagDraft(title: "Song"),
                to: MediaItem(id: "unsupported", type: .music, title: "Unsupported", filePath: "/tmp/song.txt")
            )
            XCTFail("预期抛出 unsupportedFormat")
        } catch MusicTagEditingError.unsupportedFormat(let ext) {
            XCTAssertEqual(ext, "txt")
        } catch {
            XCTFail("捕获到了非预期的错误类型：\(error)")
        }
    }

    func testWriteMissingLocalFileDoesNotRunFFmpeg() async {
        let service = MusicTagEditingService(
            ffmpegExecutableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            ffmpegRunner: { _, _, _ in
                XCTFail("缺失文件必须在执行 ffmpeg 前被拒绝")
                return (false, "unexpected")
            }
        )

        do {
            _ = try await service.write(
                MusicTagDraft(title: "Song"),
                to: MediaItem(id: "missing", type: .music, title: "Missing", filePath: "/tmp/definitely-missing-song.mp3")
            )
            XCTFail("预期抛出 missingFile")
        } catch MusicTagEditingError.missingFile {
            // Expected.
        } catch {
            XCTFail("捕获到了非预期的错误类型：\(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibMusicTagEditingServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeMusicItem(fileURL: URL) -> MediaItem {
        MediaItem(id: UUID().uuidString, type: .music, title: "Song", filePath: fileURL.path)
    }
}

private final class FFmpegCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []

    func append(_ arguments: [String]) {
        lock.lock()
        storedCalls.append(arguments)
        lock.unlock()
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }
}
