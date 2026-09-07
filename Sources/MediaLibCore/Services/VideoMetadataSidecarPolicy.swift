import Foundation

public enum VideoMetadataSidecarSkipReason: String, Sendable, Equatable {
    case writeBackDisabled
    case unsupportedSource
    case vaultLocked
    case unsupportedMedia
    case missingMediaPath
    case ownershipUnknown
    case outsideAuthorizedRoot
    case notWritable
}

public enum VideoMetadataSidecarTargetResolution: Sendable, Equatable {
    case target(URL)
    case skipped(VideoMetadataSidecarSkipReason)
}

/// Resolves sidecar destinations without granting write access merely because an item contains
/// a path. The source opt-in and current vault state remain explicit inputs to this boundary.
public enum VideoMetadataSidecarPolicy {
    public static func writeIfAllowed(
        item: MediaItem,
        update: MediaMetadataUpdate,
        source: MediaSource,
        childItems: [MediaItem] = [],
        vaultUnlocked: Bool
    ) async throws -> VideoMetadataSidecarWriteOutcome {
        switch resolveTarget(
            for: item,
            source: source,
            childItems: childItems,
            vaultUnlocked: vaultUnlocked
        ) {
        case let .target(targetURL):
            return try await VideoMetadataSidecarWriter.writeSafely(
                item: item,
                update: update,
                to: targetURL
            )
        case let .skipped(reason):
            return .skipped(reason)
        }
    }

    public static func resolveTarget(
        for item: MediaItem,
        source: MediaSource,
        childItems: [MediaItem] = [],
        vaultUnlocked: Bool
    ) -> VideoMetadataSidecarTargetResolution {
        guard source.preferMetadataWriteToSource else {
            return .skipped(.writeBackDisabled)
        }
        guard source.sourceKind == .local else {
            return .skipped(.unsupportedSource)
        }
        if source.mediaType == .privateCollection, !vaultUnlocked {
            return .skipped(.vaultLocked)
        }
        guard NSString(string: source.path).isAbsolutePath else {
            return .skipped(.outsideAuthorizedRoot)
        }

        let sourceRoot = URL(fileURLWithPath: source.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if let filePath = item.filePath {
            guard item.type != .music, item.type != .photo, item.type != .episode else {
                return .skipped(.unsupportedMedia)
            }
            guard NSString(string: filePath).isAbsolutePath else {
                return .skipped(.missingMediaPath)
            }
            let mediaURL = URL(fileURLWithPath: filePath).standardizedFileURL
            let resolvedMediaURL = mediaURL.resolvingSymlinksInPath()
            guard contains(resolvedMediaURL, in: sourceRoot) else {
                return .skipped(.outsideAuthorizedRoot)
            }
            let targetURL = mediaURL.deletingPathExtension().appendingPathExtension("nfo")
            let resolvedTargetParent = targetURL.deletingLastPathComponent().resolvingSymlinksInPath()
            guard contains(resolvedTargetParent, in: sourceRoot) else {
                return .skipped(.outsideAuthorizedRoot)
            }
            return .target(targetURL)
        }

        guard item.type == .tvShow || item.type == .anime || item.type == .documentary ||
                item.type == .variety || item.type == .privateCollection else {
            return .skipped(.unsupportedMedia)
        }

        let episodes = childItems.filter { $0.type == .episode }
        guard !episodes.isEmpty else {
            return .skipped(.ownershipUnknown)
        }
        let parser = FilenameParser()
        var resolvedSeriesRoot: URL?
        for episode in episodes {
            guard let filePath = episode.filePath,
                  NSString(string: filePath).isAbsolutePath else {
                return .skipped(.ownershipUnknown)
            }
            let episodeURL = URL(fileURLWithPath: filePath).standardizedFileURL
            let resolvedEpisodeURL = episodeURL.resolvingSymlinksInPath()
            guard contains(resolvedEpisodeURL, in: sourceRoot),
                  let candidate = parser.seriesDirectory(for: episodeURL, sourcePath: source.path) else {
                return .skipped(.ownershipUnknown)
            }
            let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedCandidate.path != sourceRoot.path,
                  contains(resolvedCandidate, in: sourceRoot) else {
                return .skipped(.ownershipUnknown)
            }
            if let resolvedSeriesRoot, resolvedSeriesRoot.path != resolvedCandidate.path {
                return .skipped(.ownershipUnknown)
            }
            resolvedSeriesRoot = resolvedCandidate
        }

        guard let resolvedSeriesRoot else {
            return .skipped(.ownershipUnknown)
        }
        return .target(resolvedSeriesRoot.appendingPathComponent("tvshow.nfo"))
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
