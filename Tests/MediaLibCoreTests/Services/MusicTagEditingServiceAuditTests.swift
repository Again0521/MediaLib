import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级音乐标签草稿清洗与批量修改专项】
/// 审计目标：验证 `MusicTagDraft` 在接收来自外部用户输入或刮削器返回的标签数据时，
/// 能否把前后冗余空格、空字串自愈清洗为真正的 nil，避免在写入 ID3/FLAC 文件时留下脏标签或破损字段；
/// 并确保在转换为 `MediaMetadataUpdate` 结构时各个核心字段百分百精确映射，不发生属性错位。
/// 对应报告问题 ID：TC-SCAN-005 / RISK-07
final class MusicTagEditingServiceAuditTests: XCTestCase {

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
}
