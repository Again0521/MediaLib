import Foundation
import MediaLibServerProtocol
import XCTest
@testable import MediaLibServer

/// P4 取舍的回归护栏。这些用例存在的目的不是覆盖率，而是防止有人日后把
/// "浏览器直接拉 Emby 播放地址"当成一个性能优化悄悄接回来。
final class ServerRemoteAccessPolicyTests: XCTestCase {
    private let publicOrigin = URL(string: "https://media.example.com")!
    private let embyUpstream = URL(string: "https://nas.lan/emby/Videos/42/stream.mkv?api_key=account-token")!
    private let plexUpstream = URL(string: "https://nas.lan/library/parts/42/file.mkv?X-Plex-Token=account-token")!

    private func policy(
        lanDirectPlayEnabled: Bool,
        publicOrigin: URL? = nil,
        trustedProxies: Set<String> = []
    ) -> ServerRemoteAccessPolicy {
        ServerRemoteAccessPolicy(
            publicOrigin: publicOrigin,
            trustedProxyAddresses: trustedProxies,
            lanDirectPlayEnabled: lanDirectPlayEnabled
        )
    }

    private func fullyOpenedPolicy() -> ServerRemoteAccessPolicy {
        policy(lanDirectPlayEnabled: true, publicOrigin: publicOrigin, trustedProxies: ["10.0.0.2"])
    }

    func testDefaultDeploymentAlwaysProxies() {
        let decision = ServerRemoteAccessPolicy.loopbackOnly.transportDecision(
            upstream: embyUpstream,
            forwardedClientAddress: "192.168.1.20"
        )
        XCTAssertEqual(decision, .sameOriginProxy(reason: .lanDirectPlayDisabled))
    }

    func testLocalAssetsHaveNoUpstreamToConnectTo() {
        let decision = fullyOpenedPolicy().transportDecision(
            upstream: nil,
            forwardedClientAddress: "192.168.1.20"
        )
        XCTAssertEqual(decision, .sameOriginProxy(reason: .sourceIsLocalAsset))
    }

    func testDirectPlayRequiresTrustedTransportBoundary() {
        let withoutBoundary = policy(lanDirectPlayEnabled: true)
        XCTAssertEqual(
            withoutBoundary.transportDecision(upstream: embyUpstream, forwardedClientAddress: "192.168.1.20"),
            .sameOriginProxy(reason: .transportBoundaryNotTrusted)
        )
        XCTAssertEqual(
            policy(lanDirectPlayEnabled: true, publicOrigin: publicOrigin)
                .transportDecision(upstream: embyUpstream, forwardedClientAddress: "192.168.1.20"),
            .sameOriginProxy(reason: .transportBoundaryNotTrusted)
        )
    }

    func testDirectPlayRequiresVerifiedLanClient() {
        let policy = fullyOpenedPolicy()
        XCTAssertEqual(
            policy.transportDecision(upstream: embyUpstream, forwardedClientAddress: nil),
            .sameOriginProxy(reason: .clientNotOnVerifiedLan)
        )
        XCTAssertEqual(
            policy.transportDecision(upstream: embyUpstream, forwardedClientAddress: "203.0.113.7"),
            .sameOriginProxy(reason: .clientNotOnVerifiedLan)
        )
    }

    func testPlainHTTPUpstreamIsRejectedBeforeCredentialCheck() throws {
        let insecure = try XCTUnwrap(URL(string: "http://nas.lan/emby/Videos/42/stream.mkv"))
        XCTAssertEqual(
            fullyOpenedPolicy().transportDecision(upstream: insecure, forwardedClientAddress: "10.1.2.3"),
            .sameOriginProxy(reason: .upstreamNotSecure)
        )
    }

    /// 本轮 P4 的核心结论：即使每一项传输门禁都打开，Emby/Jellyfin/Plex 的播放
    /// 地址仍然只带账号级长期令牌，因此永远落回代理。
    func testEmbyAndPlexUpstreamsNeverQualifyForDirectPlay() {
        let policy = fullyOpenedPolicy()
        for upstream in [embyUpstream, plexUpstream] {
            XCTAssertEqual(
                policy.transportDecision(upstream: upstream, forwardedClientAddress: "192.168.1.20"),
                .sameOriginProxy(reason: .upstreamCredentialAccountScoped),
                "带 api_key / X-Plex-Token 的地址绝不能交给浏览器"
            )
        }
    }

    func testCredentialScopeClassification() throws {
        XCTAssertEqual(ServerRemoteAccessPolicy.credentialScope(of: embyUpstream), .accountScopedLongLived)
        XCTAssertEqual(ServerRemoteAccessPolicy.credentialScope(of: plexUpstream), .accountScopedLongLived)
        XCTAssertEqual(
            ServerRemoteAccessPolicy.credentialScope(of: try XCTUnwrap(URL(string: "https://nas.lan/a.mkv"))),
            .none
        )
        // 认不出来的查询串一律按账号级处理：误判的代价是外发长期凭据。
        XCTAssertEqual(
            ServerRemoteAccessPolicy.credentialScope(of: try XCTUnwrap(URL(string: "https://nas.lan/a.mkv?x=1"))),
            .accountScopedLongLived
        )
    }

    func testUpstreamWithoutCredentialStillProxiesForLackOfTicket() throws {
        let open = try XCTUnwrap(URL(string: "https://nas.lan/movies/a.mkv"))
        XCTAssertEqual(
            fullyOpenedPolicy().transportDecision(upstream: open, forwardedClientAddress: "172.20.0.5"),
            .sameOriginProxy(reason: .upstreamProvidesNoPlaybackTicket)
        )
    }

    func testPrivateAddressClassification() {
        for address in ["10.0.0.1", "192.168.31.7", "172.16.0.1", "172.31.255.254"] {
            XCTAssertTrue(ServerRemoteAccessPolicy.isPrivateIPv4Address(address), address)
        }
        for address in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "", "1.2.3", "1.2.3.4.5", "abc"] {
            XCTAssertFalse(ServerRemoteAccessPolicy.isPrivateIPv4Address(address), address)
        }
    }

    func testReadinessReportsEachPrerequisiteSeparately() {
        let loopback = ServerRemoteAccessPolicy.loopbackOnly.lanAccessReadiness()
        XCTAssertFalse(loopback.hasHTTPSPublicOrigin)
        XCTAssertFalse(loopback.hasTrustedReverseProxy)
        XCTAssertFalse(loopback.isReadyForLanAccess)
        XCTAssertEqual(loopback.lanDirectPlayBlockedBy, .lanDirectPlayDisabled)
        XCTAssertFalse(loopback.supportedUpstreamsIssueScopedTickets)

        let opened = fullyOpenedPolicy().lanAccessReadiness()
        XCTAssertTrue(opened.hasHTTPSPublicOrigin)
        XCTAssertTrue(opened.hasTrustedReverseProxy)
        XCTAssertTrue(opened.listenerIsLoopbackOnly)
        XCTAssertTrue(opened.isReadyForLanAccess)
        XCTAssertNil(opened.lanDirectPlayBlockedBy)
        XCTAssertFalse(opened.supportedUpstreamsIssueScopedTickets)
    }

    /// 就绪度只回答策略事实，不能泄露公开域名、反代 IP 或上游地址。
    func testReadinessJSONCarriesNoDeploymentIdentifiers() throws {
        let data = try XCTUnwrap(ServerCommandOutput.jsonData(fullyOpenedPolicy().lanAccessReadiness()))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("media.example.com"))
        XCTAssertFalse(json.contains("10.0.0.2"))
        XCTAssertFalse(json.contains("nas.lan"))
        XCTAssertFalse(json.lowercased().contains("api_key"))
        XCTAssertTrue(json.contains("\"isReadyForLanAccess\":true"))
    }

    /// 派生结论不接受外部输入：被篡改的 `isReadyForLanAccess` 必须被重新计算覆盖。
    func testReadinessDecodingRecomputesDerivedVerdict() throws {
        let payload = Data(#"""
        {"hasHTTPSPublicOrigin":false,"hasTrustedReverseProxy":false,"listenerIsLoopbackOnly":true,
         "sessionCookiesAreHardened":true,"supportsSessionRevocation":true,"proxyStressTestCovered":true,
         "lanDirectPlayEnabled":false,"supportedUpstreamsIssueScopedTickets":false,
         "isReadyForLanAccess":true}
        """#.utf8)
        let decoded = try JSONDecoder().decode(ServerLanAccessReadiness.self, from: payload)
        XCTAssertFalse(decoded.isReadyForLanAccess)
    }
}
