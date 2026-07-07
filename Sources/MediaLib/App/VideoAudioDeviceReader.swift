import Foundation

/// 音频输出设备（mpv `audio-device-list` 条目）。
struct MpvAudioDevice: Identifiable, Hashable, Sendable {
    let name: String
    let deviceDescription: String

    var id: String { name }

    var displayName: String {
        deviceDescription.isEmpty ? name : deviceDescription
    }
}

struct VideoAudioDeviceSnapshot: Equatable {
    let selectedDeviceName: String
    let devices: [MpvAudioDevice]
}

@MainActor
protocol MpvAudioDeviceReadTransport: AnyObject {
    func getString(_ name: String) -> String?
}

extension LibMpvClient: MpvAudioDeviceReadTransport {}

@MainActor
protocol VideoAudioDeviceReading: AnyObject {
    func readSnapshot() -> VideoAudioDeviceSnapshot
}

@MainActor
final class MpvVideoAudioDeviceReader: VideoAudioDeviceReading {
    private let transport: MpvAudioDeviceReadTransport

    init(transport: MpvAudioDeviceReadTransport) {
        self.transport = transport
    }

    func readSnapshot() -> VideoAudioDeviceSnapshot {
        VideoAudioDeviceSnapshot(
            selectedDeviceName: transport.getString("audio-device") ?? "auto",
            devices: Self.parseDeviceListJSON(transport.getString("audio-device-list"))
        )
    }

    static func parseDeviceListJSON(_ json: String?) -> [MpvAudioDevice] {
        guard let json,
              let data = json.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry -> MpvAudioDevice? in
            guard let name = entry["name"] as? String else { return nil }
            return MpvAudioDevice(name: name, deviceDescription: (entry["description"] as? String) ?? "")
        }
    }
}
