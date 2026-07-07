import AppKit
import Foundation
import MediaLibCore

// 从 AppState.swift 物理拆出（零行为变化）：音乐主题参数文件 + 配色预设/自定义色 + 防抖落盘。
// 该域与媒体库核心零耦合（不碰 cached*/update*InMemory/libraryRevision）——是干净的拆分接缝。
// 仍是同一 AppState 的 extension；settingsStore/settingsPersistTask 已在主类放开为 internal。
extension AppState {
    /// 从配置文件重新加载音乐主题参数并即时应用（无需重启）。
    func reloadMusicThemeConfig() {
        Task { @MainActor [weak self] in
            await MusicThemeConfigStore.reloadAsync()
            self?.musicThemeRevision &+= 1
        }
    }

    /// 一键恢复默认：删除/重写默认模板并复位参数，即时应用。
    func resetMusicThemeConfig() {
        Task { @MainActor [weak self] in
            await MusicThemeConfigStore.resetToDefaultsAsync()
            self?.musicThemeRevision &+= 1
        }
    }

    /// 在访达中定位主题参数文件（不存在则先写一份默认模板），供用户直接编辑。
    func revealMusicThemeConfigFile() {
        Task { @MainActor [weak self] in
            do {
                guard let url = try await MusicThemeConfigStore.ensureTemplateFileAsync() else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.logger?.log("写入音乐主题模板失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    private func publishThemePaletteChange() {
        applyThemePalette()
        themeRevision &+= 1
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.toolbar?.validateVisibleItems()
        }
    }

    /// 设置页：切换配色预设。
    func setThemePreset(_ preset: AppThemePreset) {
        settings.themePreset = preset
        if preset.isCustom {
            // 进入自定义时，用所选/默认种子填充空缺，避免一打开就空白。
            let seed = preset.seedHex
            if settings.themeBaseHex == nil { settings.themeBaseHex = seed.base }
            if settings.themeHighlightHex == nil { settings.themeHighlightHex = seed.highlight }
            if settings.themeLightHex == nil { settings.themeLightHex = seed.light }
        }
        publishThemePaletteChange()
        persistSettingsDebounced()
    }

    /// 设置页：更新自定义配色的某个锚点颜色（十六进制，不含 #）。
    /// ColorPicker 拖动时会高频触发，因此这里只做轻量的内存换色 + 防抖落盘，
    /// 不走 `saveSettings`（其会同步写盘、遍历所有窗口刷新外观并重配扫描/TMDB 定时器，高频调用会卡顿）。
    func setCustomThemeColor(base: String? = nil, highlight: String? = nil, light: String? = nil) {
        if let base { settings.themeBaseHex = base }
        if let highlight { settings.themeHighlightHex = highlight }
        if let light { settings.themeLightHex = light }
        settings.themePreset = .custom
        publishThemePaletteChange()
        persistSettingsDebounced()
    }

    /// 防抖落盘：高频设置变更（如配色拖动）只在停止操作约 0.4s 后写一次磁盘。
    /// 触发时落盘「当前最新」的 settings（而非排程时的快照），避免期间其它设置变更被旧快照覆盖丢失。
    private func persistSettingsDebounced() {
        settingsPersistTask?.cancel()
        settingsPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.settingsStore.saveAsync(self.settings)
        }
    }
}
