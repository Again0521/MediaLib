import Darwin
import Foundation
import MediaLibCore
import XCTest
@testable import MediaLib

/// Exercises the same HTTPS, Cookie, CSRF, authorization, and Range path used
/// by a separate LAN browser, but keeps both the database and media fixture in
/// a system temporary directory. Trust succeeds only through the exported CA;
/// no certificate-error bypass is used.
@MainActor
final class ServerModeLANEndToEndTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-E2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testIndependentTrustedClientCanLoginMutateAndReadMediaRangeOverLANHTTPS() async throws {
        guard let address = LANNetworkAddressResolver.preferredPrivateIPv4Address() else {
            throw XCTSkip("当前测试机没有私有 IPv4 地址")
        }
        let executable = try serverExecutable()
        let port = try availableTCPPort()
        let password = "LAN fixture password 123"
        try prepareFixture(password: password)

        let configuration = ServerModeConfiguration(
            isEnabled: true,
            serverID: "server-lan-e2e",
            serverName: "MediaLIB LAN E2E",
            port: port,
            networkAccessMode: .lanHTTPS,
            lanAddress: address
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--serve"]
        var environment = ServerModeProcessController.processEnvironment(configuration: configuration)
        environment["MEDIALIB_SERVER_DATA_DIR"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let baseURL = try XCTUnwrap(configuration.lanHTTPSBaseURL)
        let certificateAuthority = ServerModeCertificateSupport.certificateAuthorityURL(
            applicationSupport: root
        )
        for _ in 0..<100 where process.isRunning && !FileManager.default.fileExists(atPath: certificateAuthority.path) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let delegate = try ServerModePinnedTrustDelegate(
            expectedHost: address,
            certificateAuthorityURL: certificateAuthority
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.timeoutIntervalForRequest = 2
        sessionConfiguration.timeoutIntervalForResource = 4
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let loginPage = try await waitForResponse(
            session: session,
            request: URLRequest(url: baseURL.appendingPathComponent("login")),
            process: process
        )
        XCTAssertEqual(loginPage.response.statusCode, 200)
        let loginHTML = try XCTUnwrap(String(data: loginPage.data, encoding: .utf8))
        let csrf = try csrfToken(in: loginHTML)

        let loginBody = try JSONSerialization.data(withJSONObject: [
            "username": "admin",
            "password": password,
            "deviceName": "Independent LAN Test Client",
            "platform": "macOS",
            "delivery": "cookie"
        ], options: [.sortedKeys])
        var loginRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        loginRequest.httpMethod = "POST"
        loginRequest.httpBody = loginBody
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        loginRequest.setValue(csrf, forHTTPHeaderField: "X-MediaLIB-CSRF")
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        let loginHTTP = try XCTUnwrap(loginResponse as? HTTPURLResponse)
        XCTAssertEqual(loginHTTP.statusCode, 200, String(data: loginData, encoding: .utf8) ?? "")
        let cookies = sessionConfiguration.httpCookieStorage?.cookies ?? []
        XCTAssertTrue(cookies.contains { $0.name == "MediaLIBAccess" && $0.isSecure })
        XCTAssertTrue(cookies.contains { $0.name == "MediaLIBRefresh" && $0.isSecure })

        let (homeData, homeResponse) = try await session.data(
            for: URLRequest(url: baseURL)
        )
        XCTAssertEqual((homeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: homeData, encoding: .utf8)?.contains("MediaLIB LAN E2E") == true)

        let stateBody = Data(#"{"event":"progress","positionSeconds":2,"durationSeconds":10}"#.utf8)
        var missingCSRF = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/playback/state/lan-e2e-movie")
        )
        missingCSRF.httpMethod = "POST"
        missingCSRF.httpBody = stateBody
        missingCSRF.setValue("application/json", forHTTPHeaderField: "Content-Type")
        missingCSRF.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        let (_, rejectedResponse) = try await session.data(for: missingCSRF)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 403)

        var stateRequest = missingCSRF
        stateRequest.setValue(csrf, forHTTPHeaderField: "X-MediaLIB-CSRF")
        let (_, stateResponse) = try await session.data(for: stateRequest)
        XCTAssertEqual((stateResponse as? HTTPURLResponse)?.statusCode, 200)

        var rangeRequest = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/stream/lan-e2e-movie")
        )
        rangeRequest.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await session.data(for: rangeRequest)
        let rangeHTTP = try XCTUnwrap(rangeResponse as? HTTPURLResponse)
        XCTAssertEqual(rangeHTTP.statusCode, 206)
        XCTAssertEqual(rangeHTTP.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(rangeData, Data("2345".utf8))
    }

    private func prepareFixture(password: String) throws {
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaFile = mediaDirectory.appendingPathComponent("lan-e2e.mp4")
        try Data("0123456789".utf8).write(to: mediaFile, options: .atomic)

        let database = try DatabaseManager(
            url: root.appendingPathComponent("medialib.sqlite"),
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true)
        )
        try SourceRepository(database: database).save(MediaSource(
            id: "lan-e2e-library",
            name: "LAN E2E Library",
            path: mediaDirectory.path,
            mediaType: .movie
        ))
        try MediaRepository(database: database).upsert(MediaItem(
            id: "lan-e2e-movie",
            type: .movie,
            title: "LAN E2E Movie",
            sourcePath: mediaDirectory.path,
            filePath: mediaFile.path,
            duration: 10,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 11, count: count) }
        )
        try ServerIdentityRepository(database: database).setInitialCredential(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            argon2idEncodedHash: try hasher.hash(password: password)
        )
    }

    private func waitForResponse(
        session: URLSession,
        request: URLRequest,
        process: Process
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var lastError: Error?
        for _ in 0..<100 where process.isRunning {
            do {
                let (data, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse {
                    return (data, response)
                }
            } catch {
                lastError = error
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw lastError ?? ServerModeLANEndToEndError.serverUnavailable
    }

    private func csrfToken(in html: String) throws -> String {
        let expression = try NSRegularExpression(
            pattern: #"<meta name="medialib-csrf-token" content="([^"]+)">"#
        )
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: fullRange),
              let range = Range(match.range(at: 1), in: html)
        else { throw ServerModeLANEndToEndError.missingCSRF }
        return String(html[range])
    }

    private func serverExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MEDIALIB_LAN_E2E_SERVER_EXECUTABLE"],
           !override.isEmpty {
            let executable = URL(fileURLWithPath: override).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ServerModeLANEndToEndError.serverUnavailable
            }
            return executable
        }
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/MediaLibServer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServerModeLANEndToEndError.serverUnavailable
        }
        return executable
    }

    private func availableTCPPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerModeLANEndToEndError.portUnavailable }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw ServerModeLANEndToEndError.portUnavailable
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ServerModeLANEndToEndError.portUnavailable }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw ServerModeLANEndToEndError.portUnavailable }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}

private enum ServerModeLANEndToEndError: Error {
    case missingCSRF
    case portUnavailable
    case serverUnavailable
}
