import Foundation
import Darwin
import MediaLibCore

private extension Array where Element == String {
    var only: String? { count == 1 ? first : nil }
}

/// Methods accepted by both HTTP transports before route-specific validation.
/// Keep this list transport-level: individual handlers still decide which
/// method is valid for a concrete path.
enum ServerHTTPMethodContract {
    static let orderedRawValues = ["GET", "HEAD", "POST", "PATCH", "PUT", "DELETE"]
    static let allowedRawValues = Set(orderedRawValues)
    static let mutatingRawValues: Set<String> = ["POST", "PATCH", "PUT", "DELETE"]
}

/// Shared HTTP syntax, proxy provenance and same-origin boundary for both listeners.
struct HTTPRequestSecurityPolicy {
    enum Rejection: Equatable {
        case badRequest
        case forbidden
        case payloadTooLarge
    }

    let allowedHosts: Set<String>
    let allowedPort: Int
    let csrfToken: String
    /// A reverse proxy may terminate TLS and forward to the loopback listener, but
    /// only an explicitly listed peer may assert that boundary. The public origin
    /// is kept as a parsed URL so Host/Origin cannot be widened by string prefixes.
    let trustedProxyAddresses: Set<String>
    let publicOrigin: URL?

    struct RequestContext: Equatable {
        let clientAddressKey: String
        let scheme: String
        let authority: String
        var isSecure: Bool { scheme == "https" }
    }

    init(
        allowedHosts: Set<String>,
        allowedPort: Int,
        csrfToken: String,
        trustedProxyAddresses: Set<String> = [],
        publicOrigin: URL? = nil
    ) {
        self.allowedHosts = allowedHosts
        self.allowedPort = allowedPort
        self.csrfToken = csrfToken
        self.trustedProxyAddresses = trustedProxyAddresses
        self.publicOrigin = publicOrigin
    }

    func validate(
        _ rawRequest: String,
        bodyLength: Int = 0,
        clientAddressKey: String? = nil,
        isDirectTLS: Bool = false,
        expectedCSRFTokens: [String]? = nil
    ) -> Rejection? {
        guard let headerEnd = rawRequest.range(of: "\r\n\r\n") else { return .badRequest }
        guard rawRequest[headerEnd.upperBound...].isEmpty else { return .badRequest }
        let head = String(rawRequest[..<headerEnd.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty, lines.count <= 101 else { return .badRequest }

        let requestParts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              !requestParts.contains(where: { $0.isEmpty }),
              requestParts[2] == "HTTP/1.1"
        else {
            return .badRequest
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        guard ServerHTTPMethodContract.allowedRawValues.contains(method),
              target.utf8.count <= 2_048,
              target.first == "/",
              !target.hasPrefix("//"),
              !target.contains("\\"),
              !Self.containsInvalidPercentEncoding(target),
              !target.lowercased().contains("%2f"),
              !target.lowercased().contains("%5c"),
              !target.lowercased().contains("%00")
        else {
            return .badRequest
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else {
                return .badRequest
            }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard Self.isValidHeaderName(name),
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else {
                return .badRequest
            }
            headers[name.lowercased(), default: []].append(value)
        }

        guard let hostValues = headers["host"], hostValues.count == 1,
              Self.normalizedAuthority(hostValues[0], scheme: isDirectTLS ? "https" : "http") != nil
        else {
            return .forbidden
        }
        guard headers["transfer-encoding"] == nil,
              (headers["content-length"]?.count ?? 0) <= 1,
              (headers["range"]?.count ?? 0) <= 1,
              (headers["if-match"]?.count ?? 0) <= 1,
              (headers["authorization"]?.count ?? 0) <= 1,
              (headers["cookie"]?.count ?? 0) <= 1,
              (headers["content-type"]?.count ?? 0) <= 1,
              (headers["origin"]?.count ?? 0) <= 1,
              (headers["x-medialib-csrf"]?.count ?? 0) <= 1,
              (headers["x-medialib-client"]?.count ?? 0) <= 1,
              (headers["sec-fetch-site"]?.count ?? 0) <= 1,
              (headers["connection"]?.count ?? 0) <= 1,
              (headers["x-forwarded-proto"]?.count ?? 0) <= 1,
              (headers["x-forwarded-host"]?.count ?? 0) <= 1,
              (headers["x-forwarded-for"]?.count ?? 0) <= 1,
              (headers["forwarded"]?.count ?? 0) <= 1
        else {
            return .badRequest
        }
        guard let context = requestContext(
            headers: headers, connectedAddressKey: clientAddressKey ?? "unknown",
            isDirectTLS: isDirectTLS
        ) else { return .badRequest }
        let declaredBodyLength: Int
        if let contentLength = headers["content-length"]?.first {
            guard !contentLength.isEmpty,
                  contentLength.allSatisfy(\.isNumber),
                  let parsed = Int(contentLength), parsed >= 0
            else {
                return .badRequest
            }
            declaredBodyLength = parsed
        } else {
            declaredBodyLength = 0
        }
        guard declaredBodyLength == bodyLength else { return .badRequest }
        if declaredBodyLength > 0 {
            guard declaredBodyLength <= 4_096 else { return .payloadTooLarge }
            guard ServerHTTPMethodContract.mutatingRawValues.contains(method),
                  let contentType = headers["content-type"]?.first?.lowercased(),
                  (Self.isJSONBodyPath(path) &&
                    (contentType == "application/json" || contentType == "application/json; charset=utf-8")) ||
                    (path == "/login" && contentType == "application/x-www-form-urlencoded")
            else {
                return .badRequest
            }
        }

        // Some desktop automation and embedded browser shells label a local
        // navigation form as cross-site. The only exception is /login, whose
        // route requires the unguessable rendered CSRF field before it will
        // inspect credentials; all other endpoints keep the early rejection.
        if headers["sec-fetch-site"]?.first?.lowercased() == "cross-site", path != "/login" {
            return .forbidden
        }
        if ServerHTTPMethodContract.mutatingRawValues.contains(method) {
            if isVerifiedNativeMlinkRequest(headers, path: path) {
                // 原生 Mlink 请求没有浏览器 Cookie，也不能携带 Origin；它通过 Bearer
                // 令牌在路由层认证。例外仅限两条客户端状态同步端点，绝不能成为
                // 账户、登录或管理类网页写操作的 CSRF 旁路。
                guard headers["cookie"] == nil, headers["origin"] == nil else { return .forbidden }
            } else if path == "/login" {
                // The no-JavaScript login fallback includes the server-issued CSRF
                // field in its body; the router verifies it before credential use.
                // The router accepts only a server-rendered one-time CSRF field
                // before it inspects credentials. This is intentionally the
                // narrow form-navigation exception: embedded browsers can emit
                // an opaque Origin value even for a local, user-initiated submit.
            } else {
                guard let token = headers["x-medialib-csrf"]?.first,
                      (expectedCSRFTokens ?? [csrfToken]).contains(where: {
                          Self.constantTimeEqual(token, $0)
                      }),
                      originIsAllowed(headers["origin"]?.first, context: context)
                else {
                    return .forbidden
                }
            }
        }
        return nil
    }

    private func originIsAllowed(_ value: String?, context: RequestContext) -> Bool {
        // 原生客户端不发送 Origin；浏览器只允许当前服务自身的明确 Origin。
        guard let value else { return true }
        guard let components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        guard let scheme = components.scheme?.lowercased(), scheme == context.scheme,
              let originAuthority = Self.normalizedAuthority(
                String(value.dropFirst(scheme.count + 3)), scheme: scheme
              )
        else { return false }
        return originAuthority == context.authority
    }

    /// Call only after validation; forwarded metadata from untrusted peers is ignored.
    func effectiveClientAddressKey(
        for rawRequest: String,
        connectedAddressKey: String
    ) -> String {
        requestContext(for: rawRequest, connectedAddressKey: connectedAddressKey)?.clientAddressKey
            ?? connectedAddressKey
    }

    func requestContext(
        for rawRequest: String,
        connectedAddressKey: String,
        isDirectTLS: Bool = false
    ) -> RequestContext? {
        requestContext(headers: Self.headerValues(in: rawRequest),
                       connectedAddressKey: connectedAddressKey, isDirectTLS: isDirectTLS)
    }

    private func requestContext(
        headers: [String: [String]], connectedAddressKey: String, isDirectTLS: Bool
    ) -> RequestContext? {
        guard let host = headers["host"]?.only,
              let directAuthority = Self.normalizedAuthority(host, scheme: isDirectTLS ? "https" : "http")
        else { return nil }
        let trusted = trustedProxyAddresses.contains(connectedAddressKey)
        guard trusted else {
            return RequestContext(clientAddressKey: connectedAddressKey,
                                  scheme: isDirectTLS ? "https" : "http", authority: directAuthority)
        }
        // A trusted edge must overwrite client-supplied forwarding fields. Reject
        // inconsistent or malformed edge assertions rather than mixing identities.
        let forwarded = headers["forwarded"]?.only
        let parsed = forwarded.flatMap { Self.parseForwarded($0, trustedAddresses: trustedProxyAddresses) }
        if forwarded != nil && parsed == nil { return nil }
        let xProto = headers["x-forwarded-proto"]?.only.flatMap(Self.lastForwardedValue)
        if headers["x-forwarded-proto"] != nil && xProto == nil { return nil }
        let proto = xProto?.lowercased() ?? parsed?.scheme
        guard proto == nil || proto == "http" || proto == "https" else { return nil }
        let scheme = proto ?? (isDirectTLS ? "https" : "http")
        let xHost = headers["x-forwarded-host"]?.only.flatMap(Self.lastForwardedValue)
        if headers["x-forwarded-host"] != nil && xHost == nil { return nil }
        let forwardedHost = xHost ?? parsed?.authority
        guard let authority = Self.normalizedAuthority(forwardedHost ?? host, scheme: scheme) else { return nil }
        let forwardedFor = headers["x-forwarded-for"]?.only ?? parsed?.client
        guard let client = Self.trustedClient(forwardedFor, peer: connectedAddressKey,
                                              trustedAddresses: trustedProxyAddresses) else { return nil }
        if let parsed {
            guard (parsed.scheme == nil || parsed.scheme == scheme),
                  (parsed.authority.flatMap { Self.normalizedAuthority($0, scheme: scheme) } ?? authority) == authority,
                  (parsed.client == nil || parsed.client == client)
            else { return nil }
        }
        return RequestContext(clientAddressKey: client, scheme: scheme, authority: authority)
    }

    private static func trustedClient(_ value: String?, peer: String, trustedAddresses: Set<String>) -> String? {
        guard let value else { return peer }
        let chain = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !chain.isEmpty, chain.count <= 16,
              chain.allSatisfy({ isIPAddress($0) }) else { return nil }
        for address in chain.reversed() where !trustedAddresses.contains(address) { return address }
        return chain.first
    }

    private static func lastForwardedValue(_ value: String) -> String? {
        let items = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.isEmpty, items.count <= 16, items.allSatisfy({ !$0.isEmpty }) else { return nil }
        return items.last
    }

    private static func parseForwarded(
        _ value: String, trustedAddresses: Set<String>
    ) -> (scheme: String?, authority: String?, client: String?)? {
        guard let elements = splitForwarded(value, separator: ","),
              !elements.isEmpty, elements.count <= 16 else { return nil }
        var clients: [String] = []
        var finalFields: [String: String] = [:]
        for element in elements {
            guard let parts = splitForwarded(element, separator: ";"), !parts.isEmpty else { return nil }
            var fields: [String: String] = [:]
            for part in parts {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return nil }
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                var field = pair[1].trimmingCharacters(in: .whitespaces)
                if field.hasPrefix("\"") && field.hasSuffix("\"") && field.count >= 2 {
                    field = String(field.dropFirst().dropLast())
                }
                guard ["for", "proto", "host", "by"].contains(key),
                      !field.isEmpty, !field.contains("\""), !field.contains("\\"),
                      fields[key] == nil else { return nil }
                fields[key] = field
            }
            guard let client = fields["for"].flatMap(normalizedForwardedAddress) else { return nil }
            clients.append(client)
            finalFields = fields
        }
        let effectiveClient = clients.reversed().first { !trustedAddresses.contains($0) } ?? clients.first
        // Only the rightmost entry is allowed to declare the external scheme and
        // authority; left entries may have been supplied by a client.
        return (finalFields["proto"]?.lowercased(), finalFields["host"], effectiveClient)
    }

    private static func splitForwarded(_ value: String, separator: Character) -> [String]? {
        var quoted = false
        var parts: [String] = []
        var current = ""
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == separator && !quoted {
                let part = current.trimmingCharacters(in: .whitespaces)
                guard !part.isEmpty else { return nil }
                parts.append(part)
                current = ""
            } else {
                current.append(character)
            }
        }
        let part = current.trimmingCharacters(in: .whitespaces)
        guard !quoted, !part.isEmpty else { return nil }
        parts.append(part)
        return parts
    }

    private static func normalizedForwardedAddress(_ value: String) -> String? {
        if isIPAddress(value) { return value }
        if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
            let address = String(value[value.index(after: value.startIndex)..<closing])
            let suffix = value[value.index(after: closing)...]
            guard (suffix.isEmpty || suffix.first == ":"), isIPAddress(address) else { return nil }
            return address
        }
        return nil
    }

    private static func headerValues(in rawRequest: String) -> [String: [String]] {
        guard let headerEnd = rawRequest.range(of: "\r\n\r\n") else { return [:] }
        let head = rawRequest[..<headerEnd.lowerBound]
        return head.components(separatedBy: "\r\n").dropFirst().reduce(into: [:]) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[name, default: []].append(value)
        }
    }

    private static func normalizedAuthority(_ value: String, scheme: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 255,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains("@"), !value.contains("/"), !value.contains("\\"),
              !value.contains("#"), !value.contains("?"), !value.contains(","),
              !value.contains("%"), !value.hasSuffix(":"),
              let url = URLComponents(string: "\(scheme)://\(value)"),
              url.user == nil, url.password == nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil,
              let parsedHost = url.host?.lowercased(), !parsedHost.isEmpty
        else { return nil }
        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
            ? String(parsedHost.dropFirst().dropLast()) : parsedHost
        let validHost: Bool
        if host.contains(":") {
            validHost = isIPAddress(host)
        } else {
            validHost = host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
                $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
        }
        guard validHost, url.port == nil || (1...65_535).contains(url.port!) else { return nil }
        let port = url.port
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(hostPart):\(port ?? defaultPort)"
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var address4 = in_addr()
        var address6 = in6_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET, pointer, &address4) == 1 ||
            inet_pton(AF_INET6, pointer, &address6) == 1
        }
    }

    private func isVerifiedNativeMlinkRequest(_ headers: [String: [String]], path: String) -> Bool {
        // 自定义请求头不能由跨站脚本在未获 CORS 授权时发送；同时拒绝任何浏览器
        // Cookie/Origin 组合，使它不成为浏览器 CSRF 规则的旁路。
        headers["x-medialib-client"] == ["mlink-native/1"] &&
            Self.isNativeMlinkMutationPath(path)
    }

    // v30 的设置文档使用 PATCH/PUT/DELETE；它们与 POST 一样必须通过同源、CSRF、
    // Content-Type 和正文边界校验，不能因为方法不同而成为历史清理接口的旁路。
    private static let jsonBodyPaths: Set<String> = [
        "/api/v1/auth/login",
        "/api/v1/auth/refresh"
    ]

    private static func isJSONBodyPath(_ path: String) -> Bool {
        jsonBodyPaths.contains(path) ||
        path == "/api/v1/auth/password" ||
        path == "/api/v1/me/preferences" ||
        path == "/api/v1/me/preferences/device" ||
        path == "/api/v1/admin/settings" ||
        path == "/api/v1/admin/jobs" ||
        path == "/api/v1/admin/runtime/validate" ||
        path == "/api/v1/admin/runtime/apply" ||
        path == "/api/v1/playback/sessions" ||
        path == "/api/v1/admin/users" ||
        isAdminMemberJSONPath(path) ||
        path == "/api/v1/queue" ||
        path.hasPrefix("/api/v1/playback/state/") ||
            path.hasPrefix("/api/v1/user-media/preferences/") ||
            isSingleOpaqueIdentifierPath(path, prefix: "/api/v1/playback/sessions/") ||
            isPlaybackOverridePath(path)
    }

    private static func isNativeMlinkMutationPath(_ path: String) -> Bool {
        isSingleOpaqueIdentifierPath(path, prefix: "/api/v1/playback/state/") ||
            isSingleOpaqueIdentifierPath(path, prefix: "/api/v1/user-media/preferences/")
    }

    private static func isAdminMemberJSONPath(_ path: String) -> Bool {
        let prefix = "/api/v1/admin/users/"
        for suffix in ["/access", "/password", "/policy"] {
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let identifier = path.dropFirst(prefix.count).dropLast(suffix.count)
            return !identifier.isEmpty && !identifier.contains("/") && !identifier.contains("\\")
        }
        return false
    }

    private static func isPlaybackOverridePath(_ path: String) -> Bool {
        let prefix = "/api/v1/me/playback-overrides/"
        guard path.hasPrefix(prefix) else { return false }
        let pieces = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return pieces.count == 2 && ["media", "series"].contains(String(pieces[0])) &&
            !pieces[1].isEmpty && !pieces[1].contains("\\")
    }

    /// 不要用前缀作为长期授权边界：未来在同一资源树增加子路由时，原生 CSRF
    /// 例外不应自动扩散。真正的路由还会做 percent decoding 与字符集验证。
    private static func isSingleOpaqueIdentifierPath(_ path: String, prefix: String) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let identifier = path.dropFirst(prefix.count)
        return !identifier.isEmpty && !identifier.contains("/") && !identifier.contains("\\")
    }
    private static let headerNameCharacters = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { headerNameCharacters.contains($0) }
    }

    private static func containsInvalidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      isHex(bytes[index + 1]), isHex(bytes[index + 2])
                else {
                    return true
                }
                index += 3
            } else {
                guard bytes[index] >= 0x20, bytes[index] != 0x7f else { return true }
                index += 1
            }
        }
        return false
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

enum ServerRequestSecurityToken {
    static func generate() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}
