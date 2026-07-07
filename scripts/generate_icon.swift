import AppKit
import Foundation

// MediaLIB 应用图标生成器。
// 从用户提供的源图 Resources/AppIconSource.(png|webp|jpg) 渲染出
// AppIcon.png / AppIconDark.png / iconset / AppIcon.icns。
// 不再程序化绘制图标；如需更换图标，替换源图后重新运行即可。

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/MediaLib/Resources", isDirectory: true)
let output = root.appendingPathComponent("dist/icons", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resources.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func loadSourceImage() throws -> NSImage {
    let candidates = ["AppIconSource.png", "AppIconSource.webp", "AppIconSource.jpg", "AppIconSource.jpeg"]
    for name in candidates {
        let url = resources.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) {
            return image
        }
    }
    throw NSError(
        domain: "MediaLib.Icon",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "未找到图标源图，请在 Sources/MediaLib/Resources 放置 AppIconSource.png"]
    )
}

let sourceImage = try loadSourceImage()
let sourceCropInsetFraction: CGFloat = 0.076

func renderedBitmap(size: Int, darkAdapted: Bool) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "MediaLib.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate icon bitmap"])
    }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    // 源图保留了少量展示留白。导出应用图标时裁掉外圈白色画布，
    // 保持原图主体设计不变，同时避免 Dock/启动台里出现额外白边。
    let cropInset = min(sourceImage.size.width, sourceImage.size.height) * sourceCropInsetFraction
    let sourceRect = NSRect(
        x: cropInset,
        y: cropInset,
        width: sourceImage.size.width - cropInset * 2,
        height: sourceImage.size.height - cropInset * 2
    )
    sourceImage.draw(
        in: canvas,
        from: sourceRect,
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    if darkAdapted {
        // 深色外观下轻微压暗，避免纯白磁贴在深色 Dock 上过曝。
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.10, alpha: 0.06).setFill()
        canvas.fill(using: .sourceOver)
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func pngData(size: Int, darkAdapted: Bool = false) throws -> Data {
    let bitmap = try renderedBitmap(size: size, darkAdapted: darkAdapted)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MediaLib.Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode icon PNG"])
    }
    return data
}

func writePNG(size: Int, to url: URL, darkAdapted: Bool = false) throws {
    try pngData(size: size, darkAdapted: darkAdapted).write(to: url, options: .atomic)
}

func fourCC(_ value: String) -> Data {
    Data(value.utf8)
}

func bigEndianUInt32(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

func writeICNS(entries: [(type: String, png: Data)], to url: URL) throws {
    var payload = Data()
    for entry in entries {
        payload.append(fourCC(entry.type))
        payload.append(bigEndianUInt32(UInt32(entry.png.count + 8)))
        payload.append(entry.png)
    }

    var data = Data()
    data.append(fourCC("icns"))
    data.append(bigEndianUInt32(UInt32(payload.count + 8)))
    data.append(payload)
    try data.write(to: url, options: .atomic)
}

let exportedSizes = [16, 32, 64, 128, 256, 512, 1024]
for size in exportedSizes {
    try writePNG(size: size, to: output.appendingPathComponent("AppIcon-\(size).png"))
    try writePNG(size: size, to: output.appendingPathComponent("AppIconDark-\(size).png"), darkAdapted: true)
}

try writePNG(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))
try writePNG(size: 1024, to: resources.appendingPathComponent("AppIconDark.png"), darkAdapted: true)

let iconsetEntries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in iconsetEntries {
    try writePNG(size: entry.1, to: iconset.appendingPathComponent(entry.0))
}

let icnsEntries: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]
try writeICNS(entries: icnsEntries.map { (type: $0.0, png: try pngData(size: $0.1)) }, to: icnsURL)

print("Generated MediaLIB app icon from source image at \(resources.appendingPathComponent("AppIconSource.png").path)")
