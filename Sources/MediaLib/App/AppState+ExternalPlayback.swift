import Foundation
import MediaLibCore

// 播放入口（内置播放器呈现 + 访达外部文件 + 网络串流 + 剧集队列构建 + 樱花彩蛋）从 AppState.swift
// 拆到本文件，直接缩小那个超大文件（R1-ARCH-001 头号债务）。纯文件搬运，逐字不变。依赖均为
// internal（selectedItem / quickPreviewItem / activePlayerItem / videoQueue / musicQueue / items /
// alert / showingNetworkStreamPrompt / play / children / sakuraEasterEgg*）；videoQueueItems /
// triggerSakuraEasterEggIfNeeded 仅本组使用，随之搬来仍保持 private（仅本文件可见）。
extension AppState {
    func presentBuiltInPlayer(_ item: MediaItem, preserveSelection: Bool = false) {
        if !preserveSelection {
            selectedItem = nil
        }
        quickPreviewItem = nil
        guard item.type != .music else {
            activePlayerItem = item
            triggerSakuraEasterEggIfNeeded(for: item)
            return
        }
        videoQueue = videoQueueItems(startingAt: item)
        activePlayerItem = item
    }

    /// 从访达双击/「打开方式」进入的本地媒体文件：在库内则播放库内条目
    /// （保留进度、剧集队列等），否则构造临时条目直接播放，不写入媒体库。
    func playExternalFiles(_ urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        let path = url.path
        if let existing = items.first(where: { $0.filePath == path }) {
            play(existing)
            return
        }
        let ext = url.pathExtension.lowercased()
        let isMusic = SystemDefaultPlayerRegistrar.musicExtensions.contains(ext)
        let item = MediaItem(
            id: "external-file:\(path)",
            type: isMusic ? .music : .other,
            title: url.deletingPathExtension().lastPathComponent,
            filePath: path
        )
        if isMusic {
            musicQueue = [item]
        }
        presentBuiltInPlayer(item)
    }

    /// 直接播放网络串流地址（不入库）：构造临时 MediaItem 交给内置播放器，
    /// mpv 原生支持 http(s)/rtsp/rtmp 等协议；进度按未知 id 落库为 no-op，不污染媒体库。
    func playNetworkStream(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "rtsp", "rtmp", "rtp", "mms", "srt", "udp", "ftp"].contains(scheme) else {
            alert = AppAlert(title: "无法播放", message: "请输入合法的串流地址（http / https / rtsp / rtmp 等）。")
            return
        }
        let title: String = {
            let name = url.lastPathComponent
            if !name.isEmpty, name != "/" {
                return name.removingPercentEncoding ?? name
            }
            return url.host ?? trimmed
        }()
        let item = MediaItem(
            id: "url-stream:\(trimmed)",
            type: .other,
            title: title,
            filePath: trimmed
        )
        showingNetworkStreamPrompt = false
        presentBuiltInPlayer(item)
    }

    /// 构建剧集播放队列：当前集 + 同系列中排在它之后的剧集（沿用剧集页的排序）。
    private func videoQueueItems(startingAt item: MediaItem) -> [MediaItem] {
        guard let parentID = item.parentID,
              let parent = items.first(where: { $0.id == parentID }) else {
            return [item]
        }
        let siblings = children(for: parent).filter { $0.filePath != nil }
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else {
            return [item]
        }
        return Array(siblings[index...])
    }

    /// #14 当播放的歌曲歌名包含「アゲイン」时，触发樱花纷飞特效（持续 5 秒），
    /// 每次启动软件只在首次播放该类歌曲时出现一次。
    private func triggerSakuraEasterEggIfNeeded(for item: MediaItem) {
        guard !sakuraEasterEggShownThisLaunch else { return }
        guard item.type == .music else { return }
        let matches = item.title.contains("アゲイン") || (item.originalTitle?.contains("アゲイン") ?? false)
        guard matches else { return }
        sakuraEasterEggShownThisLaunch = true
        sakuraEasterEggActive = true
        sakuraEasterEggTask?.cancel()
        sakuraEasterEggTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.sakuraEasterEggActive = false
        }
    }
}
