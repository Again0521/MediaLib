import XCTest
@testable import MediaLib

final class TraktServiceTests: XCTestCase {
    func testCredentialsTrimWhitespaceAndNewlines() {
        XCTAssertFalse(TraktService.hasCredentials(clientID: "   ", clientSecret: "secret"))
        XCTAssertFalse(TraktService.hasCredentials(clientID: "\n\t", clientSecret: "secret"))
        XCTAssertFalse(TraktService.hasCredentials(clientID: "client", clientSecret: "\n "))
        XCTAssertTrue(TraktService.hasCredentials(clientID: " client ", clientSecret: "\nsecret\t"))
    }

    func testInstanceCredentialsUseSameWhitespacePolicy() {
        XCTAssertFalse(TraktService(clientID: "\n", clientSecret: "secret").hasCredentials)
        XCTAssertFalse(TraktService(clientID: "client", clientSecret: "\t\n").hasCredentials)
        XCTAssertTrue(TraktService(clientID: "\tclient\n", clientSecret: " secret ").hasCredentials)
    }

    func testNormalizedTokenRejectsBlankValuesAndTrimsUsableTokens() {
        XCTAssertNil(TraktService.normalizedToken(nil))
        XCTAssertNil(TraktService.normalizedToken(""))
        XCTAssertNil(TraktService.normalizedToken(" \n\t "))
        XCTAssertEqual(TraktService.normalizedToken("\naccess-token "), "access-token")
    }

    func testMissingCredentialsThrowBeforeNetworkForDeviceCodeRequest() async {
        let service = TraktService(clientID: "\n\t", clientSecret: "secret")

        do {
            _ = try await service.requestDeviceCode()
            XCTFail("Expected missing credentials to fail before making a request")
        } catch TraktError.missingCredentials {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingCredentialsThrowBeforeNetworkForTokenPolling() async {
        let service = TraktService(clientID: "client", clientSecret: "\n")

        do {
            _ = try await service.pollOnce(deviceCode: "device-code")
            XCTFail("Expected missing credentials to fail before making a request")
        } catch TraktError.missingCredentials {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingCredentialsThrowBeforeNetworkForTokenRefresh() async {
        let service = TraktService(clientID: "\n", clientSecret: "secret")

        do {
            _ = try await service.refreshTokens("refresh-token")
            XCTFail("Expected missing credentials to fail before making a request")
        } catch TraktError.missingCredentials {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
