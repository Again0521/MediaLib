import Foundation

public enum StableID {
    public static func make(prefix: String, value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)_\(String(hash, radix: 16))"
    }
}
