import Foundation

public enum SQLiteValue {
    case null
    case text(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public static func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    public static func optionalInt(_ value: Int?) -> SQLiteValue {
        value.map { .int(Int64($0)) } ?? .null
    }

    public static func optionalInt64(_ value: Int64?) -> SQLiteValue {
        value.map(SQLiteValue.int) ?? .null
    }

    public static func optionalDouble(_ value: Double?) -> SQLiteValue {
        value.map(SQLiteValue.double) ?? .null
    }

    public static func optionalDate(_ value: Date?) -> SQLiteValue {
        value.flatMap(DateCoding.string).map(SQLiteValue.text) ?? .null
    }
}
