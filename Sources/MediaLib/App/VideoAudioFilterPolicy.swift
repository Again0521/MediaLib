import Foundation
import MediaLibCore

struct VideoAudioFilterProperty: Equatable {
    var name: String
    var value: String
}

enum VideoAudioFilterPolicy {
    private static let equalizerFrequencies: [Double] = [60, 230, 910, 3600, 14000]

    static func property(enabled: Bool, preset: MusicEqualizerPreset) -> VideoAudioFilterProperty {
        VideoAudioFilterProperty(name: "af", value: filter(enabled: enabled, preset: preset))
    }

    static func filter(enabled: Bool, preset: MusicEqualizerPreset) -> String {
        guard enabled, !preset.isFlat else {
            return ""
        }
        let entries = zip(equalizerFrequencies, preset.gainsDB)
            .map { String(format: "entry(%.0f,%.1f)", $0, $1) }
            .joined(separator: ";")
        return "lavfi=[firequalizer=gain_entry='\(entries)']"
    }
}
