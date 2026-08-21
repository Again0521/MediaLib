import Foundation

/// 为缺失封面生成稳定的「系统页面」色组。
///
/// 参考页不是用任意 HSL 色相生成占位图，而是把媒体映射到一组精确的
/// `g1/g2/accent` 值；这也是 PosterCard、歌曲封面与专辑封面的共同输入。
/// 这里保留相同的确定性（同一 ID 总是同一组），但不再产生参考页之外的
/// 蓝紫渐变。
enum ServerWebArtworkPalette {
    enum Context {
        case poster
        case music
    }

    private struct Palette {
        let g1: String
        let g2: String
        let accent: String
    }

    /// Fallback artwork is a placeholder, so it must never out-shout the real
    /// covers beside it in a grid.  Both ramps are deliberately deep, low-chroma
    /// duotones for two reasons: a placeholder that reads as quiet material sits
    /// naturally next to a photographic poster, and the title is drawn in white
    /// over the gradient — the previous saturated ramp put white text over
    /// `#FFCC00`, which was unreadable.
    ///
    /// The server derives a stable entry from an opaque media identifier; no
    /// title, source path or user data reaches the fallback artwork.
    private static let posterPalettes: [Palette] = [
        .init(g1: "#232F52", g2: "#465A8C", accent: "#7E93C9"),
        .init(g1: "#1B3532", g2: "#376761", accent: "#6FA69E"),
        .init(g1: "#3C2140", g2: "#6E3A5D", accent: "#A8749A"),
        .init(g1: "#33261A", g2: "#66452B", accent: "#A5814F"),
        .init(g1: "#1F2A34", g2: "#3D5468", accent: "#7690A6"),
        .init(g1: "#3E2626", g2: "#734040", accent: "#B0797A"),
        .init(g1: "#1F2E25", g2: "#3F5C4A", accent: "#7BA189"),
        .init(g1: "#282443", g2: "#4E4A78", accent: "#8B86BE"),
        .init(g1: "#372815", g2: "#69512C", accent: "#A88B52"),
        .init(g1: "#1B2830", g2: "#355062", accent: "#6E8C9F")
    ]

    /// Music covers are square and appear in dense rows, so their ramp leans a
    /// half-step warmer than the poster ramp.  That keeps a mixed page legible
    /// without giving the two placeholder families different visual weight.
    private static let musicPalettes: [Palette] = [
        .init(g1: "#35203C", g2: "#6B3A5C", accent: "#A5779A"),
        .init(g1: "#132C38", g2: "#2C6070", accent: "#6BA0B0"),
        .init(g1: "#3A2717", g2: "#7A4F2A", accent: "#B58A5A"),
        .init(g1: "#1A2942", g2: "#3A5480", accent: "#7B92C0"),
        .init(g1: "#2E1E36", g2: "#5F3B73", accent: "#9C7CAE"),
        .init(g1: "#122B24", g2: "#2A6049", accent: "#6EA28C"),
        .init(g1: "#3E1E2C", g2: "#7C3B4F", accent: "#B47B8B"),
        .init(g1: "#222B42", g2: "#455280", accent: "#8290BE"),
        .init(g1: "#382713", g2: "#725228", accent: "#AC8C4F"),
        .init(g1: "#182529", g2: "#325055", accent: "#6D9096")
    ]

    private static func index(for seed: String, context: Context) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let palettes: [Palette]
        switch context {
        case .poster: palettes = posterPalettes
        case .music: palettes = musicPalettes
        }
        return Int(hash % UInt32(palettes.count))
    }

    /// Attribute value for an artwork element.  This deliberately replaces
    /// style attributes: the web server's CSP keeps `style-src-attr` disabled,
    /// while the same-origin stylesheet below supplies the exact palette.
    static func token(for seed: String, context: Context = .poster) -> String {
        let prefix: String
        switch context {
        case .music: prefix = "music"
        case .poster: prefix = "poster"
        }
        return "\(prefix)-\(index(for: seed, context: context))"
    }

    /// Emits the same bucketing function for the page scripts.
    ///
    /// 三个脚本此前各自抄了一份这个哈希，而且抄错了：`library.js` 与
    /// `collections.js` 写死的桶数是 13/8，服务端真正的桶数是
    /// \(posterPalettes.count)/\(musicPalettes.count)——同一个条目，服务端渲染的
    /// 卡片和脚本补进来的卡片会落到两种颜色上。它们还用 `charCodeAt`（UTF-16 码
    /// 元）而服务端数的是 UTF-8 字节，于是非 ASCII 的 id 连桶都对不上。
    ///
    /// 交给 Swift 生成之后，桶数与哈希各只有一份。`TextEncoder` 让 JS 数的也是
    /// UTF-8 字节。
    ///
    /// 生成的作用域内可用：`medialibArtworkPalette(seed, context)`。
    static var scriptHelper: String {
        """
        const MEDIALIB_PALETTE_BUCKETS = { poster: \(posterPalettes.count), music: \(musicPalettes.count) };
        const MEDIALIB_PALETTE_ENCODER = typeof TextEncoder === 'function' ? new TextEncoder() : null;
        const medialibArtworkPalette = (seed, context) => {
          const kind = context === 'music' ? 'music' : 'poster';
          const text = String(seed || '');
          const bytes = MEDIALIB_PALETTE_ENCODER
            ? MEDIALIB_PALETTE_ENCODER.encode(text)
            : Array.from(text, character => character.charCodeAt(0) & 0xff);
          var hash = 2166136261;
          for (const byte of bytes) {
            hash ^= byte;
            hash = Math.imul(hash, 16777619) >>> 0;
          }
          return `${kind}-${hash % MEDIALIB_PALETTE_BUCKETS[kind]}`;
        };
        """
    }

    /// Bucket counts, for the tests that check the scripts have not drifted.
    static var bucketCounts: (poster: Int, music: Int) {
        (posterPalettes.count, musicPalettes.count)
    }

    static var css: String {
        let posterRules = posterPalettes.enumerated().map { index, palette in
            "[data-artwork-palette=\"poster-\(index)\"]{--artwork-g1:\(palette.g1);--artwork-g2:\(palette.g2);--artwork-accent:\(palette.accent);}"
        }
        let musicRules = musicPalettes.enumerated().map { index, palette in
            "[data-artwork-palette=\"music-\(index)\"]{--artwork-g1:\(palette.g1);--artwork-g2:\(palette.g2);--artwork-accent:\(palette.accent);}"
        }
        return (posterRules + musicRules).joined()
    }
}
