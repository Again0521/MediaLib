import CoreFoundation
import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authenticated queue, playback progress and per-media preference routes.
///
/// Authentication, CSRF validation and independent read/mutation throttles remain in the outer
/// router. Keeping the three related state APIs here gives them one strict route/query contract
/// and makes malformed requests fail before any repository-backed provider is invoked.
struct ServerUserMediaStateHandler {
    private let queueProvider: (ServerRequestPrincipal) throws -> ServerQueueResponse
    private let queueMutationProvider: (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse?
    private let playbackStateUpdater: (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState?
    private let mediaPreferenceUpdater: (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference?

    init(
        queueProvider: @escaping (ServerRequestPrincipal) throws -> ServerQueueResponse,
        queueMutationProvider: @escaping (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse?,
        playbackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState?,
        mediaPreferenceUpdater: @escaping (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference?
    ) {
        self.queueProvider = queueProvider
        self.queueMutationProvider = queueMutationProvider
        self.playbackStateUpdater = playbackStateUpdater
        self.mediaPreferenceUpdater = mediaPreferenceUpdater
    }

    func response(
        method: String,
        path: String,
        target: String,
        body: Data,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        readRateLimitResponse: () -> LocalHTTPResponse?,
        mutationRateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        if path == "/api/v1/queue" {
            switch method {
            case "GET", "HEAD":
                if let limited = readRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
                return queueResponse(principal: principal, omitBody: omitBody)
            case "POST":
                if let limited = mutationRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                return mutateQueueResponse(body: body, principal: principal)
            default:
                return .methodNotAllowed()
            }
        }

        if path.hasPrefix("/api/v1/playback/state/") {
            guard method == "POST" else {
                return method == "GET" || method == "HEAD" ? nil : .methodNotAllowed()
            }
            if let limited = mutationRateLimitResponse() { return limited }
            guard target == path else { return .badRequest() }
            return updatePlaybackStateResponse(path: path, body: body, principal: principal)
        }

        if path.hasPrefix("/api/v1/user-media/preferences/") {
            guard method == "POST" else {
                return method == "GET" || method == "HEAD" ? nil : .methodNotAllowed()
            }
            if let limited = mutationRateLimitResponse() { return limited }
            guard target == path else { return .badRequest() }
            return updateMediaPreferenceResponse(path: path, body: body, principal: principal)
        }
        return nil
    }

    private func queueResponse(
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let encoded = ServerCommandOutput.jsonData(try queueProvider(principal)) else {
                return .serviceUnavailable()
            }
            return .json(body: encoded, omitBody: omitBody)
        } catch { return .serviceUnavailable() }
    }

    private func mutateQueueResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let request: ServerQueueMutationRequest = ServerStrictJSONDecoder.decode(
            ServerQueueMutationRequest.self,
            from: body,
            allowedKeys: [
                "action", "mediaID", "fromIndex", "toIndex", "repeatMode",
                "shuffleEnabled", "currentPosition"
            ]
        ), request.isValid,
        ["add", "remove", "clear", "move", "settings"].contains(request.action)
        else { return .badRequest() }
        do {
            guard let queue = try queueMutationProvider(request, principal),
                  let encoded = ServerCommandOutput.jsonData(queue)
            else { return .notFound() }
            return .json(body: encoded)
        } catch is ServerUserQueueRepositoryError {
            return .badRequest()
        } catch {
            return .serviceUnavailable()
        }
    }

    private func updatePlaybackStateResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let itemID = decodedIdentifier(path: path, prefix: "/api/v1/playback/state/"),
              let request: ServerPlaybackStateUpdateRequest = ServerStrictJSONDecoder.decode(
                ServerPlaybackStateUpdateRequest.self,
                from: body,
                allowedKeys: ["event", "positionSeconds", "durationSeconds"]
              ), request.isValid
        else { return .badRequest() }
        do {
            guard let state = try playbackStateUpdater(itemID, request, principal) else {
                return .notFound()
            }
            guard let encoded = ServerCommandOutput.jsonData(state) else {
                return .serviceUnavailable()
            }
            return .json(body: encoded)
        } catch { return .serviceUnavailable() }
    }

    /// A preference request changes exactly one field. Rating zero clears a rating; 1...5 stores it.
    private func updateMediaPreferenceResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let itemID = decodedIdentifier(
            path: path,
            prefix: "/api/v1/user-media/preferences/"
        ), let object = try? JSONSerialization.jsonObject(with: body),
        let dictionary = object as? [String: Any], dictionary.count == 1
        else { return .badRequest() }

        let preference: ServerUserMediaPreferenceUpdate
        if let value = dictionary["favorite"] as? Bool,
           Set(dictionary.keys) == Set(["favorite"]) {
            preference = .favorite(value)
        } else if let value = dictionary["watchlist"] as? Bool,
                  Set(dictionary.keys) == Set(["watchlist"]) {
            preference = .watchlist(value)
        } else if let value = dictionary["rating"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  (0...5).contains(value.doubleValue),
                  Set(dictionary.keys) == Set(["rating"]) {
            preference = .rating(value.doubleValue == 0 ? nil : value.doubleValue)
        } else {
            return .badRequest()
        }

        do {
            guard let updated = try mediaPreferenceUpdater(itemID, preference, principal),
                  let encoded = ServerCommandOutput.jsonData(updated)
            else { return .notFound() }
            return .json(body: encoded)
        } catch {
            // Unknown, unauthorized and repository-failure cases stay indistinguishable.
            return .notFound()
        }
    }

    private func decodedIdentifier(path: String, prefix: String) -> String? {
        let encodedID = String(path.dropFirst(prefix.count))
        guard !encodedID.isEmpty,
              let identifier = encodedID.removingPercentEncoding,
              !identifier.isEmpty,
              !identifier.contains("/"),
              !identifier.contains("\\"),
              !identifier.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              identifier.utf8.count <= 512
        else { return nil }
        return identifier
    }
}
