import AppKit
import AVFoundation
import Foundation

public final class ThumbnailGenerator {
    private let outputDirectory: URL
    private let logger: LoggingService?

    public var outputDirectoryURL: URL {
        outputDirectory
    }

    public init(outputDirectory: URL, logger: LoggingService? = nil) {
        self.outputDirectory = outputDirectory
        self.logger = logger
    }

    public func generateThumbnail(
        for videoURL: URL,
        mediaID: String,
        ratio: Double,
        avoidBlackFrames: Bool
    ) async -> URL? {
        let ratios = avoidBlackFrames ? [ratio, 0.15, 0.2, 0.3] : [ratio]
        for candidateRatio in ratios {
            if let url = await capture(videoURL: videoURL, mediaID: mediaID, ratio: candidateRatio, avoidBlackFrames: avoidBlackFrames) {
                return url
            }
            if let url = await captureWithFFmpeg(videoURL: videoURL, mediaID: mediaID, ratio: candidateRatio, avoidBlackFrames: avoidBlackFrames) {
                return url
            }
        }
        return nil
    }

    public func generateDefaultArtwork(
        mediaID: String,
        title: String,
        mediaType: MediaType,
        aspectRatio: Double?
    ) async -> URL? {
        await MainActor.run {
            let outputURL = outputDirectory.appendingPathComponent("\(mediaID)-default.jpg")
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let image = Self.defaultArtworkImage(title: title, mediaType: mediaType, aspectRatio: aspectRatio)
                try writeJPEG(image: image, to: outputURL, compression: 0.86)
                return outputURL
            } catch {
                logger?.log("默认封面生成失败：\(title) \(error.localizedDescription)", level: .warning)
                return nil
            }
        }
    }

    public func mediaInfo(for videoURL: URL) async -> (duration: Double?, resolution: String?) {
        let asset = AVURLAsset(url: videoURL)
        let duration = try? await asset.load(.duration)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let size: CGSize?
        if let track = tracks?.first,
           let naturalSize = try? await track.load(.naturalSize) {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformedSize = naturalSize.applying(transform)
            size = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        } else {
            size = nil
        }
        let seconds = duration.map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil }
        let resolution = size.map { "\(Int(abs($0.width)))x\(Int(abs($0.height)))" }
        return (seconds, resolution)
    }

    private func capture(videoURL: URL, mediaID: String, ratio: Double, avoidBlackFrames: Bool) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = max(CMTimeGetSeconds(duration) * max(0.01, min(ratio, 0.95)), 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 1350)

        do {
            let cgImage = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            if avoidBlackFrames && Self.isLikelyBlackFrame(cgImage) {
                return nil
            }
            let outputURL = outputDirectory.appendingPathComponent("\(mediaID).jpg")
            try writeJPEG(cgImage: cgImage, to: outputURL, compression: 0.78)
            return outputURL
        } catch {
            logger?.log("视频截图失败：\(videoURL.path) \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    private func captureWithFFmpeg(videoURL: URL, mediaID: String, ratio: Double, avoidBlackFrames: Bool) async -> URL? {
        await Task.detached(priority: .utility) { [outputDirectory, logger] in
            guard let ffmpegURL = Self.ffmpegExecutableURL() else {
                logger?.log("ffmpeg 不可用，无法为 AVFoundation 不支持的视频生成截图：\(videoURL.path)", level: .warning)
                return nil
            }

            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            } catch {
                logger?.log("创建缩略图目录失败：\(error.localizedDescription)", level: .warning)
                return nil
            }

            let outputURL = outputDirectory.appendingPathComponent("\(mediaID).jpg")
            try? FileManager.default.removeItem(at: outputURL)

            let seekSeconds = max(1, min(240, ratio * 900))
            let seekArguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-ss", String(format: "%.3f", seekSeconds),
                "-i", videoURL.path,
                "-frames:v", "1",
                "-vf", "scale=900:-2:force_original_aspect_ratio=decrease",
                "-q:v", "3",
                outputURL.path
            ]
            if Self.runFFmpeg(ffmpegURL: ffmpegURL, arguments: seekArguments, timeout: 30),
               Self.validateGeneratedFrame(outputURL, avoidBlackFrames: avoidBlackFrames) {
                return outputURL
            }

            try? FileManager.default.removeItem(at: outputURL)
            let representativeFrameArguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", videoURL.path,
                "-vf", "thumbnail,scale=900:-2:force_original_aspect_ratio=decrease",
                "-frames:v", "1",
                "-q:v", "3",
                outputURL.path
            ]
            if Self.runFFmpeg(ffmpegURL: ffmpegURL, arguments: representativeFrameArguments, timeout: 45),
               Self.validateGeneratedFrame(outputURL, avoidBlackFrames: avoidBlackFrames) {
                return outputURL
            }

            try? FileManager.default.removeItem(at: outputURL)
            logger?.log("ffmpeg 视频截图失败：\(videoURL.path)", level: .warning)
            return nil
        }.value
    }

    private func writeJPEG(cgImage: CGImage, to url: URL, compression: CGFloat) throws {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeJPEG(image: NSImage, to url: URL, compression: CGFloat) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private static func ffmpegExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(ffmpegURL: URL, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        // Semaphore 让线程真正阻塞，取代原来每 50ms 轮询一次的忙等。
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            process.waitUntilExit()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func validateGeneratedFrame(_ url: URL, avoidBlackFrames: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        if avoidBlackFrames && isLikelyBlackFrame(cgImage) {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func defaultArtworkImage(title: String, mediaType: MediaType, aspectRatio: Double?) -> NSImage {
        if mediaType == .music {
            return defaultMusicArtworkImage(title: title)
        }

        let ratio = CGFloat(min(max(aspectRatio ?? 16.0 / 9.0, 0.68), 1.78))
        let size: NSSize
        if ratio >= 1 {
            size = NSSize(width: 1280, height: 1280 / ratio)
        } else {
            size = NSSize(width: 920 * ratio / (2.0 / 3.0), height: 1380)
        }

        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: size)
        let cornerRadius = min(size.width, size.height) * 0.065
        let basePath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        basePath.addClip()

        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.21, blue: 0.55, alpha: 1),
            NSColor(calibratedRed: 0.34, green: 0.18, blue: 0.72, alpha: 1),
            NSColor(calibratedRed: 0.06, green: 0.56, blue: 0.82, alpha: 1)
        ])?.draw(in: bounds, angle: -34)

        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: -size.width * 0.18, y: size.height * 0.48, width: size.width * 0.55, height: size.height * 0.68)).fill()
        NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.62, alpha: 0.24).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.55, y: -size.height * 0.08, width: size.width * 0.55, height: size.height * 0.55)).fill()

        let cardRect = bounds.insetBy(dx: size.width * 0.105, dy: size.height * 0.16)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius * 0.72, yRadius: cornerRadius * 0.72)
        NSColor.white.withAlphaComponent(0.74).setFill()
        card.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        card.lineWidth = max(2, min(size.width, size.height) * 0.006)
        card.stroke()

        let stripeWidth = max(18, cardRect.width * 0.055)
        for side in [cardRect.minX + cardRect.width * 0.065, cardRect.maxX - cardRect.width * 0.065 - stripeWidth] {
            for index in 0..<4 {
                let holeSize = min(stripeWidth, cardRect.height * 0.105)
                let y = cardRect.minY + cardRect.height * (0.21 + CGFloat(index) * 0.18)
                let hole = NSBezierPath(roundedRect: NSRect(x: side, y: y, width: stripeWidth, height: holeSize), xRadius: holeSize * 0.28, yRadius: holeSize * 0.28)
                NSColor(calibratedRed: 0.38, green: 0.44, blue: 0.72, alpha: 0.28).setFill()
                hole.fill()
            }
        }

        let playWidth = min(cardRect.width, cardRect.height) * 0.28
        let playRect = NSRect(x: cardRect.midX - playWidth * 0.42, y: cardRect.midY - playWidth * 0.5, width: playWidth, height: playWidth)
        let play = NSBezierPath()
        play.move(to: NSPoint(x: playRect.minX, y: playRect.minY))
        play.line(to: NSPoint(x: playRect.maxX, y: playRect.midY))
        play.line(to: NSPoint(x: playRect.minX, y: playRect.maxY))
        play.close()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.50, blue: 1.0, alpha: 0.92),
            NSColor(calibratedRed: 0.72, green: 0.36, blue: 1.0, alpha: 0.86)
        ])?.draw(in: play, angle: 0)

        let badgeText = mediaType.displayName
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(22, size.height * 0.038), weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let badgeRect = NSRect(x: bounds.minX + size.width * 0.08, y: bounds.maxY - size.height * 0.13, width: size.width * 0.42, height: size.height * 0.06)
        badgeText.draw(in: badgeRect, withAttributes: badgeAttributes)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(30, min(size.width, size.height) * 0.066), weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            .paragraphStyle: paragraph
        ]
        let titleRect = NSRect(x: size.width * 0.08, y: size.height * 0.055, width: size.width * 0.84, height: size.height * 0.12)
        title.draw(in: titleRect, withAttributes: titleAttributes)

        return image
    }

    private static func defaultMusicArtworkImage(title: String) -> NSImage {
        let size = NSSize(width: 1100, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: size)
        let cornerRadius = size.width * 0.075
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()

        NSGradient(colors: [
            NSColor(calibratedRed: 0.05, green: 0.33, blue: 0.92, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.66, blue: 0.96, alpha: 1),
            NSColor(calibratedRed: 0.06, green: 0.78, blue: 0.70, alpha: 1)
        ])?.draw(in: bounds, angle: -38)

        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: -size.width * 0.20, y: size.height * 0.54, width: size.width * 0.62, height: size.height * 0.62)).fill()
        NSColor(calibratedRed: 0.65, green: 0.92, blue: 1.0, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.56, y: -size.height * 0.10, width: size.width * 0.56, height: size.height * 0.56)).fill()

        let symbolRect = bounds.insetBy(dx: size.width * 0.20, dy: size.height * 0.19)
        let symbolPath = NSBezierPath(roundedRect: symbolRect, xRadius: size.width * 0.075, yRadius: size.width * 0.075)
        NSColor.white.withAlphaComponent(0.20).setFill()
        symbolPath.fill()
        NSColor.white.withAlphaComponent(0.38).setStroke()
        symbolPath.lineWidth = size.width * 0.006
        symbolPath.stroke()

        let ringRect = NSRect(x: symbolRect.midX - size.width * 0.21, y: symbolRect.midY - size.width * 0.19, width: size.width * 0.38, height: size.width * 0.38)
        let ring = NSBezierPath(ovalIn: ringRect)
        NSColor.white.withAlphaComponent(0.32).setStroke()
        ring.lineWidth = size.width * 0.018
        ring.stroke()
        NSColor.white.withAlphaComponent(0.34).setFill()
        NSBezierPath(ovalIn: NSRect(x: ringRect.midX - size.width * 0.042, y: ringRect.midY - size.width * 0.042, width: size.width * 0.084, height: size.width * 0.084)).fill()

        let noteColor = NSColor.white.withAlphaComponent(0.88)
        noteColor.setFill()
        let noteHead = NSBezierPath(ovalIn: NSRect(x: symbolRect.midX - size.width * 0.12, y: symbolRect.midY - size.width * 0.18, width: size.width * 0.17, height: size.width * 0.13))
        noteHead.fill()
        let stem = NSBezierPath(roundedRect: NSRect(x: symbolRect.midX + size.width * 0.035, y: symbolRect.midY - size.width * 0.10, width: size.width * 0.035, height: size.width * 0.34), xRadius: size.width * 0.016, yRadius: size.width * 0.016)
        stem.fill()
        let flag = NSBezierPath()
        flag.move(to: NSPoint(x: symbolRect.midX + size.width * 0.062, y: symbolRect.midY + size.width * 0.235))
        flag.curve(
            to: NSPoint(x: symbolRect.midX + size.width * 0.235, y: symbolRect.midY + size.width * 0.105),
            controlPoint1: NSPoint(x: symbolRect.midX + size.width * 0.17, y: symbolRect.midY + size.width * 0.24),
            controlPoint2: NSPoint(x: symbolRect.midX + size.width * 0.24, y: symbolRect.midY + size.width * 0.18)
        )
        flag.line(to: NSPoint(x: symbolRect.midX + size.width * 0.235, y: symbolRect.midY + size.width * 0.045))
        flag.curve(
            to: NSPoint(x: symbolRect.midX + size.width * 0.070, y: symbolRect.midY + size.width * 0.160),
            controlPoint1: NSPoint(x: symbolRect.midX + size.width * 0.17, y: symbolRect.midY + size.width * 0.105),
            controlPoint2: NSPoint(x: symbolRect.midX + size.width * 0.11, y: symbolRect.midY + size.width * 0.13)
        )
        flag.close()
        flag.fill()

        let barBaseX = symbolRect.minX + size.width * 0.075
        let barBaseY = symbolRect.minY + size.height * 0.135
        let barWidth = size.width * 0.022
        for (index, heightFactor) in [0.34, 0.54, 0.42, 0.66, 0.38].enumerated() {
            let height = size.height * CGFloat(heightFactor) * 0.18
            let barRect = NSRect(
                x: barBaseX + CGFloat(index) * size.width * 0.044,
                y: barBaseY,
                width: barWidth,
                height: height
            )
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5)
            NSColor.white.withAlphaComponent(index == 3 ? 0.70 : 0.48).setFill()
            barPath.fill()
        }

        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.height * 0.040, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        "音乐".draw(in: NSRect(x: bounds.minX + size.width * 0.085, y: bounds.maxY - size.height * 0.128, width: size.width * 0.28, height: size.height * 0.06), withAttributes: badgeAttributes)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.061, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            .paragraphStyle: paragraph
        ]
        title.draw(in: NSRect(x: size.width * 0.10, y: size.height * 0.070, width: size.width * 0.80, height: size.height * 0.13), withAttributes: titleAttributes)

        return image
    }

    private static func isLikelyBlackFrame(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let sampleCount = min(800, image.width * image.height)
        guard sampleCount > 0 else { return false }

        var darkSamples = 0
        for i in 0..<sampleCount {
            let x = (i * 37) % image.width
            let y = (i * 53) % image.height
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            let r = Int(bytes[offset])
            let g = bytesPerPixel > 1 ? Int(bytes[offset + 1]) : r
            let b = bytesPerPixel > 2 ? Int(bytes[offset + 2]) : r
            if (r + g + b) / 3 < 16 {
                darkSamples += 1
            }
        }
        return Double(darkSamples) / Double(sampleCount) > 0.88
    }
}
