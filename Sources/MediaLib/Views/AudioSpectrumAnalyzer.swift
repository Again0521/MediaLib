import AVFoundation
import CoreGraphics
import Foundation

// 从 PlayerView.swift 物理拆出（零行为变化）：音乐展开页频谱柱的离线 PCM 解码 + 频段归一化。
// 自包含，仅依赖 AVFoundation / CoreMedia / Foundation；原为 PlayerView.swift 内的 private enum，
// 拆出后改为模块内部可见（enum，无显式修饰符）以便 MpvPlayerController 继续引用；
// prefixBands 仅本分析器使用，保持文件私有。
enum AudioSpectrumAnalyzer {
    static let silenceBands: [CGFloat] = [0.18, 0.24, 0.20, 0.26, 0.21]

    static func bands(filePath: String, time: Double, bandCount: Int) async -> [CGFloat] {
        guard bandCount > 0 else { return [] }
        let url = URL(fileURLWithPath: filePath)
        guard url.isFileURL else { return silenceBands.prefixBands(bandCount) }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return silenceBands.prefixBands(bandCount)
        }

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
        guard reader.canAdd(output) else { return silenceBands.prefixBands(bandCount) }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(time, 0), preferredTimescale: 600),
            duration: CMTime(seconds: 0.16, preferredTimescale: 600)
        )
        guard reader.startReading() else { return silenceBands.prefixBands(bandCount) }

        var samples: [Float] = []
        samples.reserveCapacity(4096)
        while let sampleBuffer = output.copyNextSampleBuffer(), samples.count < 4096 {
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
            samples.append(contentsOf: floats.prefix(max(0, 4096 - samples.count)))
        }
        reader.cancelReading()

        return normalizedFrequencyBands(from: samples, bandCount: bandCount)
    }

    private static func normalizedFrequencyBands(from rawSamples: [Float], bandCount: Int) -> [CGFloat] {
        guard rawSamples.count >= 64 else { return silenceBands.prefixBands(bandCount) }
        let sampleCount = min(1024, rawSamples.count)
        let step = max(rawSamples.count / sampleCount, 1)
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        var index = 0
        while index < rawSamples.count, samples.count < sampleCount {
            let value = Double(rawSamples[index])
            if value.isFinite {
                samples.append(min(max(value, -1), 1))
            }
            index += step
        }
        guard samples.count >= 64 else { return silenceBands.prefixBands(bandCount) }

        let mean = samples.reduce(0, +) / Double(samples.count)
        for index in samples.indices {
            let window = 0.5 - 0.5 * cos((2 * .pi * Double(index)) / Double(max(samples.count - 1, 1)))
            samples[index] = (samples[index] - mean) * window
        }

        let maxBin = max(min(samples.count / 2 - 1, 96), bandCount)
        let ranges = frequencyRanges(maxBin: maxBin, bandCount: bandCount)
        let magnitudes = ranges.map { range in
            var total = 0.0
            var count = 0
            for bin in range.lowerBound...range.upperBound {
                let angleBase = -2.0 * .pi * Double(bin) / Double(samples.count)
                var real = 0.0
                var imaginary = 0.0
                for (sampleIndex, sample) in samples.enumerated() {
                    let angle = angleBase * Double(sampleIndex)
                    real += sample * cos(angle)
                    imaginary += sample * sin(angle)
                }
                total += sqrt(real * real + imaginary * imaginary)
                count += 1
            }
            return count > 0 ? total / Double(count) : 0
        }

        let peak = max(magnitudes.max() ?? 0, 0.000_001)
        let values = magnitudes.map { magnitude -> CGFloat in
            let normalized = min(max(sqrt(magnitude / peak), 0), 1)
            return CGFloat(0.16 + normalized * 0.84)
        }
        return values.isEmpty ? silenceBands.prefixBands(bandCount) : values
    }

    private static func frequencyRanges(maxBin: Int, bandCount: Int) -> [ClosedRange<Int>] {
        guard bandCount > 0 else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var lower = 1
        for index in 0..<bandCount {
            let fraction = pow(Double(index + 1) / Double(bandCount), 1.55)
            let upper = max(lower, min(maxBin, Int((Double(maxBin) * fraction).rounded())))
            ranges.append(lower...upper)
            lower = min(upper + 1, maxBin)
        }
        return ranges
    }
}

private extension Array where Element == CGFloat {
    func prefixBands(_ count: Int) -> [CGFloat] {
        if self.count == count { return self }
        if self.count > count { return Array(prefix(count)) }
        return self + Array(repeating: last ?? 0.2, count: count - self.count)
    }
}
