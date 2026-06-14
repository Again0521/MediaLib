import Foundation

public enum DefaultPlayer: String, Codable, CaseIterable, Identifiable {
    case builtIn
    case external

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: return "内置"
        case .external: return "系统"
        }
    }
}

public enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case zhHans
    case en
    case ja

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    public static var systemDefault: AppLanguage {
        let preferredIdentifier = Locale.preferredLanguages.first ?? ""
        let preferred = preferredIdentifier.lowercased()
        let locale = Locale(identifier: preferredIdentifier)
        let region = (locale.region?.identifier ?? Locale.current.region?.identifier ?? "").uppercased()
        let chineseRegions: Set<String> = ["CN", "HK", "MO", "TW", "SG", "MY"]
        if preferred.hasPrefix("zh") || chineseRegions.contains(region) {
            return .zhHans
        }
        if preferred.hasPrefix("ja") || region == "JP" {
            return .ja
        }
        return .en
    }

    public var nativeRestartTitle: String {
        switch self {
        case .zhHans: return "语言已切换"
        case .en: return "Language updated"
        case .ja: return "言語を変更しました"
        }
    }

    public var nativeRestartMessage: String {
        switch self {
        case .zhHans:
            return "重启 MediaLIB 后，界面会完整切换为简体中文。"
        case .en:
            return "Restart MediaLIB to finish switching the interface to English."
        case .ja:
            return "MediaLIB を再起動すると、画面表示が日本語に切り替わります。"
        }
    }
}

public enum ArtworkFallbackMode: String, Codable, CaseIterable, Identifiable {
    case videoFrame
    case generatedDefault
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .videoFrame: return "截取视频帧"
        case .generatedDefault: return "绘制默认封面"
        case .none: return "不生成"
        }
    }

    public var description: String {
        switch self {
        case .videoFrame: return "从视频中截取一帧，并保留原始画面比例。"
        case .generatedDefault: return "使用统一风格的默认封面，不展示视频画面。"
        case .none: return "缺失封面时显示占位卡片。"
        }
    }
}

public enum VideoScrubberPreviewMode: String, Codable, CaseIterable, Identifiable {
    case off
    case performance
    case balanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .performance: return "流畅优先"
        case .balanced: return "画面优先"
        }
    }

    public var description: String {
        switch self {
        case .off:
            return "鼠标悬停进度条时只显示时间，不提取帧预览。"
        case .performance:
            return "使用更粗的预览分段并延迟抽帧，优先保证播放流畅。"
        case .balanced:
            return "保留较细的预览分段并预热邻近帧，适合性能充足的本机视频。"
        }
    }

    public var isEnabled: Bool {
        self != .off
    }

    public var usesCoarseBuckets: Bool {
        self == .performance
    }

    public var allowsPrefetch: Bool {
        self == .balanced
    }

    public var requestDelayNanoseconds: UInt64 {
        switch self {
        case .off: return 0
        case .performance: return 120_000_000
        case .balanced: return 45_000_000
        }
    }

    public var hoverMinimumInterval: Double {
        switch self {
        case .off: return 0.18
        case .performance: return 0.11
        case .balanced: return 1.0 / 24.0
        }
    }

    public var hoverMinimumDistance: Double {
        switch self {
        case .off: return 22
        case .performance: return 16
        case .balanced: return 9
        }
    }
}

public enum VideoAspectOverride: String, Codable, CaseIterable, Identifiable {
    case source
    case square
    case fourByThree
    case sixteenByNine
    case sixteenByTen
    case twentyOneByNine
    case cinemaScope

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .source: return "跟随片源"
        case .square: return "1:1"
        case .fourByThree: return "4:3"
        case .sixteenByNine: return "16:9"
        case .sixteenByTen: return "16:10"
        case .twentyOneByNine: return "21:9"
        case .cinemaScope: return "2.39:1"
        }
    }

    public var mpvValue: String {
        switch self {
        case .source: return "no"
        case .square: return "1:1"
        case .fourByThree: return "4:3"
        case .sixteenByNine: return "16:9"
        case .sixteenByTen: return "16:10"
        case .twentyOneByNine: return "21:9"
        case .cinemaScope: return "2.39:1"
        }
    }
}

public enum VideoCropMode: String, Codable, CaseIterable, Identifiable {
    case none
    case gentle
    case balanced
    case fill

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "关闭"
        case .gentle: return "轻微"
        case .balanced: return "平衡"
        case .fill: return "填满"
        }
    }

    public var panscanValue: Double {
        switch self {
        case .none: return 0
        case .gentle: return 0.18
        case .balanced: return 0.42
        case .fill: return 1
        }
    }
}

public enum VideoDeinterlaceMode: String, Codable, CaseIterable, Identifiable {
    case off
    case auto
    case on

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .auto: return "自动"
        case .on: return "开启"
        }
    }

    public var mpvValue: String {
        switch self {
        case .off: return "no"
        case .auto: return "auto"
        case .on: return "yes"
        }
    }
}

public enum VideoRotationMode: String, Codable, CaseIterable, Identifiable {
    case source
    case clockwise90
    case rotate180
    case counterclockwise90

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .source: return "不旋转"
        case .clockwise90: return "顺时针 90"
        case .rotate180: return "180"
        case .counterclockwise90: return "逆时针 90"
        }
    }

    public var mpvValue: String {
        switch self {
        case .source: return "no"
        case .clockwise90: return "90"
        case .rotate180: return "180"
        case .counterclockwise90: return "270"
        }
    }
}

public enum VideoTrackpadGestureSensitivity: String, Codable, CaseIterable, Identifiable {
    case gentle
    case standard
    case fast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gentle: return "轻柔"
        case .standard: return "标准"
        case .fast: return "灵敏"
        }
    }

    public var seekSecondsPerPoint: Double {
        switch self {
        case .gentle: return 0.035
        case .standard: return 0.055
        case .fast: return 0.08
        }
    }

    public var volumePerPoint: Double {
        switch self {
        case .gentle: return 0.0016
        case .standard: return 0.0023
        case .fast: return 0.0032
        }
    }
}

public enum VideoMarkerSkipBehavior: String, Codable, CaseIterable, Identifiable {
    case off
    case prompt
    case automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .prompt: return "显示按钮"
        case .automatic: return "自动跳过"
        }
    }

    public var description: String {
        switch self {
        case .off:
            return "不显示片头/片尾跳过入口，章节和手动标记仍会保留。"
        case .prompt:
            return "进入完整片头或片尾范围时显示跳过按钮，由你手动确认。"
        case .automatic:
            return "进入已确认的片头或片尾范围后直接跳到结束位置。"
        }
    }
}

public enum VideoHardwareDecodingMode: String, Codable, CaseIterable, Identifiable {
    case safe
    case automatic
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .safe: return "兼容"
        case .automatic: return "自动"
        case .off: return "关闭"
        }
    }

    public var mpvValue: String {
        switch self {
        case .safe: return "auto-safe"
        case .automatic: return "auto"
        case .off: return "no"
        }
    }
}

public enum VideoDebandMode: String, Codable, CaseIterable, Identifiable {
    case off
    case light
    case strong

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻微"
        case .strong: return "明显"
        }
    }

    public var isEnabled: Bool {
        self != .off
    }

    public var threshold: Double {
        switch self {
        case .off: return 64
        case .light: return 32
        case .strong: return 48
        }
    }

    public var range: Double {
        switch self {
        case .off: return 16
        case .light: return 12
        case .strong: return 18
        }
    }

    public var grain: Double {
        switch self {
        case .off: return 48
        case .light: return 24
        case .strong: return 36
        }
    }
}

/// HDR 色调映射曲线（libmpv `tone-mapping`），SDR 显示器观看 HDR 片源时生效。
public enum VideoToneMappingMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case bt2390 = "bt.2390"
    case hable
    case mobius
    case reinhard
    case clip

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .bt2390: return "BT.2390"
        case .hable: return "Hable"
        case .mobius: return "Mobius"
        case .reinhard: return "Reinhard"
        case .clip: return "裁剪"
        }
    }
}

/// 鼠标中键在播放画面上的动作。
public enum VideoMiddleClickAction: String, Codable, CaseIterable, Identifiable {
    case none
    case playPause
    case fullscreen
    case mute
    case contextMenu

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "无"
        case .playPause: return "播放/暂停"
        case .fullscreen: return "全屏"
        case .mute: return "静音"
        case .contextMenu: return "右键菜单"
        }
    }
}

/// 鼠标侧键（后退/前进键）在播放画面上的动作。
public enum VideoSideButtonAction: String, Codable, CaseIterable, Identifiable {
    case none
    case seek
    case episode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "无"
        case .seek: return "快退/快进"
        case .episode: return "上集/下集"
        }
    }
}

/// 视频播放结束后的行为。
public enum VideoPlaybackEndAction: String, Codable, CaseIterable, Identifiable {
    case nextEpisode
    case holdLastFrame
    case closeWindow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nextEpisode: return "自动下一集"
        case .holdLastFrame: return "停在结尾"
        case .closeWindow: return "关闭窗口"
        }
    }
}

/// 镜像翻转（libmpv vf `hflip` / `vflip`）。
public enum VideoFlipMode: String, Codable, CaseIterable, Identifiable {
    case none
    case horizontal
    case vertical
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "关闭"
        case .horizontal: return "水平"
        case .vertical: return "垂直"
        case .both: return "双向"
        }
    }

    public var mpvFilters: [String] {
        switch self {
        case .none: return []
        case .horizontal: return ["hflip"]
        case .vertical: return ["vflip"]
        case .both: return ["hflip", "vflip"]
        }
    }
}

/// 画面锐化（libmpv 经 lavfi 桥接的 `unsharp` 滤镜）。
public enum VideoSharpenMode: String, Codable, CaseIterable, Identifiable {
    case off
    case light
    case medium
    case strong

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻微"
        case .medium: return "适中"
        case .strong: return "明显"
        }
    }

    public var mpvFilter: String? {
        switch self {
        case .off: return nil
        case .light: return "unsharp=la=0.4"
        case .medium: return "unsharp=la=0.8"
        case .strong: return "unsharp=la=1.2"
        }
    }
}

/// 画面降噪（libmpv 经 lavfi 桥接的 `hqdn3d` 滤镜）。
public enum VideoDenoiseMode: String, Codable, CaseIterable, Identifiable {
    case off
    case light
    case medium
    case strong

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻微"
        case .medium: return "适中"
        case .strong: return "明显"
        }
    }

    public var mpvFilter: String? {
        switch self {
        case .off: return nil
        case .light: return "hqdn3d=2:1.5:3:2.25"
        case .medium: return "hqdn3d=4:3:6:4.5"
        case .strong: return "hqdn3d=7:5:10:7.5"
        }
    }
}

public enum VideoScreenshotMode: String, Codable, CaseIterable, Identifiable {
    case subtitles
    case video
    case window

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .subtitles: return "带字幕"
        case .video: return "纯视频"
        case .window: return "窗口所见"
        }
    }

    public var mpvArgument: String {
        switch self {
        case .subtitles: return "subtitles"
        case .video: return "video"
        case .window: return "window"
        }
    }
}

public struct VideoShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = VideoShortcutModifiers(rawValue: 1 << 0)
    public static let option = VideoShortcutModifiers(rawValue: 1 << 1)
    public static let control = VideoShortcutModifiers(rawValue: 1 << 2)
    public static let shift = VideoShortcutModifiers(rawValue: 1 << 3)

    public var displayPrefix: String {
        var parts: [String] = []
        if contains(.command) { parts.append("Command") }
        if contains(.option) { parts.append("Option") }
        if contains(.control) { parts.append("Control") }
        if contains(.shift) { parts.append("Shift") }
        return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
    }
}

public struct VideoKeyboardShortcut: Codable, Hashable, Sendable {
    public var keyCode: Int
    public var characters: String
    public var modifiers: VideoShortcutModifiers

    public init(keyCode: Int, characters: String = "", modifiers: VideoShortcutModifiers = []) {
        self.keyCode = keyCode
        self.characters = Self.normalizedCharacters(characters)
        self.modifiers = modifiers
    }

    private static func normalizedCharacters(_ characters: String) -> String {
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        let shouldIgnoreCharacters = trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.controlCharacters.contains(scalar) ||
                (0xF700...0xF8FF).contains(Int(scalar.value))
        }
        return shouldIgnoreCharacters ? "" : trimmed
    }

    fileprivate var normalized: VideoKeyboardShortcut {
        VideoKeyboardShortcut(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    public var isEnabled: Bool {
        keyCode >= 0
    }

    public var displayName: String {
        guard isEnabled else { return "未设置" }
        return modifiers.displayPrefix + keyTitle
    }

    private var keyTitle: String {
        switch keyCode {
        case 36, 76: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 115: return "Home"
        case 116: return "Page Up"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:
            if !characters.isEmpty {
                return characters.uppercased()
            }
            return "Key \(keyCode)"
        }
    }
}

public enum VideoPlayerShortcutAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case exitFullscreenOrClose
    case closeWindow
    case previousEpisode
    case nextEpisode
    case restart
    case captureFrame
    case openExternal
    case cycleABLoopPoint
    case clearABLoop
    case toggleCurrentLoop
    case showPlaybackInfo
    case seekBackward
    case seekForward
    case seekBackwardSmall
    case seekForwardSmall
    case seekBackwardLarge
    case seekForwardLarge
    case seekBackwardTen
    case seekForwardTen
    case volumeUp
    case volumeDown
    case mute
    case toggleFullscreen
    case goToBeginning
    case goToEnd
    case speedDown
    case speedUp
    case resetSpeed
    case frameBackward
    case frameForward
    case audioDelayDown
    case audioDelayUp
    case subtitleDelayDown
    case subtitleDelayUp
    case subtitleSizeDown
    case subtitleSizeUp
    case subtitleMoveUp
    case subtitleMoveDown
    case cycleAspectRatio
    case cycleCropMode
    case cycleDeinterlaceMode
    case rotateVideoLeft
    case rotateVideoRight
    case subtitleCycle
    case subtitleToggle
    case audioCycle
    case seekTo0Percent
    case seekTo10Percent
    case seekTo20Percent
    case seekTo30Percent
    case seekTo40Percent
    case seekTo50Percent
    case seekTo60Percent
    case seekTo70Percent
    case seekTo80Percent
    case seekTo90Percent
    case toggleControlsLock
    case showAdvancedSettings
    case toggleMiniMode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .playPause: return "播放 / 暂停"
        case .exitFullscreenOrClose: return "退出全屏 / 关闭"
        case .closeWindow: return "关闭播放器"
        case .previousEpisode: return "上一集"
        case .nextEpisode: return "下一集"
        case .restart: return "从头播放"
        case .captureFrame: return "保存当前画面"
        case .openExternal: return "用系统播放器打开"
        case .cycleABLoopPoint: return "设置 A-B 循环点"
        case .clearABLoop: return "清除 A-B 循环"
        case .toggleCurrentLoop: return "单片循环开关"
        case .showPlaybackInfo: return "打开播放信息"
        case .seekBackward: return "后退默认间隔"
        case .seekForward: return "前进默认间隔"
        case .seekBackwardSmall: return "后退 5 秒"
        case .seekForwardSmall: return "前进 5 秒"
        case .seekBackwardLarge: return "后退 60 秒"
        case .seekForwardLarge: return "前进 60 秒"
        case .seekBackwardTen: return "后退 10 秒"
        case .seekForwardTen: return "前进 10 秒"
        case .volumeUp: return "调高音量"
        case .volumeDown: return "调低音量"
        case .mute: return "静音"
        case .toggleFullscreen: return "切换全屏"
        case .goToBeginning: return "跳到开头"
        case .goToEnd: return "跳到结尾"
        case .speedDown: return "降低倍速"
        case .speedUp: return "提高倍速"
        case .resetSpeed: return "恢复 1x 倍速"
        case .frameBackward: return "上一帧"
        case .frameForward: return "下一帧"
        case .audioDelayDown: return "音频提前 0.1 秒"
        case .audioDelayUp: return "音频延后 0.1 秒"
        case .subtitleDelayDown: return "字幕提前 0.1 秒"
        case .subtitleDelayUp: return "字幕延后 0.1 秒"
        case .subtitleSizeDown: return "缩小字幕"
        case .subtitleSizeUp: return "放大字幕"
        case .subtitleMoveUp: return "字幕上移"
        case .subtitleMoveDown: return "字幕下移"
        case .cycleAspectRatio: return "切换画面比例"
        case .cycleCropMode: return "切换黑边裁切"
        case .cycleDeinterlaceMode: return "切换去隔行"
        case .rotateVideoLeft: return "画面向左旋转"
        case .rotateVideoRight: return "画面向右旋转"
        case .subtitleCycle: return "切换字幕轨道"
        case .subtitleToggle: return "显示 / 隐藏字幕"
        case .audioCycle: return "切换音轨"
        case .seekTo0Percent: return "跳到 0%"
        case .seekTo10Percent: return "跳到 10%"
        case .seekTo20Percent: return "跳到 20%"
        case .seekTo30Percent: return "跳到 30%"
        case .seekTo40Percent: return "跳到 40%"
        case .seekTo50Percent: return "跳到 50%"
        case .seekTo60Percent: return "跳到 60%"
        case .seekTo70Percent: return "跳到 70%"
        case .seekTo80Percent: return "跳到 80%"
        case .seekTo90Percent: return "跳到 90%"
        case .toggleControlsLock: return "锁定 / 显示控制栏"
        case .showAdvancedSettings: return "打开更多设置"
        case .toggleMiniMode: return "迷你悬浮窗"
        }
    }

    public var groupTitle: String {
        switch self {
        case .playPause, .exitFullscreenOrClose, .closeWindow, .previousEpisode, .nextEpisode, .restart, .captureFrame, .openExternal,
             .cycleABLoopPoint, .clearABLoop, .toggleCurrentLoop, .showPlaybackInfo:
            return "播放"
        case .seekBackward, .seekForward, .seekBackwardSmall, .seekForwardSmall, .seekBackwardLarge, .seekForwardLarge,
             .seekBackwardTen, .seekForwardTen, .goToBeginning, .goToEnd,
             .seekTo0Percent, .seekTo10Percent, .seekTo20Percent, .seekTo30Percent, .seekTo40Percent,
             .seekTo50Percent, .seekTo60Percent, .seekTo70Percent, .seekTo80Percent, .seekTo90Percent:
            return "跳转"
        case .volumeUp, .volumeDown, .mute, .toggleFullscreen, .toggleControlsLock, .showAdvancedSettings, .toggleMiniMode:
            return "窗口与控制"
        case .speedDown, .speedUp, .resetSpeed, .frameBackward, .frameForward,
             .cycleAspectRatio, .cycleCropMode, .cycleDeinterlaceMode, .rotateVideoLeft, .rotateVideoRight:
            return "画面"
        case .audioDelayDown, .audioDelayUp, .subtitleDelayDown, .subtitleDelayUp,
             .subtitleSizeDown, .subtitleSizeUp, .subtitleMoveUp, .subtitleMoveDown:
            return "音画同步"
        case .subtitleCycle, .subtitleToggle, .audioCycle:
            return "轨道"
        }
    }

    public var defaultShortcuts: [VideoKeyboardShortcut] {
        switch self {
        case .playPause:
            return [
                VideoKeyboardShortcut(keyCode: 49),
                VideoKeyboardShortcut(keyCode: 40, characters: "k")
            ]
        case .exitFullscreenOrClose:
            return [VideoKeyboardShortcut(keyCode: 53)]
        case .closeWindow:
            return [
                VideoKeyboardShortcut(keyCode: 13, characters: "w", modifiers: .command),
                VideoKeyboardShortcut(keyCode: 12, characters: "q")
            ]
        case .previousEpisode:
            return []
        case .nextEpisode:
            return []
        case .restart:
            return []
        case .captureFrame:
            return [VideoKeyboardShortcut(keyCode: 1, characters: "s")]
        case .openExternal:
            return []
        case .cycleABLoopPoint:
            return [VideoKeyboardShortcut(keyCode: 11, characters: "b")]
        case .clearABLoop:
            return [VideoKeyboardShortcut(keyCode: 11, characters: "b", modifiers: .shift)]
        case .toggleCurrentLoop:
            return []
        case .showPlaybackInfo:
            return [VideoKeyboardShortcut(keyCode: 34, characters: "i")]
        case .seekBackward:
            return [VideoKeyboardShortcut(keyCode: 123)]
        case .seekForward:
            return [VideoKeyboardShortcut(keyCode: 124)]
        case .seekBackwardSmall:
            return [VideoKeyboardShortcut(keyCode: 123, modifiers: .shift)]
        case .seekForwardSmall:
            return [VideoKeyboardShortcut(keyCode: 124, modifiers: .shift)]
        case .seekBackwardLarge:
            return [
                VideoKeyboardShortcut(keyCode: 123, modifiers: .option),
                VideoKeyboardShortcut(keyCode: 121)
            ]
        case .seekForwardLarge:
            return [
                VideoKeyboardShortcut(keyCode: 124, modifiers: .option),
                VideoKeyboardShortcut(keyCode: 116)
            ]
        case .seekBackwardTen:
            return [VideoKeyboardShortcut(keyCode: 38, characters: "j")]
        case .seekForwardTen:
            return [VideoKeyboardShortcut(keyCode: 37, characters: "l")]
        case .volumeUp:
            return [VideoKeyboardShortcut(keyCode: 126)]
        case .volumeDown:
            return [VideoKeyboardShortcut(keyCode: 125)]
        case .mute:
            return [VideoKeyboardShortcut(keyCode: 46, characters: "m")]
        case .toggleFullscreen:
            return [
                VideoKeyboardShortcut(keyCode: 36),
                VideoKeyboardShortcut(keyCode: 3, characters: "f"),
                VideoKeyboardShortcut(keyCode: 3, characters: "f", modifiers: .command)
            ]
        case .goToBeginning:
            return [
                VideoKeyboardShortcut(keyCode: 115),
                VideoKeyboardShortcut(keyCode: 123, modifiers: .command)
            ]
        case .goToEnd:
            return [
                VideoKeyboardShortcut(keyCode: 119),
                VideoKeyboardShortcut(keyCode: 124, modifiers: .command)
            ]
        case .speedDown:
            return [VideoKeyboardShortcut(keyCode: 33, characters: "[")]
        case .speedUp:
            return [VideoKeyboardShortcut(keyCode: 30, characters: "]")]
        case .resetSpeed:
            return [VideoKeyboardShortcut(keyCode: 42, characters: "\\")]
        case .frameBackward:
            return [VideoKeyboardShortcut(keyCode: 43, characters: ",")]
        case .frameForward:
            return [VideoKeyboardShortcut(keyCode: 47, characters: ".")]
        case .audioDelayDown:
            return [VideoKeyboardShortcut(keyCode: 27, characters: "-", modifiers: .control)]
        case .audioDelayUp:
            return [VideoKeyboardShortcut(keyCode: 24, characters: "=", modifiers: .control)]
        case .subtitleDelayDown:
            return [VideoKeyboardShortcut(keyCode: 6, characters: "z")]
        case .subtitleDelayUp:
            return [VideoKeyboardShortcut(keyCode: 6, characters: "z", modifiers: .shift)]
        case .subtitleSizeDown:
            return [VideoKeyboardShortcut(keyCode: 5, characters: "g")]
        case .subtitleSizeUp:
            return [VideoKeyboardShortcut(keyCode: 5, characters: "g", modifiers: .shift)]
        case .subtitleMoveUp:
            return [VideoKeyboardShortcut(keyCode: 15, characters: "r")]
        case .subtitleMoveDown:
            return [VideoKeyboardShortcut(keyCode: 15, characters: "r", modifiers: .shift)]
        case .cycleAspectRatio, .cycleCropMode, .rotateVideoLeft, .rotateVideoRight:
            return []
        case .cycleDeinterlaceMode:
            return [VideoKeyboardShortcut(keyCode: 2, characters: "d")]
        case .subtitleCycle:
            return [VideoKeyboardShortcut(keyCode: 8, characters: "c")]
        case .subtitleToggle:
            return [VideoKeyboardShortcut(keyCode: 9, characters: "v")]
        case .audioCycle:
            return [VideoKeyboardShortcut(keyCode: 0, characters: "a")]
        case .seekTo0Percent:
            return [VideoKeyboardShortcut(keyCode: 29, characters: "0")]
        case .seekTo10Percent:
            return [VideoKeyboardShortcut(keyCode: 18, characters: "1")]
        case .seekTo20Percent:
            return [VideoKeyboardShortcut(keyCode: 19, characters: "2")]
        case .seekTo30Percent:
            return [VideoKeyboardShortcut(keyCode: 20, characters: "3")]
        case .seekTo40Percent:
            return [VideoKeyboardShortcut(keyCode: 21, characters: "4")]
        case .seekTo50Percent:
            return [VideoKeyboardShortcut(keyCode: 23, characters: "5")]
        case .seekTo60Percent:
            return [VideoKeyboardShortcut(keyCode: 22, characters: "6")]
        case .seekTo70Percent:
            return [VideoKeyboardShortcut(keyCode: 26, characters: "7")]
        case .seekTo80Percent:
            return [VideoKeyboardShortcut(keyCode: 28, characters: "8")]
        case .seekTo90Percent:
            return [VideoKeyboardShortcut(keyCode: 25, characters: "9")]
        case .toggleControlsLock:
            return []
        case .showAdvancedSettings:
            return [VideoKeyboardShortcut(keyCode: 43, characters: ",", modifiers: .command)]
        case .toggleMiniMode:
            return [VideoKeyboardShortcut(keyCode: 35, characters: "p")]
        }
    }

    public var seekPercentValue: Double? {
        switch self {
        case .seekTo0Percent: return 0
        case .seekTo10Percent: return 0.1
        case .seekTo20Percent: return 0.2
        case .seekTo30Percent: return 0.3
        case .seekTo40Percent: return 0.4
        case .seekTo50Percent: return 0.5
        case .seekTo60Percent: return 0.6
        case .seekTo70Percent: return 0.7
        case .seekTo80Percent: return 0.8
        case .seekTo90Percent: return 0.9
        default: return nil
        }
    }
}

public enum HomeTab: String, Codable, CaseIterable, Identifiable {
    case overview
    case nextUp
    case continueWatching
    case offline
    case recent
    case movies
    case tvShows
    case anime
    case documentaries
    case variety
    case homeVideos
    case music
    case other
    case favorites
    case unwatched
    case privacy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: return "总览"
        case .nextUp: return "下一集"
        case .continueWatching: return "继续观看"
        case .offline: return "离线"
        case .recent: return "最近添加"
        case .movies: return "电影"
        case .tvShows: return "电视剧"
        case .anime: return "动漫"
        case .documentaries: return "纪录片"
        case .variety: return "综艺"
        case .homeVideos: return "家庭录像"
        case .music: return "音乐"
        case .other: return "其他"
        case .favorites: return "喜欢"
        case .unwatched: return "未观看"
        case .privacy: return "保险库"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .nextUp: return "forward.end"
        case .continueWatching: return "play.circle"
        case .offline: return "arrow.down.circle"
        case .recent: return "clock"
        case .movies: return "film"
        case .tvShows: return "tv"
        case .anime: return "sparkles.tv"
        case .documentaries: return "books.vertical"
        case .variety: return "music.mic"
        case .homeVideos: return "video"
        case .music: return "music.note.list"
        case .other: return "tray"
        case .favorites: return "heart"
        case .unwatched: return "eye"
        case .privacy: return "lock.rectangle.stack"
        }
    }
}

public enum MusicMetadataProvider: String, Codable, CaseIterable, Identifiable {
    case musicBrainz
    case iTunes
    case neteaseCloud
    case qqMusic
    case lastFM
    case deezer
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .musicBrainz: return "MusicBrainz"
        case .iTunes: return "iTunes Search"
        case .neteaseCloud: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .lastFM: return "Last.fm"
        case .deezer: return "Deezer"
        case .disabled: return "关闭"
        }
    }

    /// 该来源是否需要 API Key（仅 Last.fm 需要）。
    public var requiresAPIKey: Bool {
        self == .lastFM
    }
}

/// 应用配色预设。custom 时使用 AppSettings 中的自定义十六进制颜色。
public enum AppThemePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case ocean
    case indigo
    case purple
    case rose
    case orange
    case mint
    case green
    case graphite
    case frosted
    case warm
    case oled
    case coral
    case lime
    case apricot
    case custom

    public static var allCases: [AppThemePreset] {
        [.classic, .coral, .lime, .apricot, .oled, .custom]
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted: return "清蓝"
        case .coral: return "珊瑚"
        case .lime: return "青柠"
        case .orange, .warm, .apricot: return "暖杏"
        case .graphite, .oled: return "夜幕"
        case .custom: return "自定义"
        }
    }

    public var isCustom: Bool { self == .custom }

    /// 各预设的种子颜色（浅色方案的 底色 / 高亮 / 左上光线，十六进制）。
    /// custom 由用户设置覆盖；深色方案在渲染层按规则派生。
    public var seedHex: (base: String, highlight: String, light: String) {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted, .custom:
            return ("F6F8FC", "327FDB", "F3F8FF")
        case .coral:
            return ("FAF5F3", "D95F54", "FFF1EC")
        case .lime:
            return ("F6F8F2", "6F9A48", "F1F7E9")
        case .orange, .warm, .apricot:
            return ("FAF5EC", "D17D42", "FFF1DF")
        case .graphite, .oled:
            return ("F3F5F9", "596FD8", "E9EEFF")
        }
    }

    /// 深色外观专用种子。显式给出可以让 OLED Dark 保持非纯黑的夜间基底，
    /// 同时避免浅色外观被误染成深色主题。
    public var darkSeedHex: (base: String, highlight: String, light: String) {
        switch self {
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted, .custom:
            return ("121820", "5B9FEA", "1A2936")
        case .coral:
            return ("1A1112", "EA766A", "3A211E")
        case .lime:
            return ("10170F", "93C75F", "243416")
        case .orange, .warm, .apricot:
            return ("19130E", "E79B58", "342213")
        case .graphite, .oled:
            return ("0C0E12", "7D92EE", "182039")
        }
    }
}

/// 音乐均衡器预设（5 段：60 / 230 / 910 / 3600 / 14000 Hz）。
public enum MusicEqualizerPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat
    case pop
    case rock
    case jazz
    case classical
    case bassBoost
    case vocal
    case trebleBoost

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flat: return "纯平"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .jazz: return "爵士"
        case .classical: return "古典"
        case .bassBoost: return "低音增强"
        case .vocal: return "人声"
        case .trebleBoost: return "高音增强"
        }
    }

    /// 各段增益（dB），顺序对应 60 / 230 / 910 / 3600 / 14000 Hz。
    public var gainsDB: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .pop: return [-1, 2, 4, 2, -1]
        case .rock: return [4, 2, -1, 2, 4]
        case .jazz: return [3, 1, 1, 2, 3]
        case .classical: return [4, 2, -1, 2, 3]
        case .bassBoost: return [6, 4, 1, 0, 0]
        case .vocal: return [-2, 0, 4, 3, 0]
        case .trebleBoost: return [0, 0, 1, 4, 6]
        }
    }

    public var isFlat: Bool { self == .flat }
}

/// TMDB / 元数据自动匹配的置信度宽容度。三档分别提高/降低自动套用所需的相似度阈值。
public enum MetadataMatchTolerance: String, Codable, CaseIterable, Identifiable {
    case loose
    case standard
    case strict

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .loose: return "宽松"
        case .standard: return "标准"
        case .strict: return "严格"
        }
    }

    public var summary: String {
        switch self {
        case .loose: return "更易匹配，命名混乱的库也能尽量覆盖（默认），可能偶有误配"
        case .standard: return "在准确度与覆盖率之间平衡"
        case .strict: return "仅高置信度才自动套用，最大限度避免误配"
        }
    }

    /// 视频自动匹配置信度阈值（标题相似度为主，年份加成）。
    public var videoThreshold: Double {
        switch self {
        case .loose: return 0.42
        case .standard: return 0.58
        case .strict: return 0.74
        }
    }

    /// 音乐自动匹配置信度阈值（标题 + 艺人加权）。
    public var musicThreshold: Double {
        switch self {
        case .loose: return 0.42
        case .standard: return 0.52
        case .strict: return 0.66
        }
    }
}

public enum LyricSyncAlgorithm: String, Codable, CaseIterable, Identifiable {
    case instant
    case balanced
    case audioEnergy
    case precise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instant: return "快速估算"
        case .balanced: return "语速校准"
        case .audioEnergy: return "音频校正"
        case .precise: return "精确优先"
        }
    }

    public var description: String {
        switch self {
        case .instant:
            return "按文字权重生成逐字时间，不分析音频。"
        case .balanced:
            return "结合标点、句尾留白和全曲语速校准，不分析音频。"
        case .audioEnergy:
            return "先使用语速校准，再在后台分析本地音频并自动更新结果。"
        case .precise:
            return "使用更细的音频分析进行校正，耗时更长；已有逐字歌词或缓存时直接使用。"
        }
    }

    public var usesBackgroundAlignment: Bool {
        switch self {
        case .audioEnergy, .precise: return true
        case .instant, .balanced: return false
        }
    }
}

public enum AutomaticScanInterval: String, Codable, CaseIterable, Identifiable {
    case disabled
    case fifteenMinutes
    case hourly
    case sixHours
    case daily

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: return "关闭"
        case .fifteenMinutes: return "每 15 分钟"
        case .hourly: return "每小时"
        case .sixHours: return "每 6 小时"
        case .daily: return "每天"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .disabled: return nil
        case .fifteenMinutes: return 15 * 60
        case .hourly: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .daily: return 24 * 60 * 60
        }
    }
}

public struct AppSettings: Codable, Hashable {
    private static let legacyDefaultHomeTabs: [HomeTab] = [
        .overview,
        .nextUp,
        .continueWatching,
        .recent,
        .movies,
        .tvShows,
        .anime,
        .documentaries,
        .variety,
        .music,
        .other,
        .favorites,
        .unwatched
    ]

    public static let defaultHomeTabs: [HomeTab] = [
        .overview,
        .nextUp,
        .continueWatching,
        .offline,
        .recent,
        .movies,
        .tvShows,
        .anime,
        .documentaries,
        .variety,
        .homeVideos,
        .music,
        .other,
        .favorites,
        .unwatched
    ]

    private static func normalizedEnabledHomeTabs(_ tabs: [HomeTab]) -> [HomeTab] {
        let configured = tabs.isEmpty ? defaultHomeTabs : tabs
        return configured == legacyDefaultHomeTabs ? defaultHomeTabs : configured
    }

    public var defaultPlayer: DefaultPlayer
    public var appLanguage: AppLanguage
    public var theme: AppTheme
    /// 配色预设 + 自定义颜色（十六进制，不含 #）。
    public var themePreset: AppThemePreset
    public var themeBaseHex: String?
    public var themeHighlightHex: String?
    public var themeLightHex: String?
    public var rememberPlaybackPosition: Bool
    /// 旧的「自动下一集」开关，仅用于向 videoPlaybackEndAction 迁移，不再被 UI 读取。
    public var autoPlayNextEpisode: Bool
    /// 视频播放结束后的行为（自动下一集 / 停在结尾 / 关闭窗口）。
    public var videoPlaybackEndAction: VideoPlaybackEndAction
    /// 按系列/影片记忆播放倍速（恢复 1.0 即清除记忆）。
    public var videoRememberPlaybackRate: Bool
    /// 鼠标中键动作。
    public var videoMiddleClickAction: VideoMiddleClickAction
    /// 鼠标侧键（后退/前进）动作。
    public var videoMouseBackForwardAction: VideoSideButtonAction
    /// 启动时使用固定窗口宽度（关闭则记忆上次拖拽后的宽度）。
    public var videoUseFixedLaunchWidth: Bool
    /// 启动窗口宽度占屏幕可用宽度的比例 0.45…1.0（1.0 = 占满屏幕宽度）。
    public var videoLaunchWidthRatio: Double
    /// 启动时把音量调整为固定值（关闭则沿用上次音量）。
    public var videoUseLaunchVolume: Bool
    /// 启动音量 0…1。
    public var videoLaunchVolume: Double
    /// 用户选择跳过的更新版本 tag（静默检查不再提示该版本）。
    public var updateSkippedVersion: String?
    /// 永不提醒更新（手动检查不受影响）。
    public var updateRemindersDisabled: Bool
    /// HDR 色调映射曲线。
    public var videoToneMappingMode: VideoToneMappingMode
    /// 视频音频均衡器开关（libmpv af 链，复用音乐均衡器预设）。
    public var videoEqualizerEnabled: Bool
    /// 视频音频均衡器预设。
    public var videoEqualizerPreset: MusicEqualizerPreset
    public var autoMarkWatched: Bool
    public var watchedThreshold: Double
    public var skipInterval: Double
    public var defaultVolume: Double
    public var lastVideoVolume: Double
    public var lastMusicVolume: Double
    public var defaultPlaybackRate: Double
    public var enableQuickPreview: Bool
    public var quickPreviewStartRatio: Double
    public var quickPreviewMuted: Bool
    public var enableThumbnailFallback: Bool
    public var thumbnailCaptureRatio: Double
    public var avoidBlackFrames: Bool
    public var artworkFallbackMode: ArtworkFallbackMode
    public var thumbnailConcurrency: Int
    public var posterMinWidth: Double
    public var posterMaxWidth: Double
    public var videoScrubberPreviewMode: VideoScrubberPreviewMode
    public var videoPlayerPreferredWidth: Double
    public var videoPlayerAlwaysOnTop: Bool
    public var videoMemoryBufferingEnabled: Bool
    public var videoShowRemainingTime: Bool
    public var videoResumeRewindSeconds: Double
    public var videoMarkerSkipBehavior: VideoMarkerSkipBehavior
    public var videoDoubleClickFullscreen: Bool
    public var videoMouseWheelVolumeEnabled: Bool
    public var videoHardwareDecodingMode: VideoHardwareDecodingMode
    public var videoDebandMode: VideoDebandMode
    /// 镜像翻转（水平 / 垂直 / 双向）。
    public var videoFlipMode: VideoFlipMode
    /// 画面锐化档位。
    public var videoSharpenMode: VideoSharpenMode
    /// 画面降噪档位。
    public var videoDenoiseMode: VideoDenoiseMode
    public var videoScreenshotMode: VideoScreenshotMode
    public var videoKeyboardShortcuts: [VideoPlayerShortcutAction: [VideoKeyboardShortcut]]
    public var videoTrackpadGesturesEnabled: Bool
    public var videoTrackpadHorizontalSeekEnabled: Bool
    public var videoTrackpadVerticalVolumeEnabled: Bool
    public var videoTrackpadPinchFullscreenEnabled: Bool
    public var videoTrackpadGestureSensitivity: VideoTrackpadGestureSensitivity
    public var videoDefaultAudioDelay: Double
    public var videoDefaultSubtitleDelay: Double
    public var videoDefaultSubtitleScale: Double
    public var videoDefaultSubtitlePosition: Double
    public var videoAspectOverride: VideoAspectOverride
    public var videoCropMode: VideoCropMode
    public var videoDeinterlaceMode: VideoDeinterlaceMode
    public var videoRotationMode: VideoRotationMode
    public var videoLoopCurrentItem: Bool
    /// 画面色彩微调（亮度 / 对比度 / 饱和度 / 伽马 / 色相）。
    public var videoColorAdjustments: VideoColorAdjustments
    /// 变速播放时保持音调（libmpv `audio-pitch-correction`），默认开启。
    public var videoPitchCorrectionEnabled: Bool
    /// 字幕样式（字体 / 粗体 / 颜色 / 描边 / 背景）。
    public var videoSubtitleStyle: VideoSubtitleStyle
    /// 视频音量增强倍率 1.0…2.0（libmpv `volume-max` 路径），1.0 表示不增强。
    public var videoVolumeBoost: Double
    public var enabledHomeTabs: [HomeTab]
    public var videoDefaultPlayer: DefaultPlayer
    public var musicDefaultPlayer: DefaultPlayer
    public var videoExternalPlayerPath: String?
    public var musicExternalPlayerPath: String?
    public var keepLocalAudioWithAirPlay: Bool
    public var tmdbAPIKey: String?
    public var tmdbLanguage: String
    /// TMDB / 元数据自动匹配的置信度宽容度（宽松/标准/严格）。
    public var metadataMatchTolerance: MetadataMatchTolerance
    public var musicMetadataProvider: MusicMetadataProvider
    /// 音乐元数据自动匹配宽容度；独立于影视，避免不同命名习惯互相牵连。
    public var musicMetadataMatchTolerance: MetadataMatchTolerance
    public var lyricSyncAlgorithm: LyricSyncAlgorithm
    public var musicLoudnessNormalization: MusicLoudnessNormalization
    public var musicTransitionMode: MusicTransitionMode
    public var musicSoftFadeDuration: Double
    public var musicAlbumCoverGlowEnabled: Bool
    /// 用户选择的视频缓存根目录；nil 时使用系统 Caches/MediaLib。
    public var videoCacheDirectoryPath: String?
    /// 离线视频缓存容量上限，0 表示不限制。
    public var videoCacheSizeLimitGB: Double
    /// 音乐均衡器开关与预设。
    public var musicEqualizerEnabled: Bool
    public var musicEqualizerPreset: MusicEqualizerPreset
    public var automaticScanInterval: AutomaticScanInterval
    /// 剧集 TMDB 自动拉取周期（复用扫描周期枚举：关闭/15 分钟/每小时/每 6 小时/每天）。
    public var automaticTMDBMatchInterval: AutomaticScanInterval
    public var externalPlayerPath: String?
    public var debugLoggingEnabled: Bool
    public var privacyVaultName: String
    public var privacyPINEnabled: Bool
    public var openSubtitlesAPIKey: String?
    public var subtitleLanguage: String
    /// Last.fm 音乐数据源的 API Key（其余音乐源无需密钥）。
    public var lastfmAPIKey: String?
    /// Last.fm 听歌打卡（Scrobbling）开关。
    public var lastfmScrobblingEnabled: Bool
    /// Last.fm 应用 Shared Secret（打卡签名所需）。
    public var lastfmSharedSecret: String?
    /// 授权后获得的长期 session key。
    public var lastfmSessionKey: String?
    /// 已连接的 Last.fm 用户名。
    public var lastfmUsername: String?
    /// 后台任务（扫描 / Emby 同步）完成后是否发送系统通知（仅在 App 非前台时提醒）。
    public var notifyOnTaskCompletion: Bool
    /// 是否已完成首次启动引导（完成或跳过后置 true，不再弹出）。
    public var hasCompletedOnboarding: Bool
    /// Trakt 同步：应用凭据、授权令牌与开关。
    public var traktClientID: String?
    public var traktClientSecret: String?
    public var traktAccessToken: String?
    public var traktRefreshToken: String?
    public var traktSyncEnabled: Bool

    public init(
        defaultPlayer: DefaultPlayer = .builtIn,
        appLanguage: AppLanguage = AppLanguage.systemDefault,
        theme: AppTheme = .light,
        themePreset: AppThemePreset = .classic,
        themeBaseHex: String? = nil,
        themeHighlightHex: String? = nil,
        themeLightHex: String? = nil,
        rememberPlaybackPosition: Bool = true,
        autoPlayNextEpisode: Bool = true,
        videoPlaybackEndAction: VideoPlaybackEndAction = .nextEpisode,
        videoRememberPlaybackRate: Bool = true,
        videoMiddleClickAction: VideoMiddleClickAction = .playPause,
        videoMouseBackForwardAction: VideoSideButtonAction = .seek,
        updateSkippedVersion: String? = nil,
        updateRemindersDisabled: Bool = false,
        videoUseFixedLaunchWidth: Bool = false,
        videoLaunchWidthRatio: Double = 0.7,
        videoUseLaunchVolume: Bool = false,
        videoLaunchVolume: Double = 0.8,
        videoToneMappingMode: VideoToneMappingMode = .auto,
        videoEqualizerEnabled: Bool = false,
        videoEqualizerPreset: MusicEqualizerPreset = .flat,
        autoMarkWatched: Bool = true,
        watchedThreshold: Double = 0.9,
        skipInterval: Double = 5,
        defaultVolume: Double = 0.8,
        lastVideoVolume: Double? = nil,
        lastMusicVolume: Double? = nil,
        defaultPlaybackRate: Double = 1.0,
        enableQuickPreview: Bool = true,
        quickPreviewStartRatio: Double = 0.1,
        quickPreviewMuted: Bool = true,
        enableThumbnailFallback: Bool = true,
        thumbnailCaptureRatio: Double = 0.1,
        avoidBlackFrames: Bool = true,
        artworkFallbackMode: ArtworkFallbackMode = .videoFrame,
        thumbnailConcurrency: Int = 2,
        posterMinWidth: Double = 150,
        posterMaxWidth: Double = 240,
        videoScrubberPreviewMode: VideoScrubberPreviewMode = .performance,
        videoPlayerPreferredWidth: Double = 1120,
        videoPlayerAlwaysOnTop: Bool = false,
        videoMemoryBufferingEnabled: Bool = true,
        videoShowRemainingTime: Bool = false,
        videoResumeRewindSeconds: Double = 5,
        videoMarkerSkipBehavior: VideoMarkerSkipBehavior = .prompt,
        videoDoubleClickFullscreen: Bool = true,
        videoMouseWheelVolumeEnabled: Bool = false,
        videoHardwareDecodingMode: VideoHardwareDecodingMode = .safe,
        videoDebandMode: VideoDebandMode = .off,
        videoFlipMode: VideoFlipMode = .none,
        videoSharpenMode: VideoSharpenMode = .off,
        videoDenoiseMode: VideoDenoiseMode = .off,
        videoScreenshotMode: VideoScreenshotMode = .subtitles,
        videoKeyboardShortcuts: [VideoPlayerShortcutAction: [VideoKeyboardShortcut]] = [:],
        videoTrackpadGesturesEnabled: Bool = true,
        videoTrackpadHorizontalSeekEnabled: Bool = true,
        videoTrackpadVerticalVolumeEnabled: Bool = true,
        videoTrackpadPinchFullscreenEnabled: Bool = false,
        videoTrackpadGestureSensitivity: VideoTrackpadGestureSensitivity = .standard,
        videoDefaultAudioDelay: Double = 0,
        videoDefaultSubtitleDelay: Double = 0,
        videoDefaultSubtitleScale: Double = 1,
        videoDefaultSubtitlePosition: Double = 100,
        videoAspectOverride: VideoAspectOverride = .source,
        videoCropMode: VideoCropMode = .none,
        videoDeinterlaceMode: VideoDeinterlaceMode = .off,
        videoRotationMode: VideoRotationMode = .source,
        videoLoopCurrentItem: Bool = false,
        videoColorAdjustments: VideoColorAdjustments = .neutral,
        videoPitchCorrectionEnabled: Bool = true,
        videoSubtitleStyle: VideoSubtitleStyle = .standard,
        videoVolumeBoost: Double = 1.0,
        enabledHomeTabs: [HomeTab] = AppSettings.defaultHomeTabs,
        videoDefaultPlayer: DefaultPlayer? = nil,
        musicDefaultPlayer: DefaultPlayer = .builtIn,
        videoExternalPlayerPath: String? = nil,
        musicExternalPlayerPath: String? = nil,
        keepLocalAudioWithAirPlay: Bool = false,
        tmdbAPIKey: String? = nil,
        tmdbLanguage: String = "zh-CN",
        metadataMatchTolerance: MetadataMatchTolerance = .loose,
        musicMetadataProvider: MusicMetadataProvider = .musicBrainz,
        musicMetadataMatchTolerance: MetadataMatchTolerance = .standard,
        lyricSyncAlgorithm: LyricSyncAlgorithm = .audioEnergy,
        musicLoudnessNormalization: MusicLoudnessNormalization = .track,
        musicTransitionMode: MusicTransitionMode = .immediate,
        musicSoftFadeDuration: Double = 0.8,
        musicAlbumCoverGlowEnabled: Bool = true,
        videoCacheDirectoryPath: String? = nil,
        videoCacheSizeLimitGB: Double = 0,
        musicEqualizerEnabled: Bool = false,
        musicEqualizerPreset: MusicEqualizerPreset = .flat,
        automaticScanInterval: AutomaticScanInterval = .disabled,
        automaticTMDBMatchInterval: AutomaticScanInterval = .disabled,
        externalPlayerPath: String? = nil,
        debugLoggingEnabled: Bool = false,
        privacyVaultName: String = "保险库",
        privacyPINEnabled: Bool = false,
        openSubtitlesAPIKey: String? = nil,
        subtitleLanguage: String = "zh-CN",
        lastfmAPIKey: String? = nil,
        lastfmScrobblingEnabled: Bool = false,
        lastfmSharedSecret: String? = nil,
        lastfmSessionKey: String? = nil,
        lastfmUsername: String? = nil,
        notifyOnTaskCompletion: Bool = false,
        hasCompletedOnboarding: Bool = false,
        traktClientID: String? = nil,
        traktClientSecret: String? = nil,
        traktAccessToken: String? = nil,
        traktRefreshToken: String? = nil,
        traktSyncEnabled: Bool = false
    ) {
        self.defaultPlayer = defaultPlayer
        self.appLanguage = appLanguage
        self.theme = theme
        self.themePreset = themePreset
        self.themeBaseHex = themeBaseHex
        self.themeHighlightHex = themeHighlightHex
        self.themeLightHex = themeLightHex
        self.rememberPlaybackPosition = rememberPlaybackPosition
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.videoPlaybackEndAction = videoPlaybackEndAction
        self.videoRememberPlaybackRate = videoRememberPlaybackRate
        self.videoMiddleClickAction = videoMiddleClickAction
        self.videoMouseBackForwardAction = videoMouseBackForwardAction
        self.updateSkippedVersion = updateSkippedVersion
        self.updateRemindersDisabled = updateRemindersDisabled
        self.videoUseFixedLaunchWidth = videoUseFixedLaunchWidth
        self.videoLaunchWidthRatio = Self.clampedVideoLaunchWidthRatio(videoLaunchWidthRatio)
        self.videoUseLaunchVolume = videoUseLaunchVolume
        self.videoLaunchVolume = Self.clampedVideoLaunchVolume(videoLaunchVolume)
        self.videoToneMappingMode = videoToneMappingMode
        self.videoEqualizerEnabled = videoEqualizerEnabled
        self.videoEqualizerPreset = videoEqualizerPreset
        self.autoMarkWatched = autoMarkWatched
        self.watchedThreshold = watchedThreshold
        self.skipInterval = skipInterval
        self.defaultVolume = defaultVolume
        self.lastVideoVolume = Self.clampedVolume(lastVideoVolume ?? defaultVolume)
        self.lastMusicVolume = Self.clampedVolume(lastMusicVolume ?? defaultVolume)
        self.defaultPlaybackRate = defaultPlaybackRate
        self.enableQuickPreview = enableQuickPreview
        self.quickPreviewStartRatio = quickPreviewStartRatio
        self.quickPreviewMuted = quickPreviewMuted
        self.enableThumbnailFallback = enableThumbnailFallback
        self.thumbnailCaptureRatio = thumbnailCaptureRatio
        self.avoidBlackFrames = avoidBlackFrames
        self.artworkFallbackMode = artworkFallbackMode
        self.thumbnailConcurrency = thumbnailConcurrency
        self.posterMinWidth = posterMinWidth
        self.posterMaxWidth = posterMaxWidth
        self.videoScrubberPreviewMode = videoScrubberPreviewMode
        self.videoPlayerPreferredWidth = videoPlayerPreferredWidth
        self.videoPlayerAlwaysOnTop = videoPlayerAlwaysOnTop
        self.videoMemoryBufferingEnabled = videoMemoryBufferingEnabled
        self.videoShowRemainingTime = videoShowRemainingTime
        self.videoResumeRewindSeconds = Self.clampedVideoResumeRewind(videoResumeRewindSeconds)
        self.videoMarkerSkipBehavior = videoMarkerSkipBehavior
        self.videoDoubleClickFullscreen = videoDoubleClickFullscreen
        self.videoMouseWheelVolumeEnabled = videoMouseWheelVolumeEnabled
        self.videoHardwareDecodingMode = videoHardwareDecodingMode
        self.videoDebandMode = videoDebandMode
        self.videoFlipMode = videoFlipMode
        self.videoSharpenMode = videoSharpenMode
        self.videoDenoiseMode = videoDenoiseMode
        self.videoScreenshotMode = videoScreenshotMode
        self.videoKeyboardShortcuts = Self.sanitizedVideoKeyboardShortcuts(videoKeyboardShortcuts)
        self.videoTrackpadGesturesEnabled = videoTrackpadGesturesEnabled
        self.videoTrackpadHorizontalSeekEnabled = videoTrackpadHorizontalSeekEnabled
        self.videoTrackpadVerticalVolumeEnabled = videoTrackpadVerticalVolumeEnabled
        self.videoTrackpadPinchFullscreenEnabled = videoTrackpadPinchFullscreenEnabled
        self.videoTrackpadGestureSensitivity = videoTrackpadGestureSensitivity
        self.videoDefaultAudioDelay = Self.clampedVideoSyncDelay(videoDefaultAudioDelay)
        self.videoDefaultSubtitleDelay = Self.clampedVideoSyncDelay(videoDefaultSubtitleDelay)
        self.videoDefaultSubtitleScale = Self.clampedVideoSubtitleScale(videoDefaultSubtitleScale)
        self.videoDefaultSubtitlePosition = Self.clampedVideoSubtitlePosition(videoDefaultSubtitlePosition)
        self.videoAspectOverride = videoAspectOverride
        self.videoCropMode = videoCropMode
        self.videoDeinterlaceMode = videoDeinterlaceMode
        self.videoRotationMode = videoRotationMode
        self.videoLoopCurrentItem = videoLoopCurrentItem
        self.videoColorAdjustments = videoColorAdjustments
        self.videoPitchCorrectionEnabled = videoPitchCorrectionEnabled
        self.videoSubtitleStyle = videoSubtitleStyle
        self.videoVolumeBoost = Self.clampedVideoVolumeBoost(videoVolumeBoost)
        self.enabledHomeTabs = Self.normalizedEnabledHomeTabs(enabledHomeTabs)
        self.videoDefaultPlayer = videoDefaultPlayer ?? defaultPlayer
        self.musicDefaultPlayer = musicDefaultPlayer
        self.videoExternalPlayerPath = videoExternalPlayerPath
        self.musicExternalPlayerPath = musicExternalPlayerPath
        self.keepLocalAudioWithAirPlay = keepLocalAudioWithAirPlay
        self.tmdbAPIKey = tmdbAPIKey
        self.tmdbLanguage = tmdbLanguage
        self.metadataMatchTolerance = metadataMatchTolerance
        self.musicMetadataProvider = musicMetadataProvider
        self.musicMetadataMatchTolerance = musicMetadataMatchTolerance
        self.lyricSyncAlgorithm = lyricSyncAlgorithm
        self.musicLoudnessNormalization = musicLoudnessNormalization
        self.musicTransitionMode = musicTransitionMode
        self.musicSoftFadeDuration = min(max(musicSoftFadeDuration, 0.3), 2)
        self.musicAlbumCoverGlowEnabled = musicAlbumCoverGlowEnabled
        self.videoCacheDirectoryPath = videoCacheDirectoryPath
        self.videoCacheSizeLimitGB = Self.clampedCacheSizeLimit(videoCacheSizeLimitGB)
        self.musicEqualizerEnabled = musicEqualizerEnabled
        self.musicEqualizerPreset = musicEqualizerPreset
        self.automaticScanInterval = automaticScanInterval
        self.automaticTMDBMatchInterval = automaticTMDBMatchInterval
        self.externalPlayerPath = externalPlayerPath
        self.debugLoggingEnabled = debugLoggingEnabled
        self.privacyVaultName = privacyVaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "保险库" : privacyVaultName
        self.privacyPINEnabled = privacyPINEnabled
        self.openSubtitlesAPIKey = openSubtitlesAPIKey
        self.subtitleLanguage = subtitleLanguage.isEmpty ? "zh-CN" : subtitleLanguage
        self.lastfmAPIKey = lastfmAPIKey
        self.lastfmScrobblingEnabled = lastfmScrobblingEnabled
        self.lastfmSharedSecret = lastfmSharedSecret
        self.lastfmSessionKey = lastfmSessionKey
        self.lastfmUsername = lastfmUsername
        self.notifyOnTaskCompletion = notifyOnTaskCompletion
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.traktClientID = traktClientID
        self.traktClientSecret = traktClientSecret
        self.traktAccessToken = traktAccessToken
        self.traktRefreshToken = traktRefreshToken
        self.traktSyncEnabled = traktSyncEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPlayer
        case appLanguage
        case theme
        case themePreset
        case themeBaseHex
        case themeHighlightHex
        case themeLightHex
        case rememberPlaybackPosition
        case autoPlayNextEpisode
        case videoPlaybackEndAction
        case videoRememberPlaybackRate
        case videoMiddleClickAction
        case videoMouseBackForwardAction
        case updateSkippedVersion
        case updateRemindersDisabled
        case videoUseFixedLaunchWidth
        case videoLaunchWidthRatio
        case videoUseLaunchVolume
        case videoLaunchVolume
        case videoToneMappingMode
        case videoEqualizerEnabled
        case videoEqualizerPreset
        case autoMarkWatched
        case watchedThreshold
        case skipInterval
        case defaultVolume
        case lastVideoVolume
        case lastMusicVolume
        case defaultPlaybackRate
        case enableQuickPreview
        case quickPreviewStartRatio
        case quickPreviewMuted
        case enableThumbnailFallback
        case thumbnailCaptureRatio
        case avoidBlackFrames
        case artworkFallbackMode
        case thumbnailConcurrency
        case posterMinWidth
        case posterMaxWidth
        case videoScrubberPreviewMode
        case videoPlayerPreferredWidth
        case videoPlayerAlwaysOnTop
        case videoMemoryBufferingEnabled
        case videoShowRemainingTime
        case videoResumeRewindSeconds
        case videoMarkerSkipBehavior
        case videoDoubleClickFullscreen
        case videoMouseWheelVolumeEnabled
        case videoHardwareDecodingMode
        case videoDebandMode
        case videoFlipMode
        case videoSharpenMode
        case videoDenoiseMode
        case videoScreenshotMode
        case videoKeyboardShortcuts
        case videoTrackpadGesturesEnabled
        case videoTrackpadHorizontalSeekEnabled
        case videoTrackpadVerticalVolumeEnabled
        case videoTrackpadPinchFullscreenEnabled
        case videoTrackpadGestureSensitivity
        case videoDefaultAudioDelay
        case videoDefaultSubtitleDelay
        case videoDefaultSubtitleScale
        case videoDefaultSubtitlePosition
        case videoAspectOverride
        case videoCropMode
        case videoDeinterlaceMode
        case videoRotationMode
        case videoLoopCurrentItem
        case videoColorAdjustments
        case videoPitchCorrectionEnabled
        case videoSubtitleStyle
        case videoVolumeBoost
        case enabledHomeTabs
        case videoDefaultPlayer
        case musicDefaultPlayer
        case videoExternalPlayerPath
        case musicExternalPlayerPath
        case keepLocalAudioWithAirPlay
        case tmdbAPIKey
        case tmdbLanguage
        case metadataMatchTolerance
        case musicMetadataProvider
        case musicMetadataMatchTolerance
        case lyricSyncAlgorithm
        case musicLoudnessNormalization
        case musicTransitionMode
        case musicSoftFadeDuration
        case musicAlbumCoverGlowEnabled
        case videoCacheDirectoryPath
        case videoCacheSizeLimitGB
        case musicEqualizerEnabled
        case musicEqualizerPreset
        case automaticScanInterval
        case automaticTMDBMatchInterval
        case externalPlayerPath
        case debugLoggingEnabled
        case privacyVaultName
        case privacyPINEnabled
        case openSubtitlesAPIKey
        case subtitleLanguage
        case lastfmAPIKey
        case lastfmScrobblingEnabled
        case lastfmSharedSecret
        case lastfmSessionKey
        case lastfmUsername
        case notifyOnTaskCompletion
        case hasCompletedOnboarding
        case traktClientID
        case traktClientSecret
        case traktAccessToken
        case traktRefreshToken
        case traktSyncEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        let legacyThumbnailFallback = try container.decodeIfPresent(Bool.self, forKey: .enableThumbnailFallback) ?? defaults.enableThumbnailFallback
        let decodedArtworkMode = try container.decodeIfPresent(ArtworkFallbackMode.self, forKey: .artworkFallbackMode)
        let legacyDefaultPlayer = try container.decodeIfPresent(DefaultPlayer.self, forKey: .defaultPlayer)
        let legacyExternalPlayerPath = try container.decodeIfPresent(String.self, forKey: .externalPlayerPath)
        let decodedVideoDefaultPlayer = try container.decodeIfPresent(DefaultPlayer.self, forKey: .videoDefaultPlayer)
        let decodedVideoExternalPlayerPath = try container.decodeIfPresent(String.self, forKey: .videoExternalPlayerPath)
        let legacyDefaultVolume = try container.decodeIfPresent(Double.self, forKey: .defaultVolume) ?? defaults.defaultVolume

        self.init(
            defaultPlayer: legacyDefaultPlayer ?? defaults.defaultPlayer,
            appLanguage: try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? defaults.appLanguage,
            theme: try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? defaults.theme,
            themePreset: try container.decodeIfPresent(AppThemePreset.self, forKey: .themePreset) ?? defaults.themePreset,
            themeBaseHex: try container.decodeIfPresent(String.self, forKey: .themeBaseHex) ?? defaults.themeBaseHex,
            themeHighlightHex: try container.decodeIfPresent(String.self, forKey: .themeHighlightHex) ?? defaults.themeHighlightHex,
            themeLightHex: try container.decodeIfPresent(String.self, forKey: .themeLightHex) ?? defaults.themeLightHex,
            rememberPlaybackPosition: try container.decodeIfPresent(Bool.self, forKey: .rememberPlaybackPosition) ?? defaults.rememberPlaybackPosition,
            autoPlayNextEpisode: try container.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode) ?? defaults.autoPlayNextEpisode,
            // 旧配置迁移：没存过结束行为时，沿用旧「自动下一集」开关的语义。
            videoPlaybackEndAction: try container.decodeIfPresent(VideoPlaybackEndAction.self, forKey: .videoPlaybackEndAction)
                ?? (((try? container.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode)) ?? true) ?? true ? .nextEpisode : .holdLastFrame),
            videoRememberPlaybackRate: try container.decodeIfPresent(Bool.self, forKey: .videoRememberPlaybackRate) ?? defaults.videoRememberPlaybackRate,
            videoMiddleClickAction: try container.decodeIfPresent(VideoMiddleClickAction.self, forKey: .videoMiddleClickAction) ?? defaults.videoMiddleClickAction,
            videoMouseBackForwardAction: try container.decodeIfPresent(VideoSideButtonAction.self, forKey: .videoMouseBackForwardAction) ?? defaults.videoMouseBackForwardAction,
            updateSkippedVersion: try container.decodeIfPresent(String.self, forKey: .updateSkippedVersion) ?? defaults.updateSkippedVersion,
            updateRemindersDisabled: try container.decodeIfPresent(Bool.self, forKey: .updateRemindersDisabled) ?? defaults.updateRemindersDisabled,
            videoUseFixedLaunchWidth: try container.decodeIfPresent(Bool.self, forKey: .videoUseFixedLaunchWidth) ?? defaults.videoUseFixedLaunchWidth,
            videoLaunchWidthRatio: try container.decodeIfPresent(Double.self, forKey: .videoLaunchWidthRatio) ?? defaults.videoLaunchWidthRatio,
            videoUseLaunchVolume: try container.decodeIfPresent(Bool.self, forKey: .videoUseLaunchVolume) ?? defaults.videoUseLaunchVolume,
            videoLaunchVolume: try container.decodeIfPresent(Double.self, forKey: .videoLaunchVolume) ?? defaults.videoLaunchVolume,
            videoToneMappingMode: try container.decodeIfPresent(VideoToneMappingMode.self, forKey: .videoToneMappingMode) ?? defaults.videoToneMappingMode,
            videoEqualizerEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoEqualizerEnabled) ?? defaults.videoEqualizerEnabled,
            videoEqualizerPreset: try container.decodeIfPresent(MusicEqualizerPreset.self, forKey: .videoEqualizerPreset) ?? defaults.videoEqualizerPreset,
            autoMarkWatched: try container.decodeIfPresent(Bool.self, forKey: .autoMarkWatched) ?? defaults.autoMarkWatched,
            watchedThreshold: try container.decodeIfPresent(Double.self, forKey: .watchedThreshold) ?? defaults.watchedThreshold,
            skipInterval: try container.decodeIfPresent(Double.self, forKey: .skipInterval) ?? defaults.skipInterval,
            defaultVolume: legacyDefaultVolume,
            lastVideoVolume: try container.decodeIfPresent(Double.self, forKey: .lastVideoVolume) ?? legacyDefaultVolume,
            lastMusicVolume: try container.decodeIfPresent(Double.self, forKey: .lastMusicVolume) ?? legacyDefaultVolume,
            defaultPlaybackRate: try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackRate) ?? defaults.defaultPlaybackRate,
            enableQuickPreview: try container.decodeIfPresent(Bool.self, forKey: .enableQuickPreview) ?? defaults.enableQuickPreview,
            quickPreviewStartRatio: try container.decodeIfPresent(Double.self, forKey: .quickPreviewStartRatio) ?? defaults.quickPreviewStartRatio,
            quickPreviewMuted: try container.decodeIfPresent(Bool.self, forKey: .quickPreviewMuted) ?? defaults.quickPreviewMuted,
            enableThumbnailFallback: legacyThumbnailFallback,
            thumbnailCaptureRatio: try container.decodeIfPresent(Double.self, forKey: .thumbnailCaptureRatio) ?? defaults.thumbnailCaptureRatio,
            avoidBlackFrames: try container.decodeIfPresent(Bool.self, forKey: .avoidBlackFrames) ?? defaults.avoidBlackFrames,
            artworkFallbackMode: decodedArtworkMode ?? (legacyThumbnailFallback ? defaults.artworkFallbackMode : .none),
            thumbnailConcurrency: try container.decodeIfPresent(Int.self, forKey: .thumbnailConcurrency) ?? defaults.thumbnailConcurrency,
            posterMinWidth: try container.decodeIfPresent(Double.self, forKey: .posterMinWidth) ?? defaults.posterMinWidth,
            posterMaxWidth: try container.decodeIfPresent(Double.self, forKey: .posterMaxWidth) ?? defaults.posterMaxWidth,
            videoScrubberPreviewMode: try container.decodeIfPresent(VideoScrubberPreviewMode.self, forKey: .videoScrubberPreviewMode) ?? defaults.videoScrubberPreviewMode,
            videoPlayerPreferredWidth: try container.decodeIfPresent(Double.self, forKey: .videoPlayerPreferredWidth) ?? defaults.videoPlayerPreferredWidth,
            videoPlayerAlwaysOnTop: try container.decodeIfPresent(Bool.self, forKey: .videoPlayerAlwaysOnTop) ?? defaults.videoPlayerAlwaysOnTop,
            videoMemoryBufferingEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoMemoryBufferingEnabled) ?? defaults.videoMemoryBufferingEnabled,
            videoShowRemainingTime: try container.decodeIfPresent(Bool.self, forKey: .videoShowRemainingTime) ?? defaults.videoShowRemainingTime,
            videoResumeRewindSeconds: try container.decodeIfPresent(Double.self, forKey: .videoResumeRewindSeconds) ?? defaults.videoResumeRewindSeconds,
            videoMarkerSkipBehavior: try container.decodeIfPresent(VideoMarkerSkipBehavior.self, forKey: .videoMarkerSkipBehavior) ?? defaults.videoMarkerSkipBehavior,
            videoDoubleClickFullscreen: try container.decodeIfPresent(Bool.self, forKey: .videoDoubleClickFullscreen) ?? defaults.videoDoubleClickFullscreen,
            videoMouseWheelVolumeEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoMouseWheelVolumeEnabled) ?? defaults.videoMouseWheelVolumeEnabled,
            videoHardwareDecodingMode: try container.decodeIfPresent(VideoHardwareDecodingMode.self, forKey: .videoHardwareDecodingMode) ?? defaults.videoHardwareDecodingMode,
            videoDebandMode: try container.decodeIfPresent(VideoDebandMode.self, forKey: .videoDebandMode) ?? defaults.videoDebandMode,
            videoFlipMode: try container.decodeIfPresent(VideoFlipMode.self, forKey: .videoFlipMode) ?? defaults.videoFlipMode,
            videoSharpenMode: try container.decodeIfPresent(VideoSharpenMode.self, forKey: .videoSharpenMode) ?? defaults.videoSharpenMode,
            videoDenoiseMode: try container.decodeIfPresent(VideoDenoiseMode.self, forKey: .videoDenoiseMode) ?? defaults.videoDenoiseMode,
            videoScreenshotMode: try container.decodeIfPresent(VideoScreenshotMode.self, forKey: .videoScreenshotMode) ?? defaults.videoScreenshotMode,
            videoKeyboardShortcuts: try container.decodeIfPresent([VideoPlayerShortcutAction: [VideoKeyboardShortcut]].self, forKey: .videoKeyboardShortcuts) ?? defaults.videoKeyboardShortcuts,
            videoTrackpadGesturesEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoTrackpadGesturesEnabled) ?? defaults.videoTrackpadGesturesEnabled,
            videoTrackpadHorizontalSeekEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoTrackpadHorizontalSeekEnabled) ?? defaults.videoTrackpadHorizontalSeekEnabled,
            videoTrackpadVerticalVolumeEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoTrackpadVerticalVolumeEnabled) ?? defaults.videoTrackpadVerticalVolumeEnabled,
            videoTrackpadPinchFullscreenEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoTrackpadPinchFullscreenEnabled) ?? defaults.videoTrackpadPinchFullscreenEnabled,
            videoTrackpadGestureSensitivity: try container.decodeIfPresent(VideoTrackpadGestureSensitivity.self, forKey: .videoTrackpadGestureSensitivity) ?? defaults.videoTrackpadGestureSensitivity,
            videoDefaultAudioDelay: try container.decodeIfPresent(Double.self, forKey: .videoDefaultAudioDelay) ?? defaults.videoDefaultAudioDelay,
            videoDefaultSubtitleDelay: try container.decodeIfPresent(Double.self, forKey: .videoDefaultSubtitleDelay) ?? defaults.videoDefaultSubtitleDelay,
            videoDefaultSubtitleScale: try container.decodeIfPresent(Double.self, forKey: .videoDefaultSubtitleScale) ?? defaults.videoDefaultSubtitleScale,
            videoDefaultSubtitlePosition: try container.decodeIfPresent(Double.self, forKey: .videoDefaultSubtitlePosition) ?? defaults.videoDefaultSubtitlePosition,
            videoAspectOverride: try container.decodeIfPresent(VideoAspectOverride.self, forKey: .videoAspectOverride) ?? defaults.videoAspectOverride,
            videoCropMode: try container.decodeIfPresent(VideoCropMode.self, forKey: .videoCropMode) ?? defaults.videoCropMode,
            videoDeinterlaceMode: try container.decodeIfPresent(VideoDeinterlaceMode.self, forKey: .videoDeinterlaceMode) ?? defaults.videoDeinterlaceMode,
            videoRotationMode: try container.decodeIfPresent(VideoRotationMode.self, forKey: .videoRotationMode) ?? defaults.videoRotationMode,
            videoLoopCurrentItem: try container.decodeIfPresent(Bool.self, forKey: .videoLoopCurrentItem) ?? defaults.videoLoopCurrentItem,
            videoColorAdjustments: try container.decodeIfPresent(VideoColorAdjustments.self, forKey: .videoColorAdjustments) ?? defaults.videoColorAdjustments,
            videoPitchCorrectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .videoPitchCorrectionEnabled) ?? defaults.videoPitchCorrectionEnabled,
            videoSubtitleStyle: try container.decodeIfPresent(VideoSubtitleStyle.self, forKey: .videoSubtitleStyle) ?? defaults.videoSubtitleStyle,
            videoVolumeBoost: try container.decodeIfPresent(Double.self, forKey: .videoVolumeBoost) ?? defaults.videoVolumeBoost,
            enabledHomeTabs: try container.decodeIfPresent([HomeTab].self, forKey: .enabledHomeTabs) ?? defaults.enabledHomeTabs,
            videoDefaultPlayer: decodedVideoDefaultPlayer ?? legacyDefaultPlayer ?? defaults.videoDefaultPlayer,
            musicDefaultPlayer: try container.decodeIfPresent(DefaultPlayer.self, forKey: .musicDefaultPlayer) ?? defaults.musicDefaultPlayer,
            videoExternalPlayerPath: decodedVideoExternalPlayerPath ?? legacyExternalPlayerPath ?? defaults.videoExternalPlayerPath,
            musicExternalPlayerPath: try container.decodeIfPresent(String.self, forKey: .musicExternalPlayerPath) ?? defaults.musicExternalPlayerPath,
            keepLocalAudioWithAirPlay: try container.decodeIfPresent(Bool.self, forKey: .keepLocalAudioWithAirPlay) ?? defaults.keepLocalAudioWithAirPlay,
            tmdbAPIKey: try container.decodeIfPresent(String.self, forKey: .tmdbAPIKey) ?? defaults.tmdbAPIKey,
            tmdbLanguage: try container.decodeIfPresent(String.self, forKey: .tmdbLanguage) ?? defaults.tmdbLanguage,
            metadataMatchTolerance: try container.decodeIfPresent(MetadataMatchTolerance.self, forKey: .metadataMatchTolerance) ?? defaults.metadataMatchTolerance,
            musicMetadataProvider: try container.decodeIfPresent(MusicMetadataProvider.self, forKey: .musicMetadataProvider) ?? defaults.musicMetadataProvider,
            musicMetadataMatchTolerance: try container.decodeIfPresent(MetadataMatchTolerance.self, forKey: .musicMetadataMatchTolerance)
                ?? (try container.decodeIfPresent(MetadataMatchTolerance.self, forKey: .metadataMatchTolerance) ?? defaults.musicMetadataMatchTolerance),
            lyricSyncAlgorithm: try container.decodeIfPresent(LyricSyncAlgorithm.self, forKey: .lyricSyncAlgorithm) ?? defaults.lyricSyncAlgorithm,
            musicLoudnessNormalization: try container.decodeIfPresent(MusicLoudnessNormalization.self, forKey: .musicLoudnessNormalization) ?? defaults.musicLoudnessNormalization,
            musicTransitionMode: try container.decodeIfPresent(MusicTransitionMode.self, forKey: .musicTransitionMode) ?? defaults.musicTransitionMode,
            musicSoftFadeDuration: try container.decodeIfPresent(Double.self, forKey: .musicSoftFadeDuration) ?? defaults.musicSoftFadeDuration,
            musicAlbumCoverGlowEnabled: try container.decodeIfPresent(Bool.self, forKey: .musicAlbumCoverGlowEnabled) ?? defaults.musicAlbumCoverGlowEnabled,
            videoCacheDirectoryPath: try container.decodeIfPresent(String.self, forKey: .videoCacheDirectoryPath) ?? defaults.videoCacheDirectoryPath,
            videoCacheSizeLimitGB: try container.decodeIfPresent(Double.self, forKey: .videoCacheSizeLimitGB) ?? defaults.videoCacheSizeLimitGB,
            musicEqualizerEnabled: try container.decodeIfPresent(Bool.self, forKey: .musicEqualizerEnabled) ?? defaults.musicEqualizerEnabled,
            musicEqualizerPreset: try container.decodeIfPresent(MusicEqualizerPreset.self, forKey: .musicEqualizerPreset) ?? defaults.musicEqualizerPreset,
            automaticScanInterval: try container.decodeIfPresent(AutomaticScanInterval.self, forKey: .automaticScanInterval) ?? defaults.automaticScanInterval,
            automaticTMDBMatchInterval: try container.decodeIfPresent(AutomaticScanInterval.self, forKey: .automaticTMDBMatchInterval) ?? defaults.automaticTMDBMatchInterval,
            externalPlayerPath: legacyExternalPlayerPath ?? defaults.externalPlayerPath,
            debugLoggingEnabled: try container.decodeIfPresent(Bool.self, forKey: .debugLoggingEnabled) ?? defaults.debugLoggingEnabled,
            privacyVaultName: try container.decodeIfPresent(String.self, forKey: .privacyVaultName) ?? defaults.privacyVaultName,
            privacyPINEnabled: try container.decodeIfPresent(Bool.self, forKey: .privacyPINEnabled) ?? false,
            openSubtitlesAPIKey: try container.decodeIfPresent(String.self, forKey: .openSubtitlesAPIKey) ?? defaults.openSubtitlesAPIKey,
            subtitleLanguage: try container.decodeIfPresent(String.self, forKey: .subtitleLanguage) ?? defaults.subtitleLanguage,
            lastfmAPIKey: try container.decodeIfPresent(String.self, forKey: .lastfmAPIKey) ?? defaults.lastfmAPIKey,
            lastfmScrobblingEnabled: try container.decodeIfPresent(Bool.self, forKey: .lastfmScrobblingEnabled) ?? defaults.lastfmScrobblingEnabled,
            lastfmSharedSecret: try container.decodeIfPresent(String.self, forKey: .lastfmSharedSecret) ?? defaults.lastfmSharedSecret,
            lastfmSessionKey: try container.decodeIfPresent(String.self, forKey: .lastfmSessionKey) ?? defaults.lastfmSessionKey,
            lastfmUsername: try container.decodeIfPresent(String.self, forKey: .lastfmUsername) ?? defaults.lastfmUsername,
            notifyOnTaskCompletion: try container.decodeIfPresent(Bool.self, forKey: .notifyOnTaskCompletion) ?? defaults.notifyOnTaskCompletion,
            hasCompletedOnboarding: try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding,
            traktClientID: try container.decodeIfPresent(String.self, forKey: .traktClientID) ?? defaults.traktClientID,
            traktClientSecret: try container.decodeIfPresent(String.self, forKey: .traktClientSecret) ?? defaults.traktClientSecret,
            traktAccessToken: try container.decodeIfPresent(String.self, forKey: .traktAccessToken) ?? defaults.traktAccessToken,
            traktRefreshToken: try container.decodeIfPresent(String.self, forKey: .traktRefreshToken) ?? defaults.traktRefreshToken,
            traktSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .traktSyncEnabled) ?? defaults.traktSyncEnabled
        )
    }

    public func resolvedVideoKeyboardShortcuts(for action: VideoPlayerShortcutAction) -> [VideoKeyboardShortcut] {
        if let custom = videoKeyboardShortcuts[action] {
            return custom.filter(\.isEnabled)
        }
        return action.defaultShortcuts
    }

    public func videoPlayerShortcutAction(for shortcut: VideoKeyboardShortcut) -> VideoPlayerShortcutAction? {
        let shortcut = shortcut.normalized
        guard shortcut.isEnabled else { return nil }
        return VideoPlayerShortcutAction.allCases.first { action in
            resolvedVideoKeyboardShortcuts(for: action).map(\.normalized).contains(shortcut)
        }
    }

    /// 查询某个组合键当前是否已被「除 `action` 之外」的其它动作占用，返回冲突动作。
    /// 用于在录制快捷键时先给出冲突提示，而不是静默把按键从其它动作上抢过来。
    public func videoPlayerShortcutConflict(
        for shortcut: VideoKeyboardShortcut,
        excluding action: VideoPlayerShortcutAction
    ) -> VideoPlayerShortcutAction? {
        let shortcut = shortcut.normalized
        guard shortcut.isEnabled else { return nil }
        return VideoPlayerShortcutAction.allCases.first { other in
            other != action && resolvedVideoKeyboardShortcuts(for: other).map(\.normalized).contains(shortcut)
        }
    }

    public mutating func setVideoKeyboardShortcuts(_ shortcuts: [VideoKeyboardShortcut], for action: VideoPlayerShortcutAction) {
        let enabledShortcuts = shortcuts
            .filter(\.isEnabled)
            .map(\.normalized)
            .reduce(into: [VideoKeyboardShortcut]()) { result, shortcut in
                if !result.contains(shortcut) {
                    result.append(shortcut)
                }
            }

        for otherAction in VideoPlayerShortcutAction.allCases where otherAction != action {
            var existing = resolvedVideoKeyboardShortcuts(for: otherAction)
            let oldCount = existing.count
            existing.removeAll { enabledShortcuts.contains($0) }
            if existing.count != oldCount {
                videoKeyboardShortcuts[otherAction] = existing
            }
        }

        videoKeyboardShortcuts[action] = enabledShortcuts
        videoKeyboardShortcuts = Self.sanitizedVideoKeyboardShortcuts(videoKeyboardShortcuts)
    }

    public mutating func resetVideoKeyboardShortcut(for action: VideoPlayerShortcutAction) {
        videoKeyboardShortcuts.removeValue(forKey: action)
    }

    public mutating func resetAllVideoKeyboardShortcuts() {
        videoKeyboardShortcuts = [:]
    }

    public func rememberedVolume(for mediaType: MediaType) -> Double {
        mediaType == .music ? lastMusicVolume : lastVideoVolume
    }

    public mutating func setRememberedVolume(_ volume: Double, for mediaType: MediaType) {
        let clamped = Self.clampedVolume(volume)
        if mediaType == .music {
            lastMusicVolume = clamped
        } else {
            lastVideoVolume = clamped
        }
    }

    private static func clampedVolume(_ volume: Double) -> Double {
        min(max(volume, 0), 1)
    }

    public static func clampedVideoSyncDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value * 10).rounded() / 10, -3), 3)
    }

    public static func clampedVideoSubtitleScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max((value * 20).rounded() / 20, 0.75), 1.5)
    }

    public static func clampedVideoSubtitlePosition(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value.rounded(), 70), 100)
    }

    public static func clampedVideoVolumeBoost(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 1.0), 2.0)
    }

    public static func clampedVideoLaunchWidthRatio(_ value: Double) -> Double {
        guard value.isFinite else { return 0.7 }
        return min(max(value, 0.45), 1.0)
    }

    public static func clampedVideoLaunchVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 0.8 }
        return min(max(value, 0), 1)
    }

    public static func clampedVideoResumeRewind(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value / 5).rounded() * 5, 0), 30)
    }

    private static func sanitizedVideoKeyboardShortcuts(_ shortcuts: [VideoPlayerShortcutAction: [VideoKeyboardShortcut]]) -> [VideoPlayerShortcutAction: [VideoKeyboardShortcut]] {
        shortcuts.reduce(into: [VideoPlayerShortcutAction: [VideoKeyboardShortcut]]()) { result, element in
            let unique = element.value
                .filter(\.isEnabled)
                .map(\.normalized)
                .reduce(into: [VideoKeyboardShortcut]()) { list, shortcut in
                    if !list.contains(shortcut) {
                        list.append(shortcut)
                    }
                }
            if !unique.isEmpty || element.value.isEmpty {
                result[element.key] = unique
            }
        }
    }

    private static func clampedCacheSizeLimit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 4096)
    }
}
