import Foundation

public struct ServerVersionedDocument<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var version: Int
    public var updatedAt: Date?

    public init(value: Value, version: Int, updatedAt: Date?) {
        self.value = value
        self.version = version
        self.updatedAt = updatedAt
    }
}

public enum ServerExperienceRepositoryError: Error, Equatable, Sendable {
    case invalidValue
    case versionConflict(currentVersion: Int)
    case notFound
}

public enum ServerAppearancePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum ServerContentDensity: String, Codable, CaseIterable, Sendable {
    case comfortable, compact
}

public enum ServerMotionPreference: String, Codable, CaseIterable, Sendable {
    case system, reduced
}

public enum ServerPlaybackQuality: String, Codable, CaseIterable, Sendable {
    case auto, original, quality2160p = "2160p", quality1080p = "1080p"
    case quality720p = "720p", quality480p = "480p"
}

public enum ServerSubtitleSelectionMode: String, Codable, CaseIterable, Sendable {
    case off, manual, foreignAudio, always, preferForced
}

public enum ServerSubtitleSDHPreference: String, Codable, CaseIterable, Sendable {
    case automatic, prefer, avoid
}

public enum ServerSubtitleFontFamily: String, Codable, CaseIterable, Sendable {
    case system, sansSerif, serif, monospace
}

public enum ServerSubtitleEdgeStyle: String, Codable, CaseIterable, Sendable {
    case none, shadow, outline
}

public struct ServerSubtitleStyle: Codable, Equatable, Sendable {
    public var fontFamily: ServerSubtitleFontFamily
    public var fontScalePercent: Int
    public var fontWeight: Int
    public var textColor: String
    public var backgroundOpacityPercent: Int
    public var edgeStyle: ServerSubtitleEdgeStyle
    public var verticalPositionPercent: Int

    public init(
        fontFamily: ServerSubtitleFontFamily = .system,
        fontScalePercent: Int = 100,
        fontWeight: Int = 600,
        textColor: String = "#FFFFFF",
        backgroundOpacityPercent: Int = 55,
        edgeStyle: ServerSubtitleEdgeStyle = .shadow,
        verticalPositionPercent: Int = 88
    ) {
        self.fontFamily = fontFamily
        self.fontScalePercent = min(max(fontScalePercent, 75), 200)
        self.fontWeight = min(max(fontWeight, 400), 800)
        self.textColor = Self.normalizedColor(textColor) ?? "#FFFFFF"
        self.backgroundOpacityPercent = min(max(backgroundOpacityPercent, 0), 100)
        self.edgeStyle = edgeStyle
        self.verticalPositionPercent = min(max(verticalPositionPercent, 60), 95)
    }

    public var isValid: Bool {
        (75...200).contains(fontScalePercent)
            && (400...800).contains(fontWeight)
            && Self.normalizedColor(textColor) != nil
            && (0...100).contains(backgroundOpacityPercent)
            && (60...95).contains(verticalPositionPercent)
    }

    private static func normalizedColor(_ value: String) -> String? {
        let upper = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count == 7, upper.first == "#",
              upper.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return upper
    }
}

/// 账号级默认值。默认实例刻意复现升级前网页行为。
public struct ServerUserExperiencePreferences: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var interfaceLanguage: String?
    public var appearance: ServerAppearancePreference
    public var defaultLandingPath: String
    public var homeSectionOrder: [String]
    public var hiddenHomeSections: [String]
    public var contentDensity: ServerContentDensity
    public var motion: ServerMotionPreference
    public var autoplayNext: Bool
    public var resumePlayback: Bool
    public var defaultQuality: ServerPlaybackQuality
    public var remoteBitrateMbps: Int?
    public var preferredAudioLanguage: String?
    public var preferredSubtitleLanguage: String?
    public var subtitleMode: ServerSubtitleSelectionMode
    public var subtitleSDHPreference: ServerSubtitleSDHPreference
    public var rememberTrackSelections: Bool
    public var subtitleStyle: ServerSubtitleStyle

    public init(
        schemaVersion: Int = Self.schemaVersion,
        interfaceLanguage: String? = nil,
        appearance: ServerAppearancePreference = .system,
        defaultLandingPath: String = "/",
        homeSectionOrder: [String] = [],
        hiddenHomeSections: [String] = [],
        contentDensity: ServerContentDensity = .comfortable,
        motion: ServerMotionPreference = .system,
        autoplayNext: Bool = true,
        resumePlayback: Bool = true,
        defaultQuality: ServerPlaybackQuality = .auto,
        remoteBitrateMbps: Int? = nil,
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        subtitleMode: ServerSubtitleSelectionMode = .foreignAudio,
        subtitleSDHPreference: ServerSubtitleSDHPreference = .automatic,
        rememberTrackSelections: Bool = true,
        subtitleStyle: ServerSubtitleStyle = ServerSubtitleStyle()
    ) {
        self.schemaVersion = schemaVersion
        self.interfaceLanguage = Self.normalizedLanguage(interfaceLanguage)
        self.appearance = appearance
        self.defaultLandingPath = Self.allowedLandingPaths.contains(defaultLandingPath) ? defaultLandingPath : "/"
        self.homeSectionOrder = Self.normalizedSectionIDs(homeSectionOrder)
        self.hiddenHomeSections = Self.normalizedSectionIDs(hiddenHomeSections)
        self.contentDensity = contentDensity
        self.motion = motion
        self.autoplayNext = autoplayNext
        self.resumePlayback = resumePlayback
        self.defaultQuality = defaultQuality
        self.remoteBitrateMbps = remoteBitrateMbps.map { min(max($0, 1), 200) }
        self.preferredAudioLanguage = Self.normalizedLanguage(preferredAudioLanguage)
        self.preferredSubtitleLanguage = Self.normalizedLanguage(preferredSubtitleLanguage)
        self.subtitleMode = subtitleMode
        self.subtitleSDHPreference = subtitleSDHPreference
        self.rememberTrackSelections = rememberTrackSelections
        self.subtitleStyle = subtitleStyle
    }

    public var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && Self.allowedLandingPaths.contains(defaultLandingPath)
            && homeSectionOrder.count <= 32 && hiddenHomeSections.count <= 32
            && Set(homeSectionOrder).count == homeSectionOrder.count
            && Set(hiddenHomeSections).count == hiddenHomeSections.count
            && (remoteBitrateMbps.map { (1...200).contains($0) } ?? true)
            && interfaceLanguage == Self.normalizedLanguage(interfaceLanguage)
            && preferredAudioLanguage == Self.normalizedLanguage(preferredAudioLanguage)
            && preferredSubtitleLanguage == Self.normalizedLanguage(preferredSubtitleLanguage)
            && subtitleStyle.isValid
    }

    private static let allowedLandingPaths: Set<String> = [
        "/", "/watching", "/category/video", "/music/songs", "/albums"
    ]

    private static func normalizedSectionIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 64,
                  value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  seen.insert(value).inserted, seen.count <= 32 else { return nil }
            return value
        }
    }

    public static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let subtags = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (2...35).contains(value.count),
              let language = subtags.first,
              (2...8).contains(language.count), language.allSatisfy(\.isLetter),
              subtags.dropFirst().allSatisfy({
                  (1...8).contains($0.count) && $0.allSatisfy({ $0.isLetter || $0.isNumber })
              }) else { return nil }
        let pieces = value.split(separator: "-").map(String.init)
        return pieces.enumerated().map { index, piece in
            if index == 0 { return piece.lowercased() }
            if piece.count == 4, piece.allSatisfy(\.isLetter) { return piece.capitalized }
            if piece.count == 2, piece.allSatisfy(\.isLetter) { return piece.uppercased() }
            return piece.lowercased()
        }.joined(separator: "-")
    }
}

/// 当前设备只覆盖确实具有设备差异的选项；nil 表示继承账号值。
public struct ServerDeviceExperienceOverrides: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var appearance: ServerAppearancePreference?
    public var contentDensity: ServerContentDensity?
    public var motion: ServerMotionPreference?
    public var defaultQuality: ServerPlaybackQuality?
    public var remoteBitrateMbps: Int?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        appearance: ServerAppearancePreference? = nil,
        contentDensity: ServerContentDensity? = nil,
        motion: ServerMotionPreference? = nil,
        defaultQuality: ServerPlaybackQuality? = nil,
        remoteBitrateMbps: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.contentDensity = contentDensity
        self.motion = motion
        self.defaultQuality = defaultQuality
        self.remoteBitrateMbps = remoteBitrateMbps.map { min(max($0, 1), 200) }
    }

    public var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && (remoteBitrateMbps.map { (1...200).contains($0) } ?? true)
    }
}

public enum ServerTrackOverrideScope: String, Codable, CaseIterable, Sendable {
    case media, series
}

public struct ServerTrackSelectionOverride: Codable, Equatable, Sendable {
    public var scope: ServerTrackOverrideScope
    public var scopeID: String
    public var audioFingerprint: String?
    public var subtitleFingerprint: String?
    public var subtitleDisabled: Bool
    public var updatedAt: Date

    public init(
        scope: ServerTrackOverrideScope,
        scopeID: String,
        audioFingerprint: String? = nil,
        subtitleFingerprint: String? = nil,
        subtitleDisabled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.scope = scope
        self.scopeID = scopeID
        self.audioFingerprint = Self.normalizedFingerprint(audioFingerprint)
        self.subtitleFingerprint = Self.normalizedFingerprint(subtitleFingerprint)
        self.subtitleDisabled = subtitleDisabled
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        !scopeID.isEmpty && scopeID.utf8.count <= 512 && !scopeID.contains("/")
            && (audioFingerprint?.utf8.count ?? 0) <= 256
            && (subtitleFingerprint?.utf8.count ?? 0) <= 256
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return String(value.prefix(256))
    }
}

public struct ServerUserPolicy: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var playbackAllowed: Bool
    public var remoteAccessAllowed: Bool
    public var directPlayAllowed: Bool
    public var remuxAllowed: Bool
    public var transcodeAllowed: Bool
    public var downloadAllowed: Bool
    public var maximumConcurrentStreams: Int
    public var remoteBitrateLimitMbps: Int?
    public var accessStartMinute: Int?
    public var accessEndMinute: Int?
    public var maximumContentRating: String?

    public init(
        schemaVersion: Int = Self.schemaVersion,
        playbackAllowed: Bool = true,
        remoteAccessAllowed: Bool = true,
        directPlayAllowed: Bool = true,
        remuxAllowed: Bool = true,
        transcodeAllowed: Bool = true,
        // The legacy server relied on the existing `downloadMedia` permission alone.
        // Keep that behavior after migration; a policy can only narrow it further.
        downloadAllowed: Bool = true,
        maximumConcurrentStreams: Int = 2,
        remoteBitrateLimitMbps: Int? = nil,
        accessStartMinute: Int? = nil,
        accessEndMinute: Int? = nil,
        maximumContentRating: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.playbackAllowed = playbackAllowed
        self.remoteAccessAllowed = remoteAccessAllowed
        self.directPlayAllowed = directPlayAllowed
        self.remuxAllowed = remuxAllowed
        self.transcodeAllowed = transcodeAllowed
        self.downloadAllowed = downloadAllowed
        self.maximumConcurrentStreams = min(max(maximumConcurrentStreams, 1), 8)
        self.remoteBitrateLimitMbps = remoteBitrateLimitMbps.map { min(max($0, 1), 200) }
        self.accessStartMinute = accessStartMinute
        self.accessEndMinute = accessEndMinute
        self.maximumContentRating = maximumContentRating.map { String($0.prefix(32)) }
    }

    public var isValid: Bool {
        schemaVersion == Self.schemaVersion && (1...8).contains(maximumConcurrentStreams)
            && (remoteBitrateLimitMbps.map { (1...200).contains($0) } ?? true)
            && (accessStartMinute.map { (0..<1440).contains($0) } ?? true)
            && (accessEndMinute.map { (0..<1440).contains($0) } ?? true)
            && ((accessStartMinute == nil) == (accessEndMinute == nil))
            && (maximumContentRating?.utf8.count ?? 0) <= 32
    }
}

public enum ServerTranscodeEngine: String, Codable, CaseIterable, Sendable {
    case automatic, videoToolbox, software
}

public struct ServerOperationalSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var transcodeEngine: ServerTranscodeEngine
    public var maximumTranscodeSessions: Int
    public var defaultRemoteBitrateMbps: Int
    public var temporaryStorageLimitGB: Int
    public var minimumFreeDiskGB: Int
    public var sessionIdleMinutes: Int
    public var telemetryRetentionHours: Int

    public init(
        schemaVersion: Int = Self.schemaVersion,
        transcodeEngine: ServerTranscodeEngine = .automatic,
        maximumTranscodeSessions: Int = 2,
        defaultRemoteBitrateMbps: Int = 20,
        temporaryStorageLimitGB: Int = 20,
        minimumFreeDiskGB: Int = 5,
        sessionIdleMinutes: Int = 15,
        telemetryRetentionHours: Int = 24
    ) {
        self.schemaVersion = schemaVersion
        self.transcodeEngine = transcodeEngine
        self.maximumTranscodeSessions = min(max(maximumTranscodeSessions, 1), 4)
        self.defaultRemoteBitrateMbps = min(max(defaultRemoteBitrateMbps, 1), 200)
        self.temporaryStorageLimitGB = min(max(temporaryStorageLimitGB, 1), 1_024)
        self.minimumFreeDiskGB = min(max(minimumFreeDiskGB, 1), 1_024)
        self.sessionIdleMinutes = min(max(sessionIdleMinutes, 5), 240)
        self.telemetryRetentionHours = min(max(telemetryRetentionHours, 1), 168)
    }

    public var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && (1...4).contains(maximumTranscodeSessions)
            && (1...200).contains(defaultRemoteBitrateMbps)
            && (1...1_024).contains(temporaryStorageLimitGB)
            && (1...1_024).contains(minimumFreeDiskGB)
            && (5...240).contains(sessionIdleMinutes)
            && (1...168).contains(telemetryRetentionHours)
    }
}

public enum ServerJobState: String, Codable, CaseIterable, Sendable {
    case queued, running, succeeded, failed, cancelled
}

public struct ServerJob: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var state: ServerJobState
    public var progress: Double
    public var resultCode: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var requestedByUserID: String?

    public init(
        id: String = UUID().uuidString,
        kind: String,
        state: ServerJobState = .queued,
        progress: Double = 0,
        resultCode: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        requestedByUserID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.resultCode = resultCode.map { String($0.prefix(64)) }
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.requestedByUserID = requestedByUserID
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128
            && !kind.isEmpty && kind.utf8.count <= 64
            && (0...1).contains(progress)
            && (resultCode?.utf8.count ?? 0) <= 64
    }
}
