import Foundation

@MainActor
protocol MpvLoopCommandTransport: AnyObject {
    func setDouble(_ name: String, _ value: Double)
    func setString(_ name: String, _ value: String)
}

extension LibMpvClient: MpvLoopCommandTransport {}

@MainActor
protocol VideoLoopCommandEngine: AnyObject {
    func setLoopCurrentItem(_ enabled: Bool)
    func setABLoop(start: Double?, end: Double?)
}

@MainActor
final class MpvVideoLoopCommandEngine: VideoLoopCommandEngine {
    private let transport: MpvLoopCommandTransport

    init(transport: MpvLoopCommandTransport) {
        self.transport = transport
    }

    func setLoopCurrentItem(_ enabled: Bool) {
        transport.setString("loop-file", enabled ? "inf" : "no")
    }

    func setABLoop(start: Double?, end: Double?) {
        if let start {
            transport.setDouble("ab-loop-a", start)
        } else {
            transport.setString("ab-loop-a", "no")
        }
        if let end {
            transport.setDouble("ab-loop-b", end)
        } else {
            transport.setString("ab-loop-b", "no")
        }
    }
}
