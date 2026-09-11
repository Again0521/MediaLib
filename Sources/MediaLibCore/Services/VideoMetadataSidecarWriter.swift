import Foundation

public struct VideoMetadataSidecarWriteReport: Sendable, Equatable {
    public var targetURL: URL
    public var mergedExistingDocument: Bool
    public var warning: String?

    public init(targetURL: URL, mergedExistingDocument: Bool, warning: String? = nil) {
        self.targetURL = targetURL
        self.mergedExistingDocument = mergedExistingDocument
        self.warning = warning
    }
}

public enum VideoMetadataSidecarWriteOutcome: Sendable, Equatable {
    case written(VideoMetadataSidecarWriteReport)
    case skipped(VideoMetadataSidecarSkipReason)
}

public enum VideoMetadataSidecarWriteError: Error, LocalizedError, Sendable, Equatable {
    case symbolicLinkTarget
    case existingDocumentTooLarge
    case unsafeDocumentType
    case malformedExistingDocument
    case incompatibleRoot(expected: String, found: String)
    case generatedDocumentInvalid
    case concurrentModification
    case replacementFailed
    case recoveryFailed

    public var errorDescription: String? {
        switch self {
        case .symbolicLinkTarget:
            return "NFO 目标是符号链接，已拒绝写入。"
        case .existingDocumentTooLarge:
            return "现有 NFO 超出安全合并上限，已保留原文件。"
        case .unsafeDocumentType:
            return "现有 NFO 包含不安全的文档类型或实体声明，已保留原文件。"
        case .malformedExistingDocument:
            return "现有 NFO 无法安全解析，已保留原文件。"
        case let .incompatibleRoot(expected, found):
            return "现有 NFO 根元素不兼容（需要 \(expected)，实际为 \(found)），已保留原文件。"
        case .generatedDocumentInvalid:
            return "生成的 NFO 未通过 XML 校验，未替换原文件。"
        case .concurrentModification:
            return "NFO 在写入期间被其他程序修改，已保留外部修改和安全副本。"
        case .replacementFailed:
            return "NFO 原子替换失败，原文件已恢复。"
        case .recoveryFailed:
            return "NFO 原子替换失败，且自动恢复未完成。"
        }
    }
}

private actor VideoMetadataSidecarWriteCoordinator {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private var activeTargets: Set<String> = []
    private var waitersByTarget: [String: [Waiter]] = [:]

    func acquire(target: String, waiterID: UUID) async throws {
        try Task.checkCancellation()
        if activeTargets.insert(target).inserted {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waitersByTarget[target, default: []].append(.init(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancel(target: target, waiterID: waiterID) }
        }
    }

    func release(target: String) {
        guard activeTargets.contains(target) else { return }
        if var waiters = waitersByTarget[target], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                waitersByTarget.removeValue(forKey: target)
            } else {
                waitersByTarget[target] = waiters
            }
            next.continuation.resume()
        } else {
            activeTargets.remove(target)
        }
    }

    private func cancel(target: String, waiterID: UUID) {
        guard var waiters = waitersByTarget[target],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            waitersByTarget.removeValue(forKey: target)
        } else {
            waitersByTarget[target] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

struct VideoMetadataSidecarWriteHooks: @unchecked Sendable {
    var beforeCommit: @Sendable () throws -> Void
    var replaceExisting: @Sendable (URL, URL, String) throws -> URL?

    static let live = VideoMetadataSidecarWriteHooks(
        beforeCommit: {},
        replaceExisting: { targetURL, temporaryURL, backupName in
            try FileManager.default.replaceItemAt(
                targetURL,
                withItemAt: temporaryURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
        }
    )
}

public enum VideoMetadataSidecarWriter {
    private static let maximumExistingDocumentBytes = 4 * 1024 * 1024
    private static let writeCoordinator = VideoMetadataSidecarWriteCoordinator()

    public static func xmlContent(for item: MediaItem, update: MediaMetadataUpdate) -> String {
        let document = newDocument(rootTag: rootTag(for: item))
        apply(update: update, item: item, to: document, isNewDocument: true)
        return document.xmlString(options: [.nodePrettyPrint])
    }

    /// Compatibility wrapper for callers that only need the previous written/skipped Boolean.
    @discardableResult
    public static func write(
        item: MediaItem,
        update: MediaMetadataUpdate,
        to targetURL: URL
    ) async throws -> Bool {
        switch try await writeSafely(item: item, update: update, to: targetURL) {
        case .written:
            return true
        case .skipped:
            return false
        }
    }

    public static func writeSafely(
        item: MediaItem,
        update: MediaMetadataUpdate,
        to targetURL: URL
    ) async throws -> VideoMetadataSidecarWriteOutcome {
        try await writeSafely(item: item, update: update, to: targetURL, hooks: .live)
    }

    static func writeSafely(
        item: MediaItem,
        update: MediaMetadataUpdate,
        to targetURL: URL,
        hooks: VideoMetadataSidecarWriteHooks
    ) async throws -> VideoMetadataSidecarWriteOutcome {
        let targetKey = coordinatedTargetKey(targetURL)
        let waiterID = UUID()
        try await writeCoordinator.acquire(target: targetKey, waiterID: waiterID)
        do {
            try Task.checkCancellation()
            let result = try await BlockingIOExecutor.run {
                try writeSynchronously(item: item, update: update, to: targetURL, hooks: hooks)
            }
            await writeCoordinator.release(target: targetKey)
            return result
        } catch {
            await writeCoordinator.release(target: targetKey)
            throw error
        }
    }

    private static func coordinatedTargetKey(_ targetURL: URL) -> String {
        targetURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(targetURL.lastPathComponent)
            .standardizedFileURL.path
    }

    private static func writeSynchronously(
        item: MediaItem,
        update: MediaMetadataUpdate,
        to targetURL: URL,
        hooks: VideoMetadataSidecarWriteHooks
    ) throws -> VideoMetadataSidecarWriteOutcome {
        let fileManager = FileManager.default
        let directory = targetURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: directory.path) else {
            return .skipped(.notWritable)
        }

        let existed = fileManager.fileExists(atPath: targetURL.path)
        if existed {
            guard !isSymbolicLink(targetURL, fileManager: fileManager) else {
                throw VideoMetadataSidecarWriteError.symbolicLinkTarget
            }
            guard fileManager.isWritableFile(atPath: targetURL.path) else {
                return .skipped(.notWritable)
            }
        }

        let expectedRoot = rootTag(for: item)
        let originalData: Data?
        let document: XMLDocument
        if existed {
            let data = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            guard data.count <= maximumExistingDocumentBytes else {
                throw VideoMetadataSidecarWriteError.existingDocumentTooLarge
            }
            originalData = data
            document = try parseSafeDocument(data)
            let foundRoot = document.rootElement()?.name?.lowercased() ?? ""
            guard foundRoot == expectedRoot else {
                throw VideoMetadataSidecarWriteError.incompatibleRoot(
                    expected: expectedRoot,
                    found: foundRoot.isEmpty ? "unknown" : foundRoot
                )
            }
        } else {
            originalData = nil
            document = newDocument(rootTag: expectedRoot)
        }

        apply(update: update, item: item, to: document, isNewDocument: !existed)
        let outputData = document.xmlData(options: [.nodePrettyPrint])
        let validated = try parseSafeDocument(outputData)
        guard validated.rootElement()?.name?.lowercased() == expectedRoot else {
            throw VideoMetadataSidecarWriteError.generatedDocumentInvalid
        }

        let token = UUID().uuidString.lowercased()
        let temporaryURL = directory.appendingPathComponent(".\(targetURL.lastPathComponent).medialib-nfo-\(token).tmp")
        let backupName = ".\(targetURL.lastPathComponent).medialib-nfo-backup-\(token)"
        let backupURL = directory.appendingPathComponent(backupName)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try outputData.write(to: temporaryURL, options: [.withoutOverwriting])
        _ = try parseSafeDocument(Data(contentsOf: temporaryURL))

        try hooks.beforeCommit()
        if let originalData {
            guard fileManager.fileExists(atPath: targetURL.path),
                  !isSymbolicLink(targetURL, fileManager: fileManager),
                  try Data(contentsOf: targetURL, options: [.mappedIfSafe]) == originalData else {
                throw VideoMetadataSidecarWriteError.concurrentModification
            }
            do {
                _ = try hooks.replaceExisting(targetURL, temporaryURL, backupName)
            } catch {
                // Reconcile below. File replacement APIs may throw after changing
                // one or more paths, so the filesystem is the source of truth.
            }

            let targetExists = fileManager.fileExists(atPath: targetURL.path)
            let currentData = targetExists && !isSymbolicLink(targetURL, fileManager: fileManager)
                ? try? Data(contentsOf: targetURL)
                : nil
            if currentData == outputData {
                let warning = removeBackupIfPresent(backupURL, fileManager: fileManager)
                return .written(.init(
                    targetURL: targetURL,
                    mergedExistingDocument: true,
                    warning: warning
                ))
            }
            if currentData == originalData {
                _ = removeBackupIfPresent(backupURL, fileManager: fileManager)
                throw VideoMetadataSidecarWriteError.replacementFailed
            }
            if !targetExists {
                let recovered = restoreBackupToMissingTarget(
                    targetURL: targetURL,
                    backupURL: backupURL,
                    originalData: originalData,
                    fileManager: fileManager
                )
                throw recovered
                    ? VideoMetadataSidecarWriteError.replacementFailed
                    : VideoMetadataSidecarWriteError.recoveryFailed
            }

            // A target that exists but is neither the original nor our exact
            // output may belong to another writer. Never delete or replace it;
            // retain the uniquely named backup as recovery material.
            throw VideoMetadataSidecarWriteError.concurrentModification
        }

        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw VideoMetadataSidecarWriteError.concurrentModification
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        } catch {
            throw VideoMetadataSidecarWriteError.replacementFailed
        }
        return .written(.init(targetURL: targetURL, mergedExistingDocument: false))
    }

    private static func parseSafeDocument(_ data: Data) throws -> XMLDocument {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw VideoMetadataSidecarWriteError.malformedExistingDocument
        }
        let lowercased = raw.lowercased()
        guard !lowercased.contains("<!doctype"), !lowercased.contains("<!entity") else {
            throw VideoMetadataSidecarWriteError.unsafeDocumentType
        }
        do {
            let document = try XMLDocument(
                data: data,
                options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
            )
            guard document.dtd == nil, document.rootElement() != nil else {
                throw VideoMetadataSidecarWriteError.malformedExistingDocument
            }
            return document
        } catch let error as VideoMetadataSidecarWriteError {
            throw error
        } catch {
            throw VideoMetadataSidecarWriteError.malformedExistingDocument
        }
    }

    private static func newDocument(rootTag: String) -> XMLDocument {
        let document = XMLDocument(rootElement: XMLElement(name: rootTag))
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        document.isStandalone = true
        return document
    }

    private static func apply(
        update: MediaMetadataUpdate,
        item: MediaItem,
        to document: XMLDocument,
        isNewDocument: Bool
    ) {
        guard let root = document.rootElement() else { return }
        let title = update.title ?? (isNewDocument ? item.title : nil)
        setDirectElement("title", value: title, in: root)
        setDirectElement("originaltitle", value: update.originalTitle, in: root)
        setDirectElement("year", value: update.year.map(String.init), in: root)
        setDirectElement("plot", value: update.overview, in: root)
        setDirectElement("rating", value: normalizedRating(update.rating), in: root)
        setDirectElement("genre", value: update.genre, in: root)
        setTMDBUniqueID(update.externalID, in: root)
    }

    private static func setDirectElement(_ name: String, value: String?, in root: XMLElement) {
        guard let value else { return }
        if let element = root.elements(forName: name).first {
            element.stringValue = value
        } else {
            root.addChild(XMLElement(name: name, stringValue: value))
        }
    }

    private static func setTMDBUniqueID(_ value: String?, in root: XMLElement) {
        guard let value else { return }
        if let element = root.elements(forName: "uniqueid").first(where: {
            $0.attribute(forName: "type")?.stringValue?.lowercased() == "tmdb"
        }) {
            element.stringValue = value
            return
        }
        let element = XMLElement(name: "uniqueid", stringValue: value)
        element.addAttribute(XMLNode.attribute(withName: "type", stringValue: "tmdb") as! XMLNode)
        root.addChild(element)
    }

    private static func normalizedRating(_ rating: Double?) -> String? {
        guard let rating, rating.isFinite, rating > 0, rating <= 10 else { return nil }
        return String(rating)
    }

    private static func rootTag(for item: MediaItem) -> String {
        if item.type == .movie || (item.filePath != nil && item.type != .episode && item.type != .music && item.type != .photo) {
            return "movie"
        }
        return "tvshow"
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private static func restoreBackupToMissingTarget(
        targetURL: URL,
        backupURL: URL,
        originalData: Data,
        fileManager: FileManager
    ) -> Bool {
        guard !fileManager.fileExists(atPath: targetURL.path) else { return false }
        guard fileManager.fileExists(atPath: backupURL.path) else { return false }
        do {
            // Copy first so failed verification never consumes the only recovery material.
            try fileManager.copyItem(at: backupURL, to: targetURL)
            guard (try? Data(contentsOf: targetURL)) == originalData else {
                try? fileManager.removeItem(at: targetURL)
                return false
            }
            _ = removeBackupIfPresent(backupURL, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    private static func removeBackupIfPresent(_ backupURL: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
        do {
            try fileManager.removeItem(at: backupURL)
            return nil
        } catch {
            return "NFO 已更新，但临时安全副本清理失败。"
        }
    }
}
