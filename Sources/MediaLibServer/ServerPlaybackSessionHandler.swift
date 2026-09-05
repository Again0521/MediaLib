import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// One policy evaluator shared by direct media responses and authenticated HLS session control.
/// A repository failure fails closed; a missing repository preserves the pre-v30 default policy.
struct ServerPlaybackAccessEvaluator {
    enum Capability {
        case directPlay
        case download
        case transcode
        case adaptiveStreaming
    }

    private let experienceRepository: ServerExperienceRepository?
    private let mediaDetailProvider: (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?

    init(
        experienceRepository: ServerExperienceRepository?,
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?
    ) {
        self.experienceRepository = experienceRepository
        self.mediaDetailProvider = mediaDetailProvider
    }

    func allows(
        itemID: String,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        capability: Capability
    ) -> Bool {
        guard let policy = policy(for: principal),
              policy.isValid,
              policy.playbackAllowed,
              allowsRemoteAccess(policy, clientAddressKey: clientAddressKey),
              allowsCurrentTime(policy),
              allowsContent(policy, itemID: itemID, principal: principal)
        else { return false }

        switch capability {
        case .directPlay:
            return policy.directPlayAllowed
        case .download:
            return policy.downloadAllowed
        case .transcode:
            return policy.transcodeAllowed
        case .adaptiveStreaming:
            return policy.remuxAllowed || policy.transcodeAllowed
        }
    }

    private func policy(for principal: ServerRequestPrincipal) -> ServerUserPolicy? {
        guard let experienceRepository else { return ServerUserPolicy() }
        return try? experienceRepository.userPolicy(userID: principal.userID).value
    }

    private func allowsRemoteAccess(
        _ policy: ServerUserPolicy,
        clientAddressKey: String
    ) -> Bool {
        !isRemoteClientAddressKey(clientAddressKey) || policy.remoteAccessAllowed
    }

    private func allowsCurrentTime(_ policy: ServerUserPolicy) -> Bool {
        guard let start = policy.accessStartMinute, let end = policy.accessEndMinute else {
            return true
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let hour = components.hour, let minute = components.minute else { return false }
        let current = hour * 60 + minute
        return start <= end ? (start...end).contains(current) : (current >= start || current <= end)
    }

    private func allowsContent(
        _ policy: ServerUserPolicy,
        itemID: String,
        principal: ServerRequestPrincipal
    ) -> Bool {
        guard policy.maximumContentRating != nil else { return true }
        guard let detail = try? mediaDetailProvider(itemID, principal) else { return false }
        return ServerContentRatingPolicy.allows(
            contentRating: detail.detailExtras?.contentRating,
            maximum: policy.maximumContentRating
        )
    }

    private func isRemoteClientAddressKey(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return !(normalized == "localhost" || normalized == "::1" || normalized == "[::1]" ||
            normalized.hasPrefix("127.") || normalized.hasPrefix("loopback"))
    }
}

/// Authenticated HLS session creation, status and cancellation routes.
///
/// The outer router owns authentication and the dedicated `playbackControl` bucket. This handler
/// keeps session-control parsing separate from HLS resource bytes, which remain on `mediaStream`.
struct ServerPlaybackSessionHandler {
    private let sessionProvider: (String, ServerHLSPlaybackRequest, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?
    private let statusProvider: (String, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?
    private let cancellationProvider: (String, ServerRequestPrincipal) -> Void
    private let accessEvaluator: ServerPlaybackAccessEvaluator

    init(
        sessionProvider: @escaping (String, ServerHLSPlaybackRequest, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?,
        statusProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?,
        cancellationProvider: @escaping (String, ServerRequestPrincipal) -> Void,
        accessEvaluator: ServerPlaybackAccessEvaluator
    ) {
        self.sessionProvider = sessionProvider
        self.statusProvider = statusProvider
        self.cancellationProvider = cancellationProvider
        self.accessEvaluator = accessEvaluator
    }

    func response(
        method: String,
        path: String,
        target: String,
        body: Data,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        omitBody: Bool,
        rateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        if path == "/api/v1/playback/sessions" {
            if method == "GET" || method == "HEAD" { return nil }
            guard method == "POST" else { return .methodNotAllowed() }
            if let limited = rateLimitResponse() { return limited }
            guard target == path else { return .badRequest() }
            return createNegotiatedSessionResponse(
                body: body,
                principal: principal,
                clientAddressKey: clientAddressKey
            )
        }

        let prefix = "/api/v1/playback/sessions/"
        guard path.hasPrefix(prefix) else { return nil }
        switch method {
        case "GET", "HEAD":
            if let limited = rateLimitResponse() { return limited }
            guard target == path else { return .badRequest() }
            return statusResponse(path: path, principal: principal, omitBody: omitBody)
        case "DELETE":
            if let limited = rateLimitResponse() { return limited }
            guard target == path, body.isEmpty else { return .badRequest() }
            return cancelResponse(path: path, suffix: "", principal: principal)
        case "POST":
            if let limited = rateLimitResponse() { return limited }
            guard target == path else { return .badRequest() }
            if path.hasSuffix("/cancel") {
                guard body.isEmpty else { return .badRequest() }
                return cancelResponse(path: path, suffix: "/cancel", principal: principal)
            }
            return createLegacySessionResponse(
                path: path,
                body: body,
                principal: principal,
                clientAddressKey: clientAddressKey
            )
        default:
            return .methodNotAllowed()
        }
    }

    private func createNegotiatedSessionResponse(
        body: Data,
        principal: ServerRequestPrincipal,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        guard let creation: ServerHLSPlaybackSessionCreationRequest = ServerStrictJSONDecoder.decode(
            ServerHLSPlaybackSessionCreationRequest.self,
            from: body,
            allowedKeys: [
                "itemID", "audioTrackID", "subtitleTrackID", "startSeconds", "durationSeconds",
                "capabilities", "quality", "maximumBitrateMbps"
            ],
            nestedAllowedKeys: ["capabilities": [
                "nativeHLS", "mediaSource", "videoCodecs", "audioCodecs",
                "screenWidth", "screenHeight", "hdrDisplay", "measuredDownlinkMbps"
            ]]
        ), creation.isValid else { return .badRequest() }
        return createSessionResponse(
            itemID: creation.itemID,
            request: creation.playbackRequest,
            principal: principal,
            clientAddressKey: clientAddressKey
        )
    }

    private func createLegacySessionResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        guard let itemID = decodedIdentifier(path: path, prefix: "/api/v1/playback/sessions/"),
              let request: ServerHLSPlaybackRequest = ServerStrictJSONDecoder.decode(
                ServerHLSPlaybackRequest.self,
                from: body,
                allowedKeys: [
                    "audioTrackID", "subtitleTrackID", "startSeconds", "durationSeconds",
                    "capabilities", "quality", "maximumBitrateMbps"
                ],
                nestedAllowedKeys: ["capabilities": [
                    "nativeHLS", "mediaSource", "videoCodecs", "audioCodecs",
                    "screenWidth", "screenHeight", "hdrDisplay", "measuredDownlinkMbps"
                ]]
              ), request.isValid
        else { return .badRequest() }
        return createSessionResponse(
            itemID: itemID,
            request: request,
            principal: principal,
            clientAddressKey: clientAddressKey
        )
    }

    private func createSessionResponse(
        itemID: String,
        request: ServerHLSPlaybackRequest,
        principal: ServerRequestPrincipal,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        guard accessEvaluator.allows(
            itemID: itemID,
            principal: principal,
            clientAddressKey: clientAddressKey,
            capability: .adaptiveStreaming
        ) else { return .forbidden() }
        guard let descriptor = try? sessionProvider(itemID, request, principal),
              let encoded = ServerCommandOutput.jsonData(descriptor)
        else { return .serviceUnavailable() }
        return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
    }

    private func statusResponse(
        path: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let sessionID = rawSessionIdentifier(path: path, suffix: ""),
              let descriptor = try? statusProvider(sessionID, principal),
              let encoded = ServerCommandOutput.jsonData(descriptor)
        else { return .notFound() }
        return .json(
            body: encoded,
            omitBody: omitBody,
            additionalHeaders: ["Cache-Control: no-store"]
        )
    }

    private func cancelResponse(
        path: String,
        suffix: String,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let sessionID = rawSessionIdentifier(path: path, suffix: suffix) else {
            return .notFound()
        }
        cancellationProvider(sessionID, principal)
        return .noContent()
    }

    private func rawSessionIdentifier(path: String, suffix: String) -> String? {
        let prefix = "/api/v1/playback/sessions/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let value = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value
    }

    private func decodedIdentifier(path: String, prefix: String) -> String? {
        let encoded = String(path.dropFirst(prefix.count))
        guard !encoded.isEmpty,
              let value = encoded.removingPercentEncoding,
              !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return value
    }
}
