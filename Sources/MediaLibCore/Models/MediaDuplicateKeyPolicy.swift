import Foundation

public enum MediaDuplicateKeyPolicy {
    public static func duplicateKey(for item: MediaItem) -> String {
        let normalizedTitle = item.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return "\(item.type.rawValue)-\(normalizedTitle)-\(item.year.map(String.init) ?? "unknown")"
    }

    public static func duplicateTitleGroups(
        in items: [MediaItem],
        excludingSourcePaths excludedPaths: [String]
    ) -> [[MediaItem]] {
        let groups = Dictionary(
            grouping: items.filter { !SourcePathPolicy.isExcluded($0.sourcePath, in: excludedPaths) }
        ) { duplicateKey(for: $0) }

        return groups.values
            .filter { $0.count > 1 }
            .sorted { $0[0].title.localizedStandardCompare($1[0].title) == .orderedAscending }
    }
}
