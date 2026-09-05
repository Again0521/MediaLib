import Foundation
import MediaLibCore

/// Authenticated artwork delivery for posters, backdrops and detail imagery.
///
/// The outer router owns authentication and the independent `artworkRead` bucket. This handler
/// keeps opaque path parsing, bounded thumbnail variants, private caching and remote derivation in
/// one place. Every rejected method, permission, path or query fails before an asset provider is
/// invoked; upstream artwork bytes are never forwarded directly to the browser.
struct ServerArtworkHTTPHandler {
    private enum ArtworkRequest {
        case original
        case thumbnail(Int)
    }

    private static let retryQueryKey = "_retry"

    private let artworkAssetProvider: (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let detailImageProvider: (String, ServerDetailImageKind, Int, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let thumbnailer: ServerArtworkThumbnailer
    private let remoteAssetFetcher: ServerRemoteAssetFetcher

    init(
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset?,
        detailImageProvider: @escaping (String, ServerDetailImageKind, Int, ServerRequestPrincipal) throws -> ServerMediaAsset?,
        thumbnailer: ServerArtworkThumbnailer,
        remoteAssetFetcher: ServerRemoteAssetFetcher
    ) {
        self.artworkAssetProvider = artworkAssetProvider
        self.detailImageProvider = detailImageProvider
        self.thumbnailer = thumbnailer
        self.remoteAssetFetcher = remoteAssetFetcher
    }

    func response(
        method: String,
        path: String,
        target: String,
        requestHead: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        rateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        guard path.hasPrefix("/api/v1/images/") else { return nil }
        guard method == "GET" || method == "HEAD" else { return .methodNotAllowed() }
        if let limited = rateLimitResponse() { return limited }
        guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
        guard let artworkRequest = artworkRequest(from: target) else { return .badRequest() }

        let remainder = path.dropFirst("/api/v1/images/".count)
        let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
        let asset: ServerMediaAsset?
        switch segments.count {
        case 2:
            guard let itemID = decodedItemID(String(segments[0])),
                  let kind = ServerArtworkKind(rawValue: String(segments[1]))
            else { return .notFound() }
            asset = try? artworkAssetProvider(itemID, kind, principal)
        case 3:
            guard let itemID = decodedItemID(String(segments[0])),
                  let kind = ServerDetailImageKind(rawValue: String(segments[1])),
                  let index = strictNonnegativeInteger(String(segments[2])), index < 64
            else { return .notFound() }
            asset = try? detailImageProvider(itemID, kind, index, principal)
        default:
            return .notFound()
        }
        guard let asset else { return .notFound() }

        let ifNoneMatch = httpHeader(named: "If-None-Match", in: requestHead)
        if let remoteURL = asset.remoteURL {
            let upstreamIdentity = ServerRemoteArtworkURL.stableIdentity(for: remoteURL)
            let maximumPixel: Int
            if case let .thumbnail(requestedMaximumPixel) = artworkRequest {
                maximumPixel = requestedMaximumPixel
            } else {
                maximumPixel = ServerArtworkThumbnailer.supportedMaximumPixels.max() ?? 1_024
            }
            if let cached = thumbnailer.cachedRemoteThumbnail(
                id: asset.id,
                upstreamIdentity: upstreamIdentity,
                maximumPixel: maximumPixel
            ) {
                return fileResponse(
                    cached,
                    cacheControl: "private, max-age=86400",
                    ifNoneMatch: ifNoneMatch,
                    omitBody: omitBody
                )
            }
            // HEAD never downloads or decodes remote artwork solely to discover a length.
            guard !omitBody else { return .notFound() }
            let fetchURL = ServerRemoteArtworkURL.sized(remoteURL, maximumPixel: maximumPixel)
            guard let body = remoteAssetFetcher.artworkBytes(url: fetchURL),
                  let thumbnail = thumbnailer.thumbnail(
                    forRemoteData: body,
                    id: asset.id,
                    upstreamIdentity: upstreamIdentity,
                    maximumPixel: maximumPixel
                  )
            else { return .serviceUnavailable() }
            return fileResponse(
                thumbnail,
                cacheControl: "private, max-age=86400",
                ifNoneMatch: ifNoneMatch,
                omitBody: false
            )
        }

        switch artworkRequest {
        case let .thumbnail(maximumPixel):
            guard let thumbnail = thumbnailer.thumbnail(for: asset, maximumPixel: maximumPixel) else {
                return .notFound()
            }
            return fileResponse(
                thumbnail,
                cacheControl: "private, max-age=86400",
                ifNoneMatch: ifNoneMatch,
                omitBody: omitBody
            )
        case .original:
            return fileResponse(
                asset,
                cacheControl: "private, max-age=300",
                ifNoneMatch: ifNoneMatch,
                omitBody: omitBody
            )
        }
    }

    private func artworkRequest(from target: String) -> ArtworkRequest? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        guard pieces.count == 2 else { return .original }
        guard !pieces[1].isEmpty else { return nil }

        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  key == "size" || key == Self.retryQueryKey,
                  values[key] == nil,
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  value.utf8.count <= 4
            else { return nil }
            if key == Self.retryQueryKey {
                guard value.utf8.count <= 3 else { return nil }
                values[key] = value
                continue
            }
            guard let maximumPixel = Int(value),
                  ServerArtworkThumbnailer.supportedMaximumPixels.contains(maximumPixel)
            else { return nil }
            values[key] = value
        }
        guard let value = values["size"] else { return .original }
        guard let maximumPixel = Int(value) else { return nil }
        return .thumbnail(maximumPixel)
    }

    private func decodedItemID(_ encodedID: String) -> String? {
        guard !encodedID.isEmpty,
              let itemID = encodedID.removingPercentEncoding,
              !itemID.isEmpty,
              !itemID.contains("/"), !itemID.contains("\\"),
              !itemID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              itemID.utf8.count <= 512
        else { return nil }
        return itemID
    }

    private func decodeQueryComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    private func fileResponse(
        _ asset: ServerMediaAsset,
        cacheControl: String,
        ifNoneMatch: String?,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let entityTag = Self.fileEntityTag(for: asset.fileURL) else {
            return .fullFile(asset: asset, omitBody: omitBody, cacheControl: cacheControl)
        }
        if Self.entityTagMatches(entityTag, ifNoneMatch: ifNoneMatch) {
            return .notModified(entityTag: entityTag, cacheControl: cacheControl)
        }
        return .fullFile(
            asset: asset,
            omitBody: omitBody,
            cacheControl: cacheControl,
            entityTag: entityTag
        )
    }

    /// Weak entity tag derived from the file actually served, without rereading image bytes.
    private static func fileEntityTag(for url: URL) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true, let size = values.fileSize else { return nil }
        let modified = Int64(
            (values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000
        )
        return "W/\"\(size)-\(modified)\""
    }

    private static func entityTagMatches(_ entityTag: String, ifNoneMatch header: String?) -> Bool {
        guard let header else { return false }
        let candidates = header.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !candidates.isEmpty else { return false }
        if candidates.contains("*") { return true }
        func normalized(_ value: String) -> String {
            value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
        }
        let expected = normalized(entityTag)
        return candidates.contains { normalized($0) == expected }
    }
}
