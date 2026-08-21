import Foundation

/// ASS / SSA（Advanced SubStation Alpha）到 WebVTT 的转换。
///
/// `<track>` 只认 WebVTT，而中日韩资料库里的外挂字幕**绝大多数是 `.ass`**。此前
/// 服务端把 ASS 整类挡在门外（`supportedExtensions` 只有 vtt/srt），理由是"带样式
/// 与定位，直接丢字幕文本会产出一份错位的字幕"。那个理由只对"直接丢文本"成立：
/// ASS 里真正决定观感的三件事——换行、字形强调、屏幕位置——在 WebVTT 里都有对应
/// 表达，逐条翻译过去得到的是一份**位置正确**的字幕，而不是一堆糊在底部的文字。
///
/// 明确不翻译的部分（它们没有 WebVTT 对应物，硬转只会更糟）：逐字卡拉 OK
/// （`\k`）、矢量绘图（`\p1`，整块丢弃而不是把坐标数字当台词显示）、逐帧变换
/// （`\t`/`\move`）、字体与颜色。这些只影响装饰，不影响"读者能不能在正确的位置
/// 读到正确的一句话"。
enum ServerASSSubtitle {
    /// 一行 `Dialogue:` 翻译出来的东西。
    private struct Cue {
        let start: Double
        let end: Double
        let settings: String
        let text: String
    }

    /// ASS 的 numpad 对齐值（1-9）。V4（旧 SSA）用另一套编码，见 `alignment(from:legacy:)`。
    private struct Alignment {
        let horizontal: Int   // 1 左 2 中 3 右
        let vertical: Int     // 1 底 2 中 3 顶

        static let bottomCenter = Alignment(horizontal: 2, vertical: 1)

        /// WebVTT cue 设置串。位置用百分比而不是默认值：`align:start` 单独出现时
        /// 文本框仍然居中，只是框内左对齐——那不是 `\an1` 想表达的"贴左边"。
        var cueSettings: String {
            var pieces: [String] = []
            switch vertical {
            case 3: pieces.append("line:5%")
            case 2: pieces.append("line:45%")
            default: break   // 底部是 WebVTT 的默认位置，不必声明
            }
            switch horizontal {
            case 1: pieces.append(contentsOf: ["position:10%", "align:start"])
            case 3: pieces.append(contentsOf: ["position:90%", "align:end"])
            default: pieces.append("align:center")
            }
            return pieces.joined(separator: " ")
        }
    }

    /// 转换入口。解析不出任何一条对白就返回 nil——交一份只有 `WEBVTT` 头的空轨道，
    /// 浏览器会显示"有字幕但一句话都没有"，比明确的失败更难排查。
    static func webVTT(fromASS text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var styleAlignments: [String: Alignment] = [:]
        var section = ""
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var cues: [Cue] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") , line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let descriptor = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let payload = String(line[line.index(after: separator)...])
            if section.contains("styles") {
                switch descriptor {
                case "format":
                    styleFormat = fields(payload).map { $0.lowercased() }
                case "style":
                    guard let (name, alignment) = style(
                        payload, format: styleFormat, legacy: !section.contains("v4+")
                    ) else { continue }
                    styleAlignments[name] = alignment
                default:
                    continue
                }
            } else if section.contains("events") {
                switch descriptor {
                case "format":
                    eventFormat = fields(payload).map { $0.lowercased() }
                case "dialogue":
                    guard let cue = dialogue(
                        payload, format: eventFormat, styles: styleAlignments
                    ) else { continue }
                    cues.append(cue)
                default:
                    // `Comment:` 是被作者关掉的行，不是台词。
                    continue
                }
            }
        }
        guard !cues.isEmpty else { return nil }
        // WebVTT 要求 cue 按开始时间不降序出现。ASS 里"字幕 + 屏幕字"经常交错，
        // 原顺序并不满足这一点。
        let ordered = cues.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var output = "WEBVTT\n\n"
        for cue in ordered.prefix(maximumCueCount) {
            let settings = cue.settings.isEmpty ? "" : " \(cue.settings)"
            output += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\(settings)\n\(cue.text)\n\n"
        }
        return output
    }

    /// 单个文件允许翻译的对白条数上限。卡拉 OK 逐字轨会把一句歌词拆成上百条，
    /// 一份文件因此可以有几十万行；上限让"畸形/超大字幕"不能变成内存压力。
    static let maximumCueCount = 20_000

    /// 是不是一份 ASS/SSA。扩展名可能骗人（`.srt` 里装的是 ASS 的情况很常见），
    /// 所以判断走内容。
    static func looksLikeASS(_ text: String) -> Bool {
        let head = text.prefix(4_096).lowercased()
        return head.contains("[script info]") || head.contains("[v4+ styles]") || head.contains("[v4 styles]")
    }

    // MARK: - 行解析

    private static func fields(_ payload: String) -> [String] {
        payload.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func style(
        _ payload: String, format: [String], legacy: Bool
    ) -> (String, Alignment)? {
        let values = fields(payload)
        guard let nameIndex = format.firstIndex(of: "name"), nameIndex < values.count else { return nil }
        let name = values[nameIndex]
        guard !name.isEmpty else { return nil }
        guard let alignmentIndex = format.firstIndex(of: "alignment"),
              alignmentIndex < values.count,
              let raw = Int(values[alignmentIndex])
        else { return (name, .bottomCenter) }
        return (name, alignment(from: raw, legacy: legacy) ?? .bottomCenter)
    }

    /// V4+ 用 numpad 编码（1 左下 … 9 右上）。旧 V4 用 1/2/3 表示左中右，
    /// 加 4 表示顶部、加 8 表示居中——两套编码的数值范围重叠，必须按段落头区分。
    private static func alignment(from raw: Int, legacy: Bool) -> Alignment? {
        if legacy {
            let horizontal = ((raw - 1) % 4) + 1
            guard (1...3).contains(horizontal) else { return nil }
            let vertical: Int
            switch raw {
            case 5...7: vertical = 3
            case 9...11: vertical = 2
            case 1...3: vertical = 1
            default: return nil
            }
            return Alignment(horizontal: horizontal, vertical: vertical)
        }
        guard (1...9).contains(raw) else { return nil }
        let horizontal = ((raw - 1) % 3) + 1
        let vertical = raw <= 3 ? 1 : (raw <= 6 ? 2 : 3)
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private static func dialogue(
        _ payload: String, format: [String], styles: [String: Alignment]
    ) -> Cue? {
        guard let startIndex = format.firstIndex(of: "start"),
              let endIndex = format.firstIndex(of: "end"),
              let textIndex = format.firstIndex(of: "text")
        else { return nil }
        // 正文里几乎一定含逗号，所以只能切出 `textIndex` 个分隔符，剩下的整段是正文。
        let pieces = payload.split(
            separator: ",", maxSplits: textIndex, omittingEmptySubsequences: false
        ).map(String.init)
        guard pieces.count > textIndex,
              startIndex < pieces.count, endIndex < pieces.count,
              let start = seconds(pieces[startIndex].trimmingCharacters(in: .whitespaces)),
              let end = seconds(pieces[endIndex].trimmingCharacters(in: .whitespaces)),
              end > start
        else { return nil }
        let styleName = format.firstIndex(of: "style").flatMap { index -> String? in
            index < pieces.count ? pieces[index].trimmingCharacters(in: .whitespaces) : nil
        }
        var alignment = styleName.flatMap { styles[$0] } ?? .bottomCenter
        let raw = pieces[textIndex]
        if let override = overrideAlignment(in: raw) { alignment = override }
        guard let text = plainText(from: raw) else { return nil }
        return Cue(start: start, end: end, settings: alignment.cueSettings, text: text)
    }

    /// `{\an5}` / 旧式 `{\a6}` 覆盖本行的样式对齐。取最后一个——ASS 的语义是
    /// 后面的覆盖前面的。
    private static func overrideAlignment(in text: String) -> Alignment? {
        var result: Alignment?
        var scanner = Substring(text)
        while let range = scanner.range(of: "\\a", options: .caseInsensitive) {
            var rest = scanner[range.upperBound...]
            var legacy = true
            if rest.first == "n" || rest.first == "N" {
                legacy = false
                rest = rest.dropFirst()
            }
            let digits = rest.prefix(while: { $0.isNumber })
            if let value = Int(digits), let parsed = alignment(from: value, legacy: legacy) {
                result = parsed
            }
            scanner = rest
        }
        return result
    }

    /// ASS 正文 → WebVTT 正文。
    ///
    /// 覆盖标签块整块处理：`\p1` 起的矢量绘图直到 `\p0` 为止全部丢掉（那些坐标
    /// 数字不是台词）；`\i`/`\b`/`\u` 翻成对应标签；其余覆盖指令删除。
    private static func plainText(from raw: String) -> String? {
        var output = ""
        var italic = false
        var bold = false
        var underline = false
        var drawing = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "{" {
                guard let close = raw[index...].firstIndex(of: "}") else { break }
                let block = raw[raw.index(after: index)..<close]
                for (tag, enable) in inlineToggles(in: block) {
                    switch tag {
                    case "i" where enable != italic:
                        output += enable ? "<i>" : "</i>"
                        italic = enable
                    case "b" where enable != bold:
                        output += enable ? "<b>" : "</b>"
                        bold = enable
                    case "u" where enable != underline:
                        output += enable ? "<u>" : "</u>"
                        underline = enable
                    case "p":
                        drawing = enable
                    default:
                        continue
                    }
                }
                index = raw.index(after: close)
                continue
            }
            if character == "\\", raw.index(after: index) < raw.endIndex {
                let next = raw[raw.index(after: index)]
                if next == "N" || next == "n" {
                    if !drawing { output += "\n" }
                    index = raw.index(index, offsetBy: 2)
                    continue
                }
                if next == "h" {
                    if !drawing { output += "\u{00A0}" }
                    index = raw.index(index, offsetBy: 2)
                    continue
                }
            }
            if !drawing { output.append(escaped(character)) }
            index = raw.index(after: index)
        }
        if italic { output += "</i>" }
        if bold { output += "</b>" }
        if underline { output += "</u>" }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纯绘图行翻译完是空的——它本来就不该出现在字幕里。
        guard !trimmed.isEmpty else { return nil }
        // 一条 cue 不能含空行：WebVTT 用空行分隔 cue，正文里出现一个就把后半句
        // 变成下一条 cue 的时间轴。
        return trimmed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 一个覆盖块里所有 `\i1` / `\b0` / `\p1` 形式的开关。`\b700`（字重）按"开"处理，
    /// 那正是它的效果。
    private static func inlineToggles(in block: Substring) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var scanner = block
        while let slash = scanner.firstIndex(of: "\\") {
            let rest = scanner[scanner.index(after: slash)...]
            guard let tag = rest.first, "ibup".contains(tag) else {
                scanner = rest
                continue
            }
            let digits = rest.dropFirst().prefix(while: { $0.isNumber })
            // `\be1`（边缘模糊）不是粗体，`\bord` 也不是。只有紧跟数字才算开关。
            if !digits.isEmpty, let value = Int(digits) {
                result.append((String(tag), value > 0))
            }
            scanner = rest.dropFirst()
        }
        return result
    }

    private static func escaped(_ character: Character) -> String {
        switch character {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        default: return String(character)
        }
    }

    /// ASS 时间是 `H:MM:SS.cc`（厘秒）。
    private static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2].replacingOccurrences(of: ",", with: ".")),
              hours >= 0, minutes >= 0, seconds >= 0,
              hours < 100, minutes < 60, seconds < 60
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func timestamp(_ value: Double) -> String {
        let total = max(0, value)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let milliseconds = Int((total - Double(Int(total))) * 1000 + 0.5)
        return String(
            format: "%02d:%02d:%02d.%03d",
            hours, minutes, seconds, min(milliseconds, 999)
        )
    }
}
