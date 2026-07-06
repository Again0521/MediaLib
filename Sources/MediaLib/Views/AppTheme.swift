import AppKit
import MediaLibCore
import SwiftUI

struct AppThemeColorToken: Equatable {
    var light: NSColor
    var dark: NSColor

    init(lightHex: String, darkHex: String) {
        light = NSColor(appThemeHex: lightHex) ?? .labelColor
        dark = NSColor(appThemeHex: darkHex) ?? .labelColor
    }
}

/// 语义主题 token。普通页面应优先使用这些语义色或 AppColors 的派生色，
/// 不在页面内散落新硬编码颜色；动态专辑色只作为氛围层输入。
struct AppThemeTokens: Equatable {
    var name: String
    var usage: String
    var primary: AppThemeColorToken
    var secondary: AppThemeColorToken
    var accent: AppThemeColorToken
    var background: AppThemeColorToken
    var surface: AppThemeColorToken
    var elevatedSurface: AppThemeColorToken
    var border: AppThemeColorToken
    var textPrimary: AppThemeColorToken
    var textSecondary: AppThemeColorToken
    var success: AppThemeColorToken
    var warning: AppThemeColorToken
    var error: AppThemeColorToken
}

/// 已解析的应用配色：3 个可定制锚点（底色 / 高亮 / 左上光线），各含浅色与深色方案值。
/// 其余具体色板（页面底、卡片、输入框、描边、光晕等）在 AppColors 中由这三个锚点按固定明度/透明度派生，
/// 以保证用户换色时整套层次结构（除音乐展开页外）一致更新。
struct ResolvedAppTheme: Equatable {
    var tokens: AppThemeTokens
    var baseLight: NSColor
    var baseDark: NSColor
    var highlightLight: NSColor
    var highlightDark: NSColor
    var lightLight: NSColor
    var lightDark: NSColor

    /// 系统蓝默认：接近 Apple 平台默认浅灰底 + system blue 强调色。
    static let classic = AppThemeResolver.resolve(preset: .classic)
}

enum AppThemeResolver {
    static func resolve(for settings: AppSettings) -> ResolvedAppTheme {
        let preset = settings.themePreset.canonicalPreset
        let seed = preset.seedHex
        if preset.isCustom {
            return resolve(
                baseHex: settings.themeBaseHex ?? seed.base,
                highlightHex: settings.themeHighlightHex ?? seed.highlight,
                lightHex: settings.themeLightHex ?? seed.light,
                tokens: Self.customTokens(
                    baseHex: settings.themeBaseHex ?? seed.base,
                    highlightHex: settings.themeHighlightHex ?? seed.highlight,
                    lightHex: settings.themeLightHex ?? seed.light
                )
            )
        }
        return resolve(preset: preset)
    }

    static func resolve(preset: AppThemePreset) -> ResolvedAppTheme {
        let seed = preset.seedHex
        let darkSeed = preset.darkSeedHex
        return resolve(
            baseLightHex: seed.base,
            highlightLightHex: seed.highlight,
            lightLightHex: seed.light,
            baseDarkHex: darkSeed.base,
            highlightDarkHex: darkSeed.highlight,
            lightDarkHex: darkSeed.light,
            tokens: Self.tokens(for: preset)
        )
    }

    static func resolve(baseHex: String, highlightHex: String, lightHex: String, tokens: AppThemeTokens) -> ResolvedAppTheme {
        let base = NSColor(appThemeHex: baseHex) ?? NSColor(calibratedRed: 0.940, green: 0.938, blue: 0.928, alpha: 1)
        let highlight = NSColor(appThemeHex: highlightHex) ?? NSColor(calibratedRed: 0.38, green: 0.58, blue: 0.90, alpha: 1)
        let light = NSColor(appThemeHex: lightHex) ?? NSColor(calibratedRed: 1.0, green: 0.965, blue: 0.875, alpha: 1)

        let graphite = NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.116, alpha: 1)
        return resolve(
            baseLightHex: base.appThemeHexString,
            highlightLightHex: highlight.appThemeHexString,
            lightLightHex: light.appThemeHexString,
            baseDarkHex: graphite.appThemeBlended(toward: base.appThemeSaturated(by: 1.0), fraction: 0.10).appThemeHexString,
            highlightDarkHex: highlight.appThemeAdjustingBrightness(by: 1.14).appThemeBlended(toward: .white, fraction: 0.06).appThemeHexString,
            lightDarkHex: light.appThemeAdjustingBrightness(by: 0.90).appThemeBlended(toward: NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.74, alpha: 1), fraction: 0.35).appThemeHexString,
            tokens: tokens
        )
    }

    static func resolve(
        baseLightHex: String,
        highlightLightHex: String,
        lightLightHex: String,
        baseDarkHex: String,
        highlightDarkHex: String,
        lightDarkHex: String,
        tokens: AppThemeTokens
    ) -> ResolvedAppTheme {
        ResolvedAppTheme(
            tokens: tokens,
            baseLight: NSColor(appThemeHex: baseLightHex) ?? NSColor(calibratedRed: 0.940, green: 0.938, blue: 0.928, alpha: 1),
            baseDark: NSColor(appThemeHex: baseDarkHex) ?? NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.116, alpha: 1),
            highlightLight: NSColor(appThemeHex: highlightLightHex) ?? NSColor(calibratedRed: 0.38, green: 0.58, blue: 0.90, alpha: 1),
            highlightDark: NSColor(appThemeHex: highlightDarkHex) ?? NSColor(calibratedRed: 0.46, green: 0.67, blue: 0.95, alpha: 1),
            lightLight: NSColor(appThemeHex: lightLightHex) ?? NSColor(calibratedRed: 1.0, green: 0.965, blue: 0.875, alpha: 1),
            lightDark: NSColor(appThemeHex: lightDarkHex) ?? NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.22, alpha: 1)
        )
    }

    private static func customTokens(baseHex: String, highlightHex: String, lightHex: String) -> AppThemeTokens {
        AppThemeTokens(
            name: "自定义",
            usage: "用户自定义底色、高亮和左上环境光；适合在不破坏整体层级的前提下微调个人偏好。",
            primary: AppThemeColorToken(lightHex: highlightHex, darkHex: highlightHex),
            secondary: AppThemeColorToken(lightHex: lightHex, darkHex: "A8B5C3"),
            accent: AppThemeColorToken(lightHex: highlightHex, darkHex: highlightHex),
            background: AppThemeColorToken(lightHex: baseHex, darkHex: "10151B"),
            surface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "17202A"),
            elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "202B36"),
            border: AppThemeColorToken(lightHex: "D8DEE8", darkHex: "354458"),
            textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F5F5F7"),
            textSecondary: AppThemeColorToken(lightHex: "6E6E73", darkHex: "A9B4C2"),
            success: AppThemeColorToken(lightHex: "34C759", darkHex: "30D158"),
            warning: AppThemeColorToken(lightHex: "FF9F0A", darkHex: "FFD60A"),
            error: AppThemeColorToken(lightHex: "FF3B30", darkHex: "FF453A")
        )
    }

    private static func tokens(for preset: AppThemePreset) -> AppThemeTokens {
        switch preset {
        case .graphite, .oled, .seaSalt, .duskViolet:
            return AppThemeTokens(
                name: "Dusk Violet",
                usage: "雅致紫罗兰与暮色冷灰的平衡方案，低饱和不刺眼，适合长时间浏览、海报墙与安静的夜间场景。",
                primary: AppThemeColorToken(lightHex: "6E5C9E", darkHex: "B5A6E8"),
                secondary: AppThemeColorToken(lightHex: "8B7FB0", darkHex: "9AB9D8"),
                accent: AppThemeColorToken(lightHex: "6553A0", darkHex: "C0A9EE"),
                background: AppThemeColorToken(lightHex: "F5F3F9", darkHex: "14131B"),
                surface: AppThemeColorToken(lightHex: "FCFBFE", darkHex: "1C1A25"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "272532"),
                border: AppThemeColorToken(lightHex: "E2DCEE", darkHex: "3A3548"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F4F1FA"),
                textSecondary: AppThemeColorToken(lightHex: "6A6577", darkHex: "B0A8C4"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "C98732", darkHex: "E6B866"),
                error: AppThemeColorToken(lightHex: "D74E45", darkHex: "FF6B62")
            )
        case .coral:
            return AppThemeTokens(
                name: "Soft Coral",
                usage: "年轻、轻快的媒体库和音乐场景；珊瑚红偏温暖但不过饱和，不做霓虹或游戏化表达。",
                primary: AppThemeColorToken(lightHex: "DC5B4F", darkHex: "F28A7D"),
                secondary: AppThemeColorToken(lightHex: "D99086", darkHex: "D7A99F"),
                accent: AppThemeColorToken(lightHex: "CE5347", darkHex: "FF917F"),
                background: AppThemeColorToken(lightHex: "FAF5F3", darkHex: "1B1214"),
                surface: AppThemeColorToken(lightHex: "FFFDFC", darkHex: "25191B"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "302123"),
                border: AppThemeColorToken(lightHex: "E9D9D4", darkHex: "4A3435"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F5F5F7"),
                textSecondary: AppThemeColorToken(lightHex: "746B67", darkHex: "BFA9A5"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "D18A2C", darkHex: "E8B45C"),
                error: AppThemeColorToken(lightHex: "D94F45", darkHex: "FF6B62")
            )
        case .lime:
            return AppThemeTokens(
                name: "Clean Lime",
                usage: "更年轻的清新主题，适合音乐、歌单和日常浏览；绿色压低饱和度，避免荧光感。",
                primary: AppThemeColorToken(lightHex: "6C9C3F", darkHex: "A8D96D"),
                secondary: AppThemeColorToken(lightHex: "91B16A", darkHex: "B4CB8C"),
                accent: AppThemeColorToken(lightHex: "5F8B38", darkHex: "B3DF78"),
                background: AppThemeColorToken(lightHex: "F6F8F2", darkHex: "10160F"),
                surface: AppThemeColorToken(lightHex: "FEFFFB", darkHex: "182117"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "22301D"),
                border: AppThemeColorToken(lightHex: "DDE8D0", darkHex: "354A2A"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F5F7F1"),
                textSecondary: AppThemeColorToken(lightHex: "67705F", darkHex: "B2C59D"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "C98732", darkHex: "E6B866"),
                error: AppThemeColorToken(lightHex: "D74E45", darkHex: "FF6B62")
            )
        case .orange, .warm, .apricot, .sandGold:
            return AppThemeTokens(
                name: "Sand Gold",
                usage: "以香槟金和浅砂岩替代旧橙杏调，保留温度但压低甜腻感，适合收藏、音乐与家庭媒体场景。",
                primary: AppThemeColorToken(lightHex: "886127", darkHex: "DDBA74"),
                secondary: AppThemeColorToken(lightHex: "A88956", darkHex: "C9B892"),
                accent: AppThemeColorToken(lightHex: "7C571F", darkHex: "E8C47B"),
                background: AppThemeColorToken(lightHex: "FAF7F0", darkHex: "181510"),
                surface: AppThemeColorToken(lightHex: "FFFDF9", darkHex: "221D16"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "2D271C"),
                border: AppThemeColorToken(lightHex: "E7DDCA", darkHex: "493F2E"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F7F2E9"),
                textSecondary: AppThemeColorToken(lightHex: "70685B", darkHex: "BFB092"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "B87722", darkHex: "E7B563"),
                error: AppThemeColorToken(lightHex: "D74E45", darkHex: "FF6B62")
            )
        case .grape, .mica:
            return AppThemeTokens(
                name: "Moon Mica",
                usage: "中性月白、云母灰与钢蓝高亮组成的珍珠主题，适合设置、资料整理和需要低干扰的长时间浏览。",
                primary: AppThemeColorToken(lightHex: "5B7087", darkHex: "9DB2C8"),
                secondary: AppThemeColorToken(lightHex: "8793A0", darkHex: "B3BCC6"),
                accent: AppThemeColorToken(lightHex: "52677D", darkHex: "A9C2D5"),
                background: AppThemeColorToken(lightHex: "F4F5F3", darkHex: "101416"),
                surface: AppThemeColorToken(lightHex: "FDFDFC", darkHex: "181E22"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "222A2F"),
                border: AppThemeColorToken(lightHex: "DDE1E2", darkHex: "374149"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F4F5F3"),
                textSecondary: AppThemeColorToken(lightHex: "666D73", darkHex: "ACB7BF"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "C98732", darkHex: "E6B866"),
                error: AppThemeColorToken(lightHex: "D74E45", darkHex: "FF6B62")
            )
        case .mistTeal:
            return AppThemeTokens(
                name: "Misty Teal",
                usage: "雾感蓝绿 / 莫兰迪青，安静耐看；适合长时间浏览与古典、器乐场景。低饱和不刺眼。",
                primary: AppThemeColorToken(lightHex: "3E8D82", darkHex: "66BFB3"),
                secondary: AppThemeColorToken(lightHex: "6FA59C", darkHex: "9AD2C8"),
                accent: AppThemeColorToken(lightHex: "357F76", darkHex: "70CDBF"),
                background: AppThemeColorToken(lightHex: "F1F6F4", darkHex: "0C1515"),
                surface: AppThemeColorToken(lightHex: "FBFEFD", darkHex: "14201F"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "1D2B29"),
                border: AppThemeColorToken(lightHex: "D8E6E1", darkHex: "2E403D"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F1F6F4"),
                textSecondary: AppThemeColorToken(lightHex: "63716C", darkHex: "A4BCB5"),
                success: AppThemeColorToken(lightHex: "2FA463", darkHex: "5AD184"),
                warning: AppThemeColorToken(lightHex: "C98732", darkHex: "E6B866"),
                error: AppThemeColorToken(lightHex: "D74E45", darkHex: "FF6B62")
            )
        case .classic, .ocean, .indigo, .purple, .rose, .mint, .green, .frosted, .custom:
            return AppThemeTokens(
                name: "Apple Clean Blue",
                usage: "默认主题、全局媒体库、初次使用和需要最强原生感的页面；接近 Apple Music、TV、Finder 的综合气质。",
                primary: AppThemeColorToken(lightHex: "2C7CE0", darkHex: "78B7FF"),
                secondary: AppThemeColorToken(lightHex: "72B6E8", darkHex: "87D0F4"),
                accent: AppThemeColorToken(lightHex: "3A82E6", darkHex: "8BC4FF"),
                background: AppThemeColorToken(lightHex: "F6F8FC", darkHex: "101722"),
                surface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "172230"),
                elevatedSurface: AppThemeColorToken(lightHex: "FFFFFF", darkHex: "213040"),
                border: AppThemeColorToken(lightHex: "D8DEE8", darkHex: "334459"),
                textPrimary: AppThemeColorToken(lightHex: "1D1D1F", darkHex: "F5F5F7"),
                textSecondary: AppThemeColorToken(lightHex: "6E6E73", darkHex: "A8B4C3"),
                success: AppThemeColorToken(lightHex: "34C759", darkHex: "30D158"),
                warning: AppThemeColorToken(lightHex: "FF9F0A", darkHex: "FFD60A"),
                error: AppThemeColorToken(lightHex: "FF3B30", darkHex: "FF453A")
            )
        }
    }
}

extension NSColor {
    convenience init?(appThemeHex hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    var appThemeHexString: String {
        let c = usingColorSpace(.deviceRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// 以给定透明度返回同色。
    func appThemeWithAlpha(_ alpha: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        return NSColor(calibratedRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: alpha)
    }

    /// 向目标色混合 fraction（0…1）。
    func appThemeBlended(toward other: NSColor, fraction: CGFloat) -> NSColor {
        let a = usingColorSpace(.deviceRGB) ?? self
        let b = other.usingColorSpace(.deviceRGB) ?? other
        let f = min(max(fraction, 0), 1)
        return NSColor(
            calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * f,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
            alpha: 1
        )
    }

    /// 向白色提亮（amount 0…1）。
    func appThemeLightened(by amount: CGFloat) -> NSColor {
        appThemeBlended(toward: .white, fraction: amount)
    }

    /// 亮度乘法调整（>1 提亮，<1 压暗）。
    func appThemeAdjustingBrightness(by factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &br, alpha: &al)
        return NSColor(calibratedHue: h, saturation: s, brightness: min(max(br * factor, 0), 1), alpha: al)
    }

    /// 饱和度乘法调整。
    func appThemeSaturated(by factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &br, alpha: &al)
        return NSColor(calibratedHue: h, saturation: min(max(s * factor, 0), 1), brightness: br, alpha: al)
    }

    /// 色相旋转（delta 以圈为单位，0…1 = 0…360°）。
    func appThemeHueRotated(by delta: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &br, alpha: &al)
        var nh = (h + delta).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return NSColor(calibratedHue: nh, saturation: s, brightness: br, alpha: al)
    }
}
