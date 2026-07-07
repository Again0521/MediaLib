import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级媒体源网络凭据脱敏与协议分类专项】
/// 审计目标：验证 `MediaSource.displayPath` 在处理包含敏感账号密码的远程协议地址
/// （如 SMB, FTP, Emby, Plex 等）时，能否在展现层百分之百自动剥离 user 和 password，
/// 杜绝在界面、错误提示框及截屏中外泄网络存储密码；
/// 同时验证其 `sourceKind` 对 URL 前缀及命名规则的精准判别。
/// 对应报告问题 ID：TC-SEC-007 / RISK-04
final class MediaSourceAuditTests: XCTestCase {

    /// 测试 displayPath 绝对剥离 SMB / FTP / Emby URL 中的明文账号密码
    func testDisplayPathStripsUsernameAndPasswordFromNetworkURLs() {
        let sensitiveSMB = "smb://admin:SuperSecretPw123@192.168.1.100/Movies/HD"
        let sensitiveFTP = "ftp://backup_user:Pw%23456@ftp.home.local:2121/Videos"
        let sensitiveEmby = "emby://user:token999@emby.server.net/library"
        
        var smbSource = MediaSource(name: "SMB Store", path: sensitiveSMB)
        var ftpSource = MediaSource(name: "FTP Store", path: sensitiveFTP)
        var embySource = MediaSource(name: "Emby Store", path: sensitiveEmby)
        
        XCTAssertEqual(smbSource.displayPath, "smb://192.168.1.100/Movies/HD", "SMB 路径展现时不能包含任何明文账号密码")
        XCTAssertEqual(ftpSource.displayPath, "ftp://ftp.home.local:2121/Videos")
        XCTAssertEqual(embySource.displayPath, "emby://emby.server.net/library")
        XCTAssertFalse(smbSource.displayPath.contains("SuperSecret"), "密码必须被彻底清零剔除！")
    }

    /// 测试普通本地路径在 displayPath 下原样呈现，不发生解析误删
    func testDisplayPathPreservesLocalPathsAccurately() {
        let localPath = "/Users/test/Movies/My Private Collection @ 2026"
        let source = MediaSource(name: "Local Movies", path: localPath)
        
        XCTAssertEqual(source.displayPath, localPath)
    }

    /// 测试 sourceKind 能精准通过 URL 前缀或名称前缀分类
    func testSourceKindAccurateClassification() {
        XCTAssertEqual(MediaSource(name: "Test", path: "urlsource://video.mp4").sourceKind, .url)
        XCTAssertEqual(MediaSource(name: "Test", path: "emby://server").sourceKind, .emby)
        XCTAssertEqual(MediaSource(name: "Test", path: "jellyfin://server").sourceKind, .jellyfin)
        XCTAssertEqual(MediaSource(name: "Test", path: "plex://server").sourceKind, .plex)
        XCTAssertEqual(MediaSource(name: "Test", path: "smb://server").sourceKind, .smb)
        XCTAssertEqual(MediaSource(name: "Test", path: "ftp://server").sourceKind, .ftp)
        
        // 兼容以名称前缀辨别的遗留场景
        XCTAssertEqual(MediaSource(name: "SMB 共享盘", path: "/Volumes/SMB_mount").sourceKind, .smb)
        XCTAssertEqual(MediaSource(name: "FTP 备份目录", path: "/Volumes/FTP_mount").sourceKind, .ftp)
        XCTAssertEqual(MediaSource(name: "我的本地库", path: "/Users/test/Movies").sourceKind, .local)
    }
}
