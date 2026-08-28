import XCTest
@testable import MediaLibServerProtocol

final class ServerProtocolModelsTests: XCTestCase {
    func testHealthRoundTripsWithStableAPIVersion() throws {
        let health = ServerHealth(
            serverID: "server-001",
            serverName: "客厅服务器",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(health)
        let decoded = try JSONDecoder().decode(ServerHealth.self, from: data)

        XCTAssertEqual(decoded, health)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.apiVersion, MlinkProtocol.currentAPIVersion)
    }

    func testDescriptorNormalizesCapabilityOrder() {
        let descriptor = MlinkServerDescriptor(
            serverID: "server-001",
            serverName: "客厅服务器",
            capabilities: ["server-discovery", "health"]
        )

        XCTAssertEqual(descriptor.capabilities, ["health", "server-discovery"])
        XCTAssertEqual(descriptor.apiVersion, MlinkProtocol.currentAPIVersion)
    }

    func testLibraryCardDTODoesNotNeedAnyPathField() throws {
        let response = ServerLibraryItemsResponse(
            totalItemCount: 1,
            items: [ServerLibraryItem(id: "movie-1", type: "movie", title: "影片", year: 2026, artworkAvailable: true)]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ServerLibraryItemsResponse.self, from: data)

        XCTAssertEqual(decoded, response)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("path") ?? true)
    }

    func testOlderServerPayloadsDecodeWithEmptyUserPreferences() throws {
        let cardJSON = #"{"id":"movie-1","type":"movie","title":"影片","year":2026,"artworkAvailable":true}"#
        let detailJSON = #"{"id":"movie-1","type":"movie","title":"影片","genres":[],"artworkAvailable":true,"backdropAvailable":false,"canDirectPlay":true,"canTranscode":false}"#

        let card = try JSONDecoder().decode(ServerLibraryItem.self, from: Data(cardJSON.utf8))
        XCTAssertEqual(card.userPreference, .empty)
        XCTAssertFalse(card.isRemoteSource)
        XCTAssertEqual(
            try JSONDecoder().decode(ServerMediaItemDetail.self, from: Data(detailJSON.utf8)).userPreference,
            .empty
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ServerMediaItemDetail.self, from: Data(detailJSON.utf8)).playbackModes,
            [.directPlay]
        )
    }

    func testRemoteSourceMarkerRoundTripsWithoutSourceDetails() throws {
        let card = ServerLibraryItem(
            id: "remote-movie", type: "movie", title: "远程影片", year: 2026,
            artworkAvailable: true, isRemoteSource: true
        )

        let data = try JSONEncoder().encode(card)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(try JSONDecoder().decode(ServerLibraryItem.self, from: data).isRemoteSource)
        XCTAssertTrue(text.contains("isRemoteSource"))
        XCTAssertFalse(text.contains("sourcePath"))
        XCTAssertFalse(text.contains("https://"))
    }

    func testPaginatedLibraryAndCategoriesRoundTripWithoutIdentityOrPaths() throws {
        let state = ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 50, progress: 0.5, isWatched: false,
            playCount: 1, lastPlayedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100)
        )
        let page = ServerLibraryItemsPage(
            totalItemCount: 3, offset: 0, limit: 2,
            items: [ServerLibraryItem(
                id: "movie-1", type: "movie", title: "影片", year: 2026,
                artworkAvailable: true, userState: state
            )]
        )
        let categories = ServerLibraryCategoriesResponse(
            categories: [ServerLibraryCategory(id: "movie", title: "电影", itemCount: 3)]
        )

        let pageData = try JSONEncoder().encode(page)
        let categoryData = try JSONEncoder().encode(categories)
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryItemsPage.self, from: pageData), page)
        XCTAssertEqual(try JSONDecoder().decode(ServerLibraryCategoriesResponse.self, from: categoryData), categories)
        XCTAssertTrue(page.hasMore)
        let text = String(data: pageData, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("userID"))
        XCTAssertFalse(text.contains("filePath"))
        XCTAssertFalse(text.contains("sourcePath"))
    }

    func testPlaybackInfoRoundTripsWithoutMediaPathOrProbeDiagnostics() throws {
        let info = ServerMediaPlaybackInfo(
            itemID: "movie-1",
            durationSeconds: 6123.4,
            container: "matroska,webm",
            bitrate: 14_000_000,
            streams: [
                ServerMediaStreamInfo(
                    id: 0,
                    type: "video",
                    codec: "hevc",
                    profile: "Main 10",
                    language: nil,
                    width: 3840,
                    height: 2160,
                    channels: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerMediaPlaybackInfo.self, from: data)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(decoded, info)
        XCTAssertFalse(text.contains("path"))
        XCTAssertFalse(text.contains("stderr"))
    }

    func testMediaDetailRoundTripsWithoutPlaybackTraceOrLocalPathFields() throws {
        let detail = ServerMediaItemDetail(
            id: "movie-1",
            type: "movie",
            title: "影片",
            originalTitle: "Movie",
            year: 2026,
            overview: "简介",
            genres: ["剧情", "科幻"],
            communityRating: 8.4,
            runtimeSeconds: 7_200,
            videoCodec: "hevc",
            audioCodec: "aac",
            resolution: "3840x2160",
            artworkAvailable: true,
            backdropAvailable: true,
            browserContentType: " video/mp4 ",
            canDirectPlay: true,
            canTranscode: true,
            playbackModes: [.directPlay, .directStream, .audioTranscode, .fullTranscode]
        )
        let data = try JSONEncoder().encode(detail)
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""

        XCTAssertEqual(try JSONDecoder().decode(ServerMediaItemDetail.self, from: data), detail)
        XCTAssertEqual(detail.browserContentType, "video/mp4")
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("browserContentType") ?? false)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("playbackModes") ?? false)
        XCTAssertFalse(text.contains("detailextras"))
        for forbiddenField in [
            "filepath", "sourcepath", "posterpath", "backdroppath", "externalid",
            "playposition", "playprogress", "userid", "deviceid", "sessionid", "token", "digest"
        ] {
            XCTAssertFalse(text.contains(forbiddenField), "unexpected detail field: \(forbiddenField)")
        }
    }

    func testOlderDetailPayloadsDecodeWithoutEpisodeNavigation() throws {
        let legacy = #"{"id":"episode-1","type":"episode","title":"第一集","genres":[],"artworkAvailable":false,"backdropAvailable":false,"canDirectPlay":true,"canTranscode":false}"#
        let detail = try JSONDecoder().decode(ServerMediaItemDetail.self, from: Data(legacy.utf8))

        XCTAssertNil(detail.previousEpisode)
        XCTAssertNil(detail.nextEpisode)
        XCTAssertNil(detail.browserContentType)
    }

    func testPerUserPlaybackStateRoundTripsWithoutIdentityOrPathAndRejectsInvalidUpdates() throws {
        let state = ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 120, progress: 0.25,
            isWatched: false, playCount: 2,
            lastPlayedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let data = try JSONEncoder().encode(state)
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""

        XCTAssertEqual(try JSONDecoder().decode(ServerMediaUserState.self, from: data), state)
        for forbiddenField in ["userid", "deviceid", "sessionid", "path", "token", "digest"] {
            XCTAssertFalse(text.contains(forbiddenField))
        }
        XCTAssertTrue(ServerPlaybackStateUpdateRequest(
            event: .progress, positionSeconds: 120, durationSeconds: 480
        ).isValid)
        XCTAssertFalse(ServerPlaybackStateUpdateRequest(
            event: .progress, positionSeconds: .nan, durationSeconds: 480
        ).isValid)
        XCTAssertFalse(ServerPlaybackStateUpdateRequest(
            event: .progress, positionSeconds: 900, durationSeconds: 100
        ).isValid)
    }

    func testAdministrationDTOsRoundTripWithoutCredentialOrNetworkFields() throws {
        let response = ServerManagedSessionsResponse(
            totalCount: 1,
            isTruncated: false,
            devices: [ServerManagedDeviceSummary(
                id: "device-1", userID: "user-1", name: "浏览器", platform: "Web",
                createdAt: Date(timeIntervalSince1970: 10),
                lastSeenAt: Date(timeIntervalSince1970: 20)
            )],
            sessions: [ServerManagedSessionSummary(
                id: "session-1", userID: "user-1", deviceID: "device-1",
                accessExpiresAt: Date(timeIntervalSince1970: 30),
                refreshExpiresAt: Date(timeIntervalSince1970: 40),
                createdAt: Date(timeIntervalSince1970: 10),
                lastUsedAt: Date(timeIntervalSince1970: 20),
                username: "member",
                displayName: "家庭成员"
            )]
        )
        let data = try JSONEncoder().encode(response)
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""

        XCTAssertEqual(try JSONDecoder().decode(ServerManagedSessionsResponse.self, from: data), response)
        XCTAssertEqual(response.totalCount, 1)
        for forbiddenField in ["token", "digest", "passwordhash", "cookie", "address", "useragent", "path"] {
            XCTAssertFalse(text.contains(forbiddenField))
        }
    }
}
