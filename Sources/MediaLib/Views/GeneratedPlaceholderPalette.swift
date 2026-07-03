import MediaLibCore
import SwiftUI

enum MediaPlaceholderMood: String, CaseIterable, Sendable {
    case balanced
    case calm
    case vivid
}

struct MediaPlaceholderSwatch {
    let base: Color
    let depth: Color
    let accent: Color

    init(_ base: UInt32, _ depth: UInt32, _ accent: UInt32) {
        self.base = Color.mediaLibHex(base)
        self.depth = Color.mediaLibHex(depth)
        self.accent = Color.mediaLibHex(accent)
    }
}

enum MediaPlaceholderPalette {
    static let activeMood: MediaPlaceholderMood = .balanced

    static func posterSwatch(for key: String, mediaType: MediaType?) -> MediaPlaceholderSwatch {
        let swatches = posterSwatches(for: activeMood)
        let index = stableIndex(for: "\(mediaType?.rawValue ?? "poster")|\(key)", count: swatches.count)
        return swatches[index]
    }

    static func photoSwatch(for key: String) -> MediaPlaceholderSwatch {
        let swatches = photoSwatches(for: activeMood)
        let index = stableIndex(for: "photo|\(key)", count: swatches.count)
        return swatches[index]
    }

    static func displayGlyph(for title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        for scalar in trimmed.unicodeScalars where !punctuation.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return String(scalar).uppercased()
        }
        return fallback
    }

    private static func stableIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    private static func posterSwatches(for mood: MediaPlaceholderMood) -> [MediaPlaceholderSwatch] {
        switch mood {
        case .balanced:
            return [
                .init(0x0D5B46, 0x061C18, 0x22D3A8),
                .init(0x173B63, 0x0A1628, 0x38BDF8),
                .init(0x143F66, 0x091624, 0x2E90FA),
                .init(0x5C3A08, 0x1F1304, 0xF7C948),
                .init(0x6A1019, 0x260609, 0xFF6B7A),
                .init(0x3D155F, 0x160721, 0xD946EF),
                .init(0x7A4220, 0x2A1408, 0xFF9F45),
                .init(0x223A5F, 0x0D1729, 0x8DB7FF),
                .init(0x5A2440, 0x1E0A15, 0xF9A8D4)
            ]
        case .calm:
            return [
                .init(0x294A5E, 0x0E1C25, 0x7CB8D6),
                .init(0x3B4A38, 0x121A11, 0x9BCB86),
                .init(0x4A3F57, 0x17131E, 0xB9A4D9),
                .init(0x574734, 0x1B150E, 0xD4AF6A),
                .init(0x35524A, 0x101C19, 0x7AC8B9)
            ]
        case .vivid:
            return [
                .init(0x2E90FA, 0x0B2D56, 0x36BFFA),
                .init(0xFF5C8A, 0x4A0718, 0xFFB86B),
                .init(0x22D3A8, 0x064135, 0x8BFFDC),
                .init(0xD946EF, 0x3B0845, 0xFF8CF4),
                .init(0xFF9F45, 0x542707, 0xFFD166)
            ]
        }
    }

    private static func photoSwatches(for mood: MediaPlaceholderMood) -> [MediaPlaceholderSwatch] {
        switch mood {
        case .balanced:
            return [
                .init(0xFFB067, 0xFF5C8A, 0xFFE0A8),
                .init(0x2E90FA, 0x36BFFA, 0xB9E8FF),
                .init(0x22D3A8, 0x148F7A, 0xB8F7E6),
                .init(0xB565D9, 0xD946EF, 0xF5B6FF),
                .init(0xB86B37, 0xEE8A2F, 0xFFD39B),
                .init(0x2B4D7D, 0x172C53, 0xA7C8FF)
            ]
        case .calm:
            return [
                .init(0xA7C4D8, 0x6F8EA6, 0xE6F2FA),
                .init(0xB7C9B0, 0x789169, 0xF1F6E8),
                .init(0xC9BFAE, 0x927F68, 0xFFF4DE),
                .init(0xAFA7C9, 0x746D98, 0xF1EDFF)
            ]
        case .vivid:
            return [
                .init(0xFF8A65, 0xFF5C8A, 0xFFE5A9),
                .init(0x36BFFA, 0x2E90FA, 0xD4F5FF),
                .init(0x22D3A8, 0x55E6C1, 0xD7FFF3),
                .init(0xD946EF, 0x7C3AED, 0xFFD4FF)
            ]
        }
    }
}

struct GeneratedPosterPlaceholderView: View {
    let title: String
    let mediaType: MediaType?

    var body: some View {
        let swatch = MediaPlaceholderPalette.posterSwatch(for: title, mediaType: mediaType)
        let glyph = MediaPlaceholderPalette.displayGlyph(for: title, fallback: fallbackGlyph)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [swatch.base, swatch.depth],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [swatch.accent.opacity(0.34), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: max(size.width, size.height) * 0.92
                )
                RadialGradient(
                    colors: [.white.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.72, y: 0.16),
                    startRadius: 2,
                    endRadius: max(size.width, size.height) * 0.64
                )
                Text(glyph)
                    .font(.system(size: max(size.width, size.height) * 0.72, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.13))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .rotationEffect(.degrees(-8))
                    .offset(x: size.width * 0.24, y: size.height * 0.13)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.26), .black.opacity(0.68)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: max(3, size.height * 0.018)) {
                    Text(title.isEmpty ? fallbackTitle : title)
                        .font(.system(size: max(12, min(17, size.width * 0.082)), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(mediaType?.displayName ?? "媒体")
                        .font(.system(size: max(10, min(13, size.width * 0.058)), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                }
                .shadow(color: .black.opacity(0.30), radius: 8, y: 3)
                .padding(.horizontal, max(12, size.width * 0.075))
                .padding(.bottom, max(12, size.height * 0.070))
            }
        }
        .accessibilityLabel(title.isEmpty ? fallbackTitle : title)
    }

    private var fallbackGlyph: String {
        switch mediaType {
        case .movie: return "影"
        case .tvShow, .episode: return "剧"
        case .anime: return "番"
        case .documentary: return "纪"
        case .variety: return "综"
        case .homeVideo: return "录"
        case .privateCollection: return "藏"
        default: return "片"
        }
    }

    private var fallbackTitle: String {
        mediaType?.displayName ?? "未命名媒体"
    }
}

struct GeneratedPhotoPlaceholderView: View {
    let title: String

    var body: some View {
        let swatch = MediaPlaceholderPalette.photoSwatch(for: title)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [swatch.base, swatch.depth],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [swatch.accent.opacity(0.34), .clear],
                    center: UnitPoint(x: 0.22, y: 0.18),
                    startRadius: 2,
                    endRadius: max(size.width, size.height) * 0.74
                )
                RadialGradient(
                    colors: [.white.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.80, y: 0.32),
                    startRadius: 4,
                    endRadius: max(size.width, size.height) * 0.50
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.18)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityLabel(title.isEmpty ? "照片占位图" : title)
    }
}

private extension Color {
    static func mediaLibHex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
