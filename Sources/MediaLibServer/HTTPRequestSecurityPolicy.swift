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

    func validate(_ rawRequest: String, bodyLength: Int = 0) -> Rejection? {
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

        guard let hostValues = headers["host"], hostValues.count == 1,
              isAllowedHost(hostValues[0])
        else {
            return .forbidden
        }
        guard headers["transfer-encoding"] == nil,
              (headers["content-length"]?.count ?? 0) <= 1,
              (headers["range"]?.count ?? 0) <= 1,
              (headers["authorization"]?.count ?? 0) <= 1,
              (headers["cookie"]?.count ?? 0) <= 1,
              (headers["content-type"]?.count ?? 0) <= 1
        else {
            return .badRequest
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
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            guard method == "POST",
                  Self.isJSONBodyPath(path),
                  let contentType = headers["content-type"]?.first?.lowercased(),
                  contentType == "application/json" || contentType == "application/json; charset=utf-8"
            else {
                return .badRequest
            }
        }

        if headers["sec-fetch-site"]?.first?.lowercased() == "cross-site" {
            return .forbidden
        }
        if Self.mutatingMethods.contains(method) {
            guard let token = headers["x-medialib-csrf"]?.first,
                  Self.constantTimeEqual(token, csrfToken),
                  originIsAllowed(headers["origin"]?.first)
            else {
                return .forbidden
            }
        }
        return nil
    }

    private func isAllowedHost(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard !normalized.contains("@"),
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.contains(where: { $0.isWhitespace })
        else {
            return false
        }
        let pieces = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2,
              let host = pieces.first,
              allowedHosts.contains(String(host))
        else {
            return false
        }
        if pieces.count == 2 {
            return Int(pieces[1]) == allowedPort
        }
        return true
    }

    private func originIsAllowed(_ value: String?) -> Bool {
        // 原生客户端不发送 Origin；浏览器只允许当前服务自身的明确 Origin。
        guard let value else { return true }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        return components.port == nil || components.port == allowedPort
    }

    private static let allowedMethods: Set<String> = ["GET", "HEAD", "POST", "DELETE"]
    private static let mutatingMethods: Set<String> = ["POST", "DELETE"]
    private static let jsonBodyPaths: Set<String> = [
        "/api/v1/auth/login",
        "/api/v1/auth/refresh"
    ]

    private static func isJSONBodyPath(_ path: String) -> Bool {
        jsonBodyPaths.contains(path) || path.hasPrefix("/api/v1/playback/state/")
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
