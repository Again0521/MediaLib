import Foundation

/// 外挂字幕文件的发现、命名解析与格式归一。
///
/// 网页播放器只能消费 WebVTT（`<track>` 不认 SRT/ASS），但用户媒体目录里最常见的
/// 反而是 `.srt`。此前服务端只收 `.vtt`，于是绝大多数资料库在网页上"没有字幕"，
/// 而同一批文件在客户端是能用的。这里把 SRT 在服务端转成 VTT，并从文件名里解出
/// 语言，让播放器可以按浏览器语言选默认轨。
enum ServerSubtitleSidecar {
    /// `.vtt`、`.srt` 与 `.ass`/`.ssa`。
    ///
    /// ASS 从前被整类挡在这里，理由是"直接丢字幕文本会产出一份错位的字幕"。那句
    /// 话只对"丢文本"成立：换行、字形强调与屏幕位置在 WebVTT 里都有对应表达，
    /// 逐条翻译过去得到的是一份位置正确的字幕（见 `ServerASSSubtitle`）。而在中日韩
    /// 资料库里 `.ass` 恰恰是最常见的外挂格式，挡掉它等于这些库在网页上没有字幕。
    static let supportedExtensions: Set<String> = ["vtt", "srt", "ass", "ssa"]

    /// 文件名里那些不是语言的修饰词。它们要进标签，但不能被当成语言码。
    private static let modifierTokens: Set<String> = [
        "forced", "sdh", "cc", "hi", "default", "full", "sign", "songs", "commentary"
    ]

    /// 常见语言标记 → BCP-47。资料库里的写法非常杂（`chs`/`sc`/`zh-CN`/`简体`），
    /// 而 `<track srclang>` 想要 BCP-47；映射不到就返回 nil，宁可不声明语言，
    /// 也不要声明一个错的——错的语言会让"按浏览器语言选默认轨"选错。
    private static let languageMap: [String: String] = [
        "zh": "zh", "chi": "zh", "zho": "zh",
        "chs": "zh-Hans", "sc": "zh-Hans", "gb": "zh-Hans", "cn": "zh-Hans",
        "zh-cn": "zh-Hans", "zh-hans": "zh-Hans", "简体": "zh-Hans", "简中": "zh-Hans",
        "cht": "zh-Hant", "tc": "zh-Hant", "big5": "zh-Hant", "hk": "zh-Hant",
        "tw": "zh-Hant", "zh-tw": "zh-Hant", "zh-hk": "zh-Hant", "zh-hant": "zh-Hant",
        "繁體": "zh-Hant", "繁体": "zh-Hant", "繁中": "zh-Hant",
        "en": "en", "eng": "en", "en-us": "en", "en-gb": "en", "english": "en",
        "ja": "ja", "jpn": "ja", "jp": "ja", "japanese": "ja",
        "ko": "ko", "kor": "ko", "korean": "ko",
        "fr": "fr", "fre": "fr", "fra": "fr",
        "de": "de", "ger": "de", "deu": "de",
        "es": "es", "spa": "es", "it": "it", "ita": "it",
        "ru": "ru", "rus": "ru", "pt": "pt", "por": "pt",
        "th": "th", "tha": "th", "vi": "vi", "vie": "vi", "ar": "ar", "ara": "ar"
    ]

    struct Descriptor: Equatable {
        let language: String?
        let label: String
    }

    /// 从 `影片名.zh-Hans.forced.srt` 这样的文件名里解出语言与展示标签。
    ///
    /// 只看媒体主名之后的那几段：`stem` 相同则整份文件名没有额外信息，退回序号标签。
    static func descriptor(mediaStem: String, subtitleFileName: String, fallbackIndex: Int) -> Descriptor {
        let fileStem = (subtitleFileName as NSString).deletingPathExtension
        var tokens: [String] = []
        if fileStem.count > mediaStem.count, fileStem.hasPrefix(mediaStem + ".") {
            let suffix = String(fileStem.dropFirst(mediaStem.count + 1))
            tokens = suffix.split(whereSeparator: { $0 == "." || $0 == "_" }).map(String.init)
        }
        var language: String?
        var labelParts: [String] = []
        for token in tokens {
            let key = token.lowercased()
            if language == nil, let mapped = languageMap[key] {
                language = mapped
                labelParts.append(token)
            } else if modifierTokens.contains(key) {
                labelParts.append(token)
            } else if !token.isEmpty {
                labelParts.append(token)
            }
        }
        let label = labelParts.isEmpty
            ? "字幕 \(fallbackIndex + 1)"
            : String(labelParts.joined(separator: " · ").prefix(80))
        return Descriptor(language: language, label: label)
    }

    /// 把字幕文件字节解码成文本。
    ///
    /// SRT 在中文资料库里经常不是 UTF-8。顺序尝试 UTF-8（含 BOM）、GB18030、
    /// Big5、Latin-1；全都失败就放弃，不要把乱码当字幕交出去。
    static func decodeText(_ data: Data) -> String? {
        var payload = data
        // UTF-8 BOM 会变成正文第一个字符，进而让 `WEBVTT` 头部校验失败。
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) { payload = payload.dropFirst(3) }
        if let text = String(data: payload, encoding: .utf8) { return text }
        let fallbacks: [UInt32] = [
            0x0631,             // GB18030
            0x0A03,             // Big5
            UInt32(CFStringEncodings.big5.rawValue)
        ]
        for raw in fallbacks {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(raw))
            if let text = String(data: payload, encoding: encoding) { return text }
        }
        return String(data: payload, encoding: .isoLatin1)
    }

    /// SRT → WebVTT。
    ///
    /// 只做两件必需的事：加 `WEBVTT` 头，把时间轴里的逗号小数点换成点号。
    /// 序号行原样保留——WebVTT 把它当作 cue 标识符，合法且能帮助排查。
    /// 不改动正文：SRT 里的 `<i>`/`<b>` 恰好也是 VTT 支持的标签。
    static func webVTT(fromSRT text: String) -> String {
        var output = "WEBVTT\n\n"
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            output += convertedTimingLine(rawLine) + "\n"
        }
        return output
    }

    /// 时间轴行形如 `00:00:01,000 --> 00:00:02,000`（可带定位参数）。
    /// 只在确实是时间轴行时替换逗号，避免把正文里的逗号一起改掉。
    private static func convertedTimingLine(_ line: String) -> String {
        guard line.contains("-->") else { return line }
        var converted = ""
        converted.reserveCapacity(line.count)
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            guard character == "," else { converted.append(character); continue }
            // 仅当逗号夹在数字之间（`01,000`）时才视为小数点。
            let previousIsDigit = index > 0 && characters[index - 1].isNumber
            let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
            converted.append(previousIsDigit && nextIsDigit ? "." : character)
        }
        return converted
    }

    /// 已经是 VTT 的原样返回；SRT 转换后返回。两者都保证以 `WEBVTT` 开头，
    /// 否则浏览器会静默拒绝整条轨道。
    static func webVTTPayload(from data: Data, pathExtension: String) -> Data? {
        guard let text = decodeText(data) else { return nil }
        return webVTTPayload(fromText: text, pathExtension: pathExtension)
    }

    /// 已解码文本的同一条归一路径。内嵌轨道与远程服务器给回来的字节走这里，
    /// 它们没有"文件扩展名"可依，只有一个格式提示。
    static func webVTTPayload(fromText text: String, pathExtension: String) -> Data? {
        // 内容嗅探优先于扩展名：已经是 VTT 的原样返回。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            return Data(text.utf8)
        }
        // `.srt` 里装着 ASS、`.ass` 里装着 SRT 的文件在资料库里都真实存在，所以
        // 先按内容判一次 ASS，再退回扩展名。判错的代价是一整轨字幕错乱。
        if ServerASSSubtitle.looksLikeASS(text) {
            return ServerASSSubtitle.webVTT(fromASS: text).map { Data($0.utf8) }
        }
        switch pathExtension.lowercased() {
        case "srt":
            return Data(webVTT(fromSRT: text).utf8)
        case "ass", "ssa":
            // 扩展名说是 ASS 但内容嗅探没认出来：多半是缺 `[Script Info]` 头的
            // 残缺文件。仍然按 ASS 解析一次，解析不出对白就放弃，不按 SRT 硬转。
            return ServerASSSubtitle.webVTT(fromASS: text).map { Data($0.utf8) }
        default:
            // 未知扩展名不做任何猜测——把一份不认识的文本按 SRT 硬转，产出的是
            // 一份看起来合法、实际错乱的字幕。
            return nil
        }
    }
}
