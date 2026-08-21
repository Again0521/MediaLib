import XCTest
@testable import MediaLibServer
import MediaLibServerProtocol

final class FFprobeMediaInspectorTests: XCTestCase {
    func testMapsFFprobeJSONIntoSafePlaybackDTO() throws {
        let inspector = FFprobeMediaInspector(
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffprobe-test-double") },
            runner: { _, _ in
                FFprobeProcessOutput(exitCode: 0, standardOutput: Data(Self.validJSON.utf8), standardError: Data())
            }
        )

        let info = try inspector.inspect(asset: asset())

        XCTAssertEqual(info.itemID, "movie-1")
        XCTAssertEqual(info.durationSeconds, 120.5)
        XCTAssertEqual(info.container, "mov,mp4,m4a,3gp,3g2,mj2")
        XCTAssertEqual(info.bitrate, 4_000_000)
        XCTAssertEqual(info.streams.count, 3)
        XCTAssertEqual(info.streams[0].codec, "h264")
        XCTAssertEqual(info.streams[0].width, 1920)
        XCTAssertEqual(info.streams[1].language, "zh")
        XCTAssertEqual(info.streams[2].type, "subtitle")
    }

    func testProbeFailureDoesNotExposeRawStderr() {
        let inspector = FFprobeMediaInspector(
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffprobe-test-double") },
            runner: { _, _ in
                FFprobeProcessOutput(
                    exitCode: 1,
                    standardOutput: Data(),
                    standardError: Data("/private/user-media/secret.mkv: Invalid data".utf8)
                )
            }
        )

        XCTAssertThrowsError(try inspector.inspect(asset: asset())) { error in
            XCTAssertEqual(error.localizedDescription, "ffprobe 无法读取媒体信息。")
            XCTAssertFalse(error.localizedDescription.contains("secret.mkv"))
        }
    }

    /// 输入参数是 `file:` + **未编码**的路径。
    ///
    /// 从前这里传的是 `URL.absoluteString`，也就是一个百分号编码过的 URL。ffmpeg 的
    /// file 协议逐字节取用路径、不做百分号解码，于是每一个带非 ASCII 文件名的条目
    /// 都探测失败——中日韩资料库里那几乎是全部。这不是理论问题：真实验收里
    /// `无声验收.mkv` 得到的就是 "No such file or directory"，音轨名单因此恒为空。
    ///
    /// 注入不是这里的风险来源：`Process` 直接传参数数组，中间没有 shell。`file:`
    /// 前缀防的是另外两件事——含冒号的文件名会被当成协议名，以横线开头的会被
    /// 当成选项。
    func testArgumentsPassTheRawPathBehindTheFileProtocol() {
        let fileURL = URL(fileURLWithPath: "/Volumes/Movies/电影 ; rm -rf /.mkv")
        let arguments = FFprobeMediaInspector.arguments(for: fileURL)

        XCTAssertEqual(Array(arguments.suffix(2)), ["-i", "file:/Volumes/Movies/电影 ; rm -rf /.mkv"])
        XCTAssertFalse(arguments.contains(where: { $0.contains("%E7%94%B5") }), "百分号编码会让 ffmpeg 找不到文件")
    }

    /// 含冒号、以横线开头的文件名都要能被原样交给 ffmpeg。
    func testInputArgumentSurvivesColonsAndLeadingDashes() {
        XCTAssertEqual(
            ServerMediaToolchain.inputArgument(for: URL(fileURLWithPath: "/media/My Movie: Part 2.mkv")),
            "file:/media/My Movie: Part 2.mkv"
        )
        XCTAssertEqual(
            ServerMediaToolchain.inputArgument(for: URL(fileURLWithPath: "/media/-strange.mkv")),
            "file:/media/-strange.mkv"
        )
    }

    func testDefaultInspectorCanProbeBundledImageWhenFFprobeIsInstalled() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("未找到用于 ffprobe 集成验证的内置图标。")
        }

        do {
            let info = try FFprobeMediaInspector().inspect(
                asset: ServerMediaAsset(id: "icon-fixture", fileURL: fixtureURL, byteLength: 1)
            )
            XCTAssertEqual(info.itemID, "icon-fixture")
            XCTAssertTrue(info.streams.contains { $0.type == "video" })
        } catch FFprobeMediaInspectorError.unavailable {
            throw XCTSkip("当前环境未安装 ffprobe；仅跳过真实进程集成验证。")
        }
    }

    private func asset() -> ServerMediaAsset {
        ServerMediaAsset(
            id: "movie-1",
            fileURL: URL(fileURLWithPath: "/private/never-disclosed/movie.mkv"),
            byteLength: 128
        )
    }

    private static let validJSON = #"""
    {
      "format": {
        "duration": "120.500000",
        "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
        "bit_rate": "4000000"
      },
      "streams": [
        { "index": 0, "codec_type": "video", "codec_name": "h264", "profile": "High", "width": 1920, "height": 1080 },
        { "index": 1, "codec_type": "audio", "codec_name": "aac", "channels": 2, "tags": { "language": "zh" } },
        { "index": 2, "codec_type": "subtitle", "codec_name": "subrip", "tags": { "language": "en" } },
        { "index": 3, "codec_type": "attachment", "codec_name": "ttf" }
      ]
    }
    """#
}
