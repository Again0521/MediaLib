import Foundation

/// 当前回环 HTTP 入口的严格语法与来源校验。完整 HTTP 框架接入后，这些规则仍应作为
/// 中间件和契约测试保留，不能依赖框架默认值来防止请求走私或 DNS 重绑定。
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
        isDirectTLS: Bool = false
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
        guard Self.allowedMethods.contains(method),
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

        let hasForwardedHeaders = headers.keys.contains { key in
            key == "forwarded" || key.hasPrefix("x-forwarded-")
        }
        let isTrustedProxyRequest: Bool
        if hasForwardedHeaders {
            guard let clientAddressKey,
                  trustedProxyAddresses.contains(clientAddressKey),
                  headers["x-forwarded-proto"] == ["https"],
                  headers["forwarded"] == nil,
                  headers["x-forwarded-host"] == nil
            else {
                return .forbidden
            }
            isTrustedProxyRequest = true
        } else {
            isTrustedProxyRequest = false
        }

        guard let hostValues = headers["host"], hostValues.count == 1,
              isAllowedHost(hostValues[0], allowPublicOrigin: isTrustedProxyRequest || isDirectTLS)
        else {
            return .forbidden
        }
        guard headers["transfer-encoding"] == nil,
              (headers["content-length"]?.count ?? 0) <= 1,
              (headers["range"]?.count ?? 0) <= 1,
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
        if let forwardedFor = headers["x-forwarded-for"]?.first {
            guard isTrustedProxyRequest, Self.isIPv4Address(forwardedFor) else {
                return .forbidden
            }
        }
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
            guard method == "POST",
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
        if Self.mutatingMethods.contains(method) {
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
                      Self.constantTimeEqual(token, csrfToken),
                      originIsAllowed(
                        headers["origin"]?.first,
                        allowPublicOrigin: isTrustedProxyRequest || isDirectTLS
                      )
                else {
                    return .forbidden
                }
            }
        }
        return nil
    }

    private func isAllowedHost(_ value: String, allowPublicOrigin: Bool) -> Bool {
        let normalized = value.lowercased()
        guard !normalized.contains("@"),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains(where: { $0.isWhitespace })
        else {
            return false
        }
        if allowPublicOrigin, let publicOrigin {
            guard let components = URLComponents(url: publicOrigin, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  let publicHost = components.host?.lowercased(),
                  let hostAndPort = Self.hostAndPort(from: normalized)
            else { return false }
            return hostAndPort.host == publicHost &&
                (hostAndPort.port ?? 443) == (components.port ?? 443)
        }
        guard let hostAndPort = Self.hostAndPort(from: normalized),
              allowedHosts.contains(hostAndPort.host)
        else { return false }
        return hostAndPort.port == nil || hostAndPort.port == allowedPort
    }

    private func originIsAllowed(_ value: String?, allowPublicOrigin: Bool) -> Bool {
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
        if allowPublicOrigin, let publicOrigin,
           let publicComponents = URLComponents(url: publicOrigin, resolvingAgainstBaseURL: false) {
            return components.scheme?.lowercased() == "https" &&
                components.host?.lowercased() == publicComponents.host?.lowercased() &&
                (components.port ?? 443) == (publicComponents.port ?? 443)
        }
        return components.scheme?.lowercased() == "http" &&
            components.host.map { allowedHosts.contains($0.lowercased()) } == true &&
            (components.port == nil || components.port == allowedPort)
    }

    /// Returns the one client address asserted by a trusted proxy, or the socket
    /// peer for direct loopback requests. The caller invokes this only after
    /// `validate` has accepted the request, so an untrusted header cannot reach
    /// rate-limit or audit keys.
    func effectiveClientAddressKey(
        for rawRequest: String,
        connectedAddressKey: String
    ) -> String {
        guard let headerValue = Self.headerValues(in: rawRequest)["x-forwarded-for"]?.first,
              trustedProxyAddresses.contains(connectedAddressKey),
              Self.isIPv4Address(headerValue)
        else { return connectedAddressKey }
        return headerValue
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

    private static func hostAndPort(from value: String) -> (host: String, port: Int?)? {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2,
              let host = pieces.first, !host.isEmpty
        else { return nil }
        if pieces.count == 1 { return (String(host), nil) }
        guard let port = Int(pieces[1]), (1...65_535).contains(port) else { return nil }
        return (String(host), port)
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) &&
                Int(part).map { (0...255).contains($0) } == true
        }
    }

    private func isVerifiedNativeMlinkRequest(_ headers: [String: [String]], path: String) -> Bool {
        // 自定义请求头不能由跨站脚本在未获 CORS 授权时发送；同时拒绝任何浏览器
        // Cookie/Origin 组合，使它不成为浏览器 CSRF 规则的旁路。
        headers["x-medialib-client"] == ["mlink-native/1"] &&
            Self.isNativeMlinkMutationPath(path)
    }

    // 当前 Web 写入只有登录、刷新、注销、播放状态和逐用户偏好 POST；不接受未使用的方法，
    // 避免历史转码清理等 DELETE 请求绕过入口策略进入路由层。
    private static let allowedMethods: Set<String> = ["GET", "HEAD", "POST"]
    private static let mutatingMethods: Set<String> = ["POST"]
    private static let jsonBodyPaths: Set<String> = [
        "/api/v1/auth/login",
        "/api/v1/auth/refresh"
    ]

    private static func isJSONBodyPath(_ path: String) -> Bool {
        jsonBodyPaths.contains(path) ||
        path == "/api/v1/auth/password" ||
        path == "/api/v1/admin/users" ||
        isAdminMemberJSONPath(path) ||
        path == "/api/v1/queue" ||
        path.hasPrefix("/api/v1/playback/state/") ||
            path.hasPrefix("/api/v1/user-media/preferences/")
    }

    private static func isNativeMlinkMutationPath(_ path: String) -> Bool {
        isSingleOpaqueIdentifierPath(path, prefix: "/api/v1/playback/state/") ||
            isSingleOpaqueIdentifierPath(path, prefix: "/api/v1/user-media/preferences/")
    }

    private static func isAdminMemberJSONPath(_ path: String) -> Bool {
        let prefix = "/api/v1/admin/users/"
        for suffix in ["/access", "/password"] {
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let identifier = path.dropFirst(prefix.count).dropLast(suffix.count)
            return !identifier.isEmpty && !identifier.contains("/") && !identifier.contains("\\")
        }
        return false
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
