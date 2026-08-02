import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 将 Mlink 的受权卡片目录投影为本地只读索引。这里刻意不生成 HTTP 文件 URL：
/// 桌面端不承担媒体解码，实际播放仍由网页端在它自己的认证会话中完成。
struct MlinkLibrarySynchronizer: Sendable {
    enum Error: LocalizedError, Equatable {
        case invalidCategory(String)
        case tooManyItems

        var errorDescription: String? {
            switch self {
            case .invalidCategory(let id): return "Mlink 服务返回了无效分类：\(id)。"
            case .tooManyItems: return "Mlink 服务端资料库过大，已停止同步以保护本机资源。"
            }
        }
    }

    private let client: MlinkAPIClient
    private let maximumItemCount: Int

    init(client: MlinkAPIClient = MlinkAPIClient(), maximumItemCount: Int = 50_000) {
        self.client = client
        self.maximumItemCount = max(1, maximumItemCount)
    }

    func fetchItems(
        serverURL: URL,
        accessToken: String,
        sourceID: String,
        sourcePath: String,
        categories: [ServerLibraryCategory]
    ) async throws -> [MediaItem] {
        var result: [MediaItem] = []
        var seenExternalIDs = Set<String>()
        for category in categories {
            guard let mediaType = MediaType(rawValue: category.id), mediaType != .auto, mediaType != .privateCollection else {
                throw Error.invalidCategory(category.id)
            }
            var offset = 0
            while true {
                let page = try await client.browse(
                    serverURL: serverURL, accessToken: accessToken, type: mediaType.rawValue, offset: offset, limit: 100
                )
                for item in page.items where seenExternalIDs.insert(item.id).inserted {
                    result.append(localItem(item, sourceID: sourceID, sourcePath: sourcePath))
                    if result.count > maximumItemCount { throw Error.tooManyItems }
                }
                guard page.hasMore else { break }
                let nextOffset = page.offset + page.items.count
                guard nextOffset > offset else { throw MlinkAPIClient.Error.untrustedResponse }
                offset = nextOffset
            }
        }
        return result
    }

    func localItem(_ item: ServerLibraryItem, sourceID: String, sourcePath: String) -> MediaItem {
        let state = item.userState
        let localID = "mlink:\(sourceID):\(item.id)"
        let localType = MediaType(rawValue: item.type) ?? .other
        // Never let an untrusted server response turn an opaque ID into additional
        // path segments. `fetchItems` rejects such IDs before persistence, while this
        // value-type helper also remains safe when used directly in tests/import tools.
        let encodedItemID = Self.encodedOpaqueIdentifier(item.id)
        // 本地只读来源 URI 记录网页目的地种类，但仍不含 HTTP 地址、Cookie、token 或媒体 URL。
        let itemSourcePath = sourcePath + (item.isSeries ? "/series/" : "/item/") + encodedItemID
        let playCount = state?.playCount ?? 0
        let playPosition = state?.positionSeconds ?? 0
        let playProgress = state?.progress ?? 0
        let watched = state?.isWatched ?? false
        let lastPlayedAt = state?.lastPlayedAt
        let preference = item.userPreference
        return MediaItem(
            id: localID,
            type: localType,
            title: item.title,
            year: item.year,
            userRating: preference.rating,
            sourcePath: itemSourcePath,
            playCount: playCount,
            playPosition: playPosition,
            playProgress: playProgress,
            watched: watched,
            favorite: preference.isFavorite,
            watchlist: preference.isWatchlist,
            // `externalID` 是服务端 opaque ID；绝不把 token、真实文件路径或 HTTP 媒体 URL 写进本地索引。
            externalID: item.id,
            metadataProvider: "Mlink",
            lastPlayedAt: lastPlayedAt
        )
    }

    private static let opaqueIdentifierAllowed: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()

    private static func encodedOpaqueIdentifier(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: opaqueIdentifierAllowed) ?? value
    }
}
