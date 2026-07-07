import Foundation
import MediaLibCore

struct FileHealthEvaluation: Equatable, Sendable {
    var missingItemIDs: Set<String>
    var safeMissingItemIDs: Set<String>
    var offlineSourceIDs: Set<String>
}

enum FileHealthEvaluator {
    typealias FileExists = @Sendable (String) -> Bool

    static func evaluate(
        items: [MediaItem],
        sources: [MediaSource],
        privateItemIDs: Set<String>,
        fileExists: FileExists = { FileManager.default.fileExists(atPath: $0) }
    ) -> FileHealthEvaluation {
        let healthExcludedPaths = sources.filter { !$0.includeInHealthCheck }.map(\.path)

        let missingItemIDs = Set(items.compactMap { item -> String? in
            guard !privateItemIDs.contains(item.id),
                  item.type != .music,
                  let sourcePath = item.sourcePath,
                  let source = sources
                      .filter({
                          $0.includeInHealthCheck &&
                          SourcePathPolicy.isSourcePath(sourcePath, inside: $0.path)
                      })
                      .max(by: { $0.path.count < $1.path.count }),
                  !SourcePathPolicy.isExcluded(sourcePath, in: healthExcludedPaths) else {
                return nil
            }

            let trimmedFilePath = item.filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if source.sourceKind.isRemoteMediaServer {
                return trimmedFilePath.isEmpty ? item.id : nil
            }

            guard !trimmedFilePath.isEmpty,
                  !item.isRemoteResource,
                  !fileExists(trimmedFilePath) else {
                return nil
            }
            return item.id
        })

        let offlineSourceIDs = Set(sources.compactMap { source -> String? in
            guard !source.sourceKind.isRemoteMediaServer,
                  source.sourceKind != .url,
                  source.includeInHealthCheck,
                  !fileExists(source.path) else {
                return nil
            }
            return source.id
        })

        let safeMissingItemIDs = Set(items.compactMap { item -> String? in
            guard missingItemIDs.contains(item.id) else { return nil }
            guard let sourcePath = item.sourcePath else { return item.id }
            let source = sources
                .filter { SourcePathPolicy.isSourcePath(sourcePath, inside: $0.path) }
                .max { $0.path.count < $1.path.count }
            guard let source else { return item.id }
            return offlineSourceIDs.contains(source.id) ? nil : item.id
        })

        return FileHealthEvaluation(
            missingItemIDs: missingItemIDs,
            safeMissingItemIDs: safeMissingItemIDs,
            offlineSourceIDs: offlineSourceIDs
        )
    }
}
