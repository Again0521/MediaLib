import MediaLibCore
import SwiftUI

struct SyncConflictQueueSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sheetContent) {
            AppSheetHeader(
                title: "同步冲突",
                subtitle: "处理本地与远端状态不一致的字段，采用远端会写入 MediaLIB 内部索引。",
                systemImage: "arrow.triangle.branch"
            )

            AppInfoNote(text: "Trakt 冲突选择保留本地时会把本机已看/想看状态写回 Trakt；采用远端仅写入 MediaLIB 内部索引。所有处理都不会修改用户媒体文件。")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.pendingSyncConflicts.isEmpty {
                        ConnectorEmptyState(title: "没有待处理冲突", systemImage: "checkmark.circle")
                    } else {
                        ForEach(appState.pendingSyncConflicts) { conflict in
                            SyncConflictRow(conflict: conflict)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 460)

            AppSheetActionFooter {
                Button {
                    dismiss()
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .sheetUtilityButton(width: 96, prominent: true)
            }
        }
        .appSheetChrome(width: 720, maxHeight: 660)
    }
}

private struct SyncConflictRow: View {
    @EnvironmentObject private var appState: AppState
    let conflict: SyncConflict

    var body: some View {
        let hidesDetail = appState.hidesDetailForMediaID(conflict.mediaID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(conflict.provider.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.selectedGlassTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .staticSurfaceBackground(cornerRadius: 8, thickness: 0.92)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.displayTitleForMediaID(conflict.mediaID))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(syncConflictFieldTitle(conflict.fieldName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(settingsSheetDateText(conflict.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                SyncConflictValueBox(title: "本地", value: hidesDetail ? "保险库内容已隐藏" : conflict.localValue)
                SyncConflictValueBox(title: "远端", value: hidesDetail ? "保险库内容已隐藏" : conflict.remoteValue)
            }

            HStack(spacing: 8) {
                Button {
                    appState.resolveSyncConflict(conflict, resolution: .useLocal)
                } label: {
                    Label("保留本地", systemImage: "macwindow")
                }
                .sheetUtilityButton(width: 104)

                Button {
                    appState.resolveSyncConflict(conflict, resolution: .useRemote)
                } label: {
                    Label("采用远端", systemImage: "cloud")
                }
                .sheetUtilityButton(width: 104)

                Button {
                    appState.resolveSyncConflict(conflict, resolution: .merge)
                } label: {
                    Label("合并", systemImage: "arrow.triangle.merge")
                }
                .sheetUtilityButton(width: 86)

                Button {
                    appState.resolveSyncConflict(conflict, resolution: .keepBoth)
                } label: {
                    Label("都保留", systemImage: "square.on.square")
                }
                .sheetUtilityButton(width: 92)

                Spacer(minLength: 0)

                Button {
                    appState.ignoreSyncConflict(conflict)
                } label: {
                    Label("忽略", systemImage: "eye.slash")
                }
                .sheetUtilityButton(width: 82)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 12, thickness: 0.88)
    }
}

private struct SyncConflictValueBox: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(cleanedDisplayValue(value))
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .staticSurfaceBackground(cornerRadius: 10, thickness: 0.82)
    }
}

struct MetadataCorrectionHistorySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sheetContent) {
            AppSheetHeader(
                title: "元数据历史",
                subtitle: "查看最近的元数据覆盖批次，并按批次撤销到覆盖前的内部索引值。",
                systemImage: "clock.arrow.circlepath"
            )

            AppInfoNote(text: "撤销只恢复 MediaLIB 数据库中的元数据字段，不会移动、改名或写回用户的媒体文件。")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.metadataCorrectionBatches.isEmpty {
                        ConnectorEmptyState(title: "没有可撤销的元数据历史", systemImage: "checkmark.circle")
                    } else {
                        ForEach(appState.metadataCorrectionBatches) { batch in
                            MetadataCorrectionBatchRow(batch: batch)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 460)

            AppSheetActionFooter {
                Button {
                    dismiss()
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .sheetUtilityButton(width: 96, prominent: true)
            }
        }
        .appSheetChrome(width: 680, maxHeight: 660)
    }
}

private struct MetadataCorrectionBatchRow: View {
    @EnvironmentObject private var appState: AppState
    let batch: MetadataCorrectionBatchSummary

    var body: some View {
        let fieldTitle = batch.fields
            .prefix(4)
            .map(\.displayName)
            .joined(separator: "、")
        let extraCount = max(batch.fields.count - 4, 0)
        let displayFields = extraCount > 0 ? "\(fieldTitle) 等 \(batch.fieldCount) 项" : (fieldTitle.isEmpty ? "\(batch.fieldCount) 项字段" : fieldTitle)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(appState.displayTitleForMediaID(batch.mediaID))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(metadataSourceTitle(batch.source)) · \(displayFields)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(settingsSheetDateText(batch.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                appState.undoMetadataCorrectionBatch(batch)
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .sheetUtilityButton(width: 92)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 12, thickness: 0.88)
    }
}

private struct ConnectorEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .staticSurfaceBackground(cornerRadius: 12, thickness: 0.82)
    }
}

private extension View {
    func sheetUtilityButton(width: CGFloat, prominent: Bool = false) -> some View {
        buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 9, minHeight: 30, prominent: prominent))
            .frame(width: width)
    }
}

private func syncConflictFieldTitle(_ fieldName: String) -> String {
    if SyncConflictValueParser.isUserRatingField(fieldName) {
        return "用户评级"
    }
    if let field = MetadataCorrectionField.allCases.first(where: { $0.rawValue == fieldName || $0.databaseColumn == fieldName }) {
        return field.displayName
    }
    switch fieldName {
    case "watched": return "已观看"
    case "watchlist": return "想看"
    case "favorite": return "喜欢"
    case "user_rating", "userRating", "rating": return "用户评级"
    case "play_position": return "播放进度"
    case "play_progress": return "播放百分比"
    default: return fieldName.isEmpty ? "未知字段" : fieldName
    }
}

private func metadataSourceTitle(_ source: String) -> String {
    switch source {
    case "manual": return "手动修正"
    case "metadata-supplement": return "一键补充"
    case "music-metadata-fetch": return "音乐补全"
    case "music-tag-file": return "标签写入"
    case "music-tag-index": return "标签索引"
    default: return source.isEmpty ? "未知来源" : source
    }
}

private func cleanedDisplayValue(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "空值" : trimmed
}

private func settingsSheetDateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
