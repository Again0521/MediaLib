import Foundation

struct MpvTrack: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case audio
        case subtitle = "sub"
        case unknown
    }

    let id: Int
    let type: Kind
    let title: String?
    let language: String?
    let codec: String?
    let isSelected: Bool
    let isExternal: Bool
    let externalFilename: String?

    var displayName: String {
        var parts: [String] = []
        if let language, !language.isEmpty {
            parts.append(language.uppercased())
        }
        if let title, !title.isEmpty {
            parts.append(title)
        }
        if let codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if parts.isEmpty {
            switch type {
            case .audio:
                parts.append("音轨 \(id)")
            case .subtitle:
                parts.append("字幕 \(id)")
            case .unknown:
                parts.append("轨道 \(id)")
            }
        }
        if isExternal {
            parts.append("外挂")
        }
        return parts.joined(separator: " · ")
    }

    func withSelection(_ selected: Bool) -> MpvTrack {
        MpvTrack(
            id: id,
            type: type,
            title: title,
            language: language,
            codec: codec,
            isSelected: selected,
            isExternal: isExternal,
            externalFilename: externalFilename
        )
    }
}
