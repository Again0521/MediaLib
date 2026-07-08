import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P2级多语种文件名解析与年份陷阱专项】
/// 审计目标：验证 `FilenameParser` 在面对多重组别标签、韩文/俄文/日文混合、
/// 以及标题中含有“2001太空漫游”、“1984”、“4K”、“1080p”等伪年份或数字陷阱时的解析精度。
/// 对应报告问题 ID：RISK-09
final class FilenameParserMultiLanguageTests: XCTestCase {

    /// 测试标题中带有数字或伪年份陷阱的电影名称提取
    func testFilenameWithNumberOrFakeYearTraps() {
        // 场景 1：电影名字本身就是一个年份（例如《1917》、《1984》、《2001太空漫游》）
        let movie1984 = "[BD-Remux] 1984 (1984) [1080p_FLAC].mkv"
        let parsed1984 = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + movie1984))
        XCTAssertEqual(parsed1984.year, 1984)
        XCTAssertEqual(parsed1984.title, "1984", "标题为纯数字年份时，不应被错误裁掉")

        // 场景 2：标题中含有其他数字（如 2001太空漫游、赛博朋克2077）
        let space2001 = "2001太空漫游.2001.A.Space.Odyssey.1968.UHD.BluRay.2160p.TrueHD.7.1.x265.mkv"
        let parsed2001 = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + space2001))
        XCTAssertEqual(parsed2001.year, 1968, "应准确抓取真实上映年份 1968，而非标题内的 2001 或分辨率 2160")
        XCTAssertTrue(parsed2001.title.contains("2001太空漫游") || parsed2001.title.contains("2001 A Space Odyssey"))
    }

    /// 测试多语种混合及极复杂动漫多括号压制组标签
    func testMultiLanguageAndComplexReleaseGroupTags() {
        let animeFile = "[Ohys-Raws] 进击的巨人 / 進撃の巨人 / Attack on Titan - 01 (BS11 1280x720 x264 AAC).mp4"
        let parsed = FilenameParser().parse(url: URL(fileURLWithPath: "/Anime/" + animeFile))

        XCTAssertFalse(parsed.title.isEmpty)
        XCTAssertTrue(parsed.title.contains("进击的巨人") || parsed.title.contains("Attack on Titan"))
        XCTAssertNil(parsed.year, "没有年份信息的动漫剧集不应错误从分辨率 1280 或 720 中捏造年份")
    }

    /// 测试韩文与俄文多字集标题提取
    func testKoreanAndRussianTitles() {
        let koreanMovie = "기생충.Parasite.2019.1080p.FHDRip.H264.AAC.mp4"
        let parsedKr = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + koreanMovie))
        XCTAssertEqual(parsedKr.year, 2019)
        XCTAssertTrue(parsedKr.title.contains("기생충") || parsedKr.title.contains("Parasite"))

        let russianMovie = "Солярис.Solaris.1972.BD.Remux.1080p.mkv"
        let parsedRu = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + russianMovie))
        XCTAssertEqual(parsedRu.year, 1972)
        XCTAssertTrue(parsedRu.title.contains("Солярис") || parsedRu.title.contains("Solaris"))
    }
}
