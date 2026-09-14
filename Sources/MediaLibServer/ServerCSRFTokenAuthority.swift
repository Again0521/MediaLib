import CryptoKit
import Foundation

/// Produces browser CSRF proofs without exposing the process secret. Login uses
/// an HttpOnly, host-only nonce cookie; authenticated pages use the stable
/// login's device identity, so refresh rotation does not invalidate an already open page.
struct ServerCSRFTokenAuthority {
    static let preauthCookieName = "MediaLIBCSRF"

    private let key: SymmetricKey

    init(secret: String) {
        key = SymmetricKey(data: Data(secret.utf8))
    }

    func preauthToken(nonce: String) -> String {
        sign("preauth:\(nonce)")
    }

    func sessionToken(userID: String, deviceID: String) -> String {
        sign("session:\(userID):\(deviceID)")
    }

    func preauthNonce(in requestHead: String) -> String? {
        guard let cookie = httpHeader(named: "Cookie", in: requestHead) else { return nil }
        let values = cookie.split(separator: ";").compactMap { component -> String? in
            let pair = component.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix("\(Self.preauthCookieName)=") else { return nil }
            return String(pair.dropFirst(Self.preauthCookieName.count + 1))
        }
        guard values.count == 1, let nonce = values.first,
              nonce.count == 64,
              nonce.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return nonce.lowercased()
    }

    func newPreauthNonce() -> String {
        ServerRequestSecurityToken.generate()
    }

    func preauthCookieHeader(nonce: String) -> String {
        "Set-Cookie: \(Self.preauthCookieName)=\(nonce); Path=/; HttpOnly; Secure; SameSite=Strict"
    }

    private func sign(_ value: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
