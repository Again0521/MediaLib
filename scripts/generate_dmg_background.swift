import AppKit
import Foundation

// 系统风格 DMG 背景：不再用品牌渐变卡片/光晕/大标题，而是模仿 macOS 原生安装窗口——
// 干净的浅色窗体底、应用图标与 Applications 之间一道标准的灰色拖拽箭头。
// 图标本身与名称由 Finder 绘制，这里只画底色 + 箭头 + 一行克制的说明文字。
let outputPath = CommandLine.arguments.dropFirst().first ?? "dist/dmg-background.png"
let size = NSSize(width: 600, height: 400)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    text.draw(in: rect, withAttributes: attributes)
}

let image = NSImage(size: size)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
// macOS 浅色窗体底色（接近 NSColor.windowBackgroundColor 的浅色解析值），纯平、无渐变。
color(246, 246, 248).setFill()
bounds.fill()

// 图标中心（与 .DS_Store 的 Iloc 对应）：应用在左、Applications 在右，垂直居中。
// Iloc 自上而下计数，y=200 即窗口竖直中线；图标尺寸 128，半宽 64。
let iconCenterY = size.height / 2            // 200
let appCenterX: CGFloat = 170
let applicationsCenterX: CGFloat = 430
let iconHalf: CGFloat = 64

// 标准拖拽箭头：从应用图标右缘指向 Applications 左缘，居中、系统灰、细圆头。
let arrowStartX = appCenterX + iconHalf + 14          // 248
let arrowEndX = applicationsCenterX - iconHalf - 14   // 352
let arrowY = iconCenterY + 8                            // 略高于图标几何中心，对齐图标视觉重心
let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowEndX, y: arrowY))
arrowPath.move(to: NSPoint(x: arrowEndX - 15, y: arrowY + 11))
arrowPath.line(to: NSPoint(x: arrowEndX, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowEndX - 15, y: arrowY - 11))
color(142, 142, 147).setStroke()   // systemGray
arrowPath.lineWidth = 3
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.stroke()

// 一行克制的系统级说明（次级标签灰），不重复图标名称、不做营销文案。
drawText(
    "将应用拖到 Applications 文件夹以安装",
    in: NSRect(x: 0, y: 70, width: size.width, height: 20),
    size: 13,
    weight: .regular,
    color: color(110, 110, 115)
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render DMG background.")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL, options: .atomic)
