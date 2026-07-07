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
        
        let smbSource = MediaSource(name: "SMB Store", path: sensitiveSMB)
        let ftpSource = MediaSource(name: "FTP Store", path: sensitiveFTP)
        let embySource = MediaSource(name: "Emby Store", path: sensitiveEmby)
        
        XCTAssertEqual(smbSource.displayPath, "smb://192.168.1.100/Movies/HD", "SMB 路径展现时不能包含任何明文账号密码")
        XCTAssertEqual(ftpSource.displayPath, "ftp://ftp.home.local:2121/Videos")
        XCTAssertEqual(embySource.displayPath, "emby://emby.server.net/library")
        XCTAssertFalse(smbSource.displayPath.contains("SuperSecret"), "密码必须被彻底清零剔除！")
    }

    func testDisplayPathStripsCredentialsFromUppercaseSchemesAndPreservesQueryFragment() {
        let source = MediaSource(
            name: "Mixed Case SMB",
            path: "SMB://admin:p%40ss@NAS.local/Movies/HD?mount=home#recent"
        )

        XCTAssertEqual(source.displayPath, "SMB://NAS.local/Movies/HD?mount=home#recent")
        XCTAssertEqual(source.sourceKind, .smb)
        XCTAssertFalse(source.displayPath.contains("admin"))
        XCTAssertFalse(source.displayPath.contains("p%40ss"))
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

    func testSourceKindClassifiesRemoteSchemesCaseInsensitively() {
        XCTAssertEqual(MediaSource(name: "Test", path: "URLSOURCE://video.mp4").sourceKind, .url)
        XCTAssertEqual(MediaSource(name: "Test", path: "EMBY://server").sourceKind, .emby)
        XCTAssertEqual(MediaSource(name: "Test", path: "Jellyfin://server").sourceKind, .jellyfin)
        XCTAssertEqual(MediaSource(name: "Test", path: "PLEX://server").sourceKind, .plex)
        XCTAssertEqual(MediaSource(name: "Test", path: "SMB://server/share").sourceKind, .smb)
        XCTAssertEqual(MediaSource(name: "Test", path: "FTPS://server/share").sourceKind, .ftp)
    }

    func testSourceKindClassifiesLegacyNamePrefixesCaseInsensitively() {
        XCTAssertEqual(MediaSource(name: "smb 共享盘", path: "/Volumes/smb_mount").sourceKind, .smb)
        XCTAssertEqual(MediaSource(name: "Smb Archive", path: "/Volumes/archive").sourceKind, .smb)
        XCTAssertEqual(MediaSource(name: "ftp backup", path: "/Volumes/ftp_mount").sourceKind, .ftp)
        XCTAssertEqual(MediaSource(name: "ftps secure backup", path: "/Volumes/ftps_mount").sourceKind, .ftp)
    }

    func testSelectedEmbyLibraryIDsAreNormalizedOnInitializationDecodingAndMutation() throws {
        let source = MediaSource(
            name: "Emby",
            path: "emby://server",
            selectedEmbyLibraryIDs: [" movies ", "", "shows", "movies", "\n", " shows "]
        )
        XCTAssertEqual(source.selectedEmbyLibraryIDs, ["movies", "shows"])

        let json = """
        {
          "name": "Decoded Emby",
          "path": "emby://server",
          "selectedEmbyLibraryIDs": [" kids ", "kids", " ", "music"]
        }
        """
        let decoded = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.selectedEmbyLibraryIDs, ["kids", "music"])

        var mutated = MediaSource(name: "Mutable Emby", path: "emby://server")
        mutated.selectedEmbyLibraryIDs = ["  library-a", "library-b", "library-a ", "\t"]
        XCTAssertEqual(mutated.selectedEmbyLibraryIDs, ["library-a", "library-b"])
    }

    func testDecoderDefaultsOnlyUnknownEnumFieldsAndKeepsValidSourceData() throws {
        let json = """
        {
          "id": "source-future",
          "name": "Future Source",
          "path": "emby://server",
          "mediaType": "immersiveCinema",
          "recursive": false,
          "autoScan": false,
          "remoteTraceSyncMode": "serverWins",
          "selectedEmbyLibraryIDs": [" movies ", "movies", "shows"]
        }
        """

        let source = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))

        XCTAssertEqual(source.id, "source-future")
        XCTAssertEqual(source.name, "Future Source")
        XCTAssertEqual(source.path, "emby://server")
        XCTAssertEqual(source.mediaType, .auto)
        XCTAssertFalse(source.recursive)
        XCTAssertFalse(source.autoScan)
        XCTAssertEqual(source.remoteTraceSyncMode, .bidirectional)
        XCTAssertEqual(source.selectedEmbyLibraryIDs, ["movies", "shows"])
    }
}
