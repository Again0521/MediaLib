import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authenticated, bounded playback metadata and track discovery APIs.
///
/// Media bytes and subtitle bodies deliberately stay outside this handler: they use the
/// `mediaStream` bucket and streaming response contracts. These routes all use `mediaProbe` and
/// must finish method, permission, target and query validation before invoking a provider.
struct ServerPlaybackMetadataHTTPHandler {
    private let playbackInfoProvider: (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo?
    private let subtitleTracksProvider: (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]?
    private let playbackTracksProvider: (String, ServerRequestPrincipal) throws -> ServerWebPlaybackTrackSet?
    private let remuxStartProvider: (String, Double, ServerRequestPrincipal) throws -> Double?
    private let experienceRepository: ServerExperienceRepository?
    private let mediaDetailProvider: (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?

    init(
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo?,
        subtitleTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]?,
        playbackTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerWebPlaybackTrackSet?,
        remuxStartProvider: @escaping (String, Double, ServerRequestPrincipal) throws -> Double?,
        experienceRepository: ServerExperienceRepository?,
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?
    ) {
        self.playbackInfoProvider = playbackInfoProvider
        self.subtitleTracksProvider = subtitleTracksProvider
        self.playbackTracksProvider = playbackTracksProvider
        self.remuxStartProvider = remuxStartProvider
        self.experienceRepository = experienceRepository
        self.mediaDetailProvider = mediaDetailProvider
    }

    func response(
        method: String,
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        rateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        guard let route = Route(path: path) else { return nil }
        guard method == "GET" || method == "HEAD" else { return .methodNotAllowed() }
        if let limited = rateLimitResponse() { return limited }
        guard principal.permissions.contains(.viewMedia) else { return .forbidden() }

        switch route {
        case .info:
            guard let itemID = exactItemID(
                from: target, prefix: "/api/v1/playback/info/"
            ) else { return .badRequest() }
            return playbackInfoResponse(itemID: itemID, principal: principal, omitBody: omitBody)
        case .subtitles:
            guard let itemID = exactItemID(
                from: target, prefix: "/api/v1/playback/subtitles/"
            ) else { return .badRequest() }
            return subtitleTracksResponse(itemID: itemID, principal: principal, omitBody: omitBody)
        case .tracks:
            guard let itemID = exactItemID(
                from: target, prefix: "/api/v1/playback/tracks/"
            ) else { return .badRequest() }
            return playbackTracksResponse(itemID: itemID, principal: principal, omitBody: omitBody)
        case .keyframe:
            guard let request = keyframeRequest(from: target),
                  let resolved = try? remuxStartProvider(request.itemID, request.seconds, principal)
            else { return .notFound() }
            let encoded = Data("{\"startSeconds\":\(String(format: "%.3f", resolved))}".utf8)
            return .ok(body: encoded, omitBody: omitBody)
        }
    }

    private enum Route {
        case info, subtitles, tracks, keyframe

        init?(path: String) {
            if path.hasPrefix("/api/v1/playback/info/") {
                self = .info
            } else if path.hasPrefix("/api/v1/playback/subtitles/") {
                self = .subtitles
            } else if path.hasPrefix("/api/v1/playback/tracks/") {
                self = .tracks
            } else if path.hasPrefix("/api/v1/playback/keyframe/") {
                self = .keyframe
            } else {
                return nil
            }
        }
    }

    private func playbackInfoResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let info = try playbackInfoProvider(itemID, principal) else { return .notFound() }
            guard let body = ServerCommandOutput.jsonData(info) else { return .serviceUnavailable() }
            return .ok(body: body, omitBody: omitBody)
        } catch {
            // ffprobe failures can contain local paths or corrupt-file excerpts; never echo them.
            return .serviceUnavailable()
        }
    }

    private func subtitleTracksResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let tracks = try subtitleTracksProvider(itemID, principal),
                  let body = ServerCommandOutput.jsonData(tracks)
            else { return .notFound() }
            return .ok(body: body, omitBody: omitBody)
        } catch is ServerRemoteSubtitleTracksPending {
            return .accepted(
                body: Data(),
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
            )
        } catch {
            return .notFound()
        }
    }

    private func playbackTracksResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        let baseTracks: ServerWebPlaybackTrackSet
        do {
            guard let resolved = try playbackTracksProvider(itemID, principal) else {
                return .notFound()
            }
            baseTracks = resolved
        } catch is ServerRemoteSubtitleTracksPending {
            return .accepted(
                body: Data(),
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
            )
        } catch {
            return .notFound()
        }

        var selectionOverride = try? experienceRepository?.trackOverride(
            userID: principal.userID,
            scope: .media,
            scopeID: itemID
        )
        if selectionOverride == nil,
           let detail = try? mediaDetailProvider(itemID, principal),
           let seriesID = detail.episodeContext?.seriesID {
            selectionOverride = try? experienceRepository?.trackOverride(
                userID: principal.userID,
                scope: .series,
                scopeID: seriesID
            )
        }
        let tracks = baseTracks.applying(selectionOverride: selectionOverride ?? nil)
        guard let encoded = ServerCommandOutput.jsonData(tracks) else { return .serviceUnavailable() }
        return .ok(body: encoded, omitBody: omitBody)
    }

    private func exactItemID(from target: String, prefix: String) -> String? {
        guard !target.contains("?") else { return nil }
        return decodedItemID(String(target.dropFirst(prefix.count)))
    }

    private func keyframeRequest(from target: String) -> (itemID: String, seconds: Double)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let itemID = decodedItemID(String(pieces[0].dropFirst("/api/v1/playback/keyframe/".count))),
              let values = queryValues(String(pieces[1])),
              let rawSeconds = values["at"],
              let seconds = boundedSeconds(rawSeconds)
        else { return nil }
        return (itemID, seconds)
    }

    private func queryValues(_ query: String) -> [String: String]? {
        guard !query.isEmpty else { return nil }
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  key == "at", values[key] == nil
            else { return nil }
            values[key] = value
        }
        return values
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

    /// Up to five integer digits and three fractional digits, bounded below one day.
    private func boundedSeconds(_ raw: String) -> Double? {
        guard !raw.isEmpty, raw.utf8.count <= 9 else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let whole = parts.first, !whole.isEmpty, whole.count <= 5,
              whole.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.count <= 3,
                  fraction.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
        }
        guard let value = Double(raw), value.isFinite, value >= 0, value < 86_400 else { return nil }
        return value
    }
}
