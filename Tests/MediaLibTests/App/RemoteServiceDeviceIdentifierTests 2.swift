import XCTest
@testable import MediaLib

final class RemoteServiceDeviceIdentifierTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "RemoteServiceDeviceIdentifierTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testEmbyDeviceIdentifierReusesExistingInjectedValue() {
        defaults.set("emby-existing-device", forKey: "MediaLib.emby.deviceID")
        let service = EmbyService(deviceIDDefaults: defaults)

        XCTAssertEqual(service.deviceIdentifier(), "emby-existing-device")
        XCTAssertEqual(service.clientIdentity().deviceID, "emby-existing-device")
    }

    func testEmbyDeviceIdentifierGeneratesAndPersistsStableUUIDInInjectedDefaults() throws {
        let service = EmbyService(deviceIDDefaults: defaults)

        let first = service.deviceIdentifier()
        let second = service.deviceIdentifier()

        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(defaults.string(forKey: "MediaLib.emby.deviceID"), first)
    }

    func testPlexDeviceIdentifierReusesExistingInjectedValue() {
        defaults.set("plex-existing-device", forKey: "MediaLib.plex.deviceID")
        let service = PlexService(deviceIDDefaults: defaults)

        XCTAssertEqual(service.deviceIdentifier(), "plex-existing-device")
    }

    func testPlexDeviceIdentifierGeneratesAndPersistsStableUUIDInInjectedDefaults() throws {
        let service = PlexService(deviceIDDefaults: defaults)

        let first = service.deviceIdentifier()
        let second = service.deviceIdentifier()

        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(defaults.string(forKey: "MediaLib.plex.deviceID"), first)
    }

    func testInjectedDefaultsDoNotTouchStandardDeviceIdentifiers() {
        let standardEmby = UserDefaults.standard.string(forKey: "MediaLib.emby.deviceID")
        let standardPlex = UserDefaults.standard.string(forKey: "MediaLib.plex.deviceID")

        _ = EmbyService(deviceIDDefaults: defaults).deviceIdentifier()
        _ = PlexService(deviceIDDefaults: defaults).deviceIdentifier()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "MediaLib.emby.deviceID"), standardEmby)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "MediaLib.plex.deviceID"), standardPlex)
        XCTAssertNotNil(defaults.string(forKey: "MediaLib.emby.deviceID"))
        XCTAssertNotNil(defaults.string(forKey: "MediaLib.plex.deviceID"))
    }
}
