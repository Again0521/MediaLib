import CryptoKit
import Foundation
import LocalAuthentication

enum PrivacyLockError: LocalizedError {
    case invalidPIN
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .invalidPIN:
            return "请输入 4 到 8 位数字密码。"
        case .storageFailed:
            return "隐私密码保存失败。"
        }
    }
}

struct PrivacyLockService {
    static func isValidPIN(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy(\.isNumber)
    }

    func hasPIN() -> Bool {
        credentials() != nil
    }

    func setPIN(_ pin: String) throws {
        guard Self.isValidPIN(pin) else {
            throw PrivacyLockError.invalidPIN
        }
        let salt = try randomData(length: 16)
        let payload = PrivacyPINPayload(salt: salt, digest: digest(pin: pin, salt: salt))
        let data = try JSONEncoder().encode(payload)
        // 文件存储（见 RemoteCredentialStore 同样原因：避免 ad-hoc 更新后的钥匙串密码弹窗）。
        guard let url = fileURL() else {
            throw PrivacyLockError.storageFailed
        }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PrivacyLockError.storageFailed
        }
    }

    func verify(pin: String) -> Bool {
        guard Self.isValidPIN(pin), let payload = credentials() else {
            return false
        }
        return digest(pin: pin, salt: payload.salt) == payload.digest
    }

    func removePIN() {
        if let url = fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func canUseBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func unlockWithBiometrics() async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "输入密码"
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "解锁 MediaLIB 保险库"
            ) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func credentials() -> PrivacyPINPayload? {
        // 只读文件，绝不读/删 keychain（旧 keychain ACL 会在 ad-hoc 更新后触发系统密码框）。
        if let url = fileURL(),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(PrivacyPINPayload.self, from: data) {
            return payload
        }
        return nil
    }

    private func fileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("MediaLib", isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("privacy-pin.json")
    }

    private func randomData(length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        var data = Data()
        while data.count < length {
            let key = SymmetricKey(size: .bits256)
            data.append(key.withUnsafeBytes { Data($0) })
        }
        return data.prefix(length)
    }

    private func digest(pin: String, salt: Data) -> Data {
        var data = salt
        data.append(Data(pin.utf8))
        return Data(SHA256.hash(data: data))
    }
}

private struct PrivacyPINPayload: Codable {
    var salt: Data
    var digest: Data
}
