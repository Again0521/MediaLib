public enum SourcePathPolicy {
    public static func isSourcePath(_ candidate: String?, inside sourceRoot: String) -> Bool {
        guard let candidate,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let sourceRoot = normalizedSourceRoot(sourceRoot)
        guard !sourceRoot.isEmpty else { return false }
        if sourceRoot == "/" {
            return candidate.hasPrefix("/")
        }
        let candidateComparison = comparisonKey(for: candidate)
        let sourceRootComparison = comparisonKey(for: sourceRoot)
        return candidateComparison == sourceRootComparison ||
            candidateComparison.hasPrefix("\(sourceRootComparison)/")
    }

    public static func isExcluded(_ sourcePath: String?, in excludedPaths: [String]) -> Bool {
        guard let sourcePath, !excludedPaths.isEmpty else { return false }
        return excludedPaths.contains { isSourcePath(sourcePath, inside: $0) }
    }

    static func normalizedSourceRoot(_ sourceRoot: String) -> String {
        var normalized = sourceRoot
        while normalized.count > 1,
              normalized.hasSuffix("/"),
              !normalized.hasSuffix("://") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func comparisonKey(for path: String) -> String {
        guard let schemeSeparator = path.range(of: "://") else { return path }
        let authorityStart = schemeSeparator.upperBound
        let authorityEnd = path[authorityStart...].firstIndex(of: "/") ?? path.endIndex
        let scheme = path[..<schemeSeparator.lowerBound].lowercased()
        let authority = String(path[authorityStart..<authorityEnd])
        let normalizedAuthority: String
        if let userInfoEnd = authority.lastIndex(of: "@") {
            let userInfo = authority[...userInfoEnd]
            let hostAndPort = authority[authority.index(after: userInfoEnd)...]
            normalizedAuthority = String(userInfo) + hostAndPort.lowercased()
        } else {
            normalizedAuthority = authority.lowercased()
        }
        return "\(scheme)://\(normalizedAuthority)\(path[authorityEnd...])"
    }
}
