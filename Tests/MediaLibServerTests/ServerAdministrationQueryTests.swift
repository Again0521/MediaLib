import Foundation
import XCTest
import MediaLibCore
@testable import MediaLibServer

final class ServerAdministrationQueryTests: XCTestCase {
    func testManagementQueriesUseSharedDefaultsAndDecodeSearchText() throws {
        XCTAssertEqual(
            ServerAdministrationQueryParser.users(
                from: "/api/v1/admin/users?offset=24&limit=12"
            ),
            .init(offset: 24, limit: 12)
        )
        XCTAssertTrue(ServerAdministrationQueryParser.libraries(
            from: "/api/v1/admin/libraries"
        ))
        XCTAssertEqual(
            ServerAdministrationQueryParser.sessions(from: "/api/v1/admin/sessions"),
            .init(offset: 0, limit: 50, searchText: nil)
        )
        XCTAssertEqual(
            ServerAdministrationQueryParser.sessions(
                from: "/api/v1/admin/sessions?offset=25&limit=10&q=Alice+TV%2FWeb"
            ),
            .init(offset: 25, limit: 10, searchText: "Alice TV/Web")
        )
        XCTAssertEqual(
            ServerAdministrationQueryParser.securityEvents(
                from: "/api/v1/admin/logs?category=authorization&outcome=denied&q=policy",
                path: "/api/v1/admin/logs"
            ),
            .init(
                offset: 0,
                limit: 50,
                category: .authorization,
                outcome: .denied,
                searchText: "policy"
            )
        )
        XCTAssertEqual(
            ServerAdministrationQueryParser.jobs(
                from: "/api/v1/admin/jobs?state=running&kind=library.scan&scope=library&q=scan"
            ),
            .init(
                offset: 0,
                limit: 50,
                state: .running,
                kind: "library.scan",
                scope: "library",
                searchText: "scan"
            )
        )
        XCTAssertEqual(
            ServerAdministrationQueryParser.backups(
                from: "/api/v1/admin/backups?offset=1&limit=20&kind=safety"
            ),
            .init(offset: 1, limit: 20, kind: .safety)
        )
        XCTAssertEqual(
            ServerAdministrationQueryParser.sources(
                from: "/api/v1/admin/sources?offset=50&limit=25&q=NAS+Movie"
            ),
            .init(offset: 50, limit: 25, searchText: "NAS Movie")
        )
    }

    func testManagementQueriesRejectAmbiguousMalformedAndUnboundedInput() {
        let invalidSessionTargets = [
            "/api/v1/admin/sessions?",
            "/api/v1/admin/sessions?limit=1&limit=2",
            "/api/v1/admin/sessions?unknown=1",
            "/api/v1/admin/sessions?limit=0",
            "/api/v1/admin/sessions?limit=101",
            "/api/v1/admin/sessions?offset=1000001",
            "/api/v1/admin/sessions?offset=-1",
            "/api/v1/admin/sessions?q=%ZZ",
            "/api/v1/admin/sessions?q=line%0Abreak",
            "/api/v1/admin/sessions?q=missing&",
            "/api/v1/admin/sessions?missing-value"
        ]
        for target in invalidSessionTargets {
            XCTAssertNil(ServerAdministrationQueryParser.sessions(from: target), target)
        }
        XCTAssertNil(ServerAdministrationQueryParser.sessions(
            from: "/api/v1/admin/sessions?q=" + String(repeating: "a", count: 129)
        ))
        XCTAssertNil(ServerAdministrationQueryParser.playbackSessions(
            from: "/api/v1/admin/playback-sessions?state=unknown"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.jobs(
            from: "/api/v1/admin/jobs?kind=arbitrary.command"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.jobs(
            from: "/api/v1/admin/jobs?scope=all"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.backups(
            from: "/api/v1/admin/backups?kind=temporary"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.sources(
            from: "/api/v1/admin/sources?sort=path"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.users(
            from: "/api/v1/admin/users?offset=0&sort=password"
        ))
        XCTAssertFalse(ServerAdministrationQueryParser.libraries(
            from: "/api/v1/admin/libraries?path=%2Fprivate"
        ))
        XCTAssertFalse(ServerAdministrationQueryParser.libraries(
            from: "/api/v1/admin/libraries?"
        ))
        XCTAssertNil(ServerAdministrationQueryParser.securityEvents(
            from: "/api/v1/admin/logs?category=authorization",
            path: "/api/v1/admin/security-events"
        ))
    }

    func testPlaybackSessionCatalogFiltersThenUsesStablePages() throws {
        let first = session(
            id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            userID: "User-Alice",
            state: .playing,
            mode: "hlsRemux",
            startedAt: 200
        )
        let second = session(
            id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            userID: "user-bob",
            state: .playing,
            mode: "hlsAudioTranscode",
            startedAt: 200
        )
        let older = session(
            id: "cccccccccccccccccccccccccccccccc",
            userID: "user-carol",
            state: .queued,
            mode: "hlsTranscode",
            startedAt: 100
        )
        let allQuery = try XCTUnwrap(ServerAdministrationQueryParser.playbackSessions(
            from: "/api/v1/admin/playback-sessions?offset=0&limit=2"
        ))
        let firstPage = ServerAdminPlaybackSessionCatalog.page([older, second, first], query: allQuery)
        XCTAssertEqual(firstPage.totalCount, 3)
        XCTAssertEqual(firstPage.sessions.map(\.sessionID), [first.sessionID, second.sessionID])
        XCTAssertTrue(firstPage.isTruncated)

        let secondPageQuery = try XCTUnwrap(ServerAdministrationQueryParser.playbackSessions(
            from: "/api/v1/admin/playback-sessions?offset=2&limit=2"
        ))
        let secondPage = ServerAdminPlaybackSessionCatalog.page([second, older, first], query: secondPageQuery)
        XCTAssertEqual(secondPage.sessions.map(\.sessionID), [older.sessionID])
        XCTAssertFalse(secondPage.isTruncated)

        let filteredQuery = try XCTUnwrap(ServerAdministrationQueryParser.playbackSessions(
            from: "/api/v1/admin/playback-sessions?state=playing&q=AUDIO"
        ))
        let filtered = ServerAdminPlaybackSessionCatalog.page([first, older, second], query: filteredQuery)
        XCTAssertEqual(filtered.totalCount, 1)
        XCTAssertEqual(filtered.sessions.map(\.sessionID), [second.sessionID])
    }

    private func session(
        id: String,
        userID: String,
        state: ServerHLSPlaybackSessionState,
        mode: String,
        startedAt: TimeInterval
    ) -> ServerAdminHLSPlaybackSession {
        ServerAdminHLSPlaybackSession(
            sessionID: id,
            userID: userID,
            state: state,
            mode: mode,
            startedAt: Date(timeIntervalSince1970: startedAt),
            lastAccessedAt: Date(timeIntervalSince1970: startedAt + 1),
            durationSeconds: 3_600
        )
    }
}
