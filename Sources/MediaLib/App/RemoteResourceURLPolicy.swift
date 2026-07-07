import Foundation

enum RemoteResourceURLPolicy {
    static func authenticatedURL(_ url: URL?, baseURL: URL, tokenName: String, tokenValue: String) -> URL? {
        guard let url else { return nil }
        guard isSameOrigin(url, baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare(tokenName) == .orderedSame }
        queryItems.append(URLQueryItem(name: tokenName, value: tokenValue))
        components.queryItems = queryItems
        return components.url ?? url
    }

    static func authenticatedURLString(
        relativeOrAbsolutePath: String,
        baseURL: URL,
        tokenName: String,
        tokenValue: String
    ) -> String? {
        guard let url = URL(string: relativeOrAbsolutePath, relativeTo: baseURL)?.absoluteURL else { return nil }
        return authenticatedURL(url, baseURL: baseURL, tokenName: tokenName, tokenValue: tokenValue)?.absoluteString
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              let leftScheme = left.scheme?.lowercased(),
              let rightScheme = right.scheme?.lowercased(),
              leftScheme == rightScheme,
              let leftHost = left.host,
              let rightHost = right.host,
              leftHost.caseInsensitiveCompare(rightHost) == .orderedSame else {
            return false
        }

        return effectivePort(for: left, scheme: leftScheme) == effectivePort(for: right, scheme: rightScheme)
    }

    private static func effectivePort(for components: URLComponents, scheme: String) -> Int? {
        if let port = components.port {
            return port
        }
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
