import Foundation
import MediaLibCore

/// Authenticated user and device preference routes extracted from the main HTTP router.
///
/// Authentication and the independent read/mutation buckets stay in the outer router. This
/// handler owns route recognition, strict query/body contracts, optimistic concurrency and the
/// repository mapping so account settings cannot accidentally inherit management semantics.
struct ServerUserExperienceHandler {
    private let repository: ServerExperienceRepository?

    init(repository: ServerExperienceRepository?) {
        self.repository = repository
    }

    func response(
        method: String,
        path: String,
        target: String,
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        readRateLimitResponse: () -> LocalHTTPResponse?,
        mutationRateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        if path == "/api/v1/me/preferences" {
            switch method {
            case "GET", "HEAD":
                if let limited = readRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                return preferencesResponse(principal: principal, omitBody: omitBody)
            case "PATCH":
                if let limited = mutationRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                return savePreferencesResponse(
                    requestHead: requestHead,
                    body: body,
                    principal: principal
                )
            default:
                return .methodNotAllowed()
            }
        }

        if path == "/api/v1/me/preferences/device" {
            switch method {
            case "GET", "HEAD":
                if let limited = readRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                return devicePreferencesResponse(principal: principal, omitBody: omitBody)
            case "PATCH":
                if let limited = mutationRateLimitResponse() { return limited }
                guard target == path else { return .badRequest() }
                return saveDevicePreferencesResponse(
                    requestHead: requestHead,
                    body: body,
                    principal: principal
                )
            case "DELETE":
                if let limited = mutationRateLimitResponse() { return limited }
                guard target == path, body.isEmpty else { return .badRequest() }
                return deleteDevicePreferencesResponse(
                    requestHead: requestHead,
                    principal: principal
                )
            default:
                return .methodNotAllowed()
            }
        }

        guard let route = playbackOverrideRoute(path) else { return nil }
        if method == "GET" || method == "HEAD" { return nil }
        guard method == "PUT" || method == "DELETE" else { return .methodNotAllowed() }
        if let limited = mutationRateLimitResponse() { return limited }
        guard target == path else { return .badRequest() }
        return playbackOverrideResponse(
            method: method,
            route: route,
            body: body,
            principal: principal
        )
    }

    private func preferencesResponse(
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let repository else { return .serviceUnavailable() }
        do {
            let account = try repository.userPreferences(userID: principal.userID)
            let device = try repository.devicePreferences(
                userID: principal.userID,
                deviceID: principal.deviceID
            )
            let response = ServerPreferencesResponse(
                account: account,
                device: device,
                effective: effectivePreferences(account.value, device: device?.value)
            )
            guard let encoded = ServerCommandOutput.jsonData(response) else {
                return .serviceUnavailable()
            }
            return .json(
                body: encoded,
                omitBody: omitBody,
                additionalHeaders: [etagHeader(account.version), "Cache-Control: no-store"]
            )
        } catch { return .serviceUnavailable() }
    }

    private func devicePreferencesResponse(
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let repository else { return .serviceUnavailable() }
        do {
            guard let device = try repository.devicePreferences(
                userID: principal.userID,
                deviceID: principal.deviceID
            ) else { return .notFound() }
            guard let encoded = ServerCommandOutput.jsonData(device) else {
                return .serviceUnavailable()
            }
            return .json(
                body: encoded,
                omitBody: omitBody,
                additionalHeaders: [etagHeader(device.version), "Cache-Control: no-store"]
            )
        } catch { return .serviceUnavailable() }
    }

    private func savePreferencesResponse(
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let expectedVersion = ifMatchVersion(in: requestHead) else {
            return .preconditionRequired()
        }
        guard let value: ServerUserExperiencePreferences = ServerStrictJSONDecoder.decode(
            ServerUserExperiencePreferences.self,
            from: body,
            allowedKeys: [
                "schemaVersion", "interfaceLanguage", "appearance", "defaultLandingPath",
                "homeSectionOrder", "hiddenHomeSections", "contentDensity", "motion",
                "autoplayNext", "resumePlayback", "defaultQuality", "remoteBitrateMbps",
                "preferredAudioLanguage", "preferredSubtitleLanguage", "subtitleMode",
                "subtitleSDHPreference", "rememberTrackSelections", "subtitleStyle"
            ],
            nestedAllowedKeys: ["subtitleStyle": [
                "fontFamily", "fontScalePercent", "fontWeight", "textColor",
                "backgroundOpacityPercent", "edgeStyle", "verticalPositionPercent"
            ]]
        ), value.isValid, let repository else { return .badRequest() }
        do {
            let saved = try repository.saveUserPreferences(
                userID: principal.userID,
                value: value,
                expectedVersion: expectedVersion
            )
            guard let encoded = ServerCommandOutput.jsonData(saved) else {
                return .serviceUnavailable()
            }
            return .json(
                body: encoded,
                additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"]
            )
        } catch { return mutationErrorResponse(error) }
    }

    private func saveDevicePreferencesResponse(
        requestHead: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let expectedVersion = ifMatchVersion(in: requestHead) else {
            return .preconditionRequired()
        }
        guard let value: ServerDeviceExperienceOverrides = ServerStrictJSONDecoder.decode(
            ServerDeviceExperienceOverrides.self,
            from: body,
            allowedKeys: [
                "schemaVersion", "appearance", "contentDensity", "motion",
                "defaultQuality", "remoteBitrateMbps"
            ]
        ), value.isValid, let repository else { return .badRequest() }
        do {
            let saved = try repository.saveDevicePreferences(
                userID: principal.userID,
                deviceID: principal.deviceID,
                value: value,
                expectedVersion: expectedVersion
            )
            guard let encoded = ServerCommandOutput.jsonData(saved) else {
                return .serviceUnavailable()
            }
            return .json(
                body: encoded,
                additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"]
            )
        } catch { return mutationErrorResponse(error) }
    }

    private func deleteDevicePreferencesResponse(
        requestHead: String,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let expectedVersion = ifMatchVersion(in: requestHead) else {
            return .preconditionRequired()
        }
        guard let repository else { return .serviceUnavailable() }
        do {
            try repository.deleteDevicePreferences(
                userID: principal.userID,
                deviceID: principal.deviceID,
                expectedVersion: expectedVersion
            )
            return .noContent()
        } catch { return mutationErrorResponse(error) }
    }

    private func playbackOverrideResponse(
        method: String,
        route: (scope: ServerTrackOverrideScope, id: String),
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let repository else { return .serviceUnavailable() }
        if method == "DELETE" {
            guard body.isEmpty else { return .badRequest() }
            do {
                try repository.deleteTrackOverride(
                    userID: principal.userID,
                    scope: route.scope,
                    scopeID: route.id
                )
                return .noContent()
            } catch { return .serviceUnavailable() }
        }
        guard let request: ServerTrackOverrideMutation = ServerStrictJSONDecoder.decode(
            ServerTrackOverrideMutation.self,
            from: body,
            allowedKeys: ["audioFingerprint", "subtitleFingerprint", "subtitleDisabled"]
        ) else { return .badRequest() }
        let value = ServerTrackSelectionOverride(
            scope: route.scope,
            scopeID: route.id,
            audioFingerprint: request.audioFingerprint,
            subtitleFingerprint: request.subtitleFingerprint,
            subtitleDisabled: request.subtitleDisabled
        )
        guard value.isValid else { return .badRequest() }
        do {
            let saved = try repository.saveTrackOverride(userID: principal.userID, value: value)
            guard let encoded = ServerCommandOutput.jsonData(saved) else {
                return .serviceUnavailable()
            }
            return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
        } catch { return .serviceUnavailable() }
    }

    private func playbackOverrideRoute(
        _ path: String
    ) -> (scope: ServerTrackOverrideScope, id: String)? {
        let prefix = "/api/v1/me/playback-overrides/"
        guard path.hasPrefix(prefix) else { return nil }
        let pieces = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let scope = ServerTrackOverrideScope(rawValue: String(pieces[0])),
              let decoded = String(pieces[1]).removingPercentEncoding,
              !decoded.isEmpty,
              !decoded.contains("/"),
              !decoded.contains("\\"),
              decoded.utf8.count <= 512,
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return (scope, decoded)
    }

    private func ifMatchVersion(in requestHead: String) -> Int? {
        guard let raw = httpHeader(named: "If-Match", in: requestHead),
              !raw.contains(","),
              !raw.hasPrefix("W/")
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let version = Int(value),
              version >= 0
        else { return nil }
        return version
    }

    private func etagHeader(_ version: Int) -> String {
        "ETag: \"\(max(version, 0))\""
    }

    private func mutationErrorResponse(_ error: Error) -> LocalHTTPResponse {
        switch error {
        case ServerExperienceRepositoryError.invalidValue:
            return .badRequest()
        case let ServerExperienceRepositoryError.versionConflict(currentVersion):
            return .conflict(additionalHeaders: [etagHeader(currentVersion)])
        case ServerExperienceRepositoryError.notFound:
            return .notFound()
        default:
            return .serviceUnavailable()
        }
    }

    private func effectivePreferences(
        _ account: ServerUserExperiencePreferences,
        device: ServerDeviceExperienceOverrides?
    ) -> ServerUserExperiencePreferences {
        guard let device else { return account }
        var effective = account
        if let value = device.appearance { effective.appearance = value }
        if let value = device.contentDensity { effective.contentDensity = value }
        if let value = device.motion { effective.motion = value }
        if let value = device.defaultQuality { effective.defaultQuality = value }
        if let value = device.remoteBitrateMbps { effective.remoteBitrateMbps = value }
        return effective
    }
}

private struct ServerPreferencesResponse: Encodable {
    let account: ServerVersionedDocument<ServerUserExperiencePreferences>
    let device: ServerVersionedDocument<ServerDeviceExperienceOverrides>?
    let effective: ServerUserExperiencePreferences
}

private struct ServerTrackOverrideMutation: Decodable {
    let audioFingerprint: String?
    let subtitleFingerprint: String?
    let subtitleDisabled: Bool

    private enum CodingKeys: String, CodingKey {
        case audioFingerprint, subtitleFingerprint, subtitleDisabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioFingerprint = try values.decodeIfPresent(String.self, forKey: .audioFingerprint)
        subtitleFingerprint = try values.decodeIfPresent(String.self, forKey: .subtitleFingerprint)
        subtitleDisabled = try values.decodeIfPresent(Bool.self, forKey: .subtitleDisabled) ?? false
    }
}
