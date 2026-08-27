import Foundation

public enum SyncConflictValueParseError: LocalizedError, Equatable, Sendable {
    case missingValue
    case invalidBoolean(String)
    case invalidUserRating(String)

    public var errorDescription: String? {
        switch self {
        case .missingValue:
            return "同步冲突缺少可采用的远端值。"
        case .invalidBoolean(let value):
            return "无法识别同步冲突布尔值：\(value)"
        case .invalidUserRating(let value):
            return "无法识别同步冲突用户评级：\(value)"
        }
    }
}

public enum SyncConflictValueParser {
    public static func boolean(_ rawValue: String?) throws -> Bool {
        guard let rawValue else { throw SyncConflictValueParseError.missingValue }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "y", "on":
            return true
        case "false", "0", "no", "n", "off":
            return false
        default:
            throw SyncConflictValueParseError.invalidBoolean(rawValue)
        }
    }

    public static func userRating(_ rawValue: String?) throws -> Double? {
        guard let rawValue else { throw SyncConflictValueParseError.missingValue }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "null", "nil", "none", "unrated", "clear":
            return nil
        default:
            break
        }

        guard let value = Double(trimmed), value.isFinite, value >= 0, value <= 5 else {
            throw SyncConflictValueParseError.invalidUserRating(rawValue)
        }
        return value == 0 ? nil : value
    }

    public static func isUserRatingField(_ fieldName: String) -> Bool {
        switch normalizedFieldName(fieldName) {
        case "rating", "userrating", "user_rating":
            return true
        default:
            return false
        }
    }

    public static func normalizedFieldName(_ fieldName: String) -> String {
        fieldName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}
