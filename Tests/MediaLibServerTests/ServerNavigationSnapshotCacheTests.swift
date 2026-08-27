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
        XCTAssertEqual(calls.remoteCalls, 2)

        calls.advanceRevision()
        XCTAssertEqual(response(router, path: "/account").statusCode, 200)
        XCTAssertEqual(calls.collectionCalls, 2)
        XCTAssertEqual(calls.playlistCalls, 2)
        XCTAssertEqual(calls.remoteCalls, 3)
    }

    private func response(_ router: LocalHTTPRouter, path: String) -> LocalHTTPResponse {
        router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\n\r\n")
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
