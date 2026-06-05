import AVFoundation
import Foundation
import MediaLibCore

enum LyricSourceParser {
    static func parse(_ text: String) -> [TimedLyricLine] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.localizedCaseInsensitiveContains("<tt") || trimmed.localizedCaseInsensitiveContains("<timedtext") {
            let ttmlLines = TTMLLyricParser.parse(trimmed)
            if !ttmlLines.isEmpty {
                return ttmlLines
            }
        }

        let yrcLines = parseMillisecondSyncedLines(trimmed)
        if yrcLines.contains(where: { !$0.segments.isEmpty }) {
            return yrcLines
        }

        return coalescedTimestampLines(parseLRCLines(trimmed))
    }

    private static func parseLRCLines(_ text: String) -> [TimedLyricLine] {
        let offset = lrcOffsetSeconds(in: text)
        return text
            .components(separatedBy: .newlines)
            .enumerated()
            .flatMap { parseLRCLine($0, offset: offset) }
            .filter { !$0.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if abs($0.line.time - $1.line.time) > 0.000_5 {
                    return $0.line.time < $1.line.time
                }
                return $0.order < $1.order
            }
            .map(\.line)
    }

    private static func parseLRCLine(_ entry: EnumeratedSequence<[String]>.Element, offset: Double) -> [(order: Int, line: TimedLyricLine)] {
        let (order, line) = entry
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard !matches.isEmpty else { return [] }

        let lyricBody = regex
            .stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = parseEnhancedLRCSegments(in: lyricBody, offset: offset)
        let lyricText = segments.isEmpty ? lyricBody : segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let minutes = Double(line[minuteRange]),
                let seconds = Double(line[secondRange])
            else { return nil }
            let fraction = fractionalSeconds(match: match, group: 3, in: line)
            return (
                order: order,
                line: TimedLyricLine(
                    time: max(minutes * 60 + seconds + fraction + offset, 0),
                    text: lyricText,
                    segments: segments,
                    source: segments.isEmpty ? .estimated : .exact
                )
            )
        }
    }

    private static func coalescedTimestampLines(_ lines: [TimedLyricLine]) -> [TimedLyricLine] {
        guard !lines.isEmpty else { return [] }
        let tolerance = 0.080
        var result: [TimedLyricLine] = []
        var group: [TimedLyricLine] = []

        func flushGroup() {
            guard let first = group.first else { return }
            defer { group.removeAll(keepingCapacity: true) }
            guard group.count > 1 else {
                result.append(first)
                return
            }

            var seen = Set<String>()
            let mergedText = group
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { seen.insert($0).inserted }
                .joined(separator: "\n")
            guard !mergedText.isEmpty else { return }

            result.append(
                TimedLyricLine(
                    time: first.time,
                    text: mergedText,
                    segments: [],
                    source: .estimated
                )
            )
        }

        for line in lines {
            if let first = group.first, abs(line.time - first.time) > tolerance {
                flushGroup()
            }
            group.append(line)
        }
        flushGroup()
        return result
    }

    private static func parseEnhancedLRCSegments(in text: String, offset: Double) -> [TimedLyricSegment] {
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
            let segmentText = String(text[wordRange])
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedLyricSegment(
                time: max(minutes * 60 + seconds + fractionalSeconds(match: match, group: 3, in: text) + offset, 0),
                text: segmentText,
                source: .exact
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func lrcOffsetSeconds(in text: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let milliseconds = Double(text[valueRange]) else {
            return 0
        }
        return milliseconds / 1000.0
    }

    private static func parseMillisecondSyncedLines(_ text: String) -> [TimedLyricLine] {
        let linePattern = #"\[(\d+),(\d+)\]"#
        let segmentPattern = #"(?:<|\()(\d+),(\d+)(?:,\d+)?(?:>|\))([^<\(\)\[]*)"#
        guard
            let lineRegex = try? NSRegularExpression(pattern: linePattern),
            let segmentRegex = try? NSRegularExpression(pattern: segmentPattern)
        else { return [] }

        return text.components(separatedBy: .newlines).compactMap { line in
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let lineMatch = lineRegex.firstMatch(in: line, range: lineRange),
                  let startRange = Range(lineMatch.range(at: 1), in: line),
                  let durationRange = Range(lineMatch.range(at: 2), in: line),
                  let lineStartMS = Double(line[startRange]),
                  let lineDurationMS = Double(line[durationRange]) else { return nil }

            let bodyStart = Range(lineMatch.range, in: line)?.upperBound ?? line.startIndex
            let body = String(line[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
            let lineStart = lineStartMS / 1000.0
            let segments = segmentRegex.matches(in: body, range: bodyRange).compactMap { match -> TimedLyricSegment? in
                guard
                    let segmentStartRange = Range(match.range(at: 1), in: body),
                    let segmentDurationRange = Range(match.range(at: 2), in: body),
                    let wordRange = Range(match.range(at: 3), in: body),
                    let rawStartMS = Double(body[segmentStartRange]),
                    let rawDurationMS = Double(body[segmentDurationRange])
                else { return nil }
                let text = String(body[wordRange])
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let isLikelyRelative = rawStartMS <= lineDurationMS + 1_000
                let time = isLikelyRelative ? lineStart + rawStartMS / 1000.0 : rawStartMS / 1000.0
                return TimedLyricSegment(time: time, text: text, source: .exact, durationHint: rawDurationMS / 1000.0)
            }
            let plain = segments.isEmpty
                ? segmentRegex.stringByReplacingMatches(in: body, range: bodyRange, withTemplate: "")
                : segments.map(\.text).joined()
            let lyricText = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyricText.isEmpty else { return nil }
            return TimedLyricLine(
                time: lineStart,
                text: lyricText,
                segments: segments.sorted { $0.time < $1.time },
                source: segments.isEmpty ? .estimated : .exact
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func fractionalSeconds(match: NSTextCheckingResult, group: Int, in text: String) -> Double {
        guard match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return 0 }
        let raw = String(text[range])
        return (Double(raw) ?? 0) / pow(10, Double(raw.count))
    }
}

private final class TTMLLyricParser: NSObject, XMLParserDelegate {
    private struct DraftLine {
        var begin: Double
        var text = ""
        var segments: [TimedLyricSegment] = []
    }

    private var lines: [TimedLyricLine] = []
    private var currentLine: DraftLine?
    private var currentSpanTime: Double?
    private var currentSpanDuration: Double?
    private var currentSpanText = ""

    static func parse(_ text: String) -> [TimedLyricLine] {
        guard let data = text.data(using: .utf8) else { return [] }
        let delegate = TTMLLyricParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.lines.sorted { $0.time < $1.time }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) })
        if name == "p" {
            currentLine = DraftLine(begin: Self.timeValue(attributes["begin"]) ?? Self.timeValue(attributes["start"]) ?? 0)
        } else if name == "span", let line = currentLine {
            let rawTime = Self.timeValue(attributes["begin"]) ?? Self.timeValue(attributes["start"]) ?? line.begin
            let spanBegin = rawTime < line.begin ? line.begin + rawTime : rawTime
            let spanEnd = Self.timeValue(attributes["end"]).map { $0 < line.begin ? line.begin + $0 : $0 }
            let spanDuration = Self.timeValue(attributes["dur"])
            currentSpanTime = spanBegin
            currentSpanDuration = spanEnd.map { max($0 - spanBegin, 0) } ?? spanDuration
            currentSpanText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentSpanTime != nil {
            currentSpanText += string
        } else if currentLine != nil {
            currentLine?.text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "span", let time = currentSpanTime {
            let text = currentSpanText
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentLine?.segments.append(
                    TimedLyricSegment(
                        time: time,
                        text: text,
                        source: .exact,
                        durationHint: currentSpanDuration
                    )
                )
                currentLine?.text += text
            }
            currentSpanTime = nil
            currentSpanDuration = nil
            currentSpanText = ""
        } else if name == "p", let line = currentLine {
            let text = (line.segments.isEmpty ? line.text : line.segments.map(\.text).joined())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(
                    TimedLyricLine(
                        time: line.begin,
                        text: text,
                        segments: line.segments.sorted { $0.time < $1.time },
                        source: line.segments.isEmpty ? .estimated : .exact
                    )
                )
            }
            currentLine = nil
        }
    }

    private static func timeValue(_ raw: String?) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasSuffix("ms"), let ms = Double(value.dropLast(2)) {
            return ms / 1000.0
        }
        if value.hasSuffix("s"), let seconds = Double(value.dropLast()) {
            return seconds
        }
        let parts = value.split(separator: ":")
        if parts.count == 3,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]) {
            return hours * 3600 + minutes * 60 + seconds
        }
        if parts.count == 2,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]) {
            return minutes * 60 + seconds
        }
        return Double(value)
    }
}

enum LyricEstimatedTimingBuilder {
    static func lines(from lines: [TimedLyricLine], algorithm: LyricSyncAlgorithm) -> [TimedLyricLine] {
        guard !lines.isEmpty else { return [] }
        let secondsPerWeight = globalSecondsPerWeight(in: lines)
        return lines.indices.map { index in
            let line = lines[index]
            guard line.segments.isEmpty else { return line }
            let endTime = TimedLyricLine.endTime(in: lines, index: index)
            let segments = estimatedSegments(
                text: line.text,
                start: line.time,
                end: endTime,
                algorithm: algorithm,
                secondsPerWeight: secondsPerWeight
            )
            guard !segments.isEmpty else { return line }
            return TimedLyricLine(time: line.time, text: line.text, segments: segments, source: .estimated)
        }
    }

    private static func estimatedSegments(
        text: String,
        start: Double,
        end: Double,
        algorithm: LyricSyncAlgorithm,
        secondsPerWeight: Double?
    ) -> [TimedLyricSegment] {
        let baseUnits = LyricAlignmentTokenizer.units(for: text)
        guard !baseUnits.isEmpty else { return [] }
        let units = weightedUnits(baseUnits, algorithm: algorithm)
        let lineDuration = max(end - start, 0.55)
        let totalWeight = max(units.reduce(0) { $0 + $1.weight }, 0.001)
        let config = EstimatedTimingConfig(algorithm: algorithm)

        var leading = lineDuration * config.leadingRatio
        if lineDuration < 1.5 {
            leading *= 0.55
        }
        let trailing = min(lineDuration * config.trailingRatio, max(lineDuration - 0.45, 0))
        let pauseDurations = punctuationPauses(for: units, lineDuration: lineDuration, config: config)
        let pauseBudget = min(pauseDurations.reduce(0, +), lineDuration * config.maxPauseRatio)
        let pauseScale = pauseDurations.reduce(0, +) > 0 ? pauseBudget / pauseDurations.reduce(0, +) : 1

        let rawVoiceBudget = max(lineDuration - leading - trailing - pauseBudget, lineDuration * 0.34)
        let voiceBudget: Double
        if let secondsPerWeight, algorithm != .instant {
            let expected = secondsPerWeight * totalWeight
            let lower = min(rawVoiceBudget, max(lineDuration * 0.38, Double(units.count) * 0.105))
            let upper = rawVoiceBudget
            let calibrated = min(max(expected, lower), upper)
            voiceBudget = rawVoiceBudget * (1 - config.tempoCalibrationStrength) + calibrated * config.tempoCalibrationStrength
        } else {
            voiceBudget = rawVoiceBudget
        }

        var cursor = start + leading
        var segments: [TimedLyricSegment] = []
        segments.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let pause = pauseDurations[index] * pauseScale
            cursor += pause
            let duration = max(0.055, voiceBudget * unit.weight / totalWeight)
            let segmentEnd = min(end, cursor + duration)
            segments.append(
                TimedLyricSegment(
                    time: cursor,
                    text: unit.text,
                    source: .estimated,
                    durationHint: max(segmentEnd - cursor, 0.055)
                )
            )
            cursor = segmentEnd
        }

        if let last = segments.indices.last {
            let voiceEnd = min(end, start + leading + pauseBudget + voiceBudget)
            let finalEnd = max(segments[last].time + (segments[last].durationHint ?? 0.055), voiceEnd)
            segments[last].durationHint = min(max(finalEnd - segments[last].time, 0.12), max(end - segments[last].time, 0.12))
        }
        return segments
    }

    private static func globalSecondsPerWeight(in lines: [TimedLyricLine]) -> Double? {
        var weightedDuration = 0.0
        var totalWeight = 0.0
        for index in lines.indices where lines[index].segments.isEmpty {
            guard lines.indices.contains(index + 1) else { continue }
            let duration = lines[index + 1].time - lines[index].time
            guard duration >= 0.75, duration <= 8.5 else { continue }
            let units = weightedUnits(LyricAlignmentTokenizer.units(for: lines[index].text), algorithm: .balanced)
            let weight = units.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { continue }
            weightedDuration += duration * 0.76
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return min(max(weightedDuration / totalWeight, 0.11), 0.58)
    }

    private static func weightedUnits(_ units: [LyricAlignmentUnit], algorithm: LyricSyncAlgorithm) -> [LyricAlignmentUnit] {
        units.enumerated().map { index, unit in
            var copy = unit
            switch algorithm {
            case .instant:
                copy.weight = max(unit.weight, 0.82)
            case .balanced, .audioEnergy, .precise:
                copy.weight = unit.weight * expressiveWeightMultiplier(for: unit.text)
                if index > 0, units[index - 1].text == unit.text {
                    copy.weight *= 0.92
                }
            }
            if index == units.indices.last {
                copy.weight *= algorithm == .instant ? 1.08 : 1.34
            }
            return copy
        }
    }

    private static func expressiveWeightMultiplier(for text: String) -> Double {
        let dragCharacters = Set("啊呀啦喔哦噢呜嗯哼呢嘛吧诶欸哎唉啦呐哪～~")
        let visible = text.filter { !$0.isLyricTimingIgnored }
        if visible.count == 1, let character = visible.first, dragCharacters.contains(character) {
            return 1.62
        }
        if visible.allSatisfy(\.isLatinLyricWordCharacter) {
            return min(max(Double(visible.count) * 0.18 + 0.82, 0.92), 1.48)
        }
        return 1
    }

    private static func punctuationPauses(
        for units: [LyricAlignmentUnit],
        lineDuration: Double,
        config: EstimatedTimingConfig
    ) -> [Double] {
        units.map { unit in
            guard let punctuation = unit.text.first(where: { $0.isLyricTimingIgnored }) else { return 0 }
            let text = String(punctuation)
            if "，,、；;：:".contains(text) {
                return lineDuration * config.shortPauseRatio
            }
            if "。！？!?…".contains(text) {
                return lineDuration * config.longPauseRatio
            }
            return 0
        }
    }
}

private struct EstimatedTimingConfig {
    var leadingRatio: Double
    var trailingRatio: Double
    var shortPauseRatio: Double
    var longPauseRatio: Double
    var maxPauseRatio: Double
    var tempoCalibrationStrength: Double

    init(algorithm: LyricSyncAlgorithm) {
        switch algorithm {
        case .instant:
            leadingRatio = 0.0
            trailingRatio = 0.12
            shortPauseRatio = 0.012
            longPauseRatio = 0.025
            maxPauseRatio = 0.10
            tempoCalibrationStrength = 0
        case .balanced:
            leadingRatio = 0.012
            trailingRatio = 0.17
            shortPauseRatio = 0.026
            longPauseRatio = 0.055
            maxPauseRatio = 0.18
            tempoCalibrationStrength = 0.30
        case .audioEnergy:
            leadingRatio = 0.008
            trailingRatio = 0.18
            shortPauseRatio = 0.024
            longPauseRatio = 0.052
            maxPauseRatio = 0.18
            tempoCalibrationStrength = 0.34
        case .precise:
            leadingRatio = 0.006
            trailingRatio = 0.20
            shortPauseRatio = 0.024
            longPauseRatio = 0.052
            maxPauseRatio = 0.20
            tempoCalibrationStrength = 0.40
        }
    }
}

enum LyricAlignmentService {
    static func alignedLines(
        for item: MediaItem,
        lyricsText: String,
        estimatedLines: [TimedLyricLine],
        algorithm: LyricSyncAlgorithm
    ) async -> [TimedLyricLine]? {
        guard !estimatedLines.isEmpty,
              algorithm.usesBackgroundAlignment,
              estimatedLines.allSatisfy({ $0.segments.isEmpty }),
              let filePath = item.filePath,
              !item.isRemoteResource,
              FileManager.default.fileExists(atPath: filePath),
              estimatedLines.count <= audioConfig(for: algorithm).maxLineCount else { return nil }

        let key = cacheKey(item: item, filePath: filePath, lyricsText: lyricsText, algorithm: algorithm)
        if let cached = cachedLines(for: key, estimatedLines: estimatedLines) {
            return cached
        }

        guard let aligned = await LyricAudioLineAligner.align(
            filePath: filePath,
            lines: estimatedLines,
            config: audioConfig(for: algorithm)
        ) else {
            return nil
        }
        writeCache(lines: aligned, key: key)
        return aligned
    }

    private static func cachedLines(for key: String, estimatedLines: [TimedLyricLine]) -> [TimedLyricLine]? {
        guard let url = cacheURL(for: key),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedLyricAlignment.self, from: data),
              cached.lines.count == estimatedLines.count else { return nil }
        let lines = cached.lines.map { line in
            TimedLyricLine(
                time: line.time,
                text: line.text,
                segments: line.segments.map {
                    TimedLyricSegment(time: $0.time, text: $0.text, source: .aligned, durationHint: $0.durationHint)
                },
                source: .aligned
            )
        }
        guard zip(lines, estimatedLines).allSatisfy({ $0.text == $1.text }) else { return nil }
        return lines
    }

    private static func writeCache(lines: [TimedLyricLine], key: String) {
        guard let url = cacheURL(for: key) else { return }
        let cached = CachedLyricAlignment(
            version: 2,
            createdAt: Date(),
            lines: lines.map { line in
                CachedLyricLine(
                    time: line.time,
                    text: line.text,
                    segments: line.segments.map {
                        CachedLyricSegment(time: $0.time, text: $0.text, durationHint: $0.durationHint)
                    }
                )
            }
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func cacheURL(for key: String) -> URL? {
        guard let directories = try? FileAccessService.appDirectories() else { return nil }
        let directory = directories.cache.appendingPathComponent("LyricAlignment", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(key).json")
    }

    private static func cacheKey(item: MediaItem, filePath: String, lyricsText: String, algorithm: LyricSyncAlgorithm) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? item.fileSize ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return [
            "v\(audioConfig(for: algorithm).cacheVersion)",
            algorithm.rawValue,
            stableHash(item.id),
            stableHash(filePath),
            String(size),
            String(Int(modified.rounded())),
            stableHash(lyricsText)
        ].joined(separator: "-")
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func audioConfig(for algorithm: LyricSyncAlgorithm) -> LyricAudioAlignmentConfig {
        switch algorithm {
        case .instant, .balanced:
            return .balanced
        case .audioEnergy:
            return .balanced
        case .precise:
            return .precise
        }
    }
}

private struct CachedLyricAlignment: Codable {
    var version: Int
    var createdAt: Date
    var lines: [CachedLyricLine]
}

private struct CachedLyricLine: Codable {
    var time: Double
    var text: String
    var segments: [CachedLyricSegment]
}

private struct CachedLyricSegment: Codable {
    var time: Double
    var text: String
    var durationHint: Double?
}

private struct LyricAudioAlignmentConfig {
    var cacheVersion: Int
    var maxLineCount: Int
    var windowsPerSecond: Double
    var maxWindowCount: Int
    var textBlend: Double
    var energyBlend: Double
    var onsetBlend: Double
    var valleySnapDistance: Double
    var minimumLineSuccessRatio: Double

    static let balanced = LyricAudioAlignmentConfig(
        cacheVersion: 4,
        maxLineCount: 420,
        windowsPerSecond: 30,
        maxWindowCount: 118,
        textBlend: 0.66,
        energyBlend: 0.24,
        onsetBlend: 0.10,
        valleySnapDistance: 0.026,
        minimumLineSuccessRatio: 0.34
    )

    static let precise = LyricAudioAlignmentConfig(
        cacheVersion: 5,
        maxLineCount: 360,
        windowsPerSecond: 42,
        maxWindowCount: 168,
        textBlend: 0.56,
        energyBlend: 0.28,
        onsetBlend: 0.16,
        valleySnapDistance: 0.034,
        minimumLineSuccessRatio: 0.38
    )
}

private enum LyricAudioLineAligner {
    static func align(filePath: String, lines: [TimedLyricLine], config: LyricAudioAlignmentConfig) async -> [TimedLyricLine]? {
        let url = URL(fileURLWithPath: filePath)
        guard url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }

        var aligned = lines
        var alignedLineCount = 0
        for index in lines.indices {
            if Task.isCancelled { return nil }
            let line = lines[index]
            let units = LyricAlignmentTokenizer.units(for: line.text)
            guard units.count > 1 else { continue }
            let endTime = TimedLyricLine.endTime(in: lines, index: index)
            let duration = min(max(endTime - line.time, 0.65), 10.0)
            let windowCount = min(max(Int(duration * config.windowsPerSecond), units.count + 6), config.maxWindowCount)
            guard let envelope = await LyricEnergyEnvelope.read(
                asset: asset,
                track: track,
                start: line.time,
                duration: duration,
                windowCount: windowCount
            ) else { continue }

            let boundaries = LyricBoundaryMapper.segmentBoundaries(
                lineStart: line.time,
                lineDuration: duration,
                units: units,
                envelope: envelope,
                config: config
            )
            guard boundaries.count == units.count + 1 else { continue }
            let segments = units.indices.map { unitIndex in
                let start = boundaries[unitIndex]
                let end = boundaries[unitIndex + 1]
                return TimedLyricSegment(
                    time: start,
                    text: units[unitIndex].text,
                    source: .aligned,
                    durationHint: max(end - start, 0.055)
                )
            }
            aligned[index] = TimedLyricLine(time: line.time, text: line.text, segments: segments, source: .aligned)
            alignedLineCount += 1
        }

        let required = max(3, Int(Double(min(lines.count, 18)) * config.minimumLineSuccessRatio))
        guard alignedLineCount >= required else { return nil }
        return aligned
    }
}

private struct LyricAlignmentUnit {
    var text: String
    var weight: Double
}

private enum LyricAlignmentTokenizer {
    static func units(for text: String) -> [LyricAlignmentUnit] {
        var units: [LyricAlignmentUnit] = []
        var latinWord = ""
        var pendingIgnored = ""

        func appendUnit(_ text: String, weight: Double) {
            guard !text.isEmpty else { return }
            let merged = pendingIgnored + text
            pendingIgnored = ""
            units.append(LyricAlignmentUnit(text: merged, weight: weight))
        }

        func flushLatinWord() {
            guard !latinWord.isEmpty else { return }
            appendUnit(latinWord, weight: 1.08)
            latinWord = ""
        }

        for character in text {
            if character.isLyricTimingIgnored {
                flushLatinWord()
                pendingIgnored += String(character)
            } else if character.isLatinLyricWordCharacter {
                latinWord += String(character)
            } else {
                flushLatinWord()
                appendUnit(String(character), weight: phoneticWeight(for: character))
            }
        }
        flushLatinWord()
        if !pendingIgnored.isEmpty {
            if let last = units.indices.last {
                units[last].text += pendingIgnored
            } else {
                units.append(LyricAlignmentUnit(text: pendingIgnored, weight: 0.35))
            }
        }
        if let last = units.indices.last {
            units[last].weight *= 1.12
        }
        return units
    }

    private static func phoneticWeight(for character: Character) -> Double {
        guard character.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) else {
            return 1.0
        }
        let mutable = NSMutableString(string: String(character))
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let letterCount = String(mutable)
            .unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .count
        return min(max(Double(letterCount) * 0.18, 0.95), 1.32)
    }
}

private struct LyricEnergyEnvelope {
    var values: [Double]

    static func read(
        asset: AVURLAsset,
        track: AVAssetTrack,
        start: Double,
        duration: Double,
        windowCount: Int
    ) async -> LyricEnergyEnvelope? {
        guard windowCount > 2,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(start, 0), preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        let sampleLimit = min(max(Int(duration * 96_000), windowCount * 192), 1_200_000)
        samples.reserveCapacity(min(sampleLimit, 240_000))
        while let sampleBuffer = output.copyNextSampleBuffer(), samples.count < sampleLimit {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var floats = Array(repeating: Float.zero, count: byteCount / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: min(byteCount, buffer.count),
                    destination: buffer.baseAddress!
                )
            }
            guard status == noErr else { continue }
            samples.append(contentsOf: floats.prefix(max(0, sampleLimit - samples.count)))
        }
        reader.cancelReading()
        guard samples.count >= windowCount * 8 else { return nil }

        let samplesPerWindow = max(samples.count / windowCount, 1)
        var values: [Double] = []
        values.reserveCapacity(windowCount)
        for index in 0..<windowCount {
            let lower = index * samplesPerWindow
            let upper = index == windowCount - 1 ? samples.count : min(samples.count, lower + samplesPerWindow)
            guard lower < upper else { continue }
            var total = 0.0
            for sample in samples[lower..<upper] {
                let value = Double(sample)
                total += min(value * value, 1)
            }
            values.append(sqrt(total / Double(upper - lower)))
        }
        return LyricEnergyEnvelope(values: smooth(normalized(values)))
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 0.000_001)
        return values.map { min(max($0 / peak, 0), 1) }
    }

    private static func smooth(_ values: [Double]) -> [Double] {
        guard values.count > 2 else { return values }
        return values.indices.map { index in
            let previous = values[max(index - 1, values.startIndex)]
            let current = values[index]
            let next = values[min(index + 1, values.index(before: values.endIndex))]
            return previous * 0.22 + current * 0.56 + next * 0.22
        }
    }
}

private enum LyricBoundaryMapper {
    static func segmentBoundaries(
        lineStart: Double,
        lineDuration: Double,
        units: [LyricAlignmentUnit],
        envelope: LyricEnergyEnvelope,
        config: LyricAudioAlignmentConfig
    ) -> [Double] {
        let values = envelope.values
        guard !values.isEmpty, !units.isEmpty else { return [] }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let peak = values.max() ?? 0
        let voiceThreshold = median + (peak - median) * 0.18
        let firstVoice = values.firstIndex { $0 >= voiceThreshold } ?? 0
        let lastVoice = values.indices.reversed().first { values[$0] >= voiceThreshold } ?? values.index(before: values.endIndex)
        let windowDuration = lineDuration / Double(values.count)
        var voiceStart = lineStart + Double(firstVoice) * windowDuration
        var voiceEnd = lineStart + Double(lastVoice + 1) * windowDuration
        if voiceEnd - voiceStart < max(0.45, lineDuration * 0.34) {
            voiceStart = lineStart
            voiceEnd = lineStart + lineDuration
        }

        let totalWeight = max(units.reduce(0) { $0 + $1.weight }, 0.001)
        let cumulative = cumulativeEnergy(values, floor: voiceThreshold * 0.28)
        let valleys = valleyFractions(values: values, threshold: voiceThreshold)
        let onsets = onsetFractions(values: values, threshold: voiceThreshold)
        var boundaries: [Double] = []
        var prefixWeight = 0.0
        let minimumGap = min(max((voiceEnd - voiceStart) / Double(max(units.count, 1)) * 0.28, 0.038), 0.16)

        for boundaryIndex in 0...units.count {
            if boundaryIndex == 0 {
                boundaries.append(voiceStart)
                continue
            }
            if boundaryIndex == units.count {
                boundaries.append(max(boundaries.last ?? voiceStart, voiceEnd))
                continue
            }

            prefixWeight += units[boundaryIndex - 1].weight
            let weightedFraction = prefixWeight / totalWeight
            let energyFraction = timeFraction(forEnergyFraction: weightedFraction, cumulative: cumulative)
            let onsetFraction = onsetFraction(for: weightedFraction, onsets: onsets) ?? weightedFraction
            let blendedFraction = weightedFraction * config.textBlend
                + energyFraction * config.energyBlend
                + onsetFraction * config.onsetBlend
            let snappedFraction = nearestValley(
                to: blendedFraction,
                valleys: valleys,
                maximumDistance: config.valleySnapDistance
            ) ?? blendedFraction
            var time = voiceStart + (voiceEnd - voiceStart) * min(max(snappedFraction, 0), 1)
            if let previous = boundaries.last {
                let remaining = Double(units.count - boundaryIndex)
                let upperBound = voiceEnd - remaining * minimumGap
                time = min(max(time, previous + minimumGap), max(previous + minimumGap, upperBound))
            }
            boundaries.append(time)
        }

        if let lastIndex = boundaries.indices.last {
            boundaries[lastIndex] = max(boundaries[lastIndex], voiceEnd)
        }
        return boundaries
    }

    private static func cumulativeEnergy(_ values: [Double], floor: Double) -> [Double] {
        var cumulative = [0.0]
        var total = 0.0
        for value in values {
            total += max(value - floor, 0.015)
            cumulative.append(total)
        }
        guard total > 0 else { return cumulative }
        return cumulative.map { $0 / total }
    }

    private static func timeFraction(forEnergyFraction fraction: Double, cumulative: [Double]) -> Double {
        guard cumulative.count > 1 else { return fraction }
        let target = min(max(fraction, 0), 1)
        guard let upper = cumulative.firstIndex(where: { $0 >= target }) else { return 1 }
        let lower = max(upper - 1, 0)
        let lowerValue = cumulative[lower]
        let upperValue = cumulative[upper]
        let local = (target - lowerValue) / max(upperValue - lowerValue, 0.000_001)
        return (Double(lower) + min(max(local, 0), 1)) / Double(max(cumulative.count - 1, 1))
    }

    private static func valleyFractions(values: [Double], threshold: Double) -> [Double] {
        guard values.count > 4 else { return [] }
        return values.indices.dropFirst().dropLast().compactMap { index in
            let value = values[index]
            guard value <= threshold * 0.82,
                  value <= values[index - 1],
                  value <= values[index + 1] else { return nil }
            return (Double(index) + 0.5) / Double(values.count)
        }
    }

    private static func onsetFractions(values: [Double], threshold: Double) -> [Double] {
        guard values.count > 5 else { return [] }
        var novelty: [Double] = []
        novelty.reserveCapacity(values.count - 1)
        for index in values.indices.dropFirst() {
            novelty.append(max(values[index] - values[index - 1], 0))
        }
        let mean = novelty.reduce(0, +) / Double(max(novelty.count, 1))
        let variance = novelty.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(novelty.count, 1))
        let thresholdValue = max(mean + sqrt(variance) * 0.72, threshold * 0.18)
        var peaks: [Double] = []
        for index in novelty.indices.dropFirst().dropLast() {
            guard novelty[index] >= thresholdValue,
                  novelty[index] >= novelty[index - 1],
                  novelty[index] >= novelty[index + 1] else { continue }
            let fraction = (Double(index) + 1.0) / Double(values.count)
            if let last = peaks.last, fraction - last < 0.035 {
                if novelty[index] > novelty[max(Int(last * Double(values.count)) - 1, 0)] {
                    peaks.removeLast()
                    peaks.append(fraction)
                }
            } else {
                peaks.append(fraction)
            }
        }
        return peaks
    }

    private static func onsetFraction(for weightedFraction: Double, onsets: [Double]) -> Double? {
        guard onsets.count >= 2 else { return nil }
        let anchors = [0.0] + onsets + [1.0]
        let position = min(max(weightedFraction, 0), 1) * Double(anchors.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, anchors.count - 1)
        let local = position - Double(lower)
        return anchors[lower] + (anchors[upper] - anchors[lower]) * local
    }

    private static func nearestValley(to fraction: Double, valleys: [Double], maximumDistance: Double) -> Double? {
        guard let nearest = valleys.min(by: { abs($0 - fraction) < abs($1 - fraction) }),
              abs(nearest - fraction) <= maximumDistance else { return nil }
        return nearest
    }
}
