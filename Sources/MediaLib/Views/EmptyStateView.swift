import SwiftUI

struct EmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    let message: String

    /// 空态出现时的柔和入场（淡入 + 轻上浮）：空态往往在数据刷新后瞬间顶替内容，
    /// 内建入场让所有页面的空态都不再硬弹出；Reduce Motion 时直接呈现终态。
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.12 : 0.64),
                                AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.14 : 0.20),
                                AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.08 : 0.16),
                                .clear
                            ],
                            center: UnitPoint(x: 0.36, y: 0.28),
                            startRadius: 2,
                            endRadius: 50
                        )
                    )
                    .frame(width: 104, height: 104)
                    .blur(radius: 2)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.40 : 0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(colorScheme == .dark ? 0.22 : 0.74),
                                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.10 : 0.20),
                                        AppColors.cleanPanelBorder.opacity(0.44)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .frame(width: 76, height: 76)

                AppGlyph(systemImage: systemImage, size: 46, lineWidth: 2.2)
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
            }
            .frame(width: 112, height: 104)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .lineSpacing(3)
                .frame(maxWidth: AppCardMetrics.emptyStateTextWidth)
        }
        .frame(maxWidth: .infinity, minHeight: AppCardMetrics.emptyStateMinimumHeight)
        .padding(32)
        .accessibilityElement(children: .combine)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .onAppear {
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(AppMotion.standard) { hasAppeared = true }
            }
        }
    }
}

struct AppLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let title: String
    let systemImage: String
    var rowCount = 5

    @State private var shimmerX: CGFloat = -0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppGlyph(systemImage: systemImage, size: 32)
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.9))
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text("正在准备当前页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 10) {
                ForEach(0..<rowCount, id: \.self) { index in
                    skeletonRow(index: index)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        .staticSurfaceBackground(cornerRadius: 22)
        .onAppear {
            updateShimmer()
        }
        .onChange(of: reduceMotion) { _ in
            updateShimmer()
        }
        .onChange(of: scenePhase) { _ in
            updateShimmer()
        }
    }

    private func skeletonRow(index: Int) -> some View {
        HStack(spacing: 12) {
            shimmerBlock(width: 52, height: 52, radius: 8)
            VStack(alignment: .leading, spacing: 7) {
                shimmerBlock(width: CGFloat(180 + index * 18), height: 10, radius: 4)
                shimmerBlock(width: CGFloat(120 + index * 11), height: 8, radius: 4)
                    .opacity(0.72)
            }
            Spacer()
        }
        .padding(10)
        .staticSurfaceBackground(cornerRadius: 14, thickness: 0.86)
    }

    private func shimmerBlock(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AppColors.cleanFieldFill)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.52), .clear],
                            startPoint: UnitPoint(x: shimmerX - 0.4, y: 0.5),
                            endPoint: UnitPoint(x: shimmerX + 0.4, y: 0.5)
                        )
                    )
            }
            .frame(width: width, height: height)
    }

    private func updateShimmer() {
        guard !reduceMotion, scenePhase == .active else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shimmerX = 0.28
            }
            return
        }
        shimmerX = -0.4
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerX = 1.4
        }
    }
}
