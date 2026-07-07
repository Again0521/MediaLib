import Foundation

public struct PlaybackMarker: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case chapter
        case intro
        case credits
        case bookmark

        public var title: String {
            switch self {
            case .chapter: "章节"
            case .intro: "片头"
            case .credits: "片尾"
            case .bookmark: "书签"
            }
        }
    }

    public enum Origin: String, Codable, Sendable {
        case embedded
        case manual
        case automatic
    }

    public enum ReviewStatus: String, Codable, Sendable {
        case accepted
        case pending
        case rejected
    }

    public var id: String
    public var mediaID: String
    public var kind: Kind
    public var title: String
    public var startTime: Double
    public var endTime: Double?
    public var origin: Origin
    public var reviewStatus: ReviewStatus
    public var detectorIdentifier: String?
    public var confidence: Double?
    public var createdAt: Date
    public var updatedAt: Date

    static func normalizedTime(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    static func normalizedEndTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(value, 0)
    }

    static func normalizedConfidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    public init(
        id: String = UUID().uuidString,
        mediaID: String,
        kind: Kind,
        title: String,
        startTime: Double,
        endTime: Double? = nil,
        origin: Origin = .manual,
        reviewStatus: ReviewStatus = .accepted,
        detectorIdentifier: String? = nil,
        confidence: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.kind = kind
        self.title = title
        self.startTime = Self.normalizedTime(startTime)
        self.endTime = Self.normalizedEndTime(endTime)
        self.origin = origin
        self.reviewStatus = reviewStatus
        self.detectorIdentifier = detectorIdentifier
        self.confidence = Self.normalizedConfidence(confidence)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isCompleteRange: Bool {
        guard let endTime else { return false }
        return endTime > startTime
    }

    public func contains(_ time: Double) -> Bool {
        guard time.isFinite else { return false }
        guard isCompleteRange, let endTime else { return false }
        return time >= startTime && time < endTime
    }

    public var isPendingReview: Bool {
        origin == .automatic && reviewStatus == .pending
    }

    public var isAcceptedForPlayback: Bool {
        origin != .automatic || reviewStatus == .accepted
    }
}

extension PlaybackMarker {
    private enum CodingKeys: String, CodingKey {
        case id
        case mediaID
        case kind
        case title
        case startTime
        case endTime
        case origin
        case reviewStatus
        case detectorIdentifier
        case confidence
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = Self.decodeStringBackedEnum(
            PlaybackMarker.Kind.self,
            forKey: .kind,
            in: container,
            defaultValue: .chapter
        )
        let origin = Self.decodeStringBackedEnum(
            PlaybackMarker.Origin.self,
            forKey: .origin,
            in: container,
            defaultValue: .manual
        )
        let reviewStatus = Self.decodeStringBackedEnum(
            PlaybackMarker.ReviewStatus.self,
            forKey: .reviewStatus,
            in: container,
            defaultValue: .accepted
        )

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            mediaID: try container.decodeIfPresent(String.self, forKey: .mediaID) ?? "",
            kind: kind,
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? kind.title,
            startTime: try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0,
            endTime: try container.decodeIfPresent(Double.self, forKey: .endTime),
            origin: origin,
            reviewStatus: reviewStatus,
            detectorIdentifier: try container.decodeIfPresent(String.self, forKey: .detectorIdentifier),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    private static func decodeStringBackedEnum<T: RawRepresentable>(
        _ type: T.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = try? container.decodeIfPresent(String.self, forKey: key) else {
            return defaultValue
        }
        return T(rawValue: rawValue) ?? defaultValue
    }
}
