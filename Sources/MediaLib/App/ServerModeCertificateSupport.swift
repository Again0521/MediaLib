import Foundation
import Security

enum ServerModeCertificateSupport {
    static func certificateAuthorityURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("lan-tls", isDirectory: true)
            .appendingPathComponent("ca.pem", isDirectory: false)
    }

    static func certificateDERData(fromPEM data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ServerModeCertificateError.invalidCertificate
        }
        let body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: body), !decoded.isEmpty else {
            throw ServerModeCertificateError.invalidCertificate
        }
        return decoded
    }

    static func exportCertificate(from source: URL, to destination: URL) throws {
        let pem = try Data(contentsOf: source)
        let der = try certificateDERData(fromPEM: pem)
        try der.write(to: destination, options: .atomic)
    }
}

final class ServerModePinnedTrustDelegate: NSObject, URLSessionDelegate {
    private let expectedHost: String
    private let anchor: SecCertificate

    init(expectedHost: String, certificateAuthorityURL: URL) throws {
        let pem = try Data(contentsOf: certificateAuthorityURL)
        let der = try ServerModeCertificateSupport.certificateDERData(fromPEM: pem)
        guard let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ServerModeCertificateError.invalidCertificate
        }
        self.expectedHost = expectedHost
        self.anchor = anchor
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == expectedHost,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum ServerModeCertificateError: LocalizedError {
    case invalidCertificate

    var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            return "局域网信任证书无效，请关闭并重新开启局域网访问后重试。"
        }
    }
}
