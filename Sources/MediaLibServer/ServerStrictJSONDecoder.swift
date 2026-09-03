import Foundation

/// Strict object decoding for security-sensitive browser mutations.
///
/// `Decodable` intentionally ignores unknown keys by default. Administrative and playback
/// mutations instead require an explicit top-level and nested key contract so a client cannot
/// silently opt into future authority by submitting fields an older server does not understand.
enum ServerStrictJSONDecoder {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from body: Data,
        allowedKeys: Set<String>,
        nestedAllowedKeys: [String: Set<String>] = [:]
    ) -> Value? {
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys)
        else { return nil }
        for (key, keys) in nestedAllowedKeys {
            guard let nested = object[key] else { continue }
            if nested is NSNull { continue }
            guard let dictionary = nested as? [String: Any],
                  Set(dictionary.keys).isSubset(of: keys)
            else { return nil }
        }
        return try? JSONDecoder().decode(type, from: body)
    }
}
