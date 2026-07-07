import XCTest
@testable import MediaLib

final class LastfmScrobbleServiceTests: XCTestCase {
    func testCredentialsTrimWhitespaceAndNewlines() {
        XCTAssertFalse(LastfmScrobbleService(apiKey: "   ", sharedSecret: "secret").hasCredentials)
        XCTAssertFalse(LastfmScrobbleService(apiKey: "\n\t", sharedSecret: "secret").hasCredentials)
        XCTAssertFalse(LastfmScrobbleService(apiKey: "key", sharedSecret: "\n ").hasCredentials)
        XCTAssertTrue(LastfmScrobbleService(apiKey: " key ", sharedSecret: "\nsecret\t").hasCredentials)
    }

    func testNormalizedSessionKeyRejectsBlankValuesAndTrimsUsableTokens() {
        XCTAssertNil(LastfmScrobbleService.normalizedSessionKey(nil))
        XCTAssertNil(LastfmScrobbleService.normalizedSessionKey(""))
        XCTAssertNil(LastfmScrobbleService.normalizedSessionKey(" \n\t "))
        XCTAssertEqual(LastfmScrobbleService.normalizedSessionKey(" session-key\n"), "session-key")
    }

    func testMissingCredentialsThrowBeforeNetworkForTokenFetch() async {
        let service = LastfmScrobbleService(apiKey: "\n", sharedSecret: "secret")

        do {
            _ = try await service.fetchToken()
            XCTFail("Expected missing credentials to fail before making a request")
        } catch LastfmScrobbleError.missingCredentials {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPISignatureSortsParametersAndAppendsSharedSecret() {
        let params = [
            "method": "artist.getInfo",
            "api_key": "abc",
            "artist": "Cher"
        ]

        let signature = LastfmScrobbleService.apiSignature(for: params, sharedSecret: "secret")

        XCTAssertEqual(signature, "b900c8837d144ea2790ee82217c027eb")
    }

    func testSignedQueryItemsIncludeJSONFormatButExcludeItFromSignature() {
        let service = LastfmScrobbleService(apiKey: "abc", sharedSecret: "secret")
        let params = [
            "method": "artist.getInfo",
            "api_key": "abc",
            "artist": "Cher"
        ]

        let items = dictionary(from: service.signedQueryItems(for: params))

        XCTAssertEqual(items["method"], "artist.getInfo")
        XCTAssertEqual(items["api_key"], "abc")
        XCTAssertEqual(items["artist"], "Cher")
        XCTAssertEqual(items["format"], "json")
        XCTAssertEqual(items["api_sig"], "b900c8837d144ea2790ee82217c027eb")
        XCTAssertNotEqual(
            items["api_sig"],
            LastfmScrobbleService.apiSignature(
                for: params.merging(["format": "json"]) { current, _ in current },
                sharedSecret: "secret"
            )
        )
    }

    func testAuthorizationURLPercentEncodesTokenAndKeepsAPIKey() throws {
        let service = LastfmScrobbleService(apiKey: "api key", sharedSecret: "secret")
        let url = try XCTUnwrap(service.authorizationURL(token: "token +/="))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = dictionary(from: components.queryItems ?? [])

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.last.fm")
        XCTAssertEqual(components.path, "/api/auth/")
        XCTAssertEqual(items["api_key"], "api key")
        XCTAssertEqual(items["token"], "token +/=")
    }

    func testNowPlayingParamsTrimOptionalAlbumAndIgnoreInvalidDuration() {
        let blankAlbum = LastfmScrobbleService.nowPlayingParams(
            apiKey: "key",
            sessionKey: "session",
            artist: "Artist",
            track: "Track",
            album: " \n ",
            durationSeconds: 0
        )

        XCTAssertEqual(blankAlbum["method"], "track.updateNowPlaying")
        XCTAssertEqual(blankAlbum["api_key"], "key")
        XCTAssertEqual(blankAlbum["sk"], "session")
        XCTAssertEqual(blankAlbum["artist"], "Artist")
        XCTAssertEqual(blankAlbum["track"], "Track")
        XCTAssertNil(blankAlbum["album"])
        XCTAssertNil(blankAlbum["duration"])

        let full = LastfmScrobbleService.nowPlayingParams(
            apiKey: "key",
            sessionKey: "session",
            artist: "Artist",
            track: "Track",
            album: "  Album  ",
            durationSeconds: 241
        )

        XCTAssertEqual(full["album"], "Album")
        XCTAssertEqual(full["duration"], "241")
    }

    func testScrobbleParamsIncludeTimestampAndPositiveDurationOnly() {
        let skippedDuration = LastfmScrobbleService.scrobbleParams(
            apiKey: "key",
            sessionKey: "session",
            artist: "Artist",
            track: "Track",
            album: nil,
            timestamp: 1_800_000_000,
            durationSeconds: -1
        )

        XCTAssertEqual(skippedDuration["method"], "track.scrobble")
        XCTAssertEqual(skippedDuration["timestamp"], "1800000000")
        XCTAssertNil(skippedDuration["duration"])

        let full = LastfmScrobbleService.scrobbleParams(
            apiKey: "key",
            sessionKey: "session",
            artist: "Artist",
            track: "Track",
            album: "Album",
            timestamp: 1_800_000_001,
            durationSeconds: 180
        )

        XCTAssertEqual(full["album"], "Album")
        XCTAssertEqual(full["timestamp"], "1800000001")
        XCTAssertEqual(full["duration"], "180")
    }

    private func dictionary(from items: [URLQueryItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
