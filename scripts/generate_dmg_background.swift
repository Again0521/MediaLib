import AppKit
import Foundation

let canvasSize = NSSize(width: 600, height: 400)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
  NSColor(
    calibratedRed: red / 255.0,
    green: green / 255.0,
    blue: blue / 255.0,
    alpha: alpha
  )
}

func centeredParagraph(_ alignment: NSTextAlignment = .center) -> NSMutableParagraphStyle {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = alignment
  paragraph.lineBreakMode = .byTruncatingTail
  return paragraph
}

func drawCenteredText(
  _ text: String,
  y: CGFloat,
  font: NSFont,
  foreground: NSColor,
  width: CGFloat = canvasSize.width
) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: foreground,
    .paragraphStyle: centeredParagraph()
  ]
  let rect = NSRect(x: (canvasSize.width - width) / 2.0, y: y, width: width, height: font.pointSize + 8.0)
  text.draw(in: rect, withAttributes: attributes)
}

func drawArrow(from start: NSPoint, to end: NSPoint) {
  let line = NSBezierPath()
  line.move(to: start)
  line.line(to: end)
  line.lineWidth = 2.0
  line.lineCapStyle = .round
  color(142, 142, 147, 0.82).setStroke()
  line.stroke()

  let arrowHead = NSBezierPath()
  arrowHead.move(to: end)
  arrowHead.line(to: NSPoint(x: end.x - 13, y: end.y + 8))
  arrowHead.move(to: end)
  arrowHead.line(to: NSPoint(x: end.x - 13, y: end.y - 8))
  arrowHead.lineWidth = 2.0
  arrowHead.lineCapStyle = .round
  color(142, 142, 147, 0.82).setStroke()
  arrowHead.stroke()
}

guard CommandLine.arguments.count == 2 else {
  fputs("usage: generate_dmg_background.swift <output-png>\n", stderr)
  exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: canvasSize)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: canvasSize)
NSGradient(colors: [
  color(250, 250, 252),
  color(245, 246, 248)
])?.draw(in: bounds, angle: -90)

drawCenteredText(
  "MediaLIB",
  y: 316,
  font: NSFont.systemFont(ofSize: 24, weight: .semibold),
  foreground: color(28, 28, 30)
)

drawCenteredText(
  "拖动到 Applications 文件夹完成安装",
  y: 286,
  font: NSFont.systemFont(ofSize: 14, weight: .regular),
  foreground: color(99, 99, 102)
)

drawArrow(from: NSPoint(x: 250, y: 202), to: NSPoint(x: 350, y: 202))

image.unlockFocus()

try FileManager.default.createDirectory(
  at: outputURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)

guard
  let tiffData = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiffData),
  let pngData = bitmap.representation(using: .png, properties: [:])
else {
  fputs("failed to render png\n", stderr)
  exit(1)
}

try pngData.write(to: outputURL)
