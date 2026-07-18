import Foundation
import XCTest
@testable import MediaLibServer

final class ServerDataDirectoriesTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibServerDataDirectories-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testExplicitDataDirectoryCreatesOnlyDatabaseAndBackupRoots() throws {
        let root = temporaryDirectory.appendingPathComponent("persistent-data", isDirectory: true)

        let directories = try XCTUnwrap(ServerDataDirectories.fromEnvironment([
            "MEDIALIB_SERVER_DATA_DIR": root.path
        ]))

        XCTAssertEqual(directories.root, root.standardizedFileURL)
        XCTAssertEqual(directories.database, root.appendingPathComponent("medialib.sqlite"))
        XCTAssertEqual(directories.databaseBackups, root.appendingPathComponent("backups", isDirectory: true))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories.databaseBackups.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.database.path))
    }

    func testDataDirectoryIsOptionalButRejectsRelativePath() throws {
        XCTAssertNil(try ServerDataDirectories.fromEnvironment([:]))
        XCTAssertThrowsError(try ServerDataDirectories.fromEnvironment([
            "MEDIALIB_SERVER_DATA_DIR": "relative/data"
        ])) { error in
            XCTAssertEqual(error as? ServerDataDirectoryError, .notAbsolute("relative/data"))
        }
    }
}
