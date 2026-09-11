import Foundation

/// A deliberately redacted reason for terminating a media body. These values
/// contain no media identifier, filesystem path, upstream URL, or credential,
/// so they can safely cross the HTTP transport boundary as thrown errors.
enum ServerStreamFailure: Equatable, Sendable {
    case upstreamTransport
    case upstreamRejected
    case invalidUpstreamRange
    case upstreamTimedOut
    case shortRead(expectedByteLength: Int64)
    case producerUnavailable
    case producerExited(exitCode: Int32)
    case emptyOutput
}

struct ServerStreamError: Error, Equatable, Sendable {
    let failure: ServerStreamFailure
    let deliveredByteLength: Int64
}

/// Shared completion contract for loopback and TLS media writers.
enum ServerStreamTermination: Equatable, Sendable {
    case completed(deliveredByteLength: Int64)
    case cancelled(deliveredByteLength: Int64)
    case failed(ServerStreamFailure, deliveredByteLength: Int64)

    var deliveredByteLength: Int64 {
        switch self {
        case let .completed(value), let .cancelled(value), let .failed(_, value):
            return value
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var error: ServerStreamError? {
        guard case let .failed(failure, deliveredByteLength) = self else { return nil }
        return ServerStreamError(failure: failure, deliveredByteLength: deliveredByteLength)
    }
}

/// One synchronous producer plus the operation that interrupts its underlying
/// URLSession task or child process. The wrapper is intentionally transport
/// neutral and retains no source URL or command line.
struct ServerBodyStream: @unchecked Sendable {
    typealias Consumer = @Sendable (Data) -> Bool
    typealias Producer = @Sendable (@escaping Consumer) -> ServerStreamTermination

    private let cancelOperation: @Sendable () -> Void
    private let producer: Producer

    init(
        cancel: @escaping @Sendable () -> Void,
        produce: @escaping Producer
    ) {
        cancelOperation = cancel
        producer = produce
    }

    func cancel() {
        cancelOperation()
    }

    func run(_ consume: @escaping Consumer) -> ServerStreamTermination {
        producer(consume)
    }
}
