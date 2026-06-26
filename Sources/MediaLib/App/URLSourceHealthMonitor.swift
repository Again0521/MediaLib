import Combine
import Foundation

/// URL 媒体源链接的健康探测（可达性 / 可解析性），从 AppState 抽出（R1-ARCH-001 第 4 步）。
///
/// 职责边界：本 Monitor 只负责**探测调度 + 结果存储**——按 (id, url) 列表并发 HEAD/范围 GET
/// 探测、用 refreshID 守卫丢弃过期回调、把结果按 id 存进 `healthByID`，并提供查询。探测器
/// `probe` 可注入（默认走真实网络的 HEAD→范围 GET 兜底），便于确定性单测。
///
/// 留在 AppState：从 `urlSourceItems` / `urlMediaSource.includeInHealthCheck` 构造 probeItems 与
/// liveIDs、以及探测完成后自增 `libraryRevision`（经 `onUpdated` 回调）。行为逐字搬自原
/// AppState 的 refreshURLSourceHealth / probeURLHealth / classifyURLResponse。
@MainActor
final class URLSourceHealthMonitor: ObservableObject {
    @Published private(set) var healthByID: [String: URLItemHealthState] = [:]

    private var task: Task<Void, Never>?
    private var refreshID = UUID()
    private let probe: (URL) async -> URLItemHealthState

    init(probe: @escaping (URL) async -> URLItemHealthState = URLSourceHealthMonitor.defaultProbe) {
        self.probe = probe
    }

    func state(for id: String) -> URLItemHealthState {
        healthByID[id] ?? .unknown
    }

    /// 取消正在进行的探测并清空所有结果（健康检查被关闭时调用）。
    func reset() {
        task?.cancel()
        healthByID = [:]
    }

    /// 探测给定 (id, url) 列表的可达性。
    /// - liveIDs：仍存在的条目 id，用于先清掉已删除条目的旧结果。
    /// - onUpdated：探测完成后在主线程回调（供调用方自增 `libraryRevision` 等）。
    func refresh(
        probeItems: [(id: String, url: URL)],
        liveIDs: Set<String>,
        onUpdated: @escaping () -> Void
    ) {
        task?.cancel()
        // 清掉已删除条目的旧结果。
        healthByID = healthByID.filter { liveIDs.contains($0.key) }
        guard !probeItems.isEmpty else { return }
        let currentRefresh = UUID()
        refreshID = currentRefresh
        for item in probeItems {
            healthByID[item.id] = .checking
        }
        let probe = self.probe
        task = Task { [probeItems, currentRefresh] in
            var results: [String: URLItemHealthState] = [:]
            await withTaskGroup(of: (String, URLItemHealthState).self) { group in
                for item in probeItems {
                    group.addTask {
                        (item.id, await probe(item.url))
                    }
                }
                for await pair in group {
                    results[pair.0] = pair.1
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.refreshID == currentRefresh else { return }
                for (id, state) in results {
                    self.healthByID[id] = state
                }
                onUpdated()
            }
        }
    }

    // MARK: - 默认探测实现（搬自 AppState.probeURLHealth / classifyURLResponse）

    static func defaultProbe(_ url: URL) async -> URLItemHealthState {
        let session = URLSession.shared
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        head.httpMethod = "HEAD"
        if let response = try? await session.data(for: head).1 {
            return classify(response)
        }
        // 部分服务器拒绝 HEAD，改用 1KB 范围 GET 兜底。
        var ranged = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        ranged.httpMethod = "GET"
        ranged.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        if let response = try? await session.data(for: ranged).1 {
            return classify(response)
        }
        return .unreachable
    }

    static func classify(_ response: URLResponse) -> URLItemHealthState {
        guard let http = response as? HTTPURLResponse else { return .ok }
        if http.statusCode >= 400 { return .unreachable }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // 直链一般是 video/* 或八位字节流 / m3u8；返回网页通常 text/html，多半不是可播放视频。
        if contentType.contains("text/html") || contentType.contains("application/xhtml") {
            return .unparseable
        }
        return .ok
    }
}
