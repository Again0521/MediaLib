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

    func testIndependentTrustedClientCanLoginUseAllBusinessMethodsAndReadMediaRangeOverLANHTTPS() async throws {
        try await exerciseHTTPS(proxy: false)
    }

    func testWANProxyCanLoginMutateAndReadMediaWhileLANReadinessWorks() async throws {
        try await exerciseHTTPS(proxy: true)
    }

    private func exerciseHTTPS(proxy: Bool) async throws {
        guard let address = LANNetworkAddressResolver.preferredPrivateIPv4Address() else {
            if ProcessInfo.processInfo.environment["MEDIALIB_REQUIRE_LAN_E2E"] == "1" {
                XCTFail("MEDIALIB_REQUIRE_LAN_E2E=1 but the runner has no private IPv4 address")
                return
            }
            throw XCTSkip("当前测试机没有私有 IPv4 地址")
        }
        let executable = try serverExecutable()
        let port = try availableTCPPort()
        var websitePort = try availableTCPPort()
        while websitePort == port { websitePort = try availableTCPPort() }
        let password = "LAN fixture password 123"
        try prepareFixture(password: password)

        let configuration = ServerModeConfiguration(
            isEnabled: true,
            serverID: "server-lan-e2e",
            serverName: "MediaLIB LAN E2E",
            port: port,
            websitePort: proxy ? nil : websitePort,
            networkAccessMode: .lanHTTPS,
            lanAddress: address,
            publicOrigin: proxy ? "https://media.example.test" : nil,
            trustedProxyAddresses: proxy ? [address] : [],
            allowsWANAccess: proxy
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
        sessionConfiguration.timeoutIntervalForRequest = 10
        sessionConfiguration.timeoutIntervalForResource = 15
        if proxy {
            sessionConfiguration.httpAdditionalHeaders = ["Host": "media.example.test",
                "X-Forwarded-Proto": "https", "X-Forwarded-For": "203.0.113.7"]
        }
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let browserOrigin = proxy ? URL(string: "https://media.example.test")! : baseURL

        let loginPage = try await waitForResponse(
            session: session,
            request: URLRequest(url: baseURL.appendingPathComponent("login")),
            process: process
        )
        XCTAssertEqual(loginPage.response.statusCode, 200)
        if !proxy, let websiteURL = configuration.websiteBaseURL {
            let websiteHealth = try await waitForResponse(
                session: .shared,
                request: URLRequest(url: websiteURL.appendingPathComponent("health")),
                process: process
            )
            XCTAssertEqual(websiteHealth.response.statusCode, 200)
        }
        if proxy {
            let ready = await ServerModeProcessController.checkLANHTTPSReadiness(
                configuration, certificateAuthorityURL: certificateAuthority)
            XCTAssertTrue(ready)
        }

        let loginHTML = try XCTUnwrap(String(data: loginPage.data, encoding: .utf8))
        let loginCSRF = try csrfToken(in: loginHTML)

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
        loginRequest.setValue((proxy ? "https://media.example.test" : baseURL.absoluteString), forHTTPHeaderField: "Origin")
        loginRequest.setValue(loginCSRF, forHTTPHeaderField: "X-MediaLIB-CSRF")
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        let loginHTTP = try XCTUnwrap(loginResponse as? HTTPURLResponse)
        XCTAssertEqual(loginHTTP.statusCode, 200, String(data: loginData, encoding: .utf8) ?? "")
        if !proxy, let websiteURL = configuration.websiteBaseURL {
            let browserConfiguration = URLSessionConfiguration.ephemeral
            browserConfiguration.httpShouldSetCookies = true
            browserConfiguration.httpCookieAcceptPolicy = .always
            let websiteSession = URLSession(configuration: browserConfiguration)
            defer { websiteSession.finishTasksAndInvalidate() }
            let websiteLoginPage = try await websiteSession.data(
                for: URLRequest(url: websiteURL.appendingPathComponent("login"))
            )
            XCTAssertEqual((websiteLoginPage.1 as? HTTPURLResponse)?.statusCode, 200)
            let websiteLoginHTML = try XCTUnwrap(String(data: websiteLoginPage.0, encoding: .utf8))
            var websiteLogin = URLRequest(url: websiteURL.appendingPathComponent("api/v1/auth/login"))
            websiteLogin.httpMethod = "POST"
            websiteLogin.httpBody = loginBody
            websiteLogin.setValue("application/json", forHTTPHeaderField: "Content-Type")
            websiteLogin.setValue(websiteURL.absoluteString, forHTTPHeaderField: "Origin")
            websiteLogin.setValue(try csrfToken(in: websiteLoginHTML), forHTTPHeaderField: "X-MediaLIB-CSRF")
            let websiteLoginResult = try await websiteSession.data(for: websiteLogin)
            XCTAssertEqual((websiteLoginResult.1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(browserConfiguration.httpCookieStorage?.cookies?.contains {
                $0.name == "MediaLIBAccess" && !$0.isSecure
            } == true)
        }
        let cookies = sessionConfiguration.httpCookieStorage?.cookies ?? []
        XCTAssertTrue(cookies.contains { $0.name == "MediaLIBAccess" && $0.isSecure })
        XCTAssertTrue(cookies.contains { $0.name == "MediaLIBRefresh" && $0.isSecure })

        let (homeData, homeResponse) = try await session.data(
            for: URLRequest(url: baseURL)
        )
        XCTAssertEqual((homeResponse as? HTTPURLResponse)?.statusCode, 200)
        let homeHTML = try XCTUnwrap(String(data: homeData, encoding: .utf8))
        XCTAssertTrue(homeHTML.contains("MediaLIB LAN E2E"))
        let csrf = try csrfToken(in: homeHTML)
        XCTAssertNotEqual(loginCSRF, csrf)

        let stateBody = Data(#"{"event":"progress","positionSeconds":2,"durationSeconds":10}"#.utf8)
        var missingCSRF = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/playback/state/lan-e2e-movie")
        )
        missingCSRF.httpMethod = "POST"
        missingCSRF.httpBody = stateBody
        missingCSRF.setValue("application/json", forHTTPHeaderField: "Content-Type")
        missingCSRF.setValue((proxy ? "https://media.example.test" : baseURL.absoluteString), forHTTPHeaderField: "Origin")
        let (_, rejectedResponse) = try await session.data(for: missingCSRF)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 403)

        var stateRequest = missingCSRF
        stateRequest.setValue(csrf, forHTTPHeaderField: "X-MediaLIB-CSRF")
        let (_, stateResponse) = try await session.data(for: stateRequest)
        XCTAssertEqual((stateResponse as? HTTPURLResponse)?.statusCode, 200)

        let preferencesURL = baseURL.appendingPathComponent("api/v1/me/preferences")
        let (_, initialPreferencesResponse) = try await session.data(
            for: URLRequest(url: preferencesURL)
        )
        XCTAssertEqual((initialPreferencesResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (initialPreferencesResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
            "\"0\""
        )

        var preferences = ServerUserExperiencePreferences()
        preferences.preferredAudioLanguage = "zh-Hans"
        preferences.subtitleMode = .preferForced
        let preferencesBody = try JSONEncoder().encode(preferences)
        var rejectedPatch = mutationRequest(
            url: preferencesURL,
            method: "PATCH",
            body: preferencesBody,
            origin: browserOrigin,
            csrf: nil
        )
        rejectedPatch.setValue("\"0\"", forHTTPHeaderField: "If-Match")
        let (_, rejectedPatchResponse) = try await session.data(for: rejectedPatch)
        XCTAssertEqual((rejectedPatchResponse as? HTTPURLResponse)?.statusCode, 403)

        let (_, unchangedPreferencesResponse) = try await session.data(
            for: URLRequest(url: preferencesURL)
        )
        XCTAssertEqual(
            (unchangedPreferencesResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
            "\"0\"",
            "被拒绝的 PATCH 不能修改偏好版本"
        )

        var patch = rejectedPatch
        patch.setValue(csrf, forHTTPHeaderField: "X-MediaLIB-CSRF")
        let (patchData, patchResponse) = try await session.data(for: patch)
        let patchHTTP = try XCTUnwrap(patchResponse as? HTTPURLResponse)
        XCTAssertEqual(patchHTTP.statusCode, 200, String(data: patchData, encoding: .utf8) ?? "")
        XCTAssertEqual(patchHTTP.value(forHTTPHeaderField: "ETag"), "\"1\"")

        let (_, stalePatchResponse) = try await session.data(for: patch)
        XCTAssertEqual((stalePatchResponse as? HTTPURLResponse)?.statusCode, 409)
        let unknownBody = Data(#"{"unknown":true}"#.utf8)
        var unknownPatch = mutationRequest(
            url: preferencesURL,
            method: "PATCH",
            body: unknownBody,
            origin: browserOrigin,
            csrf: csrf
        )
        unknownPatch.setValue("\"1\"", forHTTPHeaderField: "If-Match")
        let (_, unknownPatchResponse) = try await session.data(for: unknownPatch)
        XCTAssertEqual((unknownPatchResponse as? HTTPURLResponse)?.statusCode, 400)

        let overrideURL = baseURL.appendingPathComponent(
            "api/v1/me/playback-overrides/media/lan-e2e-movie"
        )
        let overrideBody = Data(#"{"audioFingerprint":"audio-main","subtitleDisabled":true}"#.utf8)
        let rejectedPut = mutationRequest(
            url: overrideURL,
            method: "PUT",
            body: overrideBody,
            origin: browserOrigin,
            csrf: nil
        )
        let (_, rejectedPutResponse) = try await session.data(for: rejectedPut)
        XCTAssertEqual((rejectedPutResponse as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertNil(try experienceRepository().trackOverride(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            scope: .media,
            scopeID: "lan-e2e-movie"
        ))

        let put = mutationRequest(
            url: overrideURL,
            method: "PUT",
            body: overrideBody,
            origin: browserOrigin,
            csrf: csrf
        )
        let (putData, putResponse) = try await session.data(for: put)
        XCTAssertEqual(
            (putResponse as? HTTPURLResponse)?.statusCode,
            200,
            String(data: putData, encoding: .utf8) ?? ""
        )
        XCTAssertNotNil(try experienceRepository().trackOverride(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            scope: .media,
            scopeID: "lan-e2e-movie"
        ))

        let invalidDeleteBody = Data("{}".utf8)
        let rejectedDelete = mutationRequest(
            url: overrideURL,
            method: "DELETE",
            body: invalidDeleteBody,
            origin: browserOrigin,
            csrf: csrf
        )
        let (_, rejectedDeleteResponse) = try await session.data(for: rejectedDelete)
        XCTAssertEqual((rejectedDeleteResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertNotNil(try experienceRepository().trackOverride(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            scope: .media,
            scopeID: "lan-e2e-movie"
        ), "被拒绝的 DELETE 不能删除轨道偏好")

        let delete = mutationRequest(
            url: overrideURL,
            method: "DELETE",
            body: Data(),
            origin: browserOrigin,
            csrf: csrf
        )
        let (_, deleteResponse) = try await session.data(for: delete)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertNil(try experienceRepository().trackOverride(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            scope: .media,
            scopeID: "lan-e2e-movie"
        ))

        var rangeRequest = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/stream/lan-e2e-movie")
        )
        rangeRequest.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await session.data(for: rangeRequest)
        let rangeHTTP = try XCTUnwrap(rangeResponse as? HTTPURLResponse)
        XCTAssertEqual(rangeHTTP.statusCode, 206)
        XCTAssertEqual(rangeHTTP.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(rangeData, Data("2345".utf8))

        // Reproducible mixed transport load: five remaining requests in the
        // per-identity login burst budget compete with a management read, an
        // authenticated light read, and a local media Range. This validates the
        // real HTTPS boundary rather than only the executor in isolation.
        var mixedRequests: [(kind: String, request: URLRequest)] = []
        for _ in 0..<5 {
            var request = loginRequest
            request.httpBody = loginBody
            mixedRequests.append(("login", request))
        }
        mixedRequests.append((
            "management",
            URLRequest(url: baseURL.appendingPathComponent("api/v1/admin/users"))
        ))
        mixedRequests.append((
            "light",
            URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/me"))
        ))
        mixedRequests.append(("range", rangeRequest))

        let resources = ExternalProcessResourceSampler(processID: process.processIdentifier)
        resources.start()
        let results = await withTaskGroup(
            of: LANMixedLoadResult.self,
            returning: [LANMixedLoadResult].self
        ) { group in
            for entry in mixedRequests {
                group.addTask {
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    do {
                        let (data, response) = try await session.data(for: entry.request)
                        return LANMixedLoadResult(
                            kind: entry.kind,
                            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                            byteCount: data.count,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
                            errorDescription: nil
                        )
                    } catch {
                        return LANMixedLoadResult(
                            kind: entry.kind,
                            status: 0,
                            byteCount: 0,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        resources.stop()

        XCTAssertEqual(results.filter { $0.kind == "login" }.map(\.status).sorted(), [200, 200, 200, 200, 200])
        XCTAssertEqual(results.first { $0.kind == "management" }?.status, 200)
        XCTAssertEqual(results.first { $0.kind == "light" }?.status, 200)
        XCTAssertEqual(results.first { $0.kind == "range" }?.status, 206)
        XCTAssertEqual(results.first { $0.kind == "range" }?.byteCount, 4)
        XCTAssertEqual(results.compactMap(\.errorDescription), [])
        XCTAssertTrue(process.isRunning)

        let loginLatency = percentiles(results.filter { $0.kind == "login" }.map(\.durationNanoseconds))
        let generalLatency = percentiles(results.filter { $0.kind != "login" }.map(\.durationNanoseconds))
        let resourceSnapshot = resources.snapshot
        print(
            "[B12-LAN] mixed login=5 general=3 login_p50=\(loginLatency.p50)ms " +
            "login_p95=\(loginLatency.p95)ms general_p50=\(generalLatency.p50)ms " +
            "general_p95=\(generalLatency.p95)ms rss_start_mib=\(resourceSnapshot.startResidentBytes / 1_048_576) " +
            "rss_peak_mib=\(resourceSnapshot.peakResidentBytes / 1_048_576) " +
            "threads_peak=\(resourceSnapshot.peakThreads)"
        )
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
            memoryCostKib: 65_536,
            randomBytes: { count in [UInt8](repeating: 11, count: count) }
        )
        try ServerIdentityRepository(database: database).setInitialCredential(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            argon2idEncodedHash: try hasher.hash(password: password)
        )
    }

    private func experienceRepository() throws -> ServerExperienceRepository {
        ServerExperienceRepository(database: try DatabaseManager(
            url: root.appendingPathComponent("medialib.sqlite"),
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true)
        ))
    }

    private func mutationRequest(
        url: URL,
        method: String,
        body: Data,
        origin: URL,
        csrf: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        if let csrf {
            request.setValue(csrf, forHTTPHeaderField: "X-MediaLIB-CSRF")
        }
        return request
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

    private func percentiles(_ values: [UInt64]) -> (p50: Int, p95: Int) {
        let sorted = values.sorted()
        func value(_ percentile: Double) -> Int {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
            return Int(sorted[index] / 1_000_000)
        }
        return (value(0.50), value(0.95))
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

private struct LANMixedLoadResult: Sendable {
    let kind: String
    let status: Int
    let byteCount: Int
    let durationNanoseconds: UInt64
    let errorDescription: String?
}

private final class ExternalProcessResourceSampler: @unchecked Sendable {
    struct Snapshot {
        let startResidentBytes: UInt64
        let peakResidentBytes: UInt64
        let peakThreads: Int
    }

    private let processID: pid_t
    private let lock = NSLock()
    private var running = false
    private var startResidentBytes: UInt64 = 0
    private var peakResidentBytes: UInt64 = 0
    private var peakThreads = 0
    private var task: Task<Void, Never>?

    init(processID: pid_t) {
        self.processID = processID
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                startResidentBytes: startResidentBytes,
                peakResidentBytes: peakResidentBytes,
                peakThreads: peakThreads
            )
        }
    }

    func start() {
        sample(recordStart: true)
        lock.withLock { running = true }
        task = Task.detached(priority: .utility) { [self] in
            while lock.withLock({ running }) {
                sample(recordStart: false)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            sample(recordStart: false)
        }
    }

    func stop() {
        lock.withLock { running = false }
        task?.cancel()
        sample(recordStart: false)
    }

    private func sample(recordStart: Bool) {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(processID, PROC_PIDTASKINFO, 0, &info, Int32(size)) == Int32(size) else { return }
        lock.withLock {
            if recordStart { startResidentBytes = info.pti_resident_size }
            peakResidentBytes = max(peakResidentBytes, info.pti_resident_size)
            peakThreads = max(peakThreads, Int(info.pti_threadnum))
        }
    }
}
