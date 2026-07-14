import CArgon2
import Foundation

public enum ServerPasswordHasherError: Error, LocalizedError, Equatable, Sendable {
    case passwordLengthInvalid
    case invalidParameters
    case hashingFailed
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .passwordLengthInvalid: "密码长度必须为 12 到 1024 个 UTF-8 字节。"
        case .invalidParameters: "Argon2id 参数无效。"
        case .hashingFailed: "无法生成密码凭据。"
        case .randomGenerationFailed: "无法生成密码盐值。"
        }
    }
}

/// 直接封装 PHC 官方 Argon2 参考实现。默认参数为 Argon2id v=19、64 MiB、3 次迭代、
/// 单 lane、16 字节随机盐和 32 字节输出；编码串自带参数与盐，可在后续校准时平滑升级。
public struct ServerPasswordHasher: Sendable {
    public let iterations: UInt32
    public let memoryCostKib: UInt32
    public let parallelism: UInt32
    public let saltLength: Int
    public let hashLength: Int
    private let randomBytes: @Sendable (Int) -> [UInt8]

    public init(
        iterations: UInt32 = 3,
        memoryCostKib: UInt32 = 65_536,
        parallelism: UInt32 = 1,
        saltLength: Int = 16,
        hashLength: Int = 32,
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = { count in
            var generator = SystemRandomNumberGenerator()
            return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
    ) throws {
        guard iterations >= 1,
              parallelism >= 1,
              memoryCostKib >= 8 * parallelism,
              saltLength >= 8,
              hashLength >= 16
        else {
            throw ServerPasswordHasherError.invalidParameters
        }
        self.iterations = iterations
        self.memoryCostKib = memoryCostKib
        self.parallelism = parallelism
        self.saltLength = saltLength
        self.hashLength = hashLength
        self.randomBytes = randomBytes
    }

    public func hash(password: String) throws -> String {
        var passwordBytes = Array(password.utf8)
        defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
        guard (12...1024).contains(passwordBytes.count) else {
            throw ServerPasswordHasherError.passwordLengthInvalid
        }
        var salt = randomBytes(saltLength)
        defer { salt.resetBytes(in: 0..<salt.count) }
        guard salt.count == saltLength else { throw ServerPasswordHasherError.randomGenerationFailed }

        let encodedLength = Int(argon2_encodedlen(
            iterations,
            memoryCostKib,
            parallelism,
            UInt32(salt.count),
            UInt32(hashLength),
            Argon2_id
        ))
        guard encodedLength > 1, encodedLength <= 1024 else {
            throw ServerPasswordHasherError.invalidParameters
        }
        var encoded = [CChar](repeating: 0, count: encodedLength)
        let result = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                argon2id_hash_encoded(
                    iterations,
                    memoryCostKib,
                    parallelism,
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    saltBuffer.baseAddress,
                    saltBuffer.count,
                    hashLength,
                    &encoded,
                    encoded.count
                )
            }
        }
        guard result == ARGON2_OK.rawValue else { throw ServerPasswordHasherError.hashingFailed }
        return String(cString: encoded)
    }

    public func verify(password: String, encodedHash: String) -> Bool {
        guard encodedHash.hasPrefix("$argon2id$"), encodedHash.utf8.count <= 1024 else { return false }
        var passwordBytes = Array(password.utf8)
        defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
        guard passwordBytes.count <= 1024 else { return false }
        return passwordBytes.withUnsafeBytes { passwordBuffer in
            encodedHash.withCString { encoded in
                argon2id_verify(encoded, passwordBuffer.baseAddress, passwordBuffer.count) == ARGON2_OK.rawValue
            }
        }
    }

}

/// 原始会话令牌使用系统 CSPRNG 生成，数据库仅保存 BLAKE2b-256 摘要。
/// BLAKE2 实现与 Argon2 官方参考源码来自同一固定发布版。
public enum ServerTokenSecurity {
    public static func generateToken(byteCount: Int = 32) -> String {
        precondition(byteCount >= 32)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }

    public static func digest(_ token: String) -> String? {
        let input = Array(token.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = input.withUnsafeBytes { buffer in
            medialib_blake2b_256(buffer.baseAddress, buffer.count, &output)
        }
        guard result == 0 else { return nil }
        return output.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
