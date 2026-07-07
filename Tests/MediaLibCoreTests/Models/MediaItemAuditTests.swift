import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级媒体条目计算属性与串流协议鉴别专项】
/// 审计目标：验证 `MediaItem` 在构建 UI 展示所必须的计算属性（如 `isRemoteResource`, `episodeLabel`, `sortKey`）
/// 时，能否百分之百兼容各类网络串流协议（HTTP, RTSP, RTMP, SRT, FTP 等）与剧集多重序号组合；
/// 并确保面对缺失年份、空标题或非法路径时，提供优雅的默认兜底显示而不过度解包抛错。
/// 对应报告问题 ID：TC-SCAN-011
final class MediaItemAuditTests: XCTestCase {

    /// 测试 isRemoteResource 能精准支持除了 HTTP/HTTPS 外的所有 MPV 串流协议
    func testIsRemoteResourceRecognizesAllMpvSupportedStreamingProtocols() {
        let protocols = ["http://x.com/1.mkv", "https://x.com/2.mp4", "rtsp://live.stream/1", "rtmp://server/live", "udp://239.0.0.1:1234", "srt://stream.server:9000", "ftp://nas.local/video.avi"]
        
        for p in protocols {
            var item = MediaItem(id: UUID().uuidString, type: .movie, title: "Stream")
            item.filePath = p
            XCTAssertTrue(item.isRemoteResource, "协议 \(p) 应该被正确判定为远程串流资源")
        }
        
        var localItem = MediaItem(id: "local", type: .movie, title: "Local")
        localItem.filePath = "/Users/test/Movies/local.mp4"
        XCTAssertFalse(localItem.isRemoteResource)
    }

    /// 测试剧集标签与卡片标题的智能格式化（带 S/E 或仅单序号）
    func testEpisodeLabelAndCardTitleFormatting() {
        var s1e5 = MediaItem(id: "ep-01", type: .episode, title: "The One Where...")
        s1e5.seasonNumber = 1
        s1e5.episodeNumber = 5
        
        XCTAssertEqual(s1e5.episodeLabel, "S01E05")
        XCTAssertEqual(s1e5.cardTitle, "S01E05  The One Where...")
        
        var onlyEp = MediaItem(id: "ep-02", type: .episode, title: "Special Episode")
        onlyEp.episodeNumber = 12
        XCTAssertEqual(onlyEp.episodeLabel, "第 12 集")
        XCTAssertEqual(onlyEp.cardTitle, "第 12 集  Special Episode")
    }

    /// 测试播放记录痕迹判定与艺术家专辑拼接逻辑
    func testPlaybackTraceAndArtistAlbumLine() {
        var item = MediaItem(id: "music-01", type: .music, title: "Song")
        XCTAssertFalse(item.hasPlaybackTrace)
        
        item.playPosition = 10.5
        XCTAssertTrue(item.hasPlaybackTrace, "只要有播放进度即视为拥有播放痕迹")
        
        item.artist = "Michael Jackson"
        item.album = "Thriller"
        XCTAssertEqual(item.artistAlbumLine, "Michael Jackson · Thriller")
        
        item.album = ""
        XCTAssertEqual(item.artistAlbumLine, "Michael Jackson", "空字符串字段在拼接时必须被干净剔除")
    }

    /// 测试非有限播放进度不会被误判为真实播放痕迹
    func testPlaybackTraceIgnoresNonFinitePlaybackValues() {
        let nonFiniteValues = [Double.nan, Double.infinity, -Double.infinity]

        for value in nonFiniteValues {
            var positionItem = MediaItem(id: "position-\(value)", type: .movie, title: "Corrupt Position")
            positionItem.playPosition = value
            XCTAssertFalse(positionItem.hasPlaybackTrace, "非有限 playPosition 不应伪造播放痕迹")

            var progressItem = MediaItem(id: "progress-\(value)", type: .movie, title: "Corrupt Progress")
            progressItem.playProgress = value
            XCTAssertFalse(progressItem.hasPlaybackTrace, "非有限 playProgress 不应伪造播放痕迹")
        }

        let playedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let timestampItem = MediaItem(
            id: "timestamp-trace",
            type: .movie,
            title: "Timestamp Trace",
            playPosition: Double.nan,
            playProgress: Double.infinity,
            lastPlayedAt: playedAt
        )
        XCTAssertTrue(timestampItem.hasPlaybackTrace, "明确的最后播放时间仍应保留播放痕迹语义")

        let watchedItem = MediaItem(
            id: "watched-trace",
            type: .movie,
            title: "Watched Trace",
            playPosition: -Double.infinity,
            playProgress: Double.nan,
            watched: true
        )
        XCTAssertTrue(watchedItem.hasPlaybackTrace, "明确 watched 标记仍应保留播放痕迹语义")
    }
}
