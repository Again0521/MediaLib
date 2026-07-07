import Foundation

public enum DateCoding {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }

    public static func date(from string: String?) -> Date? {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return formatter.date(from: trimmed)
    }
}
