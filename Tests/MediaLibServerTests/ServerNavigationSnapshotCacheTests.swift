import Dispatch
import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerNavigationSnapshotCacheTests: XCTestCase {
    func testSidebarSnapshotReusesLocalNavigationUntilRevisionChangesButAlwaysRefreshesRemoteGroups() {
        let calls = NavigationProviderCounter()
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "MediaLIB",
            remoteSourceGroupsProvider: { _ in calls.recordRemote(); return [] },
            navigationRevisionProvider: { _ in calls.revision },
            smartCollectionsProvider: { offset, limit, _ in
                calls.recordCollections()
                return ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
            },
            musicPlaylistsProvider: { offset, limit, _ in
                calls.recordPlaylists()
                return ServerMusicPlaylistsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        XCTAssertEqual(response(router, path: "/account").statusCode, 200)
        XCTAssertEqual(response(router, path: "/queue").statusCode, 200)
        XCTAssertEqual(calls.collectionCalls, 1)
        XCTAssertEqual(calls.playlistCalls, 1)
        XCTAssertEqual(calls.remoteCalls, 1)

        calls.advanceRevision()
        XCTAssertEqual(response(router, path: "/account").statusCode, 200)
        XCTAssertEqual(calls.collectionCalls, 2)
        XCTAssertEqual(calls.playlistCalls, 2)
        XCTAssertEqual(calls.remoteCalls, 2)
    }

    func testSidebarSnapshotKeyIncludesTheCompleteLibraryGrantScope() {
        let calls = NavigationProviderCounter()
        let first = ServerRequestPrincipal(
            userID: "shared-member", deviceID: "device-a", sessionID: "session-a",
            permissions: [.viewMedia],
            libraryGrants: [
                "library-a": ServerLibraryGrant(
                    userID: "shared-member", libraryID: "library-a",
                    canView: true, canPlay: false, canDownload: false
                )
            ]
        )
        let second = ServerRequestPrincipal(
            userID: "shared-member", deviceID: "device-b", sessionID: "session-b",
            permissions: [.viewMedia],
            libraryGrants: [
                "library-b": ServerLibraryGrant(
                    userID: "shared-member", libraryID: "library-b",
                    canView: true, canPlay: true, canDownload: false
                )
            ]
        )
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "MediaLIB",
            navigationRevisionProvider: { _ in "same-revision" },
            smartCollectionsProvider: { offset, limit, _ in
                calls.recordCollections()
                return ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
            },
            authenticationProvider: { token in token == "first" ? first : second }
        )

        XCTAssertEqual(response(router, path: "/account", token: "first").statusCode, 200)
        XCTAssertEqual(response(router, path: "/account", token: "second").statusCode, 200)
        XCTAssertEqual(calls.collectionCalls, 2)
    }

    func testConcurrentPagesSingleFlightTheSameNavigationSnapshot() {
        let probe = NavigationSingleFlightProbe()
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "MediaLIB",
            navigationRevisionProvider: { _ in "shared-revision" },
            smartCollectionsProvider: { offset, limit, _ in
                probe.enterProvider()
                return ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let path = index.isMultiple(of: 2) ? "/account" : "/queue"
                _ = router.response(
                    for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\n\r\n"
                )
                group.leave()
            }
        }
        for _ in 0..<8 { start.signal() }

        XCTAssertEqual(probe.firstProviderEntered.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(probe.callCount, 1)
        probe.releaseFirstProvider.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.callCount, 1)
    }

    private func response(_ router: LocalHTTPRouter, path: String, token: String = "test") -> LocalHTTPResponse {
        router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n")
    }
}

private final class NavigationSingleFlightProbe: @unchecked Sendable {
    let firstProviderEntered = DispatchSemaphore(value: 0)
    let releaseFirstProvider = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func enterProvider() {
        lock.lock()
        storedCallCount += 1
        let isFirst = storedCallCount == 1
        lock.unlock()
        guard isFirst else { return }
        firstProviderEntered.signal()
        releaseFirstProvider.wait()
    }
}

private final class NavigationProviderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRevision = "revision-1"
    private var storedCollections = 0
    private var storedPlaylists = 0
    private var storedRemote = 0

    var revision: String { locked { storedRevision } }
    var collectionCalls: Int { locked { storedCollections } }
    var playlistCalls: Int { locked { storedPlaylists } }
    var remoteCalls: Int { locked { storedRemote } }

    func recordCollections() { locked { storedCollections += 1 } }
    func recordPlaylists() { locked { storedPlaylists += 1 } }
    func recordRemote() { locked { storedRemote += 1 } }
    func advanceRevision() { locked { storedRevision = "revision-2" } }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
