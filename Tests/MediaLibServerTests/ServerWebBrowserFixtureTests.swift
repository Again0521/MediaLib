import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

/// Opt-in, local-only fixture preparation for manual browser verification.
/// It is skipped in normal test runs and refuses paths outside the system temp area.
final class ServerWebBrowserFixtureTests: XCTestCase {
    func testPrepareIsolatedAuthenticatedBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_BROWSER_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_BROWSER_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式网页浏览器验收时准备隔离夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("网页浏览器夹具只能写入系统临时目录。")
        }

        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        let mediaFile = mediaDirectory.appendingPathComponent("browser-fixture.mp4")
        guard FileManager.default.fileExists(atPath: mediaFile.path) else {
            throw XCTSkip("验收调用方必须先在隔离目录写入 browser-fixture.mp4。")
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let database = try DatabaseManager(
            url: root.appendingPathComponent("medialib.sqlite"),
            backupDirectory: backupDirectory
        )
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let identityRepository = ServerIdentityRepository(database: database)
        let passwordHasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 7, count: count) }
        )

        try sourceRepository.save(MediaSource(
            id: "browser-fixture-library",
            name: "浏览器验收资料库",
            path: mediaDirectory.path,
            mediaType: .movie
        ))
        try mediaRepository.upsert(MediaItem(
            id: "browser-fixture-movie",
            type: .movie,
            title: "浏览器原生播放验收",
            overview: "仅用于本机隔离浏览器验收的短媒体。",
            sourcePath: mediaDirectory.path,
            filePath: mediaFile.path,
            duration: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        if try !identityRepository.hasCredential(userID: ServerIdentityRepository.initialAdministratorUserID) {
            try identityRepository.setInitialCredential(
                userID: ServerIdentityRepository.initialAdministratorUserID,
                argon2idEncodedHash: try passwordHasher.hash(password: "browser fixture password")
            )
        }
    }
}
