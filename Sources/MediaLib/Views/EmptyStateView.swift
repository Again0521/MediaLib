import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            PlayfulSymbolIcon(systemImage: systemImage, size: 48)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

struct AppLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let systemImage: String
    var rowCount = 5

    @State private var shimmerX: CGFloat = -0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: systemImage, size: 38)
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
            guard !reduceMotion else {
                shimmerX = 0.28
                return
            }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerX = 1.4
            }
        }
        .onChange(of: reduceMotion) { reduced in
            shimmerX = reduced ? 0.28 : -0.4
            guard !reduced else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerX = 1.4
            }
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
}
