import SwiftUI

/// 搜索穿透的统一状态卡。它比整页骨架更轻，适合在已有结果增量出现时提示“还在继续查”。
struct SearchProgressStatusCard: View {
    let title: String
    let subtitle: String
    var systemImage: String = "magnifyingglass"
    var cornerRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.selectedGlassTint.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.42), lineWidth: 0.8)
                    }
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.selectedGlassTint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ProgressView()
                .controlSize(.small)
                .tint(AppColors.selectedGlassTint)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: cornerRadius, thickness: 1.02)
        .repeatedCardChrome(false, cornerRadius: cornerRadius, tint: AppColors.selectedGlassTint)
        .accessibilityElement(children: .combine)
    }
}
