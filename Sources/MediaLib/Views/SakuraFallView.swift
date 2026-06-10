import SwiftUI

/// 轻量樱花动效：花瓣从屏幕上方缓缓飘落到下方，整体持续约 5 秒后淡出消失。
/// 使用 TimelineView(.animation) + Canvas 驱动，按显示器刷新率绘制（高帧率、低开销），
/// 不拦截点击，覆盖整窗。
struct SakuraFallView: View {
    var duration: Double = 5

    @State private var startDate = Date()
    private let petals: [SakuraPetal]

    init(duration: Double = 5, petalCount: Int = 90) {
        self.duration = duration
        var generator = SystemRandomNumberGenerator()
        petals = (0..<petalCount).map { _ in SakuraPetal.random(using: &generator) }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startDate)
                guard elapsed >= 0 else { return }

                // 整体淡入（前 0.4s）+ 淡出（最后 1.1s），到 duration 时完全消失。
                let fadeIn = min(elapsed / 0.4, 1)
                let fadeOut = max(0, min((duration - elapsed) / 1.1, 1))
                let globalAlpha = max(0, min(fadeIn, fadeOut))
                guard globalAlpha > 0.001 else { return }

                for petal in petals {
                    draw(petal, in: &context, size: size, elapsed: elapsed, globalAlpha: globalAlpha)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func draw(
        _ petal: SakuraPetal,
        in context: inout GraphicsContext,
        size: CGSize,
        elapsed: Double,
        globalAlpha: Double
    ) {
        let local = elapsed - petal.delay
        guard local >= 0 else { return }

        // 纵向：从屏幕上方（-margin）匀速飘落到下方（height + margin）。
        let travel = size.height + petal.size * 4
        let y = -petal.size * 2 + CGFloat(local) * petal.fallSpeed
        // 落出屏幕底部后不再绘制。
        guard y < travel else { return }

        // 横向左右摇摆。
        let sway = sin(local * petal.swayFrequency + petal.swayPhase) * petal.swayAmplitude
        let x = petal.startX * size.width + sway

        let rotation = petal.rotationPhase + local * petal.rotationSpeed

        var ctx = context
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: .radians(rotation))

        let w = petal.size
        let h = petal.size * 1.35
        let path = SakuraFallView.petalPath(width: w, height: h)
        ctx.fill(path, with: .color(petal.color.opacity(petal.opacity * globalAlpha)))
    }

    /// 单片花瓣形状：略带凹口的桃形，比纯椭圆更像樱花瓣。
    private static func petalPath(width w: CGFloat, height h: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -h / 2))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: h / 2),
            control: CGPoint(x: w / 2, y: 0)
        )
        path.addQuadCurve(
            to: CGPoint(x: 0, y: -h / 2),
            control: CGPoint(x: -w / 2, y: 0)
        )
        // 顶部小凹口
        path.move(to: CGPoint(x: -w * 0.12, y: -h / 2))
        path.addQuadCurve(
            to: CGPoint(x: w * 0.12, y: -h / 2),
            control: CGPoint(x: 0, y: -h * 0.36)
        )
        return path
    }
}

private struct SakuraPetal {
    let startX: CGFloat          // 0...1 的起始横向比例
    let size: CGFloat
    let fallSpeed: CGFloat       // 点/秒
    let delay: Double            // 起飘延迟
    let swayAmplitude: CGFloat
    let swayFrequency: Double
    let swayPhase: Double
    let rotationSpeed: Double
    let rotationPhase: Double
    let opacity: Double
    let color: Color

    static func random<G: RandomNumberGenerator>(using generator: inout G) -> SakuraPetal {
        let palette: [Color] = [
            Color(red: 1.00, green: 0.79, blue: 0.87),
            Color(red: 1.00, green: 0.71, blue: 0.81),
            Color(red: 0.99, green: 0.86, blue: 0.91),
            Color(red: 1.00, green: 0.66, blue: 0.78)
        ]
        return SakuraPetal(
            startX: CGFloat.random(in: -0.05...1.05, using: &generator),
            size: CGFloat.random(in: 9...20, using: &generator),
            fallSpeed: CGFloat.random(in: 120...230, using: &generator),
            delay: Double.random(in: 0...1.6, using: &generator),
            swayAmplitude: CGFloat.random(in: 14...40, using: &generator),
            swayFrequency: Double.random(in: 1.4...2.8, using: &generator),
            swayPhase: Double.random(in: 0...(2 * .pi), using: &generator),
            rotationSpeed: Double.random(in: -2.4...2.4, using: &generator),
            rotationPhase: Double.random(in: 0...(2 * .pi), using: &generator),
            opacity: Double.random(in: 0.75...1.0, using: &generator),
            color: palette.randomElement(using: &generator) ?? palette[0]
        )
    }
}
