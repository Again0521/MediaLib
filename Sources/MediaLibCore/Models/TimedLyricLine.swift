import Foundation

// 从 MediaLib(GUI) 下沉到 MediaLibCore（跨端预备，报告 04/13）：歌词数据模型 + 时间→行定位 + 逐字时序/脚本分析。
// 全部为纯文本/Foundation 逻辑，无 SwiftUI/AppKit 依赖。解析器 LyricSourceParser（依赖 TTML/YRC/AVFoundation）
// 仍留在 GUI；TimedLyricLine.parse(_:) 作为 GUI extension 调用它。仅搬位置 + 放开为 public，算法语义零变化。

public enum LyricTimingSource: String, Codable, Hashable, Sendable {
    case exact
    case aligned
    case estimated

    public var rank: Int {
        switch self {
        case .exact: return 3
        case .aligned: return 2
        case .estimated: return 1
        }
    }

    public var displayTitle: String {
        switch self {
        case .exact: return "原词逐字"
        case .aligned: return "音频对齐"
        case .estimated: return "估算同步"
        }
    }

    public var systemImage: String {
        switch self {
        case .exact: return "waveform.badge.checkmark"
        case .aligned: return "waveform.path.ecg"
        case .estimated: return "textformat.abc"
        }
    }

    public var helpText: String {
        switch self {
        case .exact: return "歌词源自带逐字时间戳"
        case .aligned: return "已根据本地音频分析生成逐字时间"
        case .estimated: return "按歌词文字权重估算逐字进度"
        }
    }
}

public struct TimedLyricSegment: Identifiable, Hashable {
    public let id = UUID()
    public var time: Double
    public var text: String
    public var source: LyricTimingSource = .exact
    public var durationHint: Double? = nil

    public init(time: Double, text: String, source: LyricTimingSource = .exact, durationHint: Double? = nil) {
        self.time = time
        self.text = text
        self.source = source
        self.durationHint = durationHint
    }
}

public struct LyricPlaybackPosition: Equatable {
    public var lineIndex: Int
    public var startTime: Double
    public var endTime: Double
    public var referenceTime: Double

    public init(lineIndex: Int, startTime: Double, endTime: Double, referenceTime: Double) {
        self.lineIndex = lineIndex
        self.startTime = startTime
        self.endTime = endTime
        self.referenceTime = referenceTime
    }
}

public struct LyricHighlightTiming: Equatable {
    public var progress: Double
    public var activeOriginalIndex: Int
    public var headOriginalPosition: Double
    public var activeWeightRatio: Double
    public var progressBucket: Int

    public init(progress: Double, activeOriginalIndex: Int, headOriginalPosition: Double, activeWeightRatio: Double, progressBucket: Int) {
        self.progress = progress
        self.activeOriginalIndex = activeOriginalIndex
        self.headOriginalPosition = headOriginalPosition
        self.activeWeightRatio = activeWeightRatio
        self.progressBucket = progressBucket
    }

    public static func estimated(line: TimedLyricLine, progress: Double) -> LyricHighlightTiming {
        LyricHighlightEstimator.timing(for: line.text, progress: progress)
    }
}

public struct LyricTimingUnit {
    public var originalIndices: [Int]
    public var weight: Double

    public init(originalIndices: [Int], weight: Double) {
        self.originalIndices = originalIndices
        self.weight = weight
    }
}

public enum LyricHighlightEstimator {
    public static let latinWordScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "'’-"))

    public static func timing(for text: String, progress rawProgress: Double) -> LyricHighlightTiming {
        let progress = min(max(rawProgress, 0), 1)
        let units = timingUnits(for: text)
        guard !units.isEmpty else {
            let lastIndex = max(Array(text).count - 1, 0)
            return LyricHighlightTiming(
                progress: progress,
                activeOriginalIndex: lastIndex,
                headOriginalPosition: Double(lastIndex),
                activeWeightRatio: 1,
                progressBucket: 0
            )
        }

        let totalWeight = units.reduce(0) { $0 + $1.weight }
        let averageWeight = max(totalWeight / Double(max(units.count, 1)), 0.001)
        let target = progress * max(totalWeight, 0.001)
        var accumulated = 0.0

        for (unitIndex, unit) in units.enumerated() {
            let next = accumulated + unit.weight
            if target <= next || unitIndex == units.indices.last {
                let local = min(max((target - accumulated) / max(unit.weight, 0.001), 0), 1)
                let indexInUnit = min(max(Int((local * Double(unit.originalIndices.count)).rounded(.down)), 0), unit.originalIndices.count - 1)
                let activeIndex = unit.originalIndices[indexInUnit]
                let head = Double(unit.originalIndices.first ?? activeIndex)
                    + (Double(unit.originalIndices.last ?? activeIndex) - Double(unit.originalIndices.first ?? activeIndex)) * local
                return LyricHighlightTiming(
                    progress: progress,
                    activeOriginalIndex: activeIndex,
                    headOriginalPosition: head,
                    activeWeightRatio: unit.weight / averageWeight,
                    progressBucket: Int((progress * 48).rounded())
                )
            }
            accumulated = next
        }

        let last = units.last?.originalIndices.last ?? max(Array(text).count - 1, 0)
        return LyricHighlightTiming(
            progress: progress,
            activeOriginalIndex: last,
            headOriginalPosition: Double(last),
            activeWeightRatio: units.last.map { $0.weight / averageWeight } ?? 1,
            progressBucket: 48
        )
    }

    public static func conservativeDuration(for text: String) -> Double {
        let count = max(timingUnits(for: text).count, 1)
        return min(max(Double(count) * 0.24 + 0.65, 2.2), 6.8)
    }

    public static func timingUnits(for text: String) -> [LyricTimingUnit] {
        var units: [LyricTimingUnit] = []
        var latinWordIndices: [Int] = []

        func flushLatinWord() {
            guard !latinWordIndices.isEmpty else { return }
            units.append(LyricTimingUnit(originalIndices: latinWordIndices, weight: 1.08))
            latinWordIndices.removeAll(keepingCapacity: true)
        }

        for (index, character) in Array(text).enumerated() {
            if character.isLyricTimingIgnored {
                flushLatinWord()
                continue
            }

            if character.isLatinLyricWordCharacter {
                latinWordIndices.append(index)
            } else {
                flushLatinWord()
                units.append(LyricTimingUnit(originalIndices: [index], weight: 1.0))
            }
        }
        flushLatinWord()

        if let lastIndex = units.indices.last {
            units[lastIndex].weight *= 1.16
        }
        return units
    }
}

public extension Character {
    var isLyricTimingIgnored: Bool {
        unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
            CharacterSet.punctuationCharacters.contains(scalar) ||
            CharacterSet.symbols.contains(scalar)
        }
    }

    var isLatinLyricWordCharacter: Bool {
        guard !unicodeScalars.isEmpty else { return false }
        return unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x02AF && LyricHighlightEstimator.latinWordScalars.contains(scalar)
        }
    }
}

public struct LyricScriptProfile {
    public let hanCount: Int
    public let hiraganaCount: Int
    public let katakanaCount: Int
    public let hangulCount: Int
    public let latinCount: Int

    public init(text: String) {
        var hanCount = 0
        var hiraganaCount = 0
        var katakanaCount = 0
        var hangulCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if scalar.properties.isIdeographic || Self.isCJKUnifiedIdeograph(value) {
                hanCount += 1
            } else if Self.isHiragana(value) {
                hiraganaCount += 1
            } else if Self.isKatakana(value) {
                katakanaCount += 1
            } else if Self.isHangul(value) {
                hangulCount += 1
            } else if Self.isLatin(value) {
                latinCount += 1
            }
        }

        self.hanCount = hanCount
        self.hiraganaCount = hiraganaCount
        self.katakanaCount = katakanaCount
        self.hangulCount = hangulCount
        self.latinCount = latinCount
    }

    private var kanaCount: Int { hiraganaCount + katakanaCount }
    private var cjkCount: Int { hanCount + kanaCount + hangulCount }

    private var isLikelyJapanese: Bool {
        kanaCount > 0 && cjkCount >= 2
    }

    private var isLikelyChineseTranslation: Bool {
        hanCount >= 2 && kanaCount == 0 && hangulCount == 0
    }

    public var isLikelyJapaneseOriginalLine: Bool {
        isLikelyJapanese
    }

    public var isLikelyChineseTranslationLine: Bool {
        isLikelyChineseTranslation
    }

    public func isJapaneseChineseTranslationPair(with other: LyricScriptProfile) -> Bool {
        (isLikelyJapanese && other.isLikelyChineseTranslation) ||
        (other.isLikelyJapanese && isLikelyChineseTranslation)
    }

    private static func isCJKUnifiedIdeograph(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value) ||
        (0x3400...0x4DBF).contains(value) ||
        (0x20000...0x2A6DF).contains(value) ||
        (0x2A700...0x2B73F).contains(value) ||
        (0x2B740...0x2B81F).contains(value) ||
        (0x2B820...0x2CEAF).contains(value) ||
        (0xF900...0xFAFF).contains(value)
    }

    private static func isHiragana(_ value: UInt32) -> Bool {
        (0x3040...0x309F).contains(value)
    }

    private static func isKatakana(_ value: UInt32) -> Bool {
        (0x30A0...0x30FF).contains(value) ||
        (0x31F0...0x31FF).contains(value) ||
        (0xFF66...0xFF9D).contains(value)
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0xAC00...0xD7AF).contains(value) ||
        (0x1100...0x11FF).contains(value) ||
        (0x3130...0x318F).contains(value)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        (0x0041...0x005A).contains(value) ||
        (0x0061...0x007A).contains(value) ||
        (0x00C0...0x024F).contains(value)
    }
}

public struct TimedLyricLine: Identifiable, Hashable {
    public let id = UUID()
    public var time: Double
    public var text: String
    public var segments: [TimedLyricSegment] = []
    public var source: LyricTimingSource = .estimated
    private static let duplicateTimestampTolerance = 0.000_5

    public init(time: Double, text: String, segments: [TimedLyricSegment] = [], source: LyricTimingSource = .estimated) {
        self.time = time
        self.text = text
        self.segments = segments
        self.source = source
    }

    public static func activeIndex(in lines: [TimedLyricLine], at time: Double) -> Int? {
        playbackPosition(in: lines, at: time)?.lineIndex
    }

    public static func playbackPosition(in lines: [TimedLyricLine], at time: Double) -> LyricPlaybackPosition? {
        guard !lines.isEmpty else { return nil }
        let targetTime = max(time, 0)
        var lowerBound = 0
        var upperBound = lines.count - 1
        var active = 0
        while lowerBound <= upperBound {
            let mid = (lowerBound + upperBound) / 2
            if lines[mid].time <= targetTime {
                active = mid
                lowerBound = mid + 1
            } else {
                upperBound = mid - 1
            }
        }
        while active > 0 && abs(lines[active].time - lines[active - 1].time) <= duplicateTimestampTolerance {
            active -= 1
        }
        active = preferredPlaybackAnchorIndex(in: lines, clusterStart: active)
        let start = lines[active].time
        let end = endTime(in: lines, index: active)
        return LyricPlaybackPosition(
            lineIndex: active,
            startTime: start,
            endTime: end,
            referenceTime: min(max(targetTime, start), end)
        )
    }

    public static func firstTimestampIndex(after time: Double, in lines: [TimedLyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let targetTime = max(time, 0)
        var lowerBound = 0
        var upperBound = lines.count - 1
        var candidate: Int?
        while lowerBound <= upperBound {
            let mid = (lowerBound + upperBound) / 2
            if lines[mid].time > targetTime {
                candidate = mid
                upperBound = mid - 1
            } else {
                lowerBound = mid + 1
            }
        }
        while let index = candidate,
              lines.indices.contains(index - 1),
              lines[index - 1].time > targetTime,
              abs(lines[index].time - lines[index - 1].time) <= duplicateTimestampTolerance {
            candidate = index - 1
        }
        return candidate
    }

    public static func progress(in lines: [TimedLyricLine], index: Int, currentTime: Double) -> Double {
        guard let active = activeIndex(in: lines, at: currentTime),
              active == index,
              lines.indices.contains(index) else { return 0 }
        let start = lines[index].time
        let end = endTime(in: lines, index: index)
        let duration = max(end - start, 0.8)
        return min(max((currentTime - start) / duration, 0), 1)
    }

    public static func endTime(in lines: [TimedLyricLine], index: Int) -> Double {
        let start = lines[index].time
        if let nextIndex = nextDistinctTimestampIndex(after: index, in: lines) {
            return max(lines[nextIndex].time, start + 0.8)
        }

        let previousDurations = lines.indices
            .filter { $0 < index }
            .compactMap { previousIndex -> Double? in
                guard let nextIndex = nextDistinctTimestampIndex(after: previousIndex, in: lines),
                      nextIndex <= index else { return nil }
                return max(lines[nextIndex].time - lines[previousIndex].time, 0.8)
            }
            .suffix(4)
        let average = previousDurations.isEmpty
            ? nil
            : previousDurations.reduce(0, +) / Double(previousDurations.count)
        let conservative = LyricHighlightEstimator.conservativeDuration(for: lines[index].text)
        let duration = max(min(max(average ?? conservative, 1.8), 7.4), conservative)
        return start + duration
    }

    public static func sharesTimestampCluster(_ lhs: TimedLyricLine, _ rhs: TimedLyricLine) -> Bool {
        abs(lhs.time - rhs.time) <= duplicateTimestampTolerance
    }

    private static func preferredPlaybackAnchorIndex(in lines: [TimedLyricLine], clusterStart: Int) -> Int {
        guard lines.indices.contains(clusterStart) else { return clusterStart }
        let timestamp = lines[clusterStart].time
        var cluster: [Int] = []
        var candidate = clusterStart
        while lines.indices.contains(candidate),
              abs(lines[candidate].time - timestamp) <= duplicateTimestampTolerance {
            cluster.append(candidate)
            candidate += 1
        }
        guard cluster.count > 1 else { return clusterStart }

        let profiles = cluster.map { LyricScriptProfile(text: lines[$0].text) }
        let containsJapaneseChinesePair = profiles.indices.contains { lhs in
            profiles.indices.contains { rhs in
                rhs > lhs && profiles[lhs].isJapaneseChineseTranslationPair(with: profiles[rhs])
            }
        }
        guard containsJapaneseChinesePair else { return clusterStart }

        return zip(cluster, profiles)
            .first { _, profile in profile.isLikelyJapaneseOriginalLine }?
            .0 ?? clusterStart
    }

    private static func nextDistinctTimestampIndex(after index: Int, in lines: [TimedLyricLine]) -> Int? {
        guard lines.indices.contains(index) else { return nil }
        let start = lines[index].time
        var candidate = index + 1
        while lines.indices.contains(candidate) {
            if abs(lines[candidate].time - start) > duplicateTimestampTolerance {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    public static func visualEndTime(in lines: [TimedLyricLine], index: Int) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        if let lastSegment = line.segments.last {
            let segmentEnd = lastSegment.time + max(lastSegment.durationHint ?? 0.24, 0.12)
            return min(max(segmentEnd, line.time + 0.35), endTime(in: lines, index: index))
        }
        return endTime(in: lines, index: index)
    }

    public var firstRenderableTime: Double? {
        guard let first = segments.first else { return nil }
        return first.time
    }

    public static func bestTimingSource(in lines: [TimedLyricLine]) -> LyricTimingSource {
        lines
            .map(\.effectiveSource)
            .max { $0.rank < $1.rank } ?? .estimated
    }

    public var effectiveSource: LyricTimingSource {
        if !segments.isEmpty {
            return segments
                .map(\.source)
                .max { $0.rank < $1.rank } ?? source
        }
        return source
    }

    private static func parseLine(_ line: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard !matches.isEmpty else { return [] }

        let lyricBody = regex
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = parseSegments(in: lyricBody)
        let lyricText = segments.isEmpty ? lyricBody : segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let minutes = Double(line[minuteRange]),
                let seconds = Double(line[secondRange])
            else { return nil }
            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: line) {
                let raw = String(line[fractionRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(raw.count))
            }
            return TimedLyricLine(time: minutes * 60 + seconds + fraction, text: lyricText, segments: segments)
        }
    }

    private static func parseSegments(in text: String) -> [TimedLyricSegment] {
        let pattern = #"<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>([^<]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: text),
                let secondRange = Range(match.range(at: 2), in: text),
                let wordRange = Range(match.range(at: 4), in: text),
                let minutes = Double(text[minuteRange]),
                let seconds = Double(text[secondRange])
            else { return nil }
            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: text) {
                let raw = String(text[fractionRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(raw.count))
            }
            let segmentText = String(text[wordRange])
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedLyricSegment(time: minutes * 60 + seconds + fraction, text: segmentText)
        }
        .sorted { $0.time < $1.time }
    }
}
