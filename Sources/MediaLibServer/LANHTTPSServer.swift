import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HTTPTypes
import MediaLibCore
import NIOCore

/// Maintained TLS transport for browser access from the local network. The
/// application router remains transport-neutral; this type only translates
/// Hummingbird requests and responses at the network boundary.
@available(macOS 14.0, *)
struct LANHTTPSServer {
    private static let maximumRequestBodyLength = 4_096
    private static let maximumConcurrentConnections = 32

    struct Context: RequestContext, RemoteAddressRequestContext {
        var coreContext: CoreRequestContextStorage
        let remoteAddress: SocketAddress?

        init(source: Source) {
            coreContext = .init(source: source)
            remoteAddress = source.channel.remoteAddress
        }
    }

    let application: Application<RouterResponder<Context>>

    init(
        configuration: ServerLaunchConfiguration,
        dataDirectory: URL,
        requestHandler: LocalLoopbackHTTPServer
    ) throws {
        guard configuration.networkAccessMode == .lanHTTPS,
              let publicOrigin = configuration.publicOrigin,
              let publicHost = publicOrigin.host,
              LANIPv4AddressPolicy.isPrivateOrLoopback(publicHost)
        else {
            throw LANHTTPSServerError.missingPrivateHTTPSOrigin
        }

        let identities = try LANTLSIdentityStore(directory: dataDirectory)
            .loadOrCreate(serverName: configuration.serverName, addresses: [publicHost])
        let certificateChain = try NIOSSLCertificate.fromPEMFile(identities.certificate.path)
        let privateKey = try NIOSSLPrivateKey(file: identities.privateKey.path, format: .pem)
        var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        tlsConfiguration.minimumTLSVersion = .tlsv12

        let router = Router(context: Context.self)
        let responder: @Sendable (Request, Context) async throws -> Response = { request, context in
            try await Self.respond(
                to: request,
                context: context,
                handler: requestHandler
            )
        }
        for method in [HTTPRequest.Method.get, .head, .post] {
            router.on("/", method: method, use: responder)
            router.on("/**", method: method, use: responder)
        }
        application = try Application(
            router: router,
            server: .tls(tlsConfiguration: tlsConfiguration),
            configuration: .init(
                address: .hostname("0.0.0.0", port: configuration.port),
                serverName: "MediaLibServer",
                backlog: 64,
                reuseAddress: true,
                availableConnectionsDelegate: MaximumAvailableConnections(Self.maximumConcurrentConnections)
            )
        )
    }

    func run() async throws {
        try await application.run()
    }

    private static func respond(
        to originalRequest: Request,
        context: Context,
        handler: LocalLoopbackHTTPServer
    ) async throws -> Response {
        let clientAddress = context.remoteAddress?.ipAddress ?? "unresolved-client"
        guard LANIPv4AddressPolicy.isPrivateOrLoopback(clientAddress) else {
            return response(from: .forbidden())
        }

        var request = originalRequest
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.collectBody(upTo: maximumRequestBodyLength)
        } catch {
            return response(from: .payloadTooLarge())
        }
        let body = Data(bodyBuffer.readableBytesView)
        let requestHead = rawRequestHead(from: request)
        let localResponse = handler.response(
            for: requestHead,
            body: body,
            clientAddressKey: clientAddress,
            isDirectTLS: true
        )
        return response(from: localResponse)
    }

    static func rawRequestHead(from request: Request) -> String {
        var value = "\(request.method.rawValue) \(request.uri) HTTP/1.1\r\n"
        if let authority = request.head.authority {
            value += "Host: \(authority)\r\n"
        }
        for field in request.headers {
            value += "\(field.name.canonicalName): \(field.value)\r\n"
        }
        value += "\r\n"
        return value
    }

    static func response(from local: LocalHTTPResponse) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = local.contentType
        for line in local.additionalHeaders {
            guard let separator = line.firstIndex(of: ":"),
                  let name = HTTPField.Name(String(line[..<separator]))
            else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers.append(HTTPField(name: name, value: value))
        }
        let contentLength = local.declaredContentLength >= 0 ? local.declaredContentLength : nil
        let body: ResponseBody
        switch local.payload {
        case let .data(data):
            // `ResponseBody(byteBuffer:)` derives Content-Length from the
            // bytes that are actually present. That turns every translated
            // HEAD response into `Content-Length: 0`, even though the local
            // router correctly declared the size of the corresponding GET.
            // Preserve the application-level declaration at the TLS boundary.
            body = .init(contentLength: contentLength) { writer in
                if !data.isEmpty {
                    try await writer.write(ByteBuffer(bytes: data))
                }
                try await writer.finish(nil)
            }
        case let .fileRange(range):
            body = .init(contentLength: contentLength) { writer in
                let handle = try FileHandle(forReadingFrom: range.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.offset))
                var remaining = range.length
                while remaining > 0 {
                    let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
                    guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try await writer.write(ByteBuffer(bytes: data))
                    remaining -= Int64(data.count)
                }
                try await writer.finish(nil)
            }
        case let .remoteRange(range):
            body = callbackBody(contentLength: contentLength) { consume in range.stream(consume) }
        case let .remoteFull(full):
            body = callbackBody(contentLength: contentLength) { consume in full.stream(consume) }
        case let .remuxStream(stream):
            body = callbackBody(contentLength: nil) { consume in stream.stream(consume) }
        }
        return Response(
            status: .init(code: local.statusCode, reasonPhrase: local.reason),
            headers: headers,
            body: body
        )
    }

    /// Adapts the existing synchronous, cancellation-aware media producer to an
    /// async response body. A single buffered chunk bounds memory; an explicit
    /// gate blocks the producer until the async writer consumes that chunk.
    /// Slow clients therefore apply real backpressure without a polling loop.
    private static func callbackBody(
        contentLength: Int?,
        produce: @escaping @Sendable (@escaping (Data) -> Bool) -> Bool
    ) -> ResponseBody {
        ResponseBody(contentLength: contentLength) { writer in
            let flowControl = LANResponseBackpressureGate()
            let sequence = AsyncStream<ByteBuffer>(bufferingPolicy: .bufferingOldest(1)) { continuation in
                continuation.onTermination = { _ in flowControl.terminate() }
                DispatchQueue.global(qos: .userInitiated).async {
                    let completed = produce { data in
                        guard flowControl.acquire() else { return false }
                        let buffer = ByteBuffer(bytes: data)
                        switch continuation.yield(buffer) {
                        case .enqueued:
                            return true
                        case .dropped, .terminated:
                            flowControl.release()
                            return false
                        @unknown default:
                            flowControl.release()
                            return false
                        }
                    }
                    continuation.finish()
                    _ = completed
                }
            }
            for await buffer in sequence {
                do {
                    try await writer.write(buffer)
                    flowControl.release()
                } catch {
                    flowControl.terminate()
                    throw error
                }
            }
            flowControl.terminate()
            try await writer.finish(nil)
        }
    }
}

/// One-slot blocking gate used at the sync-producer/async-writer boundary.
/// `terminate()` is sticky and wakes a producer blocked behind a slow or
/// disconnected client, so cancellation never leaves a media read stranded.
final class LANResponseBackpressureGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var slotAvailable = true
    private var terminated = false

    func acquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !slotAvailable && !terminated {
            condition.wait()
        }
        guard !terminated else { return false }
        slotAvailable = false
        return true
    }

    func release() {
        condition.lock()
        if !terminated {
            slotAvailable = true
            condition.signal()
        }
        condition.unlock()
    }

    func terminate() {
        condition.lock()
        terminated = true
        condition.broadcast()
        condition.unlock()
    }
}

struct LANTLSIdentityStore {
    struct Identity {
        let certificate: URL
        let privateKey: URL
        let certificateAuthority: URL
    }

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("lan-tls", isDirectory: true)
    }

    func loadOrCreate(serverName: String, addresses: [String]) throws -> Identity {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let caCertificate = directory.appendingPathComponent("ca.pem")
        let caKey = directory.appendingPathComponent("ca-key.pem")
        if !fileManager.fileExists(atPath: caCertificate.path) ||
            !fileManager.fileExists(atPath: caKey.path) {
            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                "-days", "3650", "-subj", "/CN=MediaLib Local CA",
                "-keyout", caKey.path, "-out", caCertificate.path
            ])
        }

        let config = directory.appendingPathComponent("server.cnf")
        let request = directory.appendingPathComponent("server.csr")
        let certificate = directory.appendingPathComponent("server.pem")
        let privateKey = directory.appendingPathComponent("server-key.pem")
        let names = Array(Set(addresses.filter(LANIPv4AddressPolicy.isPrivateOrLoopback))).sorted()
        guard !names.isEmpty else { throw LANHTTPSServerError.missingPrivateHTTPSOrigin }
        let altNames = names.enumerated().map { "IP.\($0.offset + 1) = \($0.element)" }.joined(separator: "\n")
        let commonName = serverName.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "=", with: "-")
        let contents = """
        [req]
        distinguished_name = dn
        req_extensions = req_ext
        prompt = no
        [dn]
        CN = \(commonName)
        [req_ext]
        subjectAltName = @alt_names
        extendedKeyUsage = serverAuth
        [alt_names]
        \(altNames)
        DNS.1 = localhost
        """
        try Data(contents.utf8).write(to: config, options: .atomic)
        try runOpenSSL([
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", privateKey.path, "-out", request.path, "-config", config.path
        ])
        try runOpenSSL([
            "x509", "-req", "-in", request.path, "-CA", caCertificate.path,
            "-CAkey", caKey.path, "-CAcreateserial", "-out", certificate.path,
            "-days", "825", "-sha256", "-extensions", "req_ext", "-extfile", config.path
        ])
        for url in [caKey, privateKey] {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return Identity(certificate: certificate, privateKey: privateKey, certificateAuthority: caCertificate)
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            throw LANHTTPSServerError.opensslFailed(
                String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            )
        }
    }
}

enum LANHTTPSServerError: LocalizedError {
    case missingPrivateHTTPSOrigin
    case opensslFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPrivateHTTPSOrigin:
            return "局域网 HTTPS 需要 MEDIALIB_SERVER_PUBLIC_ORIGIN 指向私有 IPv4 HTTPS 地址。"
        case let .opensslFailed(message):
            return "无法生成局域网 TLS 身份：\(message)"
        }
    }
}
