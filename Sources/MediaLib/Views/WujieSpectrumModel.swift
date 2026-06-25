import Combine
import SwiftUI

// 从 MusicPlayerView.swift 物理拆出（逐字节原样搬运，零行为/零视觉变化）：无界主题频谱柱的数据/动画模型。
// 订阅 MpvPlayerController 的频谱与播放态，按真实经过时间推进峰值保持动画，并把柱体/白帽/倒影绘入
// 由视图传入的 Canvas GraphicsContext（绘制代码原样保留，未改任何渐变/不透明度/尺寸参数）。
// 原为 MusicPlayerView.swift 内的 private 类型（紧邻 @MainActor），拆出后改为模块内部可见并保留 @MainActor。
@MainActor
final class WujieSpectrumModel: ObservableObject {
    private weak var controller: MpvPlayerController?
    private let barCount = 46
    private var colorH: [CGFloat]
    private var whiteH: [CGFloat]
    private var lastDate: Date?
    private let noise: [CGFloat]
    private var latestBands: [CGFloat]
    private var latestIsPlaying: Bool
    private var cancellable: AnyCancellable?

    init(controller: MpvPlayerController) {
        colorH = Array(repeating: 0, count: barCount)
        whiteH = Array(repeating: 0, count: barCount)
        latestBands = controller.audioSpectrumBands
        latestIsPlaying = controller.isPlaying
        noise = (0..<barCount).map { i in
            let v = sin(Double(i) * 12.9898) * 43758.5453
            return CGFloat(0.72 + 0.28 * (v - floor(v)))
        }
        attach(controller: controller)
    }

    func attach(controller: MpvPlayerController) {
        if let current = self.controller, current === controller { return }
        self.controller = controller
        latestBands = controller.audioSpectrumBands
        latestIsPlaying = controller.isPlaying
        cancellable = Publishers.CombineLatest(
            controller.$audioSpectrumBands,
            controller.$isPlaying
        ).sink { [weak self] bands, isPlaying in
            self?.latestBands = bands
            self?.latestIsPlaying = isPlaying
        }
    }

    /// 按真实经过时间推进峰值保持动画（与帧率无关）。
    func advance(to date: Date) {
        let dt = min(lastDate.map { date.timeIntervalSince($0) } ?? 1.0 / 60.0, 0.1)
        lastDate = date
        let isPlaying = latestIsPlaying
        let playFactor: CGFloat = isPlaying ? 1.0 : 0.16
        let rawTargets = Self.interpolate(bands: latestBands, count: barCount, noise: noise)
        let energy = max(rawTargets.reduce(0, +) / CGFloat(max(rawTargets.count, 1)), 0.04)
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 5.1)

        let colorUpRate: CGFloat = 11.0   // 主色上升（随后填充，略慢于白帽）
        let colorDownRate: CGFloat = 8.5  // 主色下落（快）
        let whiteDecayRate: CGFloat = 0.85 // 白帽回落（慢，单位/秒）

        for i in 0..<barCount {
            // 真实采样约 0.34s 更新一次；在采样之间加很轻的相位摆动，让峰值保持能继续“呼吸”，
            // 但振幅仍由当前音频能量决定。
            let ripple = isPlaying ? (1 + sin(phase + CGFloat(i) * 0.62) * energy * 0.16) : 1
            let floorLift = isPlaying ? energy * noise[i] * 0.018 : 0
            let target = min(max(rawTargets[i] * 1.14 * playFactor * ripple + floorLift, 0), 1)
            let cRate = target > colorH[i] ? colorUpRate : colorDownRate
            colorH[i] += (target - colorH[i]) * min(cRate * CGFloat(dt), 1)
            if colorH[i] < 0.0008 { colorH[i] = 0 }

            if target > whiteH[i] {
                whiteH[i] = target              // 上升：白帽瞬间领先到峰值
            } else {
                whiteH[i] = max(whiteH[i] - whiteDecayRate * CGFloat(dt), colorH[i])
            }
        }
    }

    func draw(into context: inout GraphicsContext, size: CGSize, tint: Color, baselineFromTop: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        let baselineY = size.height * baselineFromTop
        let upZone = baselineY
        let reflZone = size.height - baselineY
        let spacing: CGFloat = 3
        let barW = max((size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount), 1.2)

        for i in 0..<barCount {
            let x = CGFloat(i) * (barW + spacing)
            let edge = Self.edgeFade(i, barCount)
            guard edge > 0.001 else { continue }
            let cH = colorH[i] * upZone
            let wH = max(whiteH[i] * upZone, cH)

            // —— 柱体（主题色，减淡）：从基线向上；顶端随渐变淡出（接近顶部更透明）——
            if cH > 0.5 {
                let rect = CGRect(x: x, y: baselineY - cH, width: barW, height: cH)
                let path = Path(roundedRect: rect, cornerRadius: min(barW / 2, cH / 2))
                let grad = Gradient(stops: [
                    .init(color: tint.opacity(0.60 * edge), location: 0.0),
                    .init(color: tint.opacity(0.42 * edge), location: 0.55),
                    .init(color: tint.opacity(0.0), location: 1.0)
                ])
                context.fill(path, with: .linearGradient(grad,
                    startPoint: CGPoint(x: x, y: baselineY),
                    endPoint: CGPoint(x: x, y: baselineY - upZone)))
            }

            // —— 白色峰帽：位于 [cH, wH] 段；同样向顶部淡出 ——
            if wH - cH > 0.5 {
                let rect = CGRect(x: x, y: baselineY - wH, width: barW, height: wH - cH)
                let path = Path(roundedRect: rect, cornerRadius: min(barW / 2, (wH - cH) / 2))
                let grad = Gradient(stops: [
                    .init(color: Color.white.opacity(0.92 * edge), location: 0.0),
                    .init(color: Color.white.opacity(0.66 * edge), location: 0.6),
                    .init(color: Color.white.opacity(0.0), location: 1.0)
                ])
                context.fill(path, with: .linearGradient(grad,
                    startPoint: CGPoint(x: x, y: baselineY),
                    endPoint: CGPoint(x: x, y: baselineY - upZone)))
            }

            // —— 倒影：基线下方镜像，整体更淡，并向下羽化消失 ——
            if reflZone > 2, cH > 0.5 {
                let reflH = min(cH * 0.82, reflZone)
                let rect = CGRect(x: x, y: baselineY, width: barW, height: reflH)
                let path = Path(roundedRect: rect, cornerRadius: min(barW / 2, reflH / 2))
                let grad = Gradient(stops: [
                    .init(color: tint.opacity(0.24 * edge), location: 0.0),
                    .init(color: tint.opacity(0.075 * edge), location: 0.55),
                    .init(color: tint.opacity(0.0), location: 1.0)
                ])
                context.fill(path, with: .linearGradient(grad,
                    startPoint: CGPoint(x: x, y: baselineY),
                    endPoint: CGPoint(x: x, y: baselineY + reflZone)))
            }
        }
    }

    /// 5 段频谱 → N 条：镜像成中心对称剖面后线性插值，叠加确定性微噪声做声波纹理。
    private static func interpolate(bands: [CGFloat], count: Int, noise: [CGFloat]) -> [CGFloat] {
        let src = bands.isEmpty ? [0.15] : bands.map { min(max($0, 0), 1) }
        let profile: [CGFloat] = src.count > 1 ? src + src.dropLast().reversed() : src
        let n = profile.count
        guard n > 1 else { return Array(repeating: src.first ?? 0.15, count: count) }
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(max(count - 1, 1)) * CGFloat(n - 1)
            let lo = Int(floor(t))
            let hi = min(lo + 1, n - 1)
            let frac = t - CGFloat(lo)
            let value = profile[lo] * (1 - frac) + profile[hi] * frac
            return min(max(value * (i < noise.count ? noise[i] : 1), 0.03), 1)
        }
    }

    /// 两端羽化：左右各约 14% 的条逐渐变淡。
    private static func edgeFade(_ index: Int, _ count: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        let t = CGFloat(index) / CGFloat(count - 1)
        let edge: CGFloat = 0.14
        if t < edge { return smoothstep(t / edge) }
        if t > 1 - edge { return smoothstep((1 - t) / edge) }
        return 1
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let c = min(max(value, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
