import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authenticated WebVTT subtitle-body delivery.
///
/// The outer router owns authentication and the independent `mediaStream` bucket. This handler
/// keeps the sidecar, embedded and remote body paths behind one strict opaque route. HEAD never
/// starts a download, FFmpeg export or whole-file conversion, while GET keeps all materialized
/// subtitle payloads bounded to the public 8 MiB contract.
struct ServerSubtitleHTTPHandler {
    private let subtitleTrackProvider: (String, Int, ServerRequestPrincipal) throws -> ServerSubtitleTrackReference?
    private let mediaTrackCatalog: ServerMediaTrackCatalog
    private let remoteSubtitleBodyCatalog: ServerRemoteSubtitleBodyCatalog

    init(
        subtitleTrackProvider: @escaping (String, Int, ServerRequestPrincipal) throws -> ServerSubtitleTrackReference?,
        mediaTrackCatalog: ServerMediaTrackCatalog,
        remoteSubtitleBodyCatalog: ServerRemoteSubtitleBodyCatalog
    ) {
        self.subtitleTrackProvider = subtitleTrackProvider
        self.mediaTrackCatalog = mediaTrackCatalog
        self.remoteSubtitleBodyCatalog = remoteSubtitleBodyCatalog
    }

    func response(
        method: String,
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        rateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        guard path.hasPrefix("/api/v1/subtitles/") else { return nil }
        guard method == "GET" || method == "HEAD" else { return .methodNotAllowed() }
        if let limited = rateLimitResponse() { return limited }
        guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
        guard !target.contains("?") else { return .badRequest() }
        guard let request = subtitleRequest(from: path) else { return .notFound() }

        let track: ServerSubtitleTrackReference
        do {
            guard let resolved = try subtitleTrackProvider(
                request.itemID, request.trackID, principal
            ) else { return .notFound() }
            track = resolved
        } catch is ServerRemoteSubtitleTracksPending {
            return .accepted(
                body: Data(),
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
            )
        } catch {
            return .notFound()
        }

        switch track.source {
        case let .sidecar(asset):
            return sidecarResponse(asset: asset, omitBody: omitBody)
        case let .embedded(asset, streamIndex):
            switch mediaTrackCatalog.embeddedSubtitleWebVTT(
                for: asset,
                streamIndex: streamIndex,
                startIfNeeded: !omitBody
            ) {
            case let .ready(payload):
                return Self.webVTTResponse(payload: payload, omitBody: omitBody)
            case .pending:
                return .accepted(
                    body: Data(),
                    additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
                )
            case .failed:
                return .notFound()
            }
        case let .remote(remoteTrack):
            guard !omitBody else {
                return Self.webVTTResponse(payload: Data(), omitBody: true)
            }
            switch remoteSubtitleBodyCatalog.webVTT(
                ownerID: "\(request.itemID)/\(request.trackID)",
                track: remoteTrack
            ) {
            case let .ready(payload):
                return Self.webVTTResponse(payload: payload, omitBody: false)
            case .pending:
                return .accepted(
                    body: Data(),
                    additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
                )
            case .failed:
                return .notFound()
            }
        }
    }

    private func subtitleRequest(from path: String) -> (itemID: String, trackID: Int)? {
        let prefix = "/api/v1/subtitles/"
        let remainder = path.dropFirst(prefix.count).split(
            separator: "/", omittingEmptySubsequences: false
        )
        guard remainder.count == 2,
              let itemID = decodedItemID(String(remainder[0])),
              let trackID = strictNonnegativeInteger(String(remainder[1])),
              trackID < ServerWebVTTSubtitleTrack.maximumTrackCount
        else { return nil }
        return (itemID, trackID)
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

    private func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    private func sidecarResponse(
        asset: ServerMediaAsset,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        let maximumByteLength = ServerWebVTTSubtitleTrack.maximumByteLength
        let pathExtension = asset.fileURL.pathExtension.lowercased()
        guard asset.byteLength >= 0,
              asset.byteLength <= Int64(maximumByteLength),
              ServerSubtitleSidecar.supportedExtensions.contains(pathExtension)
        else { return .notFound() }
        if pathExtension == "vtt" {
            return .file(
                url: asset.fileURL,
                byteLength: asset.byteLength,
                contentType: "text/vtt; charset=utf-8",
                omitBody: omitBody
            )
        }
        // Presence has already been authorised and catalogued. HEAD reports the route without
        // synchronously reading and converting up to 8 MiB solely to calculate a derived length.
        guard !omitBody else {
            return Self.webVTTResponse(payload: Data(), omitBody: true)
        }
        guard let raw = boundedFileData(
            at: asset.fileURL,
            maximumByteLength: maximumByteLength
        ), let payload = ServerSubtitleSidecar.webVTTPayload(
            from: raw,
            pathExtension: pathExtension
        ) else { return .notFound() }
        return Self.webVTTResponse(payload: payload, omitBody: false)
    }

    private func boundedFileData(at url: URL, maximumByteLength: Int) -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maximumByteLength + 1),
                  data.count <= maximumByteLength
            else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func webVTTResponse(payload: Data, omitBody: Bool) -> LocalHTTPResponse {
        guard payload.count <= ServerWebVTTSubtitleTrack.maximumByteLength else {
            return .notFound()
        }
        return LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "text/vtt; charset=utf-8",
            payload: .data(omitBody ? Data() : payload),
            declaredContentLength: payload.count,
            additionalHeaders: ["Cache-Control: private, max-age=300"]
        )
    }
}
