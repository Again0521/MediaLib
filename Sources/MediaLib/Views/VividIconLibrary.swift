import SwiftUI

// 忠实复刻「MediaLIB 系统页面.dc.html」设计稿里的 Lucide 风格线性图标库。
//
// 设计稿所有图标统一规格：viewBox 0 0 24 24、fill:none、stroke-width 2、
// stroke-linecap/linejoin = round。本文件用一个真正的 SVG path 解析器，把设计稿
// `icon(name)` 里每个图标的 path `d` 字符串逐字搬过来渲染，做到「严格按 HTML 风格绘制」。
//
// 注意：左侧栏与首页图标按用户要求不在此切换，仍沿用各自原有实现；本库供其余页面
// （媒体源 / 设置 / 任务中心 / 片库健康 / 音乐 / 相册 / 详情 / 播放器等）统一调用。

/// 一个 24×24 网格上的线性图标视图，描边 2px、round cap/join，居中铺满 size。
struct VividIcon: View {
    let name: String
    var size: CGFloat = 18
    /// 描边宽度，默认 2（与设计稿一致）。个别强调场景设计稿用 2.2~2.6，可按需覆盖。
    var lineWidth: CGFloat = 2

    var body: some View {
        VividIconShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// 把指定图标绘制到 rect 中央、按短边缩放到 24 网格。
struct VividIconShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let tx = rect.midX - 12 * scale
        let ty = rect.midY - 12 * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        var path = Path()
        VividIconLibrary.build(name, into: &path)
        return path.applying(transform)
    }
}

// MARK: - 图标定义表

enum VividIconLibrary {
    /// 已收录的图标名（便于校验拼写 / 回退）。
    static let names: Set<String> = [
        "home", "play", "tv", "anime", "lock", "plus", "box", "music", "note", "disc",
        "artists", "clock", "image", "grid", "video", "drive", "server", "nas", "health",
        "tasks", "dashboard", "gear", "sliders", "scan", "select", "refresh", "art", "meta", "caching", "heart",
        "m3u", "sources", "moon", "bell", "globe", "info", "hdd",
        "search", "chevronDown", "chevronUp", "chevronLeft", "chevronRight", "sortGlyph",
        "star", "checkCircle", "check", "shuffle", "trash", "fingerprint", "close",
        "pause", "minus", "edit", "download", "share", "ellipsis", "eye", "eyeOff",
        // —— 设计稿风格派生（HTML 未直接给出，但沿用同样 Lucide 线性语言补齐）——
        "warn", "folder", "person", "circle", "link", "bookmark",
        "stop", "tag", "copy", "externalLink", "chart", "calendar"
    ]

    static func has(_ name: String) -> Bool { names.contains(name) }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, into p: inout Path) {
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    private static func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, into p: inout Path) {
        p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
    }

    private static func d(_ s: String, into p: inout Path) { SVGPathParser.append(s, to: &p) }

    static func build(_ name: String, into p: inout Path) {
        switch name {
        case "home":
            d("M3 10.5 12 3l9 7.5", into: &p); d("M5 9.5V20h14V9.5", into: &p)
        case "play":
            d("m7 5 12 7-12 7z", into: &p)
        case "pause":
            d("M8 5v14", into: &p); d("M16 5v14", into: &p)
        case "tv":
            rrect(2.5, 5, 19, 13, 2.5, into: &p); d("M8 21h8", into: &p)
        case "anime":
            rrect(3, 4, 18, 14, 2.5, into: &p); circle(8.5, 9.5, 1.8, into: &p); d("m4 17 5-4 4 3 3-2 4 3", into: &p)
        case "lock":
            rrect(4, 10, 16, 11, 2.5, into: &p); d("M8 10V7a4 4 0 0 1 8 0v3", into: &p)
        case "plus":
            d("M12 5v14", into: &p); d("M5 12h14", into: &p)
        case "minus":
            d("M5 12h14", into: &p)
        case "box":
            d("M3 7l9-4 9 4-9 4-9-4z", into: &p); d("M3 7v10l9 4 9-4V7", into: &p)
        case "music":
            d("M9 18V5l11-2v13", into: &p); circle(6, 18, 3, into: &p); circle(17, 16, 3, into: &p)
        case "note":
            d("M9 18V6l9-2v11", into: &p); circle(6, 18, 3, into: &p)
        case "disc":
            rrect(6, 3, 12, 18, 3, into: &p); circle(12, 9, 2.4, into: &p); d("M12 13v5", into: &p)
        case "artists":
            circle(9, 8, 3, into: &p)
            d("M3.5 20a5.5 5.5 0 0 1 11 0", into: &p)
            d("M16 5.5a3 3 0 0 1 0 6", into: &p)
            d("M18.5 20a5.5 5.5 0 0 0-3-5", into: &p)
        case "clock":
            circle(12, 12, 9, into: &p); d("M12 7.5V12l3 2", into: &p)
        case "image":
            rrect(3, 4, 18, 16, 2.5, into: &p); circle(8.5, 9.5, 1.8, into: &p); d("m4 18 5-4 4 3 3-2 5 4", into: &p)
        case "grid":
            rrect(3.5, 3.5, 7, 7, 1.5, into: &p); rrect(13.5, 3.5, 7, 7, 1.5, into: &p)
            rrect(3.5, 13.5, 7, 7, 1.5, into: &p); rrect(13.5, 13.5, 7, 7, 1.5, into: &p)
        case "video":
            rrect(2.5, 6, 14, 12, 2.5, into: &p); d("m16.5 10 5-3v10l-5-3z", into: &p)
        case "drive":
            rrect(3, 6, 18, 12, 2, into: &p); circle(8, 12, 1.3, into: &p); d("M12 12h6", into: &p)
        case "server":
            rrect(3, 4, 18, 7, 2, into: &p); rrect(3, 13, 18, 7, 2, into: &p)
            d("M7 7.5h.01", into: &p); d("M7 16.5h.01", into: &p); d("M11 7.5h6", into: &p); d("M11 16.5h6", into: &p)
        case "nas":
            rrect(3, 4, 18, 7, 2, into: &p); rrect(3, 13, 18, 7, 2, into: &p)
            circle(7, 7.5, 1, into: &p); circle(7, 16.5, 1, into: &p)
        case "health":
            d("M4 4v6a4 4 0 0 0 8 0V4", into: &p); d("M8 14v1.5a4 4 0 0 0 8 0V14", into: &p); circle(18, 12.5, 2, into: &p)
        case "tasks":
            circle(6, 7, 2.3, into: &p); d("M11 7h9", into: &p); circle(6, 17, 2.3, into: &p); d("M11 17h9", into: &p)
        case "dashboard":
            rrect(3, 4, 18, 16, 2.5, into: &p)
            d("M7 16v-4", into: &p)
            d("M12 16V8", into: &p)
            d("M17 16v-6", into: &p)
            d("M7 16h10", into: &p)
        case "gear":
            circle(12, 12, 3, into: &p)
            d("M12 3v3", into: &p); d("M12 18v3", into: &p)
            d("M3 12h3", into: &p); d("M18 12h3", into: &p)
            d("M5.6 5.6 7.7 7.7", into: &p); d("m16.3 16.3 2.1 2.1", into: &p)
            d("m18.4 5.6-2.1 2.1", into: &p); d("m7.7 16.3-2.1 2.1", into: &p)
        case "sliders":
            d("M4 7h4", into: &p); circle(10, 7, 2, into: &p); d("M12 7h8", into: &p)
            d("M4 12h10", into: &p); circle(16, 12, 2, into: &p); d("M18 12h2", into: &p)
            d("M4 17h7", into: &p); circle(13, 17, 2, into: &p); d("M15 17h5", into: &p)
        case "scan":
            d("M4 8V5a1 1 0 0 1 1-1h3", into: &p); d("M16 4h3a1 1 0 0 1 1 1v3", into: &p)
            d("M20 16v3a1 1 0 0 1-1 1h-3", into: &p); d("M8 20H5a1 1 0 0 1-1-1v-3", into: &p); d("M4 12h16", into: &p)
        case "select":
            d("M9 6h11", into: &p); d("M9 12h11", into: &p); d("M9 18h11", into: &p)
            d("M4 6h.01", into: &p); d("M4 12h.01", into: &p); d("M4 18h.01", into: &p)
        case "refresh":
            d("M21 12a9 9 0 1 1-3-6.7", into: &p); d("M21 4v5h-5", into: &p)
        case "caching":
            d("M12 3a9 9 0 1 0 9 9", into: &p); d("M21 3v6h-6", into: &p)
        case "art":
            rrect(3, 4, 18, 14, 2, into: &p); circle(8.5, 9.5, 1.6, into: &p); d("m4 17 5-4 4 3 3-2 4 3", into: &p)
        case "meta":
            rrect(4, 3, 16, 18, 2, into: &p); d("M8 7h8", into: &p); d("M8 11h8", into: &p); d("M8 15h5", into: &p)
        case "heart":
            // 对称心形：左右两瓣关于 x=12 镜像，底尖落在 (12,20.5)，不再歪斜。
            d("M12 20.5 C12 20.5 3.5 14.5 3.5 8.75 C3.5 5.85 5.65 4 8 4 C9.75 4 11.2 5.05 12 6.6 C12.8 5.05 14.25 4 16 4 C18.35 4 20.5 5.85 20.5 8.75 C20.5 14.5 12 20.5 12 20.5 Z", into: &p)
        case "m3u":
            d("M12 15V3", into: &p); d("m8 7 4-4 4 4", into: &p); rrect(4, 15, 16, 6, 2, into: &p)
        case "sources":
            rrect(3, 6, 18, 12, 2, into: &p); circle(8, 12, 1.3, into: &p); d("M12 12h6", into: &p)
        case "moon":
            d("M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z", into: &p)
        case "bell":
            d("M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9", into: &p); d("M13.7 21a2 2 0 0 1-3.4 0", into: &p)
        case "globe":
            circle(12, 12, 9, into: &p); d("M3 12h18", into: &p); d("M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18", into: &p)
        case "info":
            circle(12, 12, 9, into: &p); d("M12 16v-4", into: &p); d("M12 8h.01", into: &p)
        case "hdd":
            rrect(3, 5, 18, 14, 2, into: &p); d("M3 13h18", into: &p); circle(7.5, 16, 1, into: &p)
        // —— 设计稿内联图标 ——
        case "search":
            circle(11, 11, 7, into: &p); d("m20 20-3-3", into: &p)
        case "chevronDown":
            d("m6 9 6 6 6-6", into: &p)
        case "chevronUp":
            d("m6 15 6-6 6 6", into: &p)
        case "chevronLeft":
            d("m15 6-6 6 6 6", into: &p)
        case "chevronRight":
            d("m9 6 6 6-6 6", into: &p)
        case "sortGlyph":
            d("m8 9 4-4 4 4", into: &p); d("m16 15-4 4-4-4", into: &p)
        case "star":
            d("m12 3 1.9 4.6 4.9.4-3.7 3.2 1.1 4.8L12 13.9 7.8 16l1.1-4.8L5.2 8l4.9-.4z", into: &p)
        case "checkCircle":
            circle(12, 12, 9, into: &p); d("m8.5 12 2.5 2.5 4.5-5", into: &p)
        case "check":
            d("m5 12 5 5L20 7", into: &p)
        case "shuffle":
            d("M4 8h12M4 8a2 2 0 1 0 4 0 2 2 0 1 0-4 0M20 8h-2", into: &p)
            d("M20 16H8m12 0a2 2 0 1 1-4 0 2 2 0 1 1 4 0M4 16h2", into: &p)
        case "trash":
            d("M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13", into: &p)
        case "fingerprint":
            d("M12 11c2 0 3-1.5 3-3.5S14 4 12 4 9 5.5 9 7.5", into: &p); d("M5 20c0-4 3-6 7-6s7 2 7 6", into: &p)
        case "close":
            d("M6 6 18 18", into: &p); d("M18 6 6 18", into: &p)
        case "edit":
            d("M12 20h9", into: &p); d("M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z", into: &p)
        case "download":
            d("M12 3v12", into: &p); d("m7 11 5 5 5-5", into: &p); d("M5 21h14", into: &p)
        case "share":
            circle(6, 12, 3, into: &p); circle(18, 6, 3, into: &p); circle(18, 18, 3, into: &p)
            d("m8.5 10.5 7-3", into: &p); d("m8.5 13.5 7 3", into: &p)
        case "ellipsis":
            circle(5, 12, 1, into: &p); circle(12, 12, 1, into: &p); circle(19, 12, 1, into: &p)
        case "eye":
            d("M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z", into: &p); circle(12, 12, 3, into: &p)
        case "eyeOff":
            d("M3 3 21 21", into: &p)
            d("M10.5 6.2A10.6 10.6 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3.3 4", into: &p)
            d("M6.5 8.2A17 17 0 0 0 2 12s3.5 7 10 7a10.6 10.6 0 0 0 3.5-.6", into: &p)
        case "warn":
            d("m21.7 18-8-14a2 2 0 0 0-3.4 0l-8 14a2 2 0 0 0 1.7 3h16a2 2 0 0 0 1.7-3z", into: &p)
            d("M12 9v4", into: &p); d("M12 17h.01", into: &p)
        case "folder":
            d("M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2.5h8.5A1.5 1.5 0 0 1 21 10v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18z", into: &p)
        case "person":
            circle(12, 8, 3.6, into: &p); d("M5 20a7 7 0 0 1 14 0", into: &p)
        case "circle":
            circle(12, 12, 9, into: &p)
        case "link":
            d("M9 17H7A5 5 0 0 1 7 7h2", into: &p); d("M15 7h2a5 5 0 0 1 0 10h-2", into: &p); d("M8 12h8", into: &p)
        case "bookmark":
            d("M6 4.5A1.5 1.5 0 0 1 7.5 3h9A1.5 1.5 0 0 1 18 4.5V21l-6-4-6 4z", into: &p)
        case "stop":
            rrect(6, 6, 12, 12, 2, into: &p)
        case "tag":
            d("M3 11.6 11.6 3a2 2 0 0 1 1.4-.6H19a2 2 0 0 1 2 2v6a2 2 0 0 1-.6 1.4L11.8 21a2 2 0 0 1-2.8 0l-6-6a2 2 0 0 1 0-2.8z", into: &p)
            circle(16.5, 7.5, 1, into: &p)
        case "copy":
            rrect(8, 8, 12, 12, 2, into: &p)
            d("M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2", into: &p)
        case "externalLink":
            d("M15 3h6v6", into: &p); d("M10 14 21 3", into: &p)
            d("M19 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h6", into: &p)
        case "chart":
            d("M4 20h16", into: &p); d("M7 20v-6", into: &p); d("M12 20V9", into: &p); d("M17 20v-9", into: &p)
        case "calendar":
            rrect(3, 5, 18, 16, 2.5, into: &p); d("M3 9.5h18", into: &p); d("M8 3v4", into: &p); d("M16 3v4", into: &p)
        default:
            // 未收录的名字回退到一个温和的占位方框，避免空白。
            rrect(4, 4, 16, 16, 4, into: &p)
        }
    }
}

// MARK: - SF Symbol → 焕彩图标桥接

extension VividIconLibrary {
    /// 把 app 里散落的 SF Symbol 名映射到设计稿图标名。命中则改用焕彩线性图标，
    /// 未命中返回 nil（由 AppGlyph 回退到系统符号），保证迁移不回归、可逐轮扩充。
    static func vividName(forSystemImage symbol: String) -> String? {
        if let mapped = sfMap[symbol] { return mapped }
        // 容错：剥掉常见修饰后缀再查一次（.fill / .circle / .circle.fill 等）。
        for suffix in [".circle.fill", ".square.fill", ".circle", ".square", ".fill"] where symbol.hasSuffix(suffix) {
            let base = String(symbol.dropLast(suffix.count))
            if let m = sfMap[base] { return m }
        }
        return nil
    }

    static let sfMap: [String: String] = [
        "magnifyingglass": "search", "magnifyingglass.circle": "search",
        "plus": "plus", "minus": "minus",
        "xmark": "close", "xmark.circle": "close", "xmark.circle.fill": "close",
        "checkmark": "check",
        "checkmark.circle": "checkCircle", "checkmark.circle.fill": "checkCircle",
        "checkmark.seal": "checkCircle", "checkmark.seal.fill": "checkCircle",
        "checkmark.square.fill": "checkCircle", "checkmark.shield": "checkCircle",
        "circle": "circle", "square": "circle",
        "arrow.clockwise": "refresh", "arrow.clockwise.circle": "refresh",
        "arrow.counterclockwise": "refresh", "gobackward": "refresh",
        "arrow.triangle.2.circlepath": "refresh", "arrow.triangle.2.circlepath.circle": "refresh",
        "arrow.uturn.backward": "refresh",
        "trash": "trash", "trash.fill": "trash",
        "gearshape": "gear", "gearshape.fill": "gear", "gear": "gear", "slider.horizontal.3": "sliders",
        "line.3.horizontal": "select", "list.bullet": "select", "checklist": "select",
        "list.bullet.rectangle": "select", "list.number": "select",
        "line.3.horizontal.decrease": "sortGlyph", "line.3.horizontal.decrease.circle": "sortGlyph",
        "house": "home", "house.fill": "home", "house.slash": "home",
        "bell": "bell", "bell.badge": "bell", "bell.fill": "bell",
        "moon": "moon", "moon.zzz": "moon", "moon.fill": "moon",
        "globe": "globe", "globe.desk": "globe",
        "info.circle": "info", "info.circle.fill": "info",
        "music.note": "music", "music.note.list": "music", "music.mic": "music",
        "heart": "heart", "heart.fill": "heart",
        "photo": "image", "photo.fill": "image", "photo.on.rectangle": "image",
        "photo.on.rectangle.angled": "image", "photo.stack": "image",
        "photo.badge.plus": "image", "camera.viewfinder": "image",
        "film": "video", "film.stack": "video", "play.rectangle": "video",
        "play.rectangle.fill": "video", "play.rectangle.on.rectangle": "video", "play.square.stack": "video",
        "play": "play", "play.fill": "play", "play.circle": "play", "play.circle.fill": "play",
        "pause": "pause", "pause.fill": "pause", "pause.circle": "pause", "pause.circle.fill": "pause",
        "externaldrive": "hdd", "externaldrive.fill": "hdd", "internaldrive": "hdd",
        "externaldrive.badge.plus": "hdd", "externaldrive.badge.exclamationmark": "hdd",
        "externaldrive.badge.minus": "hdd", "externaldrive.badge.arrow.down": "hdd",
        "externaldrive.connected.to.line.below": "nas", "network": "nas",
        "server.rack": "server", "cylinder.split.1x2": "server",
        "lock": "lock", "lock.fill": "lock", "lock.shield": "lock", "lock.rectangle.stack": "lock",
        "key": "lock", "key.horizontal": "lock", "person.badge.key": "lock",
        "pencil": "edit", "pencil.line": "edit", "pencil.tip": "edit", "square.and.pencil": "edit",
        "square.and.arrow.up": "share",
        "arrow.down.to.line": "download", "arrow.down.circle": "download",
        "arrow.down": "download", "square.and.arrow.down": "download",
        "eye": "eye", "eye.fill": "eye", "eye.slash": "eyeOff", "eye.slash.fill": "eyeOff",
        "chevron.down": "chevronDown", "chevron.up": "chevronUp",
        "chevron.left": "chevronLeft", "chevron.right": "chevronRight",
        "chevron.up.chevron.down": "sortGlyph", "arrow.up.arrow.down": "sortGlyph",
        "clock": "clock", "clock.fill": "clock", "clock.arrow.circlepath": "clock",
        "star": "star", "star.fill": "star",
        "ellipsis": "ellipsis", "ellipsis.circle": "ellipsis",
        "exclamationmark.triangle": "warn", "exclamationmark.triangle.fill": "warn",
        "exclamationmark.circle": "warn", "exclamationmark.circle.fill": "warn", "exclamationmark.shield": "warn",
        "folder": "folder", "folder.fill": "folder", "folder.badge.plus": "folder", "folder.badge.gearshape": "folder",
        "link": "link", "link.badge.plus": "link",
        "person": "person", "person.fill": "person", "person.crop.circle": "person",
        "person.crop.square": "person", "person.text.rectangle": "person",
        "person.crop.circle.badge.checkmark": "person",
        "person.2": "artists", "person.2.fill": "artists",
        "doc.text": "meta", "doc.on.doc": "meta", "doc.on.clipboard": "meta", "doc.badge.ellipsis": "meta",
        "tv": "tv", "tv.fill": "tv", "sparkles.tv": "anime",
        "video": "video", "video.fill": "video",
        "tray": "box", "square.stack": "disc",
        "bookmark": "bookmark", "bookmark.fill": "bookmark", "bookmark.circle": "bookmark",
        "square.grid.2x2": "grid", "square.grid.3x3": "grid", "rectangle.grid.2x2": "grid",
        "paintpalette": "art", "paintbrush.pointed": "art",
        "books.vertical": "box", "shippingbox": "box", "archivebox": "box", "tray.full": "box",
        // —— 任务中心 / 片库健康 ——
        "stop.circle": "stop", "stop.circle.fill": "stop", "stop": "stop",
        "stethoscope": "health", "cross.case": "health", "waveform.path.ecg": "health",
        "tag": "tag", "tag.fill": "tag", "tag.badge.plus": "tag", "tag.slash": "tag",
        "square.on.square": "copy", "doc.on.doc.fill": "copy", "plus.square.on.square": "copy",
        "arrow.up.forward.square": "externalLink", "arrow.up.right.square": "externalLink", "arrow.up.forward.app": "externalLink",
        "person.crop.rectangle.stack": "person", "person.crop.rectangle": "person",
        // —— 集合/歌单/媒体源 等弹窗 ——
        "rectangle.stack": "copy", "sparkles.rectangle.stack": "copy", "rectangle.stack.badge.minus": "copy",
        "rectangle.stack.badge.plus": "copy", "square.stack.3d.up": "copy",
        "chart.bar": "chart", "chart.bar.fill": "chart", "chart.xyaxis.line": "chart",
        "calendar": "calendar", "calendar.badge.clock": "calendar", "calendar.badge.plus": "calendar",
        "text.cursor": "edit", "character.cursor.ibeam": "edit", "number": "tag", "number.circle": "tag",
        "dashboard": "dashboard", "chart.pie": "dashboard", "chart.pie.fill": "dashboard"
    ]
}

/// 页眉图标：严格复刻设计稿 `titleIcon(name)` 的 56×56 彩色 SVG 插画。
/// 设置分组、sheet 等辅助场景可关闭标题插画，保留浅底线性图标块以匹配表单层级。
struct VividPageIcon: View {
    let systemImage: String
    var chip: CGFloat = 56
    var glyph: CGFloat = 30
    var tint: Color = AppColors.selectedGlassTint
    var usesSemanticGlyph: Bool = true

    var body: some View {
        Group {
            if usesSemanticGlyph, let titleName = VividTitleIconNameMapper.titleName(for: systemImage) {
                VividTitleIcon(name: titleName, size: max(chip, 56))
            } else {
                let shape = RoundedRectangle(cornerRadius: chip * 0.31, style: .continuous)
                ZStack {
                    shape.fill(
                        LinearGradient(
                            colors: fallbackChipColors(tint: tint),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    shape.strokeBorder(fallbackStrokeColor(tint: tint), lineWidth: 1)
                    AppGlyph(systemImage: systemImage, size: glyph, lineWidth: 2)
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: chip, height: chip)
    }

    private func fallbackChipColors(tint: Color) -> [Color] {
        [tint.opacity(0.16), tint.opacity(0.09)]
    }

    private func fallbackStrokeColor(tint: Color) -> Color {
        tint.opacity(0.14)
    }
}

private enum VividTitleIconNameMapper {
    static func titleName(for symbol: String) -> String? {
        let key = symbol.lowercased()
        if key.contains("recording.library") || key.contains("recordingtape") { return "video_gal" }
        if key.contains("tv.library") || key == "tv" || key.contains("emby.videos") || key.contains("play.tv") { return "tv" }
        if key.contains("sparkles.tv") { return "anime" }
        if key == "film" || key.contains("movie") { return "movie" }
        if key.contains("books.vertical") || key.contains("docu") { return "docu" }
        if key.contains("music.mic") { return "variety" }
        if key == "video" || key.contains("play.rectangle") || key.contains("tray") { return "video_other" }
        if key.contains("emby.music") || key == "music.note" { return "song_note" }
        if key.contains("emby.recent") || key.contains("music.recent") || key == "clock" || key.contains("clock.arrow") { return "clock" }
        if key.contains("music.album") || key.contains("opticaldisc") || key.contains("square.stack") { return "disc" }
        if key.contains("person.2") || key.contains("artists") { return "artists" }
        if key.contains("person") { return "person" }
        if key.contains("music.note.list") || key.contains("playlist") { return "playlist" }
        if key.contains("photo.on.rectangle") || key.contains("square.grid") || key.contains("rectangle.grid") { return "photo_all" }
        if key == "photo" || key.contains("camera") { return "photo" }
        if key.contains("lock") || key.contains("key") || key.contains("vault") || key.contains("privacy") { return "vault" }
        if key.contains("badge.checkmark") || key.contains("source.connected") { return "source_on" }
        if key.contains("badge.exclamationmark") || key.contains("badge.xmark") || key.contains("source.disconnected") { return "source_off" }
        if key.contains("externaldrive") || key.contains("server") || key.contains("network") || key.contains("cylinder") { return "sources" }
        if key.contains("dashboard") || key.contains("stethoscope") || key.contains("health") || key.contains("checkmark.seal") { return "dashboard" }
        if key.contains("gear") || key.contains("slider") { return "gear" }
        if key.contains("checklist") || key.contains("list.bullet") || key.contains("tasks") { return "tasks" }
        if key == "eye" || key.contains("eye.") || key.contains("unwatched") { return "unwatched" }
        if key.contains("checkmark") || key.contains("watched") { return "watched" }
        if key.contains("heart") || key.contains("favorite") { return "favorites" }
        if key.contains("bookmark") || key.contains("watchlist") { return "watchlist" }
        if key.contains("play.circle") || key.contains("play.fill") || key.contains("watching") { return "watching" }
        if key.contains("questionmark") || key.contains("unmatched") { return "unmatched" }
        if key.contains("tag") || key.contains("captions") || key.contains("info") { return "tag" }
        if key.contains("arrow.triangle") || key.contains("refresh") || key.contains("sync") { return "sync" }
        // 智能集合：sparkles.rectangle.stack —— 之前误落到「theme」画成调色盘，语义错。
        if key.contains("sparkles.rectangle") || key.contains("smart.collection") || key.contains("wand.and.rectangle") { return "smart" }
        if key.contains("paintbrush") || key.contains("paintpalette") { return "theme" }
        return "video_other"
    }
}

private struct VividTitleIcon: View {
    let name: String
    var size: CGFloat

    var body: some View {
        let glow = Self.palette(for: name).glow
        // clipped()=把插画严格裁进 48×48 图标框，杜绝任何形状（如旋转卡片）越界造成「色块溢出」；
        // 发光在其后施加，仍可正常向外扩散。
        return AnyView(symbol.frame(width: 48, height: 48).clipped())
            .scaleEffect(size / 48)
            .frame(width: size, height: size)
            .modifier(VividTitleGlowModifier(glow: glow, size: size))
            .accessibilityHidden(true)
    }

    /// 每个图标的辉光色（用于 drop-shadow）。无边框插画的柔光即来自此。
    static func palette(for name: String) -> (top: Color, bottom: Color, glow: Color) {
        func c(_ hex: String) -> Color { Color.vividHex(hex) }
        switch name {
        case "movie": return (c("#FBBF24"), c("#F59E0B"), c("#F59E0B"))
        case "tv": return (c("#38BDF8"), c("#4F46E5"), c("#3B82F6"))
        case "anime": return (c("#FF8FBD"), c("#FF5C8A"), c("#FF5C8A"))
        case "variety": return (c("#F472B6"), c("#A855F7"), c("#EC4899"))
        case "docu": return (c("#38BDF8"), c("#0284C7"), c("#0EA5E9"))
        case "video_other": return (c("#A855F7"), c("#6366F1"), c("#8B5CF6"))
        case "song_note": return (c("#C084FC"), c("#EC4899"), c("#EC4899"))
        case "disc": return (c("#6366F1"), c("#A855F7"), c("#8B5CF6"))
        case "artists": return (c("#FB7185"), c("#E11D48"), c("#F43F5E"))
        case "playlist": return (c("#3B82F6"), c("#1D4ED8"), c("#3B82F6"))
        case "clock": return (c("#3B82F6"), c("#1E40AF"), c("#1E40AF"))
        case "photo": return (c("#38BDF8"), c("#06B6D4"), c("#06B6D4"))
        case "photo_all": return (c("#FBBF24"), c("#F97316"), c("#F59E0B"))
        case "video_gal": return (c("#FB7185"), c("#BE123C"), c("#F43F5E"))
        case "sources": return (c("#38BDF8"), c("#2563EB"), c("#0EA5E9"))
        case "source_on": return (c("#38BDF8"), c("#2563EB"), c("#10B981"))
        case "source_off": return (c("#94A3B8"), c("#64748B"), c("#F97316"))
        case "gear": return (c("#38BDF8"), c("#2563EB"), c("#0EA5E9"))
        case "dashboard", "health": return (c("#34D399"), c("#059669"), c("#10B981"))
        case "vault": return (c("#64748B"), c("#334155"), c("#F59E0B"))
        case "tasks": return (c("#FFAE6B"), c("#FF5C8A"), c("#FF5C8A"))
        case "watching": return (c("#38BDF8"), c("#4F46E5"), c("#0EA5E9"))
        case "watchlist": return (c("#FBBF24"), c("#F59E0B"), c("#F59E0B"))
        case "favorites": return (c("#FB7185"), c("#E11D48"), c("#F43F5E"))
        case "unwatched": return (c("#C084FC"), c("#EC4899"), c("#EC4899"))
        case "watched": return (c("#34D399"), c("#059669"), c("#10B981"))
        case "unmatched": return (c("#94A3B8"), c("#475569"), c("#8B5CF6"))
        case "person": return (c("#C084FC"), c("#EC4899"), c("#EC4899"))
        case "tag": return (c("#38BDF8"), c("#6366F1"), c("#0EA5E9"))
        case "sync": return (c("#3B82F6"), c("#1D4ED8"), c("#3B82F6"))
        case "theme": return (c("#F43F5E"), c("#8B5CF6"), c("#F43F5E"))
        case "smart": return (c("#A855F7"), c("#6366F1"), c("#8B5CF6"))
        default: return (c("#2E90FA"), c("#36BFFA"), c("#2E90FA"))
        }
    }

    private func ws(_ w: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
    }

    private func k(_ hex: String) -> Color { Color.vividHex(hex) }

    private func lg(_ a: String, _ b: String, _ vertical: Bool = false) -> LinearGradient {
        LinearGradient(colors: [Color.vividHex(a), Color.vividHex(b)],
                       startPoint: .topLeading, endPoint: vertical ? .bottom : .bottomTrailing)
    }

    /// 无边框（MIUI 无界风）彩色插画：图标本身即彩色物体，浮于页面之上（无背景磁贴/描边），
    /// 依赖饱和配色 + drop-shadow 柔光成形。刻意避免浅灰/白作为主色（浅底会隐形）。
    @ViewBuilder
    private var symbol: some View {
        switch name {
        case "movie": movieObj
        case "tv": tvObj
        case "anime": animeObj
        case "variety": varietyObj
        case "docu": docuObj
        case "video_other": videoOtherObj
        case "song_note": songNoteObj
        case "disc": discObj
        case "artists": artistsObj
        case "playlist": playlistObj
        case "clock": clockObj
        case "photo": photoObj
        case "photo_all": photoAllObj
        case "video_gal": videoGalObj
        case "sources": sourcesObj
        case "source_on": sourceOnObj
        case "source_off": sourceOffObj
        case "gear": gearObj
        case "dashboard", "health": dashboardObj
        case "vault": vaultObj
        case "tasks": tasksObj
        case "watching": watchingObj
        case "watchlist": watchlistObj
        case "favorites": favoritesObj
        case "unwatched": unwatchedObj
        case "watched": watchedObj
        case "unmatched": unmatchedObj
        case "person": personObj
        case "tag": tagObj
        case "sync": syncObj
        case "theme": themeObj
        case "smart": smartObj
        default: defaultObj
        }
    }

    private var movieObj: some View {
        ZStack {
            VividTitleRect(x: 7, y: 20, width: 34, height: 20, radius: 4).fill(lg("#FBBF24", "#F59E0B", true))
            VividTitlePath(d: "M8 18 L38 12 L40 19 L10 25 Z").fill(lg("#334155", "#0F172A"))
            VividTitlePath(d: "M13 15.4 L15.5 20 M19 14.2 L21.5 18.8 M25 13 L27.5 17.6 M31 11.8 L33.5 16.4").stroke(.white, style: ws(1.8))
            VividTitlePath(d: "M21 26 L29 30 L21 34 Z").fill(.white)
        }
    }

    private var tvObj: some View {
        ZStack {
            VividTitleRect(x: 5, y: 9, width: 38, height: 25, radius: 6).fill(lg("#38BDF8", "#4F46E5"))
            VividTitlePath(d: "M5 15 C5 12 7 10 10 10 H38 C40 10 41 11 41 13 V16 L5 23 V15 Z").fill(.white.opacity(0.28))
            VividTitlePath(d: "M20 34 L18 41 H30 L28 34 Z").fill(lg("#64748B", "#334155", true))
            VividTitleRect(x: 13, y: 40, width: 22, height: 3.4, radius: 1.7).fill(k("#475569"))
            VividTitlePath(d: "M20 15 L31 21 L20 27 Z").fill(.white)
        }
    }

    // 动漫：星芒/闪光（常见「动漫·魔法」意象），大四角星 + 小星点，区别于电视/电影。
    private var animeObj: some View {
        ZStack {
            VividTitlePath(d: "M24 5 C25.6 18 26 18.4 39 20 C26 21.6 25.6 22 24 35 C22.4 22 22 21.6 9 20 C22 18.4 22.4 18 24 5 Z").fill(lg("#FF8FBD", "#A855F7"))
            VividTitlePath(d: "M24 12 C24.7 18.5 25 18.7 31 20 C25 21.3 24.7 21.5 24 28 C23.3 21.5 23 21.3 17 20 C23 18.7 23.3 18.5 24 12 Z").fill(.white.opacity(0.55))
            VividTitlePath(d: "M37 29 C37.7 34 37.8 34.2 43 35 C37.8 35.8 37.7 36 37 41 C36.3 36 36.2 35.8 31 35 C36.2 34.2 36.3 34 37 29 Z").fill(k("#FDE047"))
            VividTitleCircle(cx: 10, cy: 33, r: 2.2).fill(k("#38BDF8"))
        }
    }

    private var varietyObj: some View {
        ZStack {
            VividTitlePath(d: "M14 36 L34 36 L38 43 H10 Z").fill(lg("#EC4899", "#8B5CF6", true))
            VividTitleRect(x: 20, y: 32, width: 8, height: 5, radius: 1.5).fill(k("#A855F7"))
            VividTitlePath(d: "M15 10 H33 V19 C33 25 28.9 29 24 29 C19.1 29 15 25 15 19 V10 Z").fill(lg("#FDE047", "#D97706", true))
            VividTitlePath(d: "M15 13 H10 C7 13 7 19 12 20").stroke(k("#FDE047"), style: ws(2.4))
            VividTitlePath(d: "M33 13 H38 C41 13 41 19 36 20").stroke(k("#FDE047"), style: ws(2.4))
            VividTitlePolygon(points: "24,14 25.6,18.2 30,18.4 26.5,21.2 27.7,25.5 24,23 20.3,25.5 21.5,21.2 18,18.4 22.4,18.2").fill(.white)
            VividTitleCircle(cx: 9, cy: 12, r: 2).fill(k("#38BDF8"))
            VividTitleCircle(cx: 39, cy: 11, r: 2.2).fill(k("#F43F5E"))
        }
    }

    private var docuObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 16).fill(lg("#0EA5E9", "#0369A1"))
            VividTitlePath(d: "M8 24 H40 M24 8 V40 M12 15 C18 20 30 20 36 15 M12 33 C18 28 30 28 36 33").stroke(k("#7DD3FC").opacity(0.8), style: ws(1.6))
            VividTitleEllipse(cx: 24, cy: 24, rx: 7, ry: 16).stroke(k("#7DD3FC").opacity(0.8), style: ws(1.6))
            VividTitleCircle(cx: 18, cy: 17, r: 4).fill(.white.opacity(0.22))
        }
    }

    private var videoOtherObj: some View {
        ZStack {
            VividTitlePath(d: "M6 14 C6 11.8 7.8 10 10 10 H18 L22 14 H38 C40.2 14 42 15.8 42 18 V36 C42 38.2 40.2 40 38 40 H10 C7.8 40 6 38.2 6 36 V14 Z").fill(lg("#A855F7", "#6366F1"))
            VividTitlePath(d: "M20 21 L33 28 L20 35 Z").fill(.white)
        }
    }

    private var songNoteObj: some View {
        ZStack {
            VividTitlePath(d: "M18 34 V13 L36 9 V30").stroke(lg("#C084FC", "#EC4899"), style: ws(3.4))
            VividTitleCircle(cx: 14, cy: 34, r: 5).fill(lg("#C084FC", "#A855F7"))
            VividTitleCircle(cx: 32, cy: 30, r: 5).fill(lg("#EC4899", "#DB2777"))
            VividTitleCircle(cx: 40, cy: 10, r: 2).fill(k("#FDE047"))
        }
    }

    /// 智能集合：扇形叠放的内容卡（=集合）+ 右上魔法星（=按规则自动更新）。
    private var smartObj: some View {
        ZStack {
            // 背卡（左倾）
            VividTitleRect(x: 11, y: 13, width: 22, height: 25, radius: 5).fill(lg("#818CF8", "#6366F1", true))
                .rotationEffect(.degrees(-11), anchor: UnitPoint(x: 24.0 / 48, y: 26.0 / 48))
            // 中卡（右倾）
            VividTitleRect(x: 15, y: 13, width: 22, height: 25, radius: 5).fill(lg("#C084FC", "#8B5CF6", true))
                .rotationEffect(.degrees(11), anchor: UnitPoint(x: 24.0 / 48, y: 26.0 / 48))
            // 前卡（正立）+ 规则行
            VividTitleRect(x: 13, y: 15, width: 22, height: 25, radius: 5).fill(lg("#A855F7", "#6366F1", true))
            VividTitlePath(d: "M18 23 H30 M18 28 H28 M18 33 H25").stroke(.white.opacity(0.9), style: ws(2.1))
            // 魔法星（智能/自动）
            VividTitlePolygon(points: "37,5 38.7,9.6 43.3,11.3 38.7,13 37,17.6 35.3,13 30.7,11.3 35.3,9.6").fill(k("#FDE047"))
            VividTitleCircle(cx: 30.5, cy: 7.5, r: 1.7).fill(.white)
        }
    }

    private var discObj: some View {
        ZStack {
            VividTitleCircle(cx: 30, cy: 22, r: 16).fill(lg("#334155", "#1E293B"))
            VividTitleCircle(cx: 30, cy: 22, r: 10).stroke(k("#475569"), style: ws(1))
            VividTitleCircle(cx: 30, cy: 22, r: 5).fill(lg("#A855F7", "#6366F1"))
            VividTitleCircle(cx: 30, cy: 22, r: 1.6).fill(k("#1E293B"))
            VividTitleRect(x: 6, y: 12, width: 24, height: 24, radius: 4).fill(lg("#6366F1", "#A855F7", true))
            VividTitlePath(d: "M6 27 L14 20 L20 25 L30 17 V32 C30 34 28 36 26 36 H10 C8 36 6 34 6 32 V27 Z").fill(.white.opacity(0.16))
            VividTitleCircle(cx: 13, cy: 19, r: 3).fill(.white.opacity(0.55))
        }
    }

    // 艺术家：音乐库常见「人物半身像」+ 音符徽标，明确指向「音乐艺术家」而非通用人物。
    private var artistsObj: some View {
        ZStack {
            VividTitlePath(d: "M8 41 C8 31 34 31 34 41 Z").fill(lg("#FB7185", "#E11D48", true))
            VividTitleCircle(cx: 21, cy: 17, r: 8.5).fill(lg("#FDA4AF", "#F43F5E"))
            VividTitleCircle(cx: 36, cy: 13, r: 7.5).fill(lg("#A855F7", "#7C3AED"))
            VividTitlePath(d: "M34 10 V16.5").stroke(.white, style: ws(1.8))
            VividTitleCircle(cx: 32.6, cy: 16.5, r: 2).fill(.white)
            VividTitlePath(d: "M34 10 L39 8.6").stroke(.white, style: ws(1.8))
        }
    }

    private var playlistObj: some View {
        ZStack {
            VividTitleRect(x: 12, y: 8, width: 28, height: 32, radius: 5).fill(k("#93C5FD"))
                .rotationEffect(.degrees(6), anchor: UnitPoint(x: 26.0 / 48, y: 24.0 / 48))
            VividTitleRect(x: 7, y: 11, width: 30, height: 30, radius: 6).fill(lg("#3B82F6", "#1D4ED8", true))
            VividTitlePath(d: "M13 19 H29 M13 25 H24").stroke(.white.opacity(0.85), style: ws(2.4))
            VividTitleCircle(cx: 29, cy: 31, r: 8).fill(.white)
            VividTitlePath(d: "M27 27.5 L33 31 L27 34.5 Z").fill(k("#2563EB"))
        }
    }

    private var clockObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 18).fill(lg("#3B82F6", "#1E40AF"))
            VividTitleCircle(cx: 24, cy: 24, r: 14).stroke(k("#93C5FD").opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
            VividTitlePath(d: "M24 13 V24 L31 28").stroke(k("#FBBF24"), style: ws(3.2))
            VividTitleCircle(cx: 24, cy: 24, r: 2.6).fill(.white)
            VividTitleCircle(cx: 18, cy: 17, r: 4).fill(.white.opacity(0.2))
        }
    }

    private var photoObj: some View {
        ZStack {
            VividTitleRect(x: 6, y: 10, width: 36, height: 28, radius: 5).fill(lg("#38BDF8", "#06B6D4"))
            VividTitleCircle(cx: 16, cy: 19, r: 4).fill(k("#FDE047"))
            VividTitlePath(d: "M6 34 L18 24 L26 30 L34 22 L42 30 V33 C42 36 40 38 37 38 H11 C8 38 6 36 6 33 V34 Z").fill(k("#0369A1").opacity(0.5))
            VividTitleRect(x: 6, y: 10, width: 36, height: 28, radius: 5).stroke(.white, style: ws(2.5))
        }
    }

    private var photoAllObj: some View {
        ZStack {
            VividTitleRect(x: 11, y: 13, width: 20, height: 22, radius: 3).fill(lg("#EC4899", "#A855F7"))
                .rotationEffect(.degrees(-12), anchor: UnitPoint(x: 24.0 / 48, y: 24.0 / 48))
            VividTitleRect(x: 17, y: 13, width: 20, height: 22, radius: 3).fill(lg("#38BDF8", "#2563EB"))
                .rotationEffect(.degrees(12), anchor: UnitPoint(x: 24.0 / 48, y: 24.0 / 48))
            VividTitleRect(x: 14, y: 14, width: 20, height: 23, radius: 4).fill(lg("#FBBF24", "#F97316"))
            VividTitleCircle(cx: 20, cy: 20, r: 2.4).fill(.white)
            VividTitlePath(d: "M15 33 L21 27 L26 31 L33 23 V34 H15 Z").fill(.white.opacity(0.85))
            VividTitlePolygon(points: "36,7 37.3,10.5 41,11.5 37.3,12.5 36,16 34.7,12.5 31,11.5 34.7,10.5").fill(k("#FDE047"))
        }
    }

    private var videoGalObj: some View {
        ZStack {
            VividTitleRect(x: 8, y: 16, width: 22, height: 16, radius: 4).fill(lg("#F43F5E", "#BE123C"))
            VividTitlePath(d: "M30 21 L40 16 V32 L30 27 Z").fill(lg("#FB7185", "#E11D48"))
            VividTitleCircle(cx: 15, cy: 24, r: 4.5).fill(.white.opacity(0.92))
            VividTitleCircle(cx: 15, cy: 24, r: 2).fill(k("#BE123C"))
        }
    }

    private var sourcesObj: some View {
        ZStack {
            VividTitlePath(d: "M16 8 C21 3 27 3 32 8").stroke(k("#38BDF8"), style: ws(2.5))
            VividTitlePath(d: "M19 12 C22 9 26 9 29 12").stroke(k("#60A5FA"), style: ws(2.2))
            VividTitlePolygon(points: "24,15 39,23 24,31 9,23").fill(lg("#E0F2FE", "#7DD3FC"))
            VividTitlePolygon(points: "9,23 24,31 24,45 9,37").fill(lg("#38BDF8", "#0284C7", true))
            VividTitlePolygon(points: "24,31 39,23 39,37 24,45").fill(lg("#8B5CF6", "#4F46E5", true))
            VividTitleCircle(cx: 14, cy: 26, r: 1.5).fill(k("#34D399"))
            VividTitleCircle(cx: 19, cy: 28.5, r: 1.5).fill(k("#34D399"))
            VividTitleCircle(cx: 32, cy: 30, r: 1.8).fill(k("#FDE047"))
        }
    }

    // 已连接媒体源：服务器/NAS 机箱（两层盘位 + 状态灯）+ 绿色对勾徽标 = 「已连接」。
    private var sourceOnObj: some View {
        ZStack {
            VividTitleRect(x: 8, y: 10, width: 30, height: 12, radius: 3).fill(lg("#38BDF8", "#2563EB"))
            VividTitleRect(x: 8, y: 24, width: 30, height: 12, radius: 3).fill(lg("#38BDF8", "#2563EB"))
            VividTitleCircle(cx: 13, cy: 16, r: 1.6).fill(.white)
            VividTitleCircle(cx: 13, cy: 30, r: 1.6).fill(.white)
            VividTitlePath(d: "M18 16 H32 M18 30 H32").stroke(.white.opacity(0.55), style: ws(1.6))
            VividTitleCircle(cx: 35, cy: 34, r: 8).fill(lg("#34D399", "#059669"))
            VividTitlePath(d: "M31.4 34 L34 36.6 L38.6 31.4").stroke(.white, style: ws(2.4))
        }
    }

    // 已断开媒体源：灰调服务器机箱 + 橙色警示三角 = 「不可访问/已断开」。
    private var sourceOffObj: some View {
        ZStack {
            VividTitleRect(x: 8, y: 10, width: 30, height: 12, radius: 3).fill(lg("#94A3B8", "#64748B"))
            VividTitleRect(x: 8, y: 24, width: 30, height: 12, radius: 3).fill(lg("#94A3B8", "#64748B"))
            VividTitleCircle(cx: 13, cy: 16, r: 1.6).fill(.white.opacity(0.9))
            VividTitleCircle(cx: 13, cy: 30, r: 1.6).fill(.white.opacity(0.9))
            VividTitlePath(d: "M18 16 H32 M18 30 H32").stroke(.white.opacity(0.45), style: ws(1.6))
            VividTitlePath(d: "M34 25 L42 39 H26 Z").fill(lg("#FBBF24", "#F97316"))
            VividTitlePath(d: "M34 30 V34").stroke(.white, style: ws(2))
            VividTitleCircle(cx: 34, cy: 36.6, r: 1.1).fill(.white)
        }
    }

    // 设置：标准八齿齿轮（贴近系统「设置」齿轮），去掉之前的放射线状。
    private var gearObj: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                VividTitleRect(x: 21, y: 5, width: 6, height: 10, radius: 2).fill(lg("#38BDF8", "#2563EB"))
                    .rotationEffect(.degrees(Double(i) * 45), anchor: UnitPoint(x: 24.0 / 48, y: 24.0 / 48))
            }
            VividTitleCircle(cx: 24, cy: 24, r: 13).fill(lg("#38BDF8", "#2563EB"))
            VividTitleCircle(cx: 24, cy: 24, r: 5.5).fill(.white)
            VividTitleCircle(cx: 24, cy: 24, r: 2.4).fill(lg("#38BDF8", "#2563EB"))
        }
    }

    private var dashboardObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 15).stroke(k("#A7F3D0"), style: ws(6))
            VividTitlePath(d: "M24 9 A15 15 0 1 1 10.5 32").stroke(lg("#34D399", "#059669"), style: ws(6))
            VividTitlePath(d: "M14 25 H19 L21.5 19 L25 31 L27 25 H34").stroke(k("#047857"), style: ws(2.6))
            VividTitleCircle(cx: 24, cy: 9, r: 3).fill(k("#FDE047"))
        }
    }

    // 保险库：真实「保险箱」——机身 + 内门板 + 黄铜密码转盘 + 拉手 + 底脚，语义直指「保险库」。
    private var vaultObj: some View {
        ZStack {
            VividTitleRect(x: 6, y: 8, width: 36, height: 33, radius: 6).fill(lg("#475569", "#1E293B", true))
            VividTitleRect(x: 10, y: 12, width: 23, height: 25, radius: 4).fill(lg("#64748B", "#334155", true))
            VividTitleCircle(cx: 21, cy: 24.5, r: 8).fill(lg("#FDE68A", "#F59E0B"))
            VividTitleCircle(cx: 21, cy: 24.5, r: 4).fill(lg("#FBBF24", "#D97706"))
            VividTitleCircle(cx: 21, cy: 24.5, r: 1.5).fill(k("#78350F"))
            VividTitlePath(d: "M21 16.5 V19 M21 30 V32.5 M13.5 24.5 H16 M26 24.5 H28.5").stroke(.white.opacity(0.85), style: ws(1.6))
            VividTitleRect(x: 34, y: 21, width: 5, height: 7, radius: 2.5).fill(lg("#E2E8F0", "#94A3B8"))
            VividTitleRect(x: 11, y: 39, width: 4, height: 4, radius: 1).fill(k("#0F172A"))
            VividTitleRect(x: 28, y: 39, width: 4, height: 4, radius: 1).fill(k("#0F172A"))
        }
    }

    private var tasksObj: some View {
        ZStack {
            VividTitleRect(x: 8, y: 6, width: 32, height: 36, radius: 8).fill(lg("#FF9F45", "#FF5C8A", true))
            VividTitleRect(x: 12, y: 12, width: 24, height: 26, radius: 4).fill(k("#1E293B").opacity(0.85))
            VividTitleRect(x: 18, y: 3, width: 12, height: 7, radius: 3.5).fill(lg("#FDE047", "#F59E0B"))
            VividTitleCircle(cx: 16, cy: 19, r: 2.5).fill(k("#34D399"))
            VividTitlePath(d: "M21 19 H32").stroke(.white, style: ws(2.2))
            VividTitleCircle(cx: 16, cy: 28, r: 2.5).fill(k("#38BDF8"))
            VividTitlePath(d: "M21 28 H32").stroke(.white.opacity(0.8), style: ws(2.2))
        }
    }

    private var watchingObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 17).fill(lg("#38BDF8", "#4F46E5"))
            VividTitleCircle(cx: 24, cy: 24, r: 13).stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            VividTitlePath(d: "M20 16 L33 24 L20 32 Z").fill(.white)
        }
    }

    private var watchlistObj: some View {
        ZStack {
            VividTitlePath(d: "M14 6 C14 4.3 15.3 3 17 3 H31 C32.7 3 34 4.3 34 6 V43 L24 36 L14 43 Z").fill(lg("#FDE047", "#F97316"))
            VividTitlePath(d: "M18 6 H30 V22 L24 18 L18 22 Z").fill(.white.opacity(0.28))
            VividTitlePolygon(points: "38,10 39.5,14 43.5,15.5 39.5,17 38,21 36.5,17 32.5,15.5 36.5,14").fill(k("#38BDF8"))
        }
    }

    private var favoritesObj: some View {
        ZStack {
            VividTitlePath(d: "M24 40 C24 40 8 30 8 18.5 C8 13 12 9 17 9 C20 9 22.6 10.7 24 13 C25.4 10.7 28 9 31 9 C36 9 40 13 40 18.5 C40 30 24 40 24 40 Z").fill(lg("#FB7185", "#E11D48"))
            VividTitlePath(d: "M15 17 C15 14 18 12 21 12").stroke(.white.opacity(0.8), style: ws(2.6))
            VividTitlePolygon(points: "37,6 38.5,10 42.5,11.5 38.5,13 37,17 35.5,13 31.5,11.5 35.5,10").fill(k("#FDE047"))
        }
    }

    private var unwatchedObj: some View {
        ZStack {
            VividTitlePath(d: "M6 24 C14 12 34 12 42 24 C34 36 14 36 6 24 Z").fill(lg("#38BDF8", "#6366F1"))
            VividTitleCircle(cx: 24, cy: 24, r: 7).fill(.white)
            VividTitleCircle(cx: 24, cy: 24, r: 4).fill(k("#1E293B"))
            VividTitleCircle(cx: 26, cy: 22, r: 1.4).fill(.white)
        }
    }

    private var watchedObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 17).fill(lg("#34D399", "#047857"))
            VividTitlePath(d: "M15 24 L21 30 L33 18").stroke(.white, style: ws(3.5))
            VividTitlePolygon(points: "38,8 39.3,11.5 43,12.7 39.3,14 38,17.5 36.7,14 33,12.7 36.7,11.5").fill(k("#FDE047"))
        }
    }

    private var unmatchedObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 16).fill(lg("#94A3B8", "#475569"))
            VividTitlePath(d: "M18.5 19.5 C18.5 16 21.3 14 24.5 14 C27.7 14 30 16 30 19.2 C30 23 24 23.5 24 28").stroke(.white, style: ws(3.2))
            VividTitleCircle(cx: 24, cy: 33, r: 2).fill(.white)
        }
    }

    private var personObj: some View {
        ZStack {
            VividTitlePath(d: "M9 40 C9 28 39 28 39 40 Z").fill(lg("#A855F7", "#EC4899", true))
            VividTitleCircle(cx: 24, cy: 16, r: 8).fill(lg("#FDE68A", "#F59E0B"))
        }
    }

    private var tagObj: some View {
        ZStack {
            VividTitlePath(d: "M8 16 C8 13.8 9.8 12 12 12 H23 L40 29 C41.5 30.5 41.5 33 40 34.5 L31 43.5 C29.5 45 27 45 25.5 43.5 L8 26 V16 Z").fill(lg("#38BDF8", "#6366F1"))
            VividTitleCircle(cx: 16, cy: 20, r: 3.2).fill(.white)
            VividTitlePolygon(points: "38,8 39.3,11.5 43,12.7 39.3,14 38,17.5 36.7,14 33,12.7 36.7,11.5").fill(k("#FDE047"))
        }
    }

    private var syncObj: some View {
        ZStack {
            VividTitleCircle(cx: 24, cy: 24, r: 16).fill(lg("#3B82F6", "#1D4ED8"))
            VividTitlePath(d: "M16 18 A9 9 0 0 1 32 17 M32 11 V17.5 H25.5").stroke(.white, style: ws(2.8))
            VividTitlePath(d: "M32 30 A9 9 0 0 1 16 31 M16 37 V30.5 H22.5").stroke(.white, style: ws(2.8))
        }
    }

    private var themeObj: some View {
        ZStack {
            VividTitleRect(x: 6, y: 8, width: 36, height: 32, radius: 16).fill(lg("#F43F5E", "#8B5CF6"))
            VividTitleCircle(cx: 16, cy: 20, r: 3.5).fill(k("#FDE047"))
            VividTitleCircle(cx: 24, cy: 15, r: 3.5).fill(k("#38BDF8"))
            VividTitleCircle(cx: 32, cy: 20, r: 3.5).fill(k("#10B981"))
            VividTitleCircle(cx: 20, cy: 28, r: 3.5).fill(.white)
            VividTitlePolygon(points: "38,30 39.5,34 43.5,35.5 39.5,37 38,41 36.5,37 32.5,35.5 36.5,34").fill(k("#FDE047"))
        }
    }

    private var defaultObj: some View {
        ZStack {
            VividTitleRect(x: 8, y: 8, width: 32, height: 32, radius: 9).fill(lg("#3B82F6", "#1D4ED8"))
            VividTitleCircle(cx: 24, cy: 24, r: 8).fill(.white.opacity(0.9))
        }
    }

}

private struct VividTitleGlowModifier: ViewModifier {
    let glow: Color
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            // 底部收敛的柔光：贴身接触投影 + 轻量下沉光晕。半径刻意收小，
            // 避免大范围彩色阴影在纯色图标周围糊成「色块溢出」。
            .shadow(color: glow.opacity(0.28), radius: size * 0.05, y: size * 0.045)
            .shadow(color: glow.opacity(0.20), radius: size * 0.13, y: size * 0.11)
    }
}

private struct VividTitlePath: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        var path = Path()
        SVGPathParser.append(d, to: &path)
        return path.applying(VividTitleScale.transform(in: rect))
    }
}

private struct VividTitleCircle: Shape {
    let cx: CGFloat
    let cy: CGFloat
    let r: CGFloat
    func path(in rect: CGRect) -> Path {
        let t = VividTitleScale.transform(in: rect)
        return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2).applying(t))
    }
}

private struct VividTitleEllipse: Shape {
    let cx: CGFloat
    let cy: CGFloat
    let rx: CGFloat
    let ry: CGFloat
    func path(in rect: CGRect) -> Path {
        let t = VividTitleScale.transform(in: rect)
        return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2).applying(t))
    }
}

private struct VividTitleRect: Shape {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let scale = VividTitleScale.scale(in: rect)
        let frame = CGRect(x: x, y: y, width: width, height: height).applying(VividTitleScale.transform(in: rect))
        return Path(roundedRect: frame, cornerRadius: radius * scale)
    }
}

private struct VividTitleLine: Shape {
    let x1: CGFloat
    let y1: CGFloat
    let x2: CGFloat
    let y2: CGFloat
    func path(in rect: CGRect) -> Path {
        let t = VividTitleScale.transform(in: rect)
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1).applying(t))
        path.addLine(to: CGPoint(x: x2, y: y2).applying(t))
        return path
    }
}

private struct VividTitlePolygon: Shape {
    let points: String
    func path(in rect: CGRect) -> Path {
        let t = VividTitleScale.transform(in: rect)
        let values = points
            .split { $0 == " " || $0 == "," }
            .compactMap { token -> CGFloat? in
                guard let value = Double(token) else { return nil }
                return CGFloat(value)
            }
        var path = Path()
        var index = 0
        while index + 1 < values.count {
            let point = CGPoint(x: values[index], y: values[index + 1]).applying(t)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            index += 2
        }
        path.closeSubpath()
        return path
    }
}

private enum VividTitleScale {
    static func scale(in rect: CGRect) -> CGFloat { min(rect.width, rect.height) / 48 }
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = scale(in: rect)
        let tx = rect.midX - 24 * scale
        let ty = rect.midY - 24 * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}

private extension Color {
    static func vividHex(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255.0
        let g = Double((int >> 8) & 0xff) / 255.0
        let b = Double(int & 0xff) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

private enum VividSemanticPageIconKind {
    case video, movie, tv, anime, recording, embyVideos, privacy, collection
    case song, music, artist, playlist, album, recent, embyMusic, embyRecent
    case photo, grid, sources, health, dashboard, tasks, settings
    case person, metadata, subtitles, appearance, storage, network, info, home, tag

    init?(symbol: String) {
        let key = symbol.lowercased()
        if key.contains("house") { self = .home }
        else if key.contains("sparkles.tv") { self = .anime }
        else if key.contains("tv.library") { self = .tv }
        else if key.contains("recording.library") { self = .recording }
        else if key.contains("music.album") { self = .album }
        else if key.contains("music.recent") { self = .recent }
        else if key.contains("emby.videos") || key.contains("play.tv") || key.contains("play.rectangle.on.rectangle") { self = .embyVideos }
        else if key.contains("emby.music") { self = .embyMusic }
        else if key.contains("emby.recent") { self = .embyRecent }
        else if key == "tv" { self = .tv }
        else if key.contains("recordingtape") { self = .recording }
        else if key.contains("film") || key.contains("play.rectangle") || key == "video" { self = key.contains("film") ? .movie : .video }
        else if key.contains("lock") || key.contains("key") { self = .privacy }
        else if key.contains("grid") { self = .grid }
        else if key.contains("rectangle.stack") || key.contains("shippingbox") || key.contains("square.stack.3d") { self = .collection }
        else if key.contains("music.note.list") { self = .playlist }
        else if key == "music.note" { self = .song }
        else if key.contains("clock.arrow") { self = .recent }
        else if key.contains("music") || key.contains("waveform") || key.contains("dial") { self = .music }
        else if key.contains("person.2") || key.contains("artists") { self = .artist }
        else if key.contains("square.stack") || key.contains("opticaldisc") { self = .album }
        else if key.contains("list") { self = .playlist }
        else if key.contains("photo") || key.contains("camera") { self = .photo }
        else if key.contains("externaldrive") || key.contains("internaldrive") || key.contains("server") || key.contains("network") || key.contains("cylinder") { self = key.contains("server") || key.contains("network") ? .network : .sources }
        else if key.contains("dashboard") || key.contains("chart.pie") { self = .dashboard }
        else if key.contains("stethoscope") || key.contains("checkmark.seal") { self = .health }
        else if key.contains("checklist") || key.contains("arrow.triangle") || key.contains("clock") { self = .tasks }
        else if key.contains("gear") || key.contains("slider") { self = .settings }
        else if key.contains("person") { self = .person }
        else if key.contains("sparkles") || key.contains("wand") || key.contains("doc") { self = .metadata }
        else if key.contains("caption") || key.contains("text") { self = .subtitles }
        else if key.contains("paint") || key.contains("palette") || key.contains("circle.lefthalf") { self = .appearance }
        else if key.contains("folder") || key.contains("tray") { self = .storage }
        else if key.contains("info") { self = .info }
        else if key.contains("tag") { self = .tag }
        else { return nil }
    }

    var accent: Color {
        switch self {
        case .video, .movie, .tv, .embyVideos, .home, .settings: return AppColors.referenceBlue
        case .embyMusic, .embyRecent: return Color(red: 0.13, green: 0.83, blue: 0.66)
        case .anime, .metadata, .appearance: return Color(red: 0.84, green: 0.27, blue: 0.94)
        case .privacy, .tag: return Color(red: 1.0, green: 0.36, blue: 0.54)
        case .song, .music, .playlist, .album, .recent: return Color(red: 1.0, green: 0.35, blue: 0.58)
        case .artist, .photo, .sources, .network: return AppColors.referenceCyan
        case .grid: return AppColors.referenceBlue
        case .health, .dashboard, .recording: return Color(red: 0.13, green: 0.83, blue: 0.66)
        case .tasks, .storage: return Color(red: 1.0, green: 0.62, blue: 0.27)
        case .collection, .person, .subtitles, .info: return AppColors.referenceBlue
        }
    }

    var secondary: Color {
        switch self {
        case .video, .movie, .tv, .embyVideos, .home, .settings, .collection, .grid, .person, .subtitles, .info:
            return AppColors.referenceCyan
        case .embyMusic, .embyRecent:
            return AppColors.referenceBlue
        case .song, .music, .playlist, .album, .recent, .privacy, .tag:
            return Color(red: 1.0, green: 0.62, blue: 0.27)
        case .anime, .metadata, .appearance:
            return Color(red: 1.0, green: 0.36, blue: 0.54)
        case .artist, .photo, .sources, .network, .health, .dashboard, .recording:
            return Color(red: 0.13, green: 0.83, blue: 0.66)
        case .tasks, .storage:
            return AppColors.referenceBlue
        }
    }

    var backgroundStart: Color { accent.opacity(0.18) }
    var backgroundEnd: Color { secondary.opacity(0.11) }

    var titleTheme: (start: Color, end: Color, shadow: Color) {
        switch self {
        case .video, .tv, .anime, .movie, .embyVideos:
            return (Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.50))
        case .song, .playlist, .music, .embyMusic:
            return (AppColors.referenceBlue, AppColors.referenceCyan, AppColors.referenceBlue.opacity(0.50))
        case .album:
            return (Color(red: 0.85, green: 0.27, blue: 0.94), Color(red: 0.66, green: 0.33, blue: 0.97), Color(red: 0.85, green: 0.27, blue: 0.94).opacity(0.50))
        case .artist:
            return (Color(red: 0.98, green: 0.45, blue: 0.09), Color(red: 0.98, green: 0.57, blue: 0.24), Color(red: 0.98, green: 0.45, blue: 0.09).opacity(0.50))
        case .recent, .embyRecent:
            return (Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.50))
        case .photo, .grid, .recording:
            return (AppColors.referenceCyan, AppColors.referenceBlue, AppColors.referenceCyan.opacity(0.50))
        case .sources, .network, .health, .dashboard:
            return (Color(red: 0.05, green: 0.65, blue: 0.91), Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.05, green: 0.65, blue: 0.91).opacity(0.50))
        case .tasks, .storage:
            return (Color(red: 1.0, green: 0.36, blue: 0.54), Color(red: 1.0, green: 0.62, blue: 0.27), Color(red: 1.0, green: 0.36, blue: 0.54).opacity(0.50))
        case .settings:
            return (AppColors.referenceBlue, AppColors.referenceCyan, AppColors.referenceBlue.opacity(0.50))
        case .privacy, .tag:
            return (Color(red: 1.0, green: 0.36, blue: 0.54), Color(red: 1.0, green: 0.62, blue: 0.27), Color(red: 1.0, green: 0.36, blue: 0.54).opacity(0.50))
        case .collection, .person, .metadata, .subtitles, .appearance, .info, .home:
            return (AppColors.referenceBlue, AppColors.referenceCyan, AppColors.referenceBlue.opacity(0.50))
        }
    }

    var titleGlyphSystemImage: String {
        switch self {
        case .video: return "play.rectangle"
        case .movie: return "film"
        case .tv: return "tv"
        case .anime: return "sparkles.tv"
        case .recording: return "video"
        case .embyVideos: return "play.rectangle.on.rectangle"
        case .privacy: return "lock"
        case .collection: return "rectangle.stack.badge.plus"
        case .song, .music: return "music.note"
        case .artist: return "person.2"
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .recent, .embyRecent: return "clock"
        case .embyMusic: return "server.rack"
        case .photo: return "photo"
        case .grid: return "square.grid.2x2"
        case .sources: return "externaldrive"
        case .health: return "stethoscope"
        case .dashboard: return "dashboard"
        case .tasks: return "checklist"
        case .settings: return "gearshape"
        case .person: return "person"
        case .metadata: return "doc.text"
        case .subtitles: return "captions.bubble"
        case .appearance: return "paintbrush.pointed"
        case .storage: return "folder"
        case .network: return "server.rack"
        case .info: return "info.circle"
        case .home: return "house"
        case .tag: return "tag"
        }
    }
}

private struct VividSemanticPageGlyph: View {
    let kind: VividSemanticPageIconKind

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let accent = kind.accent
            let secondary = kind.secondary
            ZStack {
                switch kind {
                case .video:
                    tvSet(size, accent: accent, secondary: secondary, showsPlay: true)
                case .movie:
                    clapper(size, accent: accent, secondary: secondary)
                case .tv:
                    dramaScreen(size, accent: accent, secondary: secondary)
                case .anime:
                    tvSet(size, accent: accent, secondary: secondary, showsPlay: false)
                case .recording:
                    recordingCamera(size, accent: accent, secondary: secondary)
                case .embyVideos:
                    stackedScreens(size, accent: accent, secondary: secondary)
                case .embyMusic:
                    embyMusicServer(size, accent: accent, secondary: secondary)
                case .embyRecent:
                    embyRecentServer(size, accent: accent, secondary: secondary)
                case .privacy:
                    shield(size, accent: accent, secondary: secondary)
                    Circle().fill(.white).frame(width: size * 0.16, height: size * 0.16).offset(y: -size * 0.03)
                    RoundedRectangle(cornerRadius: size * 0.03).fill(.white).frame(width: size * 0.07, height: size * 0.21).offset(y: size * 0.10)
                case .collection:
                    folder(size, accent: accent, secondary: secondary)
                    plusMark(size, color: .white)
                case .song:
                    songCard(size, accent: accent, secondary: secondary)
                case .music:
                    note(size, accent: accent, secondary: secondary)
                case .artist:
                    artistGroup(size, accent: accent, secondary: secondary)
                case .playlist:
                    roundedBox(size, radius: 0.20, accent: accent, secondary: secondary)
                    VStack(spacing: size * 0.09) {
                        line(size, width: 0.45)
                        line(size, width: 0.36)
                        line(size, width: 0.28)
                    }
                    .foregroundStyle(.white)
                case .album:
                    albumStack(size, accent: accent, secondary: secondary)
                case .recent:
                    recentClock(size, accent: accent, secondary: secondary)
                case .photo:
                    photo(size, accent: accent, secondary: secondary)
                case .grid:
                    grid(size, accent: accent, secondary: secondary)
                case .sources:
                    drive(size, accent: accent, secondary: secondary)
                case .network:
                    server(size, accent: accent, secondary: secondary)
                case .health:
                    heartPulse(size, accent: accent, secondary: secondary)
                case .dashboard:
                    dashboardGauge(size, accent: accent, secondary: secondary)
                case .tasks:
                    checklist(size, accent: accent, secondary: secondary)
                case .settings:
                    gearLike(size, accent: accent, secondary: secondary)
                case .person:
                    person(size, accent: accent, secondary: secondary)
                case .metadata:
                    sparkleDoc(size, accent: accent, secondary: secondary)
                case .subtitles:
                    captions(size, accent: accent, secondary: secondary)
                case .appearance:
                    brush(size, accent: accent, secondary: secondary)
                case .storage:
                    storage(size, accent: accent, secondary: secondary)
                case .info:
                    circleIcon(size, accent: accent, secondary: secondary)
                    Text("i")
                        .font(.system(size: size * 0.60, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                case .home:
                    house(size, accent: accent, secondary: secondary)
                case .tag:
                    tag(size, accent: accent, secondary: secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func roundedBox(_ size: CGFloat, radius: CGFloat, accent: Color, secondary: Color) -> some View {
        RoundedRectangle(cornerRadius: size * radius, style: .continuous)
            .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func circleIcon(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        Circle()
            .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func triangle(_ size: CGFloat, color: Color, x: CGFloat, y: CGFloat, scale: CGFloat) -> some View {
        PlayTriangle()
            .fill(color)
            .frame(width: size * scale, height: size * scale * 1.12)
            .position(x: size * x, y: size * y)
    }

    private func plusMark(_ size: CGFloat, color: Color) -> some View {
        ZStack {
            Capsule().fill(color).frame(width: size * 0.42, height: size * 0.08)
            Capsule().fill(color).frame(width: size * 0.08, height: size * 0.42)
        }
    }

    private func line(_ size: CGFloat, width: CGFloat) -> some View {
        Capsule().frame(width: size * width, height: size * 0.08)
    }

    private func clapper(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.88, height: size * 0.70)
                .offset(y: size * 0.08)
            HStack(spacing: size * 0.06) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: size * 0.025)
                        .fill(.white.opacity(0.95))
                        .frame(width: size * 0.18, height: size * 0.12)
                        .rotationEffect(.degrees(-14))
                }
            }
            .offset(y: -size * 0.02)
            triangle(size, color: .white, x: 0.53, y: 0.56, scale: 0.24)
        }
    }

    private func tvSet(_ size: CGFloat, accent: Color, secondary: Color, showsPlay: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(LinearGradient(colors: [secondary, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.88, height: size * 0.68)
                .offset(y: size * 0.05)
            RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                .stroke(.white.opacity(0.62), lineWidth: size * 0.035)
                .frame(width: size * 0.70, height: size * 0.48)
                .offset(y: size * 0.05)
            if showsPlay {
                triangle(size, color: .white, x: 0.53, y: 0.55, scale: 0.24)
            } else {
                RoundedRectangle(cornerRadius: size * 0.025)
                    .fill(.white.opacity(0.90))
                    .frame(width: size * 0.38, height: size * 0.08)
                    .offset(y: size * 0.05)
            }
            HStack(spacing: size * 0.30) {
                Capsule().fill(accent).frame(width: size * 0.08, height: size * 0.20).rotationEffect(.degrees(-32))
                Capsule().fill(secondary).frame(width: size * 0.08, height: size * 0.20).rotationEffect(.degrees(32))
            }
            .offset(y: -size * 0.42)
        }
    }

    private func dramaScreen(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Capsule()
                .fill(secondary.opacity(0.30))
                .frame(width: size * 0.58, height: size * 0.28)
                .blur(radius: size * 0.045)
                .offset(x: size * 0.20, y: -size * 0.20)
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.88, height: size * 0.60)
                .offset(y: -size * 0.01)
                .shadow(color: accent.opacity(0.22), radius: size * 0.10, y: size * 0.06)
            RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                .stroke(.white.opacity(0.56), lineWidth: size * 0.040)
                .frame(width: size * 0.68, height: size * 0.38)
                .offset(y: -size * 0.03)
            HStack(spacing: size * 0.055) {
                RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                    .fill(.white.opacity(0.95))
                    .frame(width: size * 0.13, height: size * 0.24)
                RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                    .fill(.white.opacity(0.76))
                    .frame(width: size * 0.13, height: size * 0.24)
                RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                    .fill(.white.opacity(0.96))
                    .frame(width: size * 0.13, height: size * 0.24)
            }
            .offset(y: -size * 0.03)
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.88), .white.opacity(0.52)], startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 0.42, height: size * 0.060)
                .offset(y: size * 0.35)
            HStack(spacing: size * 0.24) {
                Capsule().fill(.white.opacity(0.86)).frame(width: size * 0.07, height: size * 0.18).rotationEffect(.degrees(10))
                Capsule().fill(.white.opacity(0.72)).frame(width: size * 0.07, height: size * 0.18).rotationEffect(.degrees(-10))
            }
            .offset(y: size * 0.28)
        }
    }

    private func stackedScreens(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(secondary.opacity(0.92))
                .frame(width: size * 0.34, height: size * 0.68)
                .offset(x: -size * 0.25, y: size * 0.02)
            VStack(spacing: size * 0.06) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == 1 ? 0.92 : 0.66))
                        .frame(width: size * 0.18, height: size * 0.045)
                }
            }
            .offset(x: -size * 0.25, y: size * 0.02)
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.64, height: size * 0.48)
                .offset(x: size * 0.12, y: -size * 0.03)
            triangle(size, color: .white, x: 0.61, y: 0.47, scale: 0.19)
            Capsule().fill(.white.opacity(0.75)).frame(width: size * 0.32, height: size * 0.055).offset(x: size * 0.12, y: size * 0.27)
        }
    }

    private func embyMusicServer(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            server(size, accent: secondary, secondary: accent)
                .frame(width: size * 0.82, height: size * 0.70)
                .offset(x: -size * 0.10, y: size * 0.10)
            Circle().fill(Color.white.opacity(0.95)).frame(width: size * 0.22, height: size * 0.22).offset(x: size * 0.24, y: size * 0.20)
            RoundedRectangle(cornerRadius: size * 0.022).fill(.white).frame(width: size * 0.06, height: size * 0.44).offset(x: size * 0.32, y: -size * 0.06)
            Capsule().fill(.white).frame(width: size * 0.28, height: size * 0.065).rotationEffect(.degrees(-10)).offset(x: size * 0.23, y: -size * 0.30)
        }
    }

    private func embyRecentServer(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            server(size, accent: secondary, secondary: accent)
                .frame(width: size * 0.74, height: size * 0.66)
                .offset(x: -size * 0.12, y: size * 0.12)
            Circle()
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.48, height: size * 0.48)
                .offset(x: size * 0.22, y: -size * 0.16)
            Circle().stroke(.white.opacity(0.55), lineWidth: size * 0.032)
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: size * 0.22, y: -size * 0.16)
            Capsule().fill(.white).frame(width: size * 0.045, height: size * 0.15).offset(x: size * 0.22, y: -size * 0.21)
            Capsule().fill(.white).frame(width: size * 0.14, height: size * 0.045).offset(x: size * 0.27, y: -size * 0.12)
        }
    }

    private func recordingCamera(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Capsule()
                .fill(secondary.opacity(0.26))
                .frame(width: size * 0.62, height: size * 0.28)
                .blur(radius: size * 0.055)
                .offset(x: -size * 0.12, y: size * 0.22)
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.86, height: size * 0.58)
                .rotationEffect(.degrees(-3))
                .shadow(color: secondary.opacity(0.20), radius: size * 0.10, y: size * 0.06)
            HStack(spacing: size * 0.14) {
                reel(size, opacity: 0.96)
                reel(size, opacity: 0.82)
            }
            .offset(y: -size * 0.04)
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .stroke(.white.opacity(0.82), lineWidth: size * 0.045)
                .frame(width: size * 0.58, height: size * 0.28)
                .offset(y: size * 0.02)
            Capsule()
                .fill(.white.opacity(0.88))
                .frame(width: size * 0.48, height: size * 0.060)
                .offset(y: size * 0.23)
            Capsule()
                .fill(.white.opacity(0.60))
                .frame(width: size * 0.24, height: size * 0.045)
                .offset(x: size * 0.20, y: size * 0.34)
        }
    }

    private func reel(_ size: CGFloat, opacity: Double) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(opacity))
                .frame(width: size * 0.25, height: size * 0.25)
            Circle()
                .fill(.black.opacity(0.10))
                .frame(width: size * 0.075, height: size * 0.075)
        }
    }

    private func shield(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ShieldShape()
            .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size * 0.82, height: size * 0.92)
    }

    private func folder(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        FolderShape()
            .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size * 0.92, height: size * 0.74)
    }

    private func note(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle().fill(secondary).frame(width: size * 0.28, height: size * 0.28).offset(x: -size * 0.23, y: size * 0.25)
            Circle().fill(accent).frame(width: size * 0.33, height: size * 0.33).offset(x: size * 0.20, y: size * 0.16)
            RoundedRectangle(cornerRadius: size * 0.035).fill(accent).frame(width: size * 0.09, height: size * 0.74).offset(x: size * 0.36, y: -size * 0.14)
            RoundedRectangle(cornerRadius: size * 0.035).fill(secondary).frame(width: size * 0.09, height: size * 0.60).offset(x: -size * 0.08, y: -size * 0.07)
            Capsule().fill(accent).frame(width: size * 0.48, height: size * 0.10).rotationEffect(.degrees(-10)).offset(x: size * 0.14, y: -size * 0.46)
        }
    }

    private func songCard(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.74, height: size * 0.78)
                .rotationEffect(.degrees(-5))
                .offset(x: -size * 0.06, y: size * 0.01)
            VStack(alignment: .leading, spacing: size * 0.07) {
                Capsule().fill(.white.opacity(0.92)).frame(width: size * 0.34, height: size * 0.055)
                Capsule().fill(.white.opacity(0.64)).frame(width: size * 0.45, height: size * 0.050)
                Capsule().fill(.white.opacity(0.50)).frame(width: size * 0.28, height: size * 0.050)
            }
            .offset(x: -size * 0.08, y: size * 0.10)
            Circle().fill(.white.opacity(0.94)).frame(width: size * 0.20, height: size * 0.20).offset(x: size * 0.27, y: size * 0.25)
            RoundedRectangle(cornerRadius: size * 0.024)
                .fill(.white.opacity(0.96))
                .frame(width: size * 0.06, height: size * 0.42)
                .offset(x: size * 0.36, y: -size * 0.06)
            Capsule().fill(.white.opacity(0.96)).frame(width: size * 0.27, height: size * 0.07).rotationEffect(.degrees(-12)).offset(x: size * 0.29, y: -size * 0.30)
        }
    }

    private func palette(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach(0..<4, id: \.self) { index in
                let xOffsets: [CGFloat] = [-0.22, 0.02, 0.24, -0.05]
                let yOffsets: [CGFloat] = [-0.16, -0.28, -0.08, 0.18]
                Circle().fill(.white.opacity(0.9))
                    .frame(width: size * 0.13, height: size * 0.13)
                    .offset(x: xOffsets[index] * size, y: yOffsets[index] * size)
            }
        }
        .frame(width: size * 0.86, height: size * 0.86)
    }

    private func disc(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            circleIcon(size, accent: accent, secondary: secondary)
            Circle().stroke(.white.opacity(0.42), lineWidth: size * 0.05).frame(width: size * 0.58, height: size * 0.58)
            Circle().fill(.white).frame(width: size * 0.18, height: size * 0.18)
        }
    }

    private func albumStack(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [secondary, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.66, height: size * 0.66)
                .offset(x: size * 0.20, y: -size * 0.04)
                .shadow(color: secondary.opacity(0.18), radius: size * 0.10, y: size * 0.04)
            Circle().stroke(.white.opacity(0.44), lineWidth: size * 0.035).frame(width: size * 0.48, height: size * 0.48).offset(x: size * 0.20, y: -size * 0.04)
            Circle().stroke(.white.opacity(0.28), lineWidth: size * 0.026).frame(width: size * 0.30, height: size * 0.30).offset(x: size * 0.20, y: -size * 0.04)
            Circle().fill(.white.opacity(0.93)).frame(width: size * 0.13, height: size * 0.13).offset(x: size * 0.20, y: -size * 0.04)
            RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                .fill(secondary.opacity(0.42))
                .frame(width: size * 0.56, height: size * 0.62)
                .rotationEffect(.degrees(8))
                .offset(x: -size * 0.13, y: size * 0.08)
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.58, height: size * 0.70)
                .rotationEffect(.degrees(-5))
                .offset(x: -size * 0.15, y: size * 0.08)
                .shadow(color: accent.opacity(0.20), radius: size * 0.08, y: size * 0.05)
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(.white.opacity(0.20))
                .frame(width: size * 0.32, height: size * 0.34)
                .offset(x: -size * 0.15, y: -size * 0.02)
            Capsule().fill(.white.opacity(0.90)).frame(width: size * 0.34, height: size * 0.065).offset(x: -size * 0.15, y: size * 0.30)
        }
    }

    private func artistGroup(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle()
                .fill(secondary.opacity(0.82))
                .frame(width: size * 0.35, height: size * 0.35)
                .offset(x: -size * 0.23, y: -size * 0.17)
            Circle()
                .fill(accent)
                .frame(width: size * 0.40, height: size * 0.40)
                .offset(x: size * 0.10, y: -size * 0.22)
            Capsule()
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.78, height: size * 0.42)
                .offset(y: size * 0.24)
            Capsule().fill(.white.opacity(0.35)).frame(width: size * 0.38, height: size * 0.07).offset(y: size * 0.20)
        }
    }

    private func recentClock(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle()
                .fill(secondary.opacity(0.25))
                .frame(width: size * 0.52, height: size * 0.52)
                .blur(radius: size * 0.040)
                .offset(x: -size * 0.18, y: size * 0.18)
            Circle()
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.68, height: size * 0.68)
                .offset(x: size * 0.06, y: -size * 0.07)
                .shadow(color: accent.opacity(0.18), radius: size * 0.10, y: size * 0.05)
            Circle()
                .stroke(.white.opacity(0.40), lineWidth: size * 0.042)
                .frame(width: size * 0.50, height: size * 0.50)
                .offset(x: size * 0.06, y: -size * 0.07)
            Capsule().fill(.white).frame(width: size * 0.055, height: size * 0.20).offset(x: size * 0.06, y: -size * 0.13)
            Capsule().fill(.white).frame(width: size * 0.19, height: size * 0.055).rotationEffect(.degrees(18)).offset(x: size * 0.15, y: -size * 0.02)
            Circle().fill(.white.opacity(0.92)).frame(width: size * 0.19, height: size * 0.19).offset(x: -size * 0.25, y: size * 0.24)
            RoundedRectangle(cornerRadius: size * 0.020)
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.055, height: size * 0.32)
                .offset(x: -size * 0.17, y: size * 0.08)
            Capsule().fill(.white.opacity(0.92)).frame(width: size * 0.22, height: size * 0.060).rotationEffect(.degrees(-12)).offset(x: -size * 0.20, y: -size * 0.10)
        }
    }

    private func photo(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.86, height: size * 0.74)
            Circle().fill(.white.opacity(0.92)).frame(width: size * 0.16, height: size * 0.16).offset(x: -size * 0.22, y: -size * 0.18)
            MountainShape().fill(.white.opacity(0.95)).frame(width: size * 0.62, height: size * 0.30).offset(y: size * 0.18)
        }
    }

    private func grid(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let x = index.isMultiple(of: 2) ? -size * 0.20 : size * 0.20
                let y = index < 2 ? -size * 0.20 : size * 0.20
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(index.isMultiple(of: 2) ? accent : secondary)
                    .frame(width: size * 0.30, height: size * 0.30)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                            .stroke(.white.opacity(0.34), lineWidth: size * 0.025)
                    }
                    .offset(x: x, y: y)
            }
        }
        .frame(width: size * 0.88, height: size * 0.88)
    }

    private func drive(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [secondary, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.86, height: size * 0.68)
            RoundedRectangle(cornerRadius: size * 0.05)
                .stroke(.white.opacity(0.88), lineWidth: size * 0.065)
                .frame(width: size * 0.60, height: size * 0.28)
                .offset(y: -size * 0.04)
            Circle().fill(.white).frame(width: size * 0.09, height: size * 0.09).offset(x: -size * 0.18, y: size * 0.22)
        }
    }

    private func server(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        VStack(spacing: size * 0.09) {
            ForEach(0..<2, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                    .fill(index == 0 ? accent : secondary)
                    .overlay(alignment: .leading) {
                        Circle().fill(.white.opacity(0.92)).frame(width: size * 0.10, height: size * 0.10).padding(.leading, size * 0.13)
                    }
                    .frame(width: size * 0.84, height: size * 0.31)
            }
        }
    }

    private func heartPulse(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            HeartShape().fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.90, height: size * 0.80)
            PulseShape().stroke(.white, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 0.28)
                .offset(y: size * 0.04)
        }
    }

    private func dashboardGauge(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.88, height: size * 0.72)
                .shadow(color: accent.opacity(0.18), radius: size * 0.10, y: size * 0.05)

            Circle()
                .trim(from: 0.10, to: 0.86)
                .stroke(.white.opacity(0.42), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                .rotationEffect(.degrees(126))
                .frame(width: size * 0.46, height: size * 0.46)
                .offset(x: -size * 0.18, y: -size * 0.06)

            Circle()
                .trim(from: 0.10, to: 0.58)
                .stroke(.white.opacity(0.96), style: StrokeStyle(lineWidth: size * 0.070, lineCap: .round))
                .rotationEffect(.degrees(126))
                .frame(width: size * 0.46, height: size * 0.46)
                .offset(x: -size * 0.18, y: -size * 0.06)

            VStack(alignment: .leading, spacing: size * 0.055) {
                Capsule().fill(.white.opacity(0.94)).frame(width: size * 0.32, height: size * 0.055)
                Capsule().fill(.white.opacity(0.62)).frame(width: size * 0.26, height: size * 0.050)
                Capsule().fill(.white.opacity(0.46)).frame(width: size * 0.20, height: size * 0.050)
            }
            .offset(x: size * 0.22, y: size * 0.02)

            HStack(spacing: size * 0.035) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: size * 0.025, style: .continuous)
                        .fill(.white.opacity(index == 1 ? 0.90 : 0.68))
                        .frame(width: size * 0.07, height: size * CGFloat([0.16, 0.25, 0.20][index]))
                }
            }
            .offset(x: size * 0.23, y: size * 0.27)
        }
    }

    private func checklist(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            roundedBox(size, radius: 0.18, accent: accent, secondary: secondary)
            VStack(spacing: size * 0.11) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: size * 0.08) {
                        Circle().fill(.white).frame(width: size * 0.09, height: size * 0.09)
                        Capsule().fill(.white.opacity(0.92)).frame(width: size * 0.42, height: size * 0.07)
                    }
                }
            }
        }
    }

    private func gearLike(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 2) ? accent : secondary)
                    .frame(width: size * 0.13, height: size * 0.32)
                    .offset(y: -size * 0.36)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle()
                .fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.60, height: size * 0.60)
            Circle().fill(.white.opacity(0.94)).frame(width: size * 0.22, height: size * 0.22)
        }
        .frame(width: size * 0.84, height: size * 0.84)
    }

    private func person(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            Circle().fill(accent).frame(width: size * 0.38, height: size * 0.38).offset(y: -size * 0.20)
            Capsule().fill(secondary).frame(width: size * 0.72, height: size * 0.42).offset(y: size * 0.26)
        }
    }

    private func sparkleDoc(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            roundedBox(size, radius: 0.14, accent: accent, secondary: secondary).frame(width: size * 0.64, height: size * 0.82)
            SparkleShape().fill(.white).frame(width: size * 0.28, height: size * 0.28).offset(x: size * 0.24, y: -size * 0.26)
            Capsule().fill(.white.opacity(0.82)).frame(width: size * 0.34, height: size * 0.06).offset(y: size * 0.08)
            Capsule().fill(.white.opacity(0.70)).frame(width: size * 0.24, height: size * 0.06).offset(y: size * 0.24)
        }
    }

    private func captions(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            roundedBox(size, radius: 0.18, accent: accent, secondary: secondary)
            Capsule().fill(.white.opacity(0.92)).frame(width: size * 0.58, height: size * 0.08).offset(y: -size * 0.10)
            Capsule().fill(.white.opacity(0.80)).frame(width: size * 0.42, height: size * 0.08).offset(y: size * 0.12)
        }
    }

    private func brush(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            PaletteDropShape().fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.82, height: size * 0.82)
            Capsule().fill(.white.opacity(0.95)).frame(width: size * 0.12, height: size * 0.56).rotationEffect(.degrees(38)).offset(x: size * 0.24, y: size * 0.05)
        }
    }

    private func storage(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.14).fill(accent).frame(width: size * 0.76, height: size * 0.30).offset(y: -size * 0.22)
            RoundedRectangle(cornerRadius: size * 0.14).fill(secondary).frame(width: size * 0.76, height: size * 0.30).offset(y: size * 0.12)
            Circle().fill(.white.opacity(0.92)).frame(width: size * 0.08, height: size * 0.08).offset(x: -size * 0.24, y: size * 0.12)
        }
    }

    private func house(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            HouseShape().fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.86, height: size * 0.78)
            RoundedRectangle(cornerRadius: size * 0.03).fill(.white.opacity(0.92)).frame(width: size * 0.16, height: size * 0.28).offset(y: size * 0.20)
        }
    }

    private func tag(_ size: CGFloat, accent: Color, secondary: Color) -> some View {
        ZStack {
            TagShape().fill(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.84, height: size * 0.72)
            Circle().fill(.white.opacity(0.92)).frame(width: size * 0.12, height: size * 0.12).offset(x: size * 0.20, y: -size * 0.18)
        }
    }
}

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18), control1: CGPoint(x: rect.midX + rect.width * 0.20, y: rect.minY + rect.height * 0.04), control2: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY + rect.height * 0.10))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.height * 0.58), control2: CGPoint(x: rect.midX + rect.width * 0.25, y: rect.height * 0.86))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18), control1: CGPoint(x: rect.midX - rect.width * 0.25, y: rect.height * 0.86), control2: CGPoint(x: rect.minX, y: rect.height * 0.58))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY), control1: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.10), control2: CGPoint(x: rect.midX - rect.width * 0.20, y: rect.minY + rect.height * 0.04))
        return p
    }
}

private struct FolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tabW = rect.width * 0.38
        let tabH = rect.height * 0.28
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + tabH))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + tabH * 0.58), control: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + tabH * 0.58))
        p.addLine(to: CGPoint(x: rect.minX + tabW, y: rect.minY + tabH * 0.58))
        p.addLine(to: CGPoint(x: rect.minX + tabW + rect.width * 0.10, y: rect.minY + tabH))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY + tabH))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabH + rect.height * 0.12), control: CGPoint(x: rect.maxX, y: rect.minY + tabH))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.10))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.10), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tabH + rect.height * 0.12))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + tabH), control: CGPoint(x: rect.minX, y: rect.minY + tabH))
        return p
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.33, y: rect.minY + rect.height * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.minY + rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.40))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.height * 0.34), control1: CGPoint(x: rect.width * 0.12, y: rect.height * 0.72), control2: CGPoint(x: rect.minX, y: rect.height * 0.50))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.height * 0.20), control1: CGPoint(x: rect.minX, y: rect.minY), control2: CGPoint(x: rect.width * 0.35, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.34), control1: CGPoint(x: rect.width * 0.65, y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.height * 0.50), control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.72))
        return p
    }
}

private struct PulseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.26, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.width * 0.66, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.38))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height * 0.38))
        p.closeSubpath()
        return p
    }
}

private struct PaletteDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rect)
        return p
    }
}

private struct HouseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.43))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.height * 0.43))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.height * 0.43))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.43))
        p.closeSubpath()
        return p
    }
}

private struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 桥接视图：能映射到焕彩图标就用线性图标渲染，否则回退到原 SF Symbol。
/// 用它替换页面里的 `Image(systemName:)`，即可逐页换上设计稿图标且不破坏未覆盖的符号。
struct AppGlyph: View {
    let systemImage: String
    var size: CGFloat = 17
    var lineWidth: CGFloat = 2
    /// 个别场景（如填充态徽标）想强制走系统符号，可置 true。
    var forceSystem: Bool = false

    var body: some View {
        if !forceSystem, let vivid = VividIconLibrary.vividName(forSystemImage: systemImage) {
            VividIcon(name: vivid, size: size, lineWidth: lineWidth)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.94))
        }
    }
}

func vividReferenceTint(forSystemImage systemImage: String) -> Color {
    let key = systemImage.lowercased()
    if key.contains("music") || key.contains("waveform") || key.contains("dial") {
        return Color(red: 0.84, green: 0.27, blue: 0.94)
    }
    if key.contains("photo") || key.contains("paint") || key.contains("palette") || key.contains("sun") {
        return Color(red: 0.21, green: 0.75, blue: 0.98)
    }
    if key.contains("externaldrive") || key.contains("internaldrive") || key.contains("server") || key.contains("cylinder") {
        return Color(red: 0.13, green: 0.83, blue: 0.66)
    }
    if key.contains("lock") || key.contains("key") || key.contains("vault") || key.contains("touchid") {
        return Color(red: 1.0, green: 0.36, blue: 0.54)
    }
    if key.contains("bell") || key.contains("clock") || key.contains("arrow.triangle") || key.contains("refresh") {
        return AppColors.referenceCyan
    }
    if key.contains("sparkle") || key.contains("wand") || key.contains("tag") || key.contains("meta") {
        return Color(red: 1.0, green: 0.62, blue: 0.27)
    }
    if key.contains("stethoscope") || key.contains("check") || key.contains("heart") {
        return Color(red: 0.13, green: 0.83, blue: 0.66)
    }
    return AppColors.referenceBlue
}

// MARK: - SVG path 解析器

/// 极简但完整的 SVG path `d` 解析器：支持 M m L l H h V v C c S s Q q T t A a Z z。
/// 圆弧 A/a 用端点参数化转中心、再以三次贝塞尔逼近（每段 ≤90°），与系统坐标无关、稳定可靠。
enum SVGPathParser {
    static func append(_ data: String, to path: inout Path) {
        var reader = Reader(data)
        var cur = CGPoint.zero
        var subStart = CGPoint.zero
        var lastCmd: Character = " "
        var lastCtrl: CGPoint?

        func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

        while true {
            reader.skipSep()
            if reader.isAtEnd { break }
            let cmd: Character
            if let letter = reader.nextCommandLetter() {
                cmd = letter
            } else {
                // 缺省命令字母时按 SVG 规则重复上一命令（M→L、m→l）。
                if lastCmd == "M" { cmd = "L" }
                else if lastCmd == "m" { cmd = "l" }
                else if lastCmd == " " { break }
                else { cmd = lastCmd }
            }
            let rel = cmd.isLowercase
            let key = cmd.lowercased()

            switch key {
            case "m":
                var pt = CGPoint(x: reader.num(), y: reader.num())
                if rel { pt = add(pt, cur) }
                cur = pt; subStart = pt; path.move(to: pt); lastCtrl = nil
            case "l":
                var pt = CGPoint(x: reader.num(), y: reader.num())
                if rel { pt = add(pt, cur) }
                cur = pt; path.addLine(to: pt); lastCtrl = nil
            case "h":
                var x = reader.num(); if rel { x += cur.x }
                cur.x = x; path.addLine(to: cur); lastCtrl = nil
            case "v":
                var y = reader.num(); if rel { y += cur.y }
                cur.y = y; path.addLine(to: cur); lastCtrl = nil
            case "c":
                var c1 = CGPoint(x: reader.num(), y: reader.num())
                var c2 = CGPoint(x: reader.num(), y: reader.num())
                var end = CGPoint(x: reader.num(), y: reader.num())
                if rel { c1 = add(c1, cur); c2 = add(c2, cur); end = add(end, cur) }
                path.addCurve(to: end, control1: c1, control2: c2); lastCtrl = c2; cur = end
            case "s":
                var c2 = CGPoint(x: reader.num(), y: reader.num())
                var end = CGPoint(x: reader.num(), y: reader.num())
                if rel { c2 = add(c2, cur); end = add(end, cur) }
                let c1: CGPoint
                if (lastCmd == "c" || lastCmd == "C" || lastCmd == "s" || lastCmd == "S"), let lc = lastCtrl {
                    c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
                } else { c1 = cur }
                path.addCurve(to: end, control1: c1, control2: c2); lastCtrl = c2; cur = end
            case "q":
                var c = CGPoint(x: reader.num(), y: reader.num())
                var end = CGPoint(x: reader.num(), y: reader.num())
                if rel { c = add(c, cur); end = add(end, cur) }
                path.addQuadCurve(to: end, control: c); lastCtrl = c; cur = end
            case "t":
                var end = CGPoint(x: reader.num(), y: reader.num())
                if rel { end = add(end, cur) }
                let c: CGPoint
                if (lastCmd == "q" || lastCmd == "Q" || lastCmd == "t" || lastCmd == "T"), let lc = lastCtrl {
                    c = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y)
                } else { c = cur }
                path.addQuadCurve(to: end, control: c); lastCtrl = c; cur = end
            case "a":
                let rx = reader.num(); let ry = reader.num(); let rot = reader.num()
                let large = reader.flag(); let sweep = reader.flag()
                var end = CGPoint(x: reader.num(), y: reader.num())
                if rel { end = add(end, cur) }
                appendArc(&path, from: cur, to: end, rx: rx, ry: ry, rotationDeg: rot, largeArc: large, sweep: sweep)
                cur = end; lastCtrl = nil
            case "z":
                path.closeSubpath(); cur = subStart; lastCtrl = nil
            default:
                return
            }
            lastCmd = cmd
        }
    }

    // 端点参数化的椭圆弧 → 三次贝塞尔。
    private static func appendArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDeg: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) {
            path.addLine(to: p1); return
        }
        let phi = rotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        var numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        if numerator < 0 { numerator = 0 }
        var coef = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard len != 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var dtheta = angle(ux, uy, vx, vy)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }

        let segs = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        let delta = dtheta / CGFloat(segs)
        let alpha = (4.0 / 3.0) * tan(delta / 4)
        var t = theta1
        for _ in 0..<segs {
            let t2 = t + delta
            let p0s = pointOnArc(cx, cy, rx, ry, cosP, sinP, t)
            let p3s = pointOnArc(cx, cy, rx, ry, cosP, sinP, t2)
            let d1 = derivOnArc(rx, ry, cosP, sinP, t)
            let d2 = derivOnArc(rx, ry, cosP, sinP, t2)
            let c1 = CGPoint(x: p0s.x + alpha * d1.x, y: p0s.y + alpha * d1.y)
            let c2 = CGPoint(x: p3s.x - alpha * d2.x, y: p3s.y - alpha * d2.y)
            path.addCurve(to: p3s, control1: c1, control2: c2)
            t = t2
        }
    }

    private static func pointOnArc(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                                   _ cosP: CGFloat, _ sinP: CGFloat, _ t: CGFloat) -> CGPoint {
        let x = rx * cos(t), y = ry * sin(t)
        return CGPoint(x: cosP * x - sinP * y + cx, y: sinP * x + cosP * y + cy)
    }

    private static func derivOnArc(_ rx: CGFloat, _ ry: CGFloat, _ cosP: CGFloat, _ sinP: CGFloat, _ t: CGFloat) -> CGPoint {
        let dx = -rx * sin(t), dy = ry * cos(t)
        return CGPoint(x: cosP * dx - sinP * dy, y: sinP * dx + cosP * dy)
    }

    // 数字 / 命令字母扫描器。
    private struct Reader {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }
        var isAtEnd: Bool { i >= chars.count }

        mutating func skipSep() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
            }
        }

        mutating func nextCommandLetter() -> Character? {
            skipSep()
            guard i < chars.count else { return nil }
            let c = chars[i]
            // e/E 属于指数，不当命令；其余字母才是命令。
            if c.isLetter && c != "e" && c != "E" { i += 1; return c }
            return nil
        }

        mutating func num() -> CGFloat {
            skipSep()
            guard i < chars.count else { return 0 }
            var s = ""
            if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var seenDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c); i += 1 }
                else if c == "." {
                    if seenDot { break }      // 第二个小数点 → 新数字起点（如 "4.9.4"）
                    seenDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                } else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }

        // 圆弧标志位是单个 0/1，可能紧贴后续数字无分隔。
        mutating func flag() -> Bool {
            skipSep()
            guard i < chars.count else { return false }
            let c = chars[i]
            if c == "0" { i += 1; return false }
            if c == "1" { i += 1; return true }
            return num() != 0
        }
    }
}
