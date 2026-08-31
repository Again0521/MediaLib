import Foundation
import MediaLibCore

/// Emby / Jellyfin / Plex 条目的字幕轨发现与读取。
///
/// 远程条目在网页上从来没有过字幕：`webVTTSubtitleAssets` 第一行就是
/// `guard asset.remoteURL == nil`——那条判断本身没错（远程条目没有同目录可扫），
/// 但它之后什么也没有接上，于是整台 Emby 的内封字幕在网页上不存在。
///
/// 服务端问得到：同步阶段写进 `file_path` 的那个播放地址**本身带着凭据**
///（Emby/Jellyfin 是 `api_key`，Plex 是 `X-Plex-Token`），从它就能推出同一台服务器的
/// 元数据端点。凭据自始至终留在服务端——浏览器拿到的只有本机的
/// `/api/v1/subtitles/<id>/<n>`，和本地文件那条路径完全一样。
enum ServerRemoteSubtitleCatalog {
    /// 一条远程字幕轨。`downloadURL` 只在服务端流转。
    struct Track: Equatable {
        let label: String
        let language: String?
        /// 用来决定怎么归一：`vtt` 直接发，`srt`/`ass` 走转换。
        let format: String
        let downloadURL: URL
    }

    static let maximumMetadataByteLength = 2 * 1_024 * 1_024

    /// 同步入口只供直接单元测试和兼容调用使用。生产路由使用下面的
    /// `ServerRemoteSubtitleTrackCatalog`，不会在 HTTP 执行队列等待这次读取。
    static func tracks(
        for item: MediaItem,
        streamURL: URL,
        fetcher: ServerRemoteAssetFetcher
    ) -> [Track] {
        resolvedTracks(for: item, streamURL: streamURL, fetcher: fetcher) ?? []
    }

    static func resolvedTracks(
        for item: MediaItem,
        streamURL: URL,
        fetcher: ServerRemoteAssetFetcher,
        cancellation: ServerRemoteAssetFetcher.Cancellation? = nil
    ) -> [Track]? {
        guard RemoteLibraryPathPolicy.isMediaServerSourcePath(item.sourcePath) else { return [] }
        if RemoteLibraryPathPolicy.isEmbyCompatibleSourcePath(item.sourcePath) {
            return embyTracks(
                streamURL: streamURL,
                fetcher: fetcher,
                cancellation: cancellation
            )
        }
        if item.sourcePath?.lowercased().hasPrefix("plex://") == true {
            return plexTracks(
                streamURL: streamURL,
                ratingKey: item.externalID,
                fetcher: fetcher,
                cancellation: cancellation
            )
        }
        // Mlink 条目在本地索引里**没有** `file_path`（见 `MlinkLibrarySynchronizer`），
        // 因此根本走不到这里；留一个空数组而不是猜一个端点。
        return []
    }

    /// 取回一条远程字幕并归一成 WebVTT。
    static func webVTT(
        for track: Track,
        fetcher: ServerRemoteAssetFetcher,
        cancellation: ServerRemoteAssetFetcher.Cancellation? = nil
    ) -> Data? {
        guard let raw = fetcher.metadataBytes(
            url: track.downloadURL,
            maximumByteLength: ServerWebVTTSubtitleTrack.maximumByteLength,
            accept: "text/vtt, text/plain, */*",
            cancellation: cancellation
        ) else { return nil }
        return ServerSubtitleSidecar.webVTTPayload(from: raw, pathExtension: track.format)
    }

    // MARK: - Emby / Jellyfin

    /// 播放地址形如 `<base>/Videos/<itemID>/stream.mkv?…&api_key=…&MediaSourceId=…`。
    /// 从它拆出 base、条目 ID、媒体源 ID 与 token。
    private static func embyTracks(
        streamURL: URL,
        fetcher: ServerRemoteAssetFetcher,
        cancellation: ServerRemoteAssetFetcher.Cancellation?
    ) -> [Track]? {
        guard let components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let token = queryItems.first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?.value,
              !token.isEmpty
        else { return [] }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // 倒着找 `Videos`/`Audio`：服务器可能挂在 `/emby` 这样的子路径下。
        guard let anchor = segments.lastIndex(where: { $0 == "Videos" || $0 == "Audio" }),
              anchor + 1 < segments.count
        else { return [] }
        let itemID = segments[anchor + 1]
        guard !itemID.isEmpty else { return [] }
        var base = components
        base.path = "/" + segments[..<anchor].joined(separator: "/")
        base.query = nil
        base.fragment = nil
        guard let baseURL = base.url else { return [] }
        let mediaSourceID = queryItems.first {
            $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame
        }?.value

        guard var listing = URLComponents(
            url: baseURL.appendingPathComponent("Items"), resolvingAgainstBaseURL: false
        ) else { return [] }
        listing.queryItems = [
            URLQueryItem(name: "Ids", value: itemID),
            URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams"),
            URLQueryItem(name: "api_key", value: token)
        ]
        guard let listingURL = listing.url else { return [] }
        guard let data = fetcher.metadataBytes(
            url: listingURL,
            maximumByteLength: maximumMetadataByteLength,
            accept: "application/json",
            cancellation: cancellation
        ) else { return nil }
        guard
              let document = try? JSONDecoder().decode(EmbyItemsDocument.self, from: data),
              let source = document.Items?.first?.MediaSources?.first(where: { candidate in
                  mediaSourceID.map { $0 == candidate.Id } ?? true
              }) ?? document.Items?.first?.MediaSources?.first
        else { return [] }

        let sourceID = source.Id ?? mediaSourceID
        return (source.MediaStreams ?? []).compactMap { stream -> Track? in
            guard stream.StreamType?.caseInsensitiveCompare("Subtitle") == .orderedSame,
                  let index = stream.Index,
                  index >= 0
            else { return nil }
            guard let format = textSubtitleFormat(stream.Codec, deliveryURL: stream.DeliveryUrl) else {
                // 图形字幕（PGS/VobSub）没有文本形态，列出来读者也只会选到一条空轨。
                return nil
            }
            // 交付地址优先用上游自己给的（Jellyfin 会给一条已经转好的 `.vtt`）。
            let url: URL?
            if let delivery = stream.DeliveryUrl, !delivery.isEmpty {
                url = authenticated(URL(string: delivery, relativeTo: baseURL)?.absoluteURL, token: token)
            } else if let sourceID {
                url = authenticated(
                    baseURL
                        .appendingPathComponent("Videos")
                        .appendingPathComponent(itemID)
                        .appendingPathComponent(sourceID)
                        .appendingPathComponent("Subtitles")
                        .appendingPathComponent("\(index)")
                        .appendingPathComponent("Stream.vtt"),
                    token: token
                )
            } else {
                url = nil
            }
            guard let url, sameHost(url, baseURL) else { return nil }
            // 走 `Stream.vtt` 时上游已经转好了，格式就是 vtt。
            let effectiveFormat = url.pathExtension.lowercased() == "vtt" ? "vtt" : format
            return Track(
                label: label(stream.DisplayTitle ?? stream.Title, language: stream.Language),
                language: normalizedLanguage(stream.Language),
                format: effectiveFormat,
                downloadURL: url
            )
        }
    }

    private static func authenticated(_ url: URL?, token: String) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }
        items.append(URLQueryItem(name: "api_key", value: token))
        components.queryItems = items
        return components.url
    }

    // MARK: - Plex

    /// 播放地址形如 `<base>/library/parts/<partID>/<ts>/file.mkv?X-Plex-Token=…`。
    /// 字幕轨挂在条目元数据上，因此还需要 `ratingKey`（同步时存进了 `externalID`）。
    private static func plexTracks(
        streamURL: URL,
        ratingKey: String?,
        fetcher: ServerRemoteAssetFetcher,
        cancellation: ServerRemoteAssetFetcher.Cancellation?
    ) -> [Track]? {
        guard let ratingKey, !ratingKey.isEmpty,
              ratingKey.allSatisfy({ $0.isNumber }),
              var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame
              })?.value,
              !token.isEmpty
        else { return [] }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else { return [] }
        guard var metadata = URLComponents(
            url: baseURL
                .appendingPathComponent("library")
                .appendingPathComponent("metadata")
                .appendingPathComponent(ratingKey),
            resolvingAgainstBaseURL: false
        ) else { return [] }
        metadata.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let metadataURL = metadata.url else { return [] }
        guard let data = fetcher.metadataBytes(
            url: metadataURL,
            maximumByteLength: maximumMetadataByteLength,
            accept: "application/xml",
            cancellation: cancellation
        ), let text = String(data: data, encoding: .utf8) else { return nil }

        return ServerXMLAttributeScanner.elements(named: "Stream", in: text).compactMap { attributes -> Track? in
            // Plex 的 streamType：1 视频、2 音频、3 字幕。
            guard attributes["streamType"] == "3" else { return nil }
            guard let format = textSubtitleFormat(attributes["codec"], deliveryURL: attributes["key"]) else {
                return nil
            }
            // 外挂字幕带 `key`（一个可直接下载的相对路径）；内封轨没有 key，
            // 走 `/library/streams/<id>`。
            let path: String
            if let key = attributes["key"], key.hasPrefix("/") {
                path = key
            } else if let id = attributes["id"], id.allSatisfy(\.isNumber), !id.isEmpty {
                path = "/library/streams/\(id)"
            } else {
                return nil
            }
            guard var download = URLComponents(
                url: URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL,
                resolvingAgainstBaseURL: false
            ) else { return nil }
            var items = download.queryItems ?? []
            items.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            download.queryItems = items
            guard let url = download.url, sameHost(url, baseURL) else { return nil }
            let displayTitle = attributes["extendedDisplayTitle"] ?? attributes["displayTitle"] ?? attributes["title"]
            return Track(
                label: label(displayTitle, language: attributes["languageTag"] ?? attributes["language"]),
                language: normalizedLanguage(attributes["languageTag"] ?? attributes["languageCode"]),
                format: format,
                downloadURL: url
            )
        }
    }

    // MARK: - 共用

    /// 上游报的编码名是不是一种**文本**字幕。图形字幕返回 nil。
    private static func textSubtitleFormat(_ codec: String?, deliveryURL: String?) -> String? {
        let candidates = [
            deliveryURL.flatMap { URL(string: $0)?.pathExtension.lowercased() },
            codec?.lowercased()
        ]
        for value in candidates {
            switch value {
            case "srt", "subrip": return "srt"
            case "ass": return "ass"
            case "ssa": return "ssa"
            case "vtt", "webvtt": return "vtt"
            case "mov_text", "text": return "srt"
            default: continue
            }
        }
        return nil
    }

    private static func label(_ raw: String?, language: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        if let language, !language.isEmpty { return String(language.prefix(80)) }
        return "字幕"
    }

    /// 上游的语言标记写法很杂（`chi`/`zh-CN`/`Chinese`）。复用外挂字幕那份映射，
    /// 映射不到就不声明——声明一个错的语言会让"按浏览器语言选默认轨"选错。
    private static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return ServerSubtitleSidecar.descriptor(
            mediaStem: "media",
            subtitleFileName: "media.\(raw).srt",
            fallbackIndex: 0
        ).language
    }

    /// 推导出来的地址必须还落在同一台服务器上。上游给的 `DeliveryUrl` / `key` 是
    /// 数据，不是指令——一个被改过的返回值不能把服务端引到别的主机去取东西。
    private static func sameHost(_ url: URL, _ base: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil
        else { return false }
        return url.host?.lowercased() == base.host?.lowercased() && url.port == base.port
    }
}

struct ServerRemoteSubtitleTracksPending: Error {}

/// Asynchronous, revision-aware discovery for Emby/Jellyfin/Plex subtitle
/// metadata. The track list is part of playback preparation, not page rendering:
/// a cold upstream must therefore produce 202 instead of occupying an HTTP
/// connection thread for the fetcher's full timeout.
final class ServerRemoteSubtitleTrackCatalog {
    enum State {
        case ready([ServerRemoteSubtitleCatalog.Track])
        case pending
        case failed
    }

    private struct Key: Hashable {
        let ownerID: String
        let revision: String
    }

    private final class Flight {
        let cancellation = ServerRemoteAssetFetcher.Cancellation()
    }

    private let lock = NSLock()
    private var cache: [Key: (tracks: [ServerRemoteSubtitleCatalog.Track], expiresAt: TimeInterval)] = [:]
    private var cacheOrder: [Key] = []
    private var flights: [Key: Flight] = [:]
    private var failures: [Key: TimeInterval] = [:]
    private var failureOrder: [Key] = []
    private let fetchTracks: (
        MediaItem,
        URL,
        ServerRemoteAssetFetcher.Cancellation
    ) -> [ServerRemoteSubtitleCatalog.Track]?
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore
    private let uptimeProvider: () -> TimeInterval

    private static let cacheLifetime: TimeInterval = 60
    private static let failureVisibility: TimeInterval = 1
    private static let maximumCacheEntries = 128
    private static let maximumPendingFetches = 8

    init(
        fetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher(),
        fetchTracks: ((
            MediaItem,
            URL,
            ServerRemoteAssetFetcher.Cancellation
        ) -> [ServerRemoteSubtitleCatalog.Track]?)? = nil,
        queue: DispatchQueue = DispatchQueue(
            label: "MediaLibServer.RemoteSubtitleTracks",
            qos: .utility,
            attributes: .concurrent
        ),
        maximumConcurrentFetches: Int = 2,
        uptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.fetchTracks = fetchTracks ?? { item, streamURL, cancellation in
            ServerRemoteSubtitleCatalog.resolvedTracks(
                for: item,
                streamURL: streamURL,
                fetcher: fetcher,
                cancellation: cancellation
            )
        }
        self.queue = queue
        self.slots = DispatchSemaphore(value: min(4, max(1, maximumConcurrentFetches)))
        self.uptimeProvider = uptimeProvider
    }

    deinit {
        cancelAll()
    }

    func tracks(for item: MediaItem, streamURL: URL, startIfNeeded: Bool = true) -> State {
        let key = Key(ownerID: item.id, revision: Self.revision(for: item, streamURL: streamURL))
        let now = uptimeProvider()
        lock.lock()
        if let cached = cache[key] {
            if cached.expiresAt > now {
                lock.unlock()
                return .ready(cached.tracks)
            }
            cache.removeValue(forKey: key)
            cacheOrder.removeAll { $0 == key }
        }
        if let failureUntil = failures[key] {
            if failureUntil > now {
                lock.unlock()
                return .failed
            }
            failures.removeValue(forKey: key)
            failureOrder.removeAll { $0 == key }
        }
        if flights[key] != nil {
            lock.unlock()
            return .pending
        }

        let superseded = flights.filter { $0.key.ownerID == item.id && $0.key != key }
        for oldKey in superseded.keys { flights.removeValue(forKey: oldKey) }
        let staleCache = cacheOrder.filter { $0.ownerID == item.id && $0 != key }
        for oldKey in staleCache { cache.removeValue(forKey: oldKey) }
        cacheOrder.removeAll { staleCache.contains($0) }
        let staleFailures = failureOrder.filter { $0.ownerID == item.id && $0 != key }
        for oldKey in staleFailures { failures.removeValue(forKey: oldKey) }
        failureOrder.removeAll { staleFailures.contains($0) }

        guard startIfNeeded, flights.count < Self.maximumPendingFetches else {
            lock.unlock()
            superseded.values.forEach { $0.cancellation.cancel() }
            return startIfNeeded ? .failed : .pending
        }
        let flight = Flight()
        flights[key] = flight
        lock.unlock()
        superseded.values.forEach { $0.cancellation.cancel() }

        queue.async { [self] in
            slots.wait()
            defer { slots.signal() }
            guard !flight.cancellation.isCancelled else { return }
            let tracks = fetchTracks(item, streamURL, flight.cancellation)
            finish(tracks, key: key)
        }
        return .pending
    }

    func cancel(ownerID: String) {
        lock.lock()
        let cancelled = flights.filter { $0.key.ownerID == ownerID }
        for key in cancelled.keys { flights.removeValue(forKey: key) }
        lock.unlock()
        cancelled.values.forEach { $0.cancellation.cancel() }
    }

    private func cancelAll() {
        lock.lock()
        let cancelled = Array(flights.values)
        flights.removeAll()
        lock.unlock()
        cancelled.forEach { $0.cancellation.cancel() }
    }

    private func finish(_ tracks: [ServerRemoteSubtitleCatalog.Track]?, key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard flights.removeValue(forKey: key) != nil else { return }
        let now = uptimeProvider()
        guard let tracks else {
            failures[key] = now + Self.failureVisibility
            failureOrder.removeAll { $0 == key }
            failureOrder.append(key)
            while failureOrder.count > Self.maximumCacheEntries {
                failures.removeValue(forKey: failureOrder.removeFirst())
            }
            return
        }
        failures.removeValue(forKey: key)
        failureOrder.removeAll { $0 == key }
        cache[key] = (Array(tracks.prefix(ServerWebVTTSubtitleTrack.maximumTrackCount)), now + Self.cacheLifetime)
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.maximumCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private static func revision(for item: MediaItem, streamURL: URL) -> String {
        ServerTokenSecurity.digest([
            item.sourcePath ?? "",
            item.externalID ?? "",
            streamURL.absoluteString
        ].joined(separator: "|")) ?? "remote-track-\(streamURL.absoluteString.hashValue)"
    }
}

/// Remote subtitle bodies have the same cold-start shape as embedded subtitle
/// exports: the work can take a full upstream timeout, while the browser only
/// needs a small state response that it can retry. This catalog keeps that
/// wait off the HTTP connection queue, coalesces identical requests, and owns
/// cancellation when an item's track revision changes.
final class ServerRemoteSubtitleBodyCatalog {
    enum State {
        case ready(Data)
        case pending
        case failed
    }

    private struct Key: Hashable {
        let ownerID: String
        let revision: String
    }

    private struct CacheEntry {
        let payload: Data
        let expiresAt: TimeInterval
    }

    private final class Flight {
        let cancellation = ServerRemoteAssetFetcher.Cancellation()
    }

    private let lock = NSLock()
    private var cache: [Key: CacheEntry] = [:]
    private var cacheOrder: [Key] = []
    private var cacheByteLength = 0
    private var flights: [Key: Flight] = [:]
    private var failures: [Key: TimeInterval] = [:]
    private var failureOrder: [Key] = []
    private let fetchBody: (
        ServerRemoteSubtitleCatalog.Track,
        ServerRemoteAssetFetcher.Cancellation
    ) -> Data?
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore
    private let uptimeProvider: () -> TimeInterval

    private static let cacheLifetime: TimeInterval = 300
    private static let failureVisibility: TimeInterval = 1
    private static let maximumCacheEntries = 64
    private static let maximumCacheByteLength = 32 * 1_024 * 1_024
    private static let maximumPendingFetches = 8

    init(
        fetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher(),
        fetchBody: ((
            ServerRemoteSubtitleCatalog.Track,
            ServerRemoteAssetFetcher.Cancellation
        ) -> Data?)? = nil,
        queue: DispatchQueue = DispatchQueue(
            label: "MediaLibServer.RemoteSubtitleBodies",
            qos: .utility,
            attributes: .concurrent
        ),
        maximumConcurrentFetches: Int = 2,
        uptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.fetchBody = fetchBody ?? { track, cancellation in
            ServerRemoteSubtitleCatalog.webVTT(
                for: track,
                fetcher: fetcher,
                cancellation: cancellation
            )
        }
        self.queue = queue
        self.slots = DispatchSemaphore(value: min(4, max(1, maximumConcurrentFetches)))
        self.uptimeProvider = uptimeProvider
    }

    deinit {
        cancelAll()
    }

    /// `ownerID` is an opaque local item/track identity, never an upstream URL.
    /// A changed URL/format creates a new revision and immediately cancels any
    /// queued or active request for the previous revision of that owner.
    func webVTT(
        ownerID: String,
        track: ServerRemoteSubtitleCatalog.Track,
        startIfNeeded: Bool = true
    ) -> State {
        guard !ownerID.isEmpty else { return .failed }
        let key = Key(ownerID: ownerID, revision: Self.revision(for: track))
        let now = uptimeProvider()
        lock.lock()
        if let cached = cache[key] {
            if cached.expiresAt > now {
                lock.unlock()
                return .ready(cached.payload)
            }
            removeCached(key)
        }
        if let failureUntil = failures[key] {
            if failureUntil > now {
                lock.unlock()
                return .failed
            }
            failures.removeValue(forKey: key)
            failureOrder.removeAll { $0 == key }
        }
        if flights[key] != nil {
            lock.unlock()
            return .pending
        }

        let superseded = flights.filter { $0.key.ownerID == ownerID && $0.key != key }
        for oldKey in superseded.keys { flights.removeValue(forKey: oldKey) }
        let supersededCache = cacheOrder.filter { $0.ownerID == ownerID && $0 != key }
        for oldKey in supersededCache { removeCached(oldKey) }
        let supersededFailures = failureOrder.filter { $0.ownerID == ownerID && $0 != key }
        for oldKey in supersededFailures { failures.removeValue(forKey: oldKey) }
        failureOrder.removeAll { supersededFailures.contains($0) }

        guard startIfNeeded, flights.count < Self.maximumPendingFetches else {
            lock.unlock()
            superseded.values.forEach { $0.cancellation.cancel() }
            return startIfNeeded ? .failed : .pending
        }
        let flight = Flight()
        flights[key] = flight
        lock.unlock()
        superseded.values.forEach { $0.cancellation.cancel() }

        queue.async { [self] in
            slots.wait()
            defer { slots.signal() }
            guard !flight.cancellation.isCancelled else { return }
            let payload = fetchBody(track, flight.cancellation)
            finish(payload, key: key)
        }
        return .pending
    }

    func cancel(ownerID: String) {
        lock.lock()
        let cancelled = flights.filter { $0.key.ownerID == ownerID }
        for key in cancelled.keys { flights.removeValue(forKey: key) }
        lock.unlock()
        cancelled.values.forEach { $0.cancellation.cancel() }
    }

    private func cancelAll() {
        lock.lock()
        let cancelled = Array(flights.values)
        flights.removeAll()
        lock.unlock()
        cancelled.forEach { $0.cancellation.cancel() }
    }

    private func finish(_ payload: Data?, key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard flights.removeValue(forKey: key) != nil else { return }
        let now = uptimeProvider()
        guard let payload,
              !payload.isEmpty,
              payload.count <= ServerWebVTTSubtitleTrack.maximumByteLength
        else {
            failures[key] = now + Self.failureVisibility
            failureOrder.removeAll { $0 == key }
            failureOrder.append(key)
            trimFailures()
            return
        }
        failures.removeValue(forKey: key)
        failureOrder.removeAll { $0 == key }
        if cache[key] == nil {
            cache[key] = CacheEntry(
                payload: payload,
                expiresAt: now + Self.cacheLifetime
            )
            cacheOrder.append(key)
            cacheByteLength += payload.count
            while cacheOrder.count > Self.maximumCacheEntries
                || cacheByteLength > Self.maximumCacheByteLength {
                removeCached(cacheOrder[0])
            }
        }
    }

    private func removeCached(_ key: Key) {
        if let removed = cache.removeValue(forKey: key) {
            cacheByteLength -= removed.payload.count
        }
        cacheOrder.removeAll { $0 == key }
    }

    private func trimFailures() {
        while failureOrder.count > Self.maximumCacheEntries {
            failures.removeValue(forKey: failureOrder.removeFirst())
        }
    }

    private static func revision(for track: ServerRemoteSubtitleCatalog.Track) -> String {
        ServerTokenSecurity.digest(
            "\(track.format.lowercased())|\(track.downloadURL.absoluteString)"
        ) ?? "remote-subtitle-\(track.downloadURL.absoluteString.hashValue)"
    }
}

// MARK: - Emby JSON

private struct EmbyItemsDocument: Decodable {
    let Items: [EmbyItem]?

    struct EmbyItem: Decodable {
        let MediaSources: [EmbyMediaSource]?
    }

    struct EmbyMediaSource: Decodable {
        let Id: String?
        let MediaStreams: [EmbyMediaStream]?
    }

    struct EmbyMediaStream: Decodable {
        /// 上游字段名就叫 `Type`，但 Swift 不允许这个成员名，只能改名并显式映射。
        enum CodingKeys: String, CodingKey {
            case Index, Codec, Language, Title, DisplayTitle, DeliveryUrl
            case StreamType = "Type"
        }

        let Index: Int?
        let StreamType: String?
        let Codec: String?
        let Language: String?
        let Title: String?
        let DisplayTitle: String?
        let DeliveryUrl: String?
    }
}

/// Plex 的元数据是 XML。这里只需要"找出所有 `<Stream …/>` 并读它们的属性"，
/// 所以用一个几十行的属性扫描器，而不是拉进 `FoundationXML`——服务端要能在
/// 没有 Foundation XML 的环境里构建，而完整 XML 解析在这里也用不上。
enum ServerXMLAttributeScanner {
    static let maximumElements = 512

    static func elements(named name: String, in xml: String) -> [[String: String]] {
        var result: [[String: String]] = []
        var scanner = Substring(xml)
        let opening = "<\(name) "
        while let start = scanner.range(of: opening), result.count < maximumElements {
            let rest = scanner[start.upperBound...]
            guard let close = rest.firstIndex(of: ">") else { break }
            result.append(attributes(in: rest[..<close]))
            scanner = rest[close...]
        }
        return result
    }

    private static func attributes(in fragment: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var scanner = fragment
        while let equals = scanner.firstIndex(of: "=") {
            let name = scanner[..<equals]
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                .last
                .map(String.init) ?? ""
            let afterEquals = scanner[scanner.index(after: equals)...]
            guard let quote = afterEquals.first, quote == "\"" || quote == "'" else {
                scanner = afterEquals
                continue
            }
            let value = afterEquals.dropFirst()
            guard let end = value.firstIndex(of: quote) else { break }
            if !name.isEmpty, result.count < 64 {
                result[name] = decodedEntities(String(value[..<end]))
            }
            scanner = value[value.index(after: end)...]
        }
        return result
    }

    private static func decodedEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
