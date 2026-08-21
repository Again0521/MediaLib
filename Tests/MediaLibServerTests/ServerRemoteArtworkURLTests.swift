import Foundation
import XCTest
@testable import MediaLibServer

final class ServerRemoteArtworkURLTests: XCTestCase {
    private func url(_ value: String) throws -> URL { try XCTUnwrap(URL(string: value)) }

    /// 同步阶段写下的地址固定是 `maxWidth=700`；海报墙要 320 时应当只要 320。
    func testShrinksExistingSizeParameterToRequestedBucket() throws {
        let sized = ServerRemoteArtworkURL.sized(
            try url("https://nas/Items/42/Images/Primary?maxWidth=700&quality=90&api_key=token"),
            maximumPixel: 320
        )
        let components = try XCTUnwrap(URLComponents(url: sized, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first { $0.name == "maxWidth" }?.value, "320")
        // 凭据与其它参数原样保留，否则上游会拒绝这次请求。
        XCTAssertEqual(items.first { $0.name == "api_key" }?.value, "token")
        XCTAssertEqual(items.first { $0.name == "quality" }?.value, "90")
    }

    /// 上游给的是"不超过"语义：原图本来就比请求的桶小时不得放大。
    func testNeverEnlargesBeyondUpstreamSize() throws {
        let sized = ServerRemoteArtworkURL.sized(
            try url("https://nas/Items/42/Images/Primary?maxWidth=160&api_key=t"),
            maximumPixel: 640
        )
        XCTAssertTrue(sized.absoluteString.contains("maxWidth=160"))
    }

    /// 没有尺寸参数的上游保持原样——凭空加一个参数可能被对方拒绝。
    func testLeavesURLsWithoutSizeParametersUntouched() throws {
        let original = try url("https://nas/library/parts/9/file.jpg?X-Plex-Token=abc")
        XCTAssertEqual(ServerRemoteArtworkURL.sized(original, maximumPixel: 320), original)
    }

    /// token 轮换不得让整墙缓存失效：剥掉凭据后身份必须稳定。
    func testIdentityIsStableAcrossTokenRotationAndSizeChanges() throws {
        let first = ServerRemoteArtworkURL.stableIdentity(
            for: try url("https://nas/Items/42/Images/Primary?maxWidth=700&quality=90&api_key=old")
        )
        let rotated = ServerRemoteArtworkURL.stableIdentity(
            for: try url("https://nas/Items/42/Images/Primary?maxWidth=320&quality=90&api_key=new")
        )
        XCTAssertEqual(first, rotated)
    }

    /// 不同封面必须得到不同身份，否则会串图。
    func testDifferentImagesGetDifferentIdentities() throws {
        let a = ServerRemoteArtworkURL.stableIdentity(for: try url("https://nas/Items/1/Images/Primary?api_key=t"))
        let b = ServerRemoteArtworkURL.stableIdentity(for: try url("https://nas/Items/2/Images/Primary?api_key=t"))
        let c = ServerRemoteArtworkURL.stableIdentity(for: try url("https://other/Items/1/Images/Primary?api_key=t"))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    /// 身份里不得残留任何凭据。
    func testIdentityCarriesNoCredential() throws {
        let identity = ServerRemoteArtworkURL.stableIdentity(
            for: try url("https://nas/Items/42/Images/Primary?api_key=super-secret")
        )
        XCTAssertFalse(identity.contains("super-secret"))
        XCTAssertTrue(identity.allSatisfy(\.isHexDigit))
    }
}

/// 远程缩略图的磁盘缓存必须能被"重新找到"。
///
/// 旧实现用**图片字节的摘要**做磁盘键：想命中那张已经派生好的缩略图，必须先把
/// 原图重新下载一遍才能算出键——缓存对省流量毫无作用。唯一的捷径是一个 5 分钟
/// 的内存别名，过期后整墙回源。这些用例锁住新的稳定键行为。
final class ServerRemoteThumbnailCacheTests: XCTestCase {
    private var cacheDirectory: URL!
    private var sourceData: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteThumbCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        sourceData = try Data(contentsOf: sourceURL)
    }

    override func tearDownWithError() throws {
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
        cacheDirectory = nil
        sourceData = nil
        try super.tearDownWithError()
    }

    /// 派生一次之后，**另一个** thumbnailer 实例（等价于进程重启／内存缓存过期）
    /// 不用原图字节就能命中同一张缩略图。
    func testDerivedThumbnailIsFoundAgainWithoutTheOriginalBytes() throws {
        let identity = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/42/Images/Primary?maxWidth=700&api_key=old"))
        )
        let generated = try XCTUnwrap(
            ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).thumbnail(
                forRemoteData: sourceData, id: "movie-1", upstreamIdentity: identity, maximumPixel: 320
            )
        )
        XCTAssertGreaterThan(generated.byteLength, 0)

        // 全新实例：没有任何内存别名，也没有原图字节。
        let cached = try XCTUnwrap(
            ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).cachedRemoteThumbnail(
                id: "movie-1", upstreamIdentity: identity, maximumPixel: 320
            )
        )
        XCTAssertEqual(cached.fileURL, generated.fileURL)
        XCTAssertEqual(cached.byteLength, generated.byteLength)
    }

    /// token 轮换之后仍要命中：否则每次凭据刷新都会让整面海报墙回源。
    func testRotatedUpstreamTokenStillHitsTheSameThumbnail() throws {
        let before = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/42/Images/Primary?maxWidth=700&api_key=old"))
        )
        let after = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/42/Images/Primary?maxWidth=320&api_key=rotated"))
        )
        _ = ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).thumbnail(
            forRemoteData: sourceData, id: "movie-1", upstreamIdentity: before, maximumPixel: 320
        )

        XCTAssertNotNil(
            ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).cachedRemoteThumbnail(
                id: "movie-1", upstreamIdentity: after, maximumPixel: 320
            ),
            "token 轮换不得让已派生的缩略图失效"
        )
    }

    /// 不同封面不得互相命中。
    func testDifferentUpstreamImagesDoNotShareAThumbnail() throws {
        let first = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/1/Images/Primary?api_key=t"))
        )
        let second = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/2/Images/Primary?api_key=t"))
        )
        _ = ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).thumbnail(
            forRemoteData: sourceData, id: "movie-1", upstreamIdentity: first, maximumPixel: 320
        )
        XCTAssertNil(
            ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).cachedRemoteThumbnail(
                id: "movie-2", upstreamIdentity: second, maximumPixel: 320
            )
        )
    }

    /// 每个尺寸桶各自独立，320 的缓存不得被当成 640 返回。
    func testSizeBucketsDoNotCollide() throws {
        let identity = ServerRemoteArtworkURL.stableIdentity(
            for: try XCTUnwrap(URL(string: "https://nas/Items/42/Images/Primary?api_key=t"))
        )
        _ = ServerArtworkThumbnailer(cacheDirectory: cacheDirectory).thumbnail(
            forRemoteData: sourceData, id: "movie-1", upstreamIdentity: identity, maximumPixel: 320
        )
        let thumbnailer = ServerArtworkThumbnailer(cacheDirectory: cacheDirectory)
        XCTAssertNotNil(thumbnailer.cachedRemoteThumbnail(id: "movie-1", upstreamIdentity: identity, maximumPixel: 320))
        XCTAssertNil(thumbnailer.cachedRemoteThumbnail(id: "movie-1", upstreamIdentity: identity, maximumPixel: 640))
    }
}
