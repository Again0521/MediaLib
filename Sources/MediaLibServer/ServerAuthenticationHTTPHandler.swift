import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authentication HTTP routes, kept separate from authenticated media and administration pages.
///
/// The outer router still owns request security and rate-limit storage. This handler owns the
/// credential-specific parsing and response contract so login, refresh and session mutation cannot
/// silently diverge as the main router is split into route groups.
struct ServerAuthenticationHTTPHandler {
    private let authenticationService: ServerAuthenticationService?
    private let currentUserProfileProvider: (ServerRequestPrincipal) throws -> ServerCurrentUserProfile?
    private let csrfToken: String

    init(
        authenticationService: ServerAuthenticationService?,
        currentUserProfileProvider: @escaping (ServerRequestPrincipal) throws -> ServerCurrentUserProfile?,
        csrfToken: String
    ) {
        self.authenticationService = authenticationService
        self.currentUserProfileProvider = currentUserProfileProvider
        self.csrfToken = csrfToken
    }

    func publicResponse(
        method: String,
        path: String,
        target: String,
        requestHead: String,
        body: Data,
        clientAddressKey: String,
        rateLimitResponse: (ServerRateLimitScope, [String]) -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        guard method == "POST" else { return nil }
        switch path {
        case "/api/v1/auth/login":
            guard target == path else { return .badRequest() }
            return loginResponse(
                body: body,
                clientAddressKey: clientAddressKey,
                rateLimitResponse: rateLimitResponse
            )
        case "/login":
            guard target == path || loginReturnState(from: target) != nil else {
                return .badRequest()
            }
            return webFormLoginResponse(
                requestHead: requestHead,
                target: target,
                body: body,
                clientAddressKey: clientAddressKey,
                rateLimitResponse: rateLimitResponse
            )
        case "/api/v1/auth/refresh":
            guard target == path else { return .badRequest() }
            return refreshResponse(
                requestHead: requestHead,
                body: body,
                clientAddressKey: clientAddressKey,
                rateLimitResponse: rateLimitResponse
            )
        default:
            return nil
        }
    }

    func authenticatedResponse(
        method: String,
        path: String,
        target: String,
        body: Data,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        readRateLimitResponse: () -> LocalHTTPResponse?,
        mutationRateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        switch path {
        case "/api/v1/auth/me":
            guard method == "GET" || method == "HEAD" else { return .methodNotAllowed() }
            guard target == path else { return .badRequest() }
            if let limited = readRateLimitResponse() { return limited }
            return currentUserResponse(principal: principal, omitBody: omitBody)
        case "/api/v1/auth/password":
            guard method == "POST" else { return .methodNotAllowed() }
            guard target == path else { return .badRequest() }
            if let limited = mutationRateLimitResponse() { return limited }
            return passwordChangeResponse(body: body, principal: principal)
        case "/api/v1/auth/logout":
            guard method == "POST" else { return .methodNotAllowed() }
            guard target == path, body.isEmpty else { return .badRequest() }
            if let limited = mutationRateLimitResponse() { return limited }
            return logoutResponse(principal: principal)
        default:
            return nil
        }
    }

    /// The server derives the return target and transports it as URL-safe Base64. Encoded slash
    /// sequences are intentionally unavailable at the public HTTP request-policy layer.
    func loginLocation(for target: String) -> String {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), target.utf8.count <= 2_048 else {
            return "/login"
        }
        let state = Data(target.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "/login?next=\(state)"
    }

    func loginReturnState(from target: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)"),
              let values = components.queryItems?.filter({ $0.name == "next" }),
              values.count == 1,
              components.queryItems?.count == 1,
              let value = values[0].value,
              value.utf8.count <= 2_732,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private func loginResponse(
        body: Data,
        clientAddressKey: String,
        rateLimitResponse: (ServerRateLimitScope, [String]) -> LocalHTTPResponse?
    ) -> LocalHTTPResponse {
        if let limited = rateLimitResponse(.loginClient, [clientAddressKey]) { return limited }
        guard let request: ServerLoginRequest = ServerStrictJSONDecoder.decode(
            ServerLoginRequest.self,
            from: body,
            allowedKeys: ["username", "password", "deviceName", "platform", "delivery"]
        ), request.isValid else {
            return authenticationService == nil ? .serviceUnavailable() : .badRequest()
        }
        if let limited = rateLimitResponse(.loginIdentity, [
            "username",
            ServerIdentityRepository.normalizeUsername(
                request.username.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ]) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        return performLogin(request, using: authenticationService)
    }

    /// Constrained HTML form fallback. Credentials never enter the URL and the return path is
    /// decoded only after a successful login.
    private func webFormLoginResponse(
        requestHead: String,
        target: String,
        body: Data,
        clientAddressKey: String,
        rateLimitResponse: (ServerRateLimitScope, [String]) -> LocalHTTPResponse?
    ) -> LocalHTTPResponse {
        guard httpHeader(named: "Content-Type", in: requestHead)?.lowercased() == "application/x-www-form-urlencoded",
              let form = String(data: body, encoding: .utf8),
              let components = URLComponents(
                string: "http://localhost/?\(form.replacingOccurrences(of: "+", with: "%20"))"
              ),
              let items = components.queryItems,
              Set(items.map(\.name)) == Set(["username", "password", "csrf"]),
              items.count == 3,
              let username = items.first(where: { $0.name == "username" })?.value,
              let password = items.first(where: { $0.name == "password" })?.value,
              let submittedCSRF = items.first(where: { $0.name == "csrf" })?.value,
              submittedCSRF == csrfToken
        else { return .badRequest() }
        if let limited = rateLimitResponse(.loginClient, [clientAddressKey]) { return limited }
        let request = ServerLoginRequest(
            username: username,
            password: password,
            deviceName: "Web Browser",
            platform: "Web",
            delivery: "cookie"
        )
        guard request.isValid else { return .badRequest() }
        if let limited = rateLimitResponse(.loginIdentity, [
            "username",
            ServerIdentityRepository.normalizeUsername(
                request.username.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ]) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        do {
            switch try authenticationService.login(
                username: request.username,
                password: request.password,
                deviceName: request.deviceName,
                platform: request.platform
            ) {
            case let .success(tokens):
                return .seeOther(
                    location: loginReturnPath(from: target) ?? "/",
                    omitBody: false,
                    additionalHeaders: Self.authenticationCookieHeaders(tokens: tokens)
                )
            case .rejected:
                return .unauthorized()
            case let .temporarilyLocked(until):
                return .tooManyRequests(
                    retryAfter: max(Int(until.timeIntervalSinceNow.rounded(.up)), 1)
                )
            case .initialSetupRequired:
                return .preconditionRequired()
            }
        } catch {
            return .serviceUnavailable()
        }
    }

    private func refreshResponse(
        requestHead: String,
        body: Data,
        clientAddressKey: String,
        rateLimitResponse: (ServerRateLimitScope, [String]) -> LocalHTTPResponse?
    ) -> LocalHTTPResponse {
        if let limited = rateLimitResponse(.refreshClient, [clientAddressKey]) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        let cookieToken = authenticationService.refreshToken(forRequestHead: requestHead)
        let request: ServerRefreshRequest
        if body.isEmpty {
            request = ServerRefreshRequest(refreshToken: nil, delivery: nil)
        } else if let decoded: ServerRefreshRequest = ServerStrictJSONDecoder.decode(
            ServerRefreshRequest.self,
            from: body,
            allowedKeys: ["refreshToken", "delivery"]
        ) {
            request = decoded
        } else {
            return .badRequest()
        }
        guard request.isValid,
              !(cookieToken != nil && request.refreshToken != nil),
              let token = request.refreshToken ?? cookieToken
        else { return .badRequest() }
        if let limited = rateLimitResponse(.refreshCredential, ["refresh", token]) { return limited }
        do {
            guard let tokens = try authenticationService.refresh(refreshToken: token) else {
                return .unauthorized(clearingCookies: cookieToken != nil)
            }
            let delivery: ServerAuthenticationDelivery = cookieToken != nil ? .cookie : request.deliveryMode
            return authenticationResponse(tokens: tokens, delivery: delivery)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func currentUserResponse(
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let profile = try currentUserProfileProvider(principal),
                  let data = ServerCommandOutput.jsonData(profile)
            else { return .unauthorized() }
            return .ok(body: data, omitBody: omitBody)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func logoutResponse(principal: ServerRequestPrincipal) -> LocalHTTPResponse {
        guard let authenticationService else { return .serviceUnavailable() }
        do {
            try authenticationService.logout(principal: principal)
            return .noContent(clearingAuthenticationCookies: true)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func passwordChangeResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let request: ServerPasswordChangeRequest = ServerStrictJSONDecoder.decode(
            ServerPasswordChangeRequest.self,
            from: body,
            allowedKeys: ["currentPassword", "newPassword"]
        ), request.isValid, let authenticationService else { return .badRequest() }
        do {
            try authenticationService.changePassword(
                for: principal,
                currentPassword: request.currentPassword,
                newPassword: request.newPassword
            )
            return .noContent(clearingAuthenticationCookies: true)
        } catch {
            // Keep password, account and concurrent-update failures indistinguishable.
            return .badRequest()
        }
    }

    private func performLogin(
        _ request: ServerLoginRequest,
        using authenticationService: ServerAuthenticationService
    ) -> LocalHTTPResponse {
        do {
            switch try authenticationService.login(
                username: request.username,
                password: request.password,
                deviceName: request.deviceName,
                platform: request.platform
            ) {
            case let .success(tokens):
                return authenticationResponse(tokens: tokens, delivery: request.deliveryMode)
            case .rejected:
                return .unauthorized()
            case let .temporarilyLocked(until):
                return .tooManyRequests(
                    retryAfter: max(Int(until.timeIntervalSinceNow.rounded(.up)), 1)
                )
            case .initialSetupRequired:
                return .preconditionRequired()
            }
        } catch {
            return .serviceUnavailable()
        }
    }

    private func loginReturnPath(from target: String) -> String? {
        guard let state = loginReturnState(from: target) else { return nil }
        let padding = String(repeating: "=", count: (4 - state.count % 4) % 4)
        let base64 = state.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64),
              let value = String(data: data, encoding: .utf8),
              value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains("\\"),
              value.utf8.count <= 2_048
        else { return nil }
        return value
    }

    private func authenticationResponse(
        tokens: ServerIssuedTokens,
        delivery: ServerAuthenticationDelivery
    ) -> LocalHTTPResponse {
        switch delivery {
        case .token:
            guard let body = ServerCommandOutput.jsonData(tokens) else { return .serviceUnavailable() }
            return .ok(body: body, omitBody: false)
        case .cookie:
            let session = ServerBrowserSession(
                accessExpiresAt: tokens.accessExpiresAt,
                refreshExpiresAt: tokens.refreshExpiresAt,
                sessionID: tokens.sessionID,
                deviceID: tokens.deviceID
            )
            guard let body = ServerCommandOutput.jsonData(session) else { return .serviceUnavailable() }
            return .json(body: body, additionalHeaders: Self.authenticationCookieHeaders(tokens: tokens))
        }
    }

    private static func authenticationCookieHeaders(tokens: ServerIssuedTokens) -> [String] {
        let accessAge = max(Int(tokens.accessExpiresAt.timeIntervalSinceNow), 1)
        let refreshAge = max(Int(tokens.refreshExpiresAt.timeIntervalSinceNow), 1)
        return [
            "Set-Cookie: \(ServerAuthenticationService.accessCookieName)=\(tokens.accessToken); Path=/; Max-Age=\(accessAge); HttpOnly; Secure; SameSite=Strict",
            "Set-Cookie: \(ServerAuthenticationService.refreshCookieName)=\(tokens.refreshToken); Path=/api/v1/auth; Max-Age=\(refreshAge); HttpOnly; Secure; SameSite=Strict"
        ]
    }
}

private enum ServerAuthenticationDelivery: String, Decodable {
    case token
    case cookie
}

private struct ServerLoginRequest: Decodable {
    let username: String
    let password: String
    let deviceName: String
    let platform: String
    let delivery: String?

    var deliveryMode: ServerAuthenticationDelivery {
        ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") ?? .token
    }

    var isValid: Bool {
        !username.isEmpty && username.utf8.count <= 128 &&
            !password.isEmpty && password.utf8.count <= 1_024 &&
            !deviceName.isEmpty && deviceName.utf8.count <= 128 &&
            !platform.isEmpty && platform.utf8.count <= 128 &&
            (delivery == nil || ServerAuthenticationDelivery(
                rawValue: delivery?.lowercased() ?? ""
            ) != nil)
    }
}

private struct ServerRefreshRequest: Decodable {
    let refreshToken: String?
    let delivery: String?

    var deliveryMode: ServerAuthenticationDelivery {
        ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") ?? .token
    }

    var isValid: Bool {
        (refreshToken == nil || (32...1_024).contains(refreshToken?.utf8.count ?? 0)) &&
            (delivery == nil || ServerAuthenticationDelivery(
                rawValue: delivery?.lowercased() ?? ""
            ) != nil)
    }
}

private struct ServerPasswordChangeRequest: Decodable {
    let currentPassword: String
    let newPassword: String

    var isValid: Bool {
        (1...1_024).contains(currentPassword.utf8.count) &&
            (12...1_024).contains(newPassword.utf8.count)
    }
}

private struct ServerBrowserSession: Encodable {
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let sessionID: String
    let deviceID: String
}
