import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class RemoteCredentialStoreTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testAsyncSaveLoadAndDeleteRoundTripsCredentialWithStrictPermissions() async throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteCredentialStore(directory: directory)
        let sourceID = "server:one/with unsafe chars"
        let credential = RemoteSourceCredential(
            kind: "emby",
            serverURL: "https://media.example.test",
            username: "alice",
            password: "secret",
            accessToken: "token-1",
            userID: "user-1"
        )

        try await store.saveAsync(credential, sourceID: sourceID)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "server_one_with_unsafe_chars.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let loaded = try await store.loadAsync(sourceID: sourceID)
        XCTAssertEqual(loaded?.kind, credential.kind)
        XCTAssertEqual(loaded?.serverURL, credential.serverURL)
        XCTAssertEqual(loaded?.username, credential.username)
        XCTAssertEqual(loaded?.password, credential.password)
        XCTAssertEqual(loaded?.accessToken, credential.accessToken)
        XCTAssertEqual(loaded?.userID, credential.userID)
        XCTAssertEqual(try store.load(sourceID: sourceID)?.accessToken, "token-1")

        await store.deleteAsync(sourceID: sourceID)
        let deletedCredential = try await store.loadAsync(sourceID: sourceID)
        XCTAssertNil(deletedCredential)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    func testConcurrentAsyncSavesKeepIndependentCredentialsReadable() async throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteCredentialStore(directory: directory)
        let count = 30

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let credential = RemoteSourceCredential(
                        kind: index.isMultiple(of: 2) ? "emby" : "plex",
                        serverURL: "https://server-\(index).example.test",
                        username: "user-\(index)",
                        password: "password-\(index)",
                        accessToken: "token-\(index)",
                        userID: "remote-user-\(index)"
                    )
                    try await store.saveAsync(credential, sourceID: "source:\(index)")
                }
            }
            try await group.waitForAll()
        }

        for index in 0..<count {
            let loaded = try await store.loadAsync(sourceID: "source:\(index)")
            XCTAssertEqual(loaded?.serverURL, "https://server-\(index).example.test")
            XCTAssertEqual(loaded?.accessToken, "token-\(index)")
            XCTAssertEqual(loaded?.userID, "remote-user-\(index)")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, count)
    }

    func testAsyncLoadReturnsNilForCorruptedJSONAndDeleteIsIdempotent() async throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteCredentialStore(directory: directory)
        let sourceID = "corrupted"
        try await store.saveAsync(
            RemoteSourceCredential(
                kind: "smb",
                serverURL: "smb://nas.local/media",
                username: "nas",
                password: "pw",
                accessToken: nil,
                userID: nil
            ),
            sourceID: sourceID
        )
        let fileURL = directory.appendingPathComponent("corrupted.json")
        try Data("{\"serverURL\":".utf8).write(to: fileURL)

        let corruptedCredential = try await store.loadAsync(sourceID: sourceID)
        XCTAssertNil(corruptedCredential)

        await store.deleteAsync(sourceID: sourceID)
        await store.deleteAsync(sourceID: sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAsyncOperationsRunThroughInjectedIOOnBlockingIOQueue() async throws {
        let directory = try makeTemporaryDirectory()
        let recorder = RecordingRemoteCredentialStoreIO(directory: directory)
        let store = RemoteCredentialStore(directory: directory, io: recorder.io())
        let sourceID = "server:queue/check"
        let credential = RemoteSourceCredential(
            kind: "plex",
            serverURL: "https://plex.example.test",
            username: "queue-user",
            password: "queue-password",
            accessToken: "queue-token",
            userID: "queue-user-id"
        )

        try await store.saveAsync(credential, sourceID: sourceID)
        let loaded = try await store.loadAsync(sourceID: sourceID)
        await store.deleteAsync(sourceID: sourceID)

        XCTAssertEqual(loaded?.serverURL, credential.serverURL)
        XCTAssertEqual(loaded?.accessToken, credential.accessToken)
        XCTAssertEqual(recorder.operationNames, [
            "fileURL",
            "write",
            "fileURL",
            "read",
            "fileURL",
            "remove"
        ])
        XCTAssertTrue(recorder.didObserveBlockingIOOperation)
        XCTAssertTrue(recorder.allOperationsObservedOnBlockingIOQueue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.fileURL(for: sourceID).path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }
}

private final class RecordingRemoteCredentialStoreIO: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var records: [(name: String, onBlockingIOQueue: Bool)] = []

    init(directory: URL) {
        self.directory = directory
    }

    var operationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.name)
    }

    var didObserveBlockingIOOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.onBlockingIOQueue }
    }

    var allOperationsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !records.isEmpty && records.allSatisfy(\.onBlockingIOQueue)
    }

    func io() -> RemoteCredentialStore.IO {
        RemoteCredentialStore.IO(
            fileURL: { [weak self] sourceID, directoryOverride in
                guard let self else { return nil }
                record("fileURL")
                let directory = directoryOverride ?? self.directory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return fileURL(for: sourceID, in: directory)
            },
            write: { [weak self] data, url in
                self?.record("write")
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            },
            read: { [weak self] url in
                self?.record("read")
                return try Data(contentsOf: url)
            },
            remove: { [weak self] url in
                self?.record("remove")
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    func fileURL(for sourceID: String) -> URL {
        fileURL(for: sourceID, in: directory)
    }

    private func fileURL(for sourceID: String, in directory: URL) -> URL {
        let safe = sourceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    private func record(_ name: String) {
        lock.lock()
        records.append((name, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        lock.unlock()
    }
}
