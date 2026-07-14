@testable import MediaLibCore
@testable import MediaLibServer

extension ServerRequestPrincipal {
    static func testAdministrator(sessionID: String = "test-session") -> ServerRequestPrincipal {
        ServerRequestPrincipal(
            userID: "test-admin",
            deviceID: "test-device",
            sessionID: sessionID,
            permissions: Set(ServerPermission.allCases),
            libraryGrants: [:]
        )
    }
}
