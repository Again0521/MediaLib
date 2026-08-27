import Foundation
import MediaLibServerProtocol

/// 管理控制台中尚未拥有专用复杂视图的运维页面。
/// 页面只组合共享壳与共享组件；动态数据全部来自权限隔离的 `/api/v1/admin/…`。
enum ServerWebOperationsPage {
    enum Section: Equatable {
        case playback, network, tasks, storage, security, logs

        var active: ServerWebNavigation.Active {
            switch self {
            case .playback: return .adminPlayback
            case .network: return .adminNetwork
            case .tasks: return .adminTasks
            case .storage: return .adminStorage
            case .security: return .adminSecurity
            case .logs: return .adminLogs
            }
        }

        var icon: ServerWebPageHeader.Icon {
            switch self {
            case .playback: return .queue
            case .network: return .status
            case .tasks: return .status
            case .storage: return .library
            case .security: return .status
            case .logs: return .history
            }
        }

        var eyebrow: String {
            switch self {
            case .playback: return "Playback"
            case .network: return "Network"
            case .tasks: return "Jobs"
            case .storage: return "Storage"
            case .security: return "Security"
            case .logs: return "Logs"
            }
        }

        var title: String {
            switch self {
            case .playback: return "播放与转码"
            case .network: return "网络"
            case .tasks: return "任务"
            case .storage: return "存储与维护"
            case .security: return "安全"
            case .logs: return "日志"
            }
        }

        var subtitle: String {
            switch self {
            case .playback: return "在安全范围内调整转码引擎、并发和资源边界。"
            case .network: return "检查监听与 HTTPS 边界；没有桌面宿主控制通道时保持只读。"
            case .tasks: return "查看扫描、索引和元数据任务的状态与脱敏结果。"
            case .storage: return "查看缓存、备份和诊断能力，危险操作保持分级确认。"
            case .security: return "审阅认证、权限与危险操作的结构化审计。"
            case .logs: return "查看有容量和保留期上限、且经过脱敏的服务日志。"
            }
        }
    }

    static func render(
        section: Section,
        serverName: String,
        csrfToken: String,
        categories: [ServerLibraryCategory] = [],
        sidebarExtras: ServerWebSidebarExtras
    ) -> String {
        let sidebar = ServerWebNavigation.render(
            active: section.active,
            showAdministration: true,
            note: section == .network ? .security : .none,
            categories: categories,
            extras: sidebarExtras,
            context: .administration
        )
        let content = """
        \(ServerWebPageHeader.render(
            icon: section.icon,
            eyebrow: section.eyebrow,
            title: section.title,
            subtitle: section.subtitle,
            actions: ServerWebUI.button("刷新", variant: .secondary, icon: .refresh, id: "operations-refresh")
        ))
        \(ServerWebUI.alert(.info, message: "正在读取受保护的管理数据…", id: "operations-state", messageID: "operations-state-text", role: "status"))
        <div class="operations-grid" id="operations-content" data-section="\(section.eyebrow.lowercased())">
          \(cards(for: section))
        </div>
        <p class="t-footnote t-tertiary operations-footnote">页面不会返回来源凭据、真实上游 URL、未脱敏路径或完整 FFmpeg 命令。写操作必须通过权限、CSRF、乐观并发和审计校验。</p>
        """
        return ServerWebDocument.render(
            title: section.title,
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/operations.css"],
            pageScripts: ["/assets/overlays.js", "/assets/operations.js"],
            tint: .admin
        )
    }

    private static func cards(for section: Section) -> String {
        let definitions: [(String, String)] = switch section {
        case .playback: [
            ("转码策略", "自动选择 VideoToolbox 或软件编码，并保持浏览器不支持音频转 AAC。"),
            ("并发与队列", "默认同时转码 2 路；安全可调范围 1–4，超限请求进入有界队列。"),
            ("临时空间", "转码目录仅当前用户可读，并受容量、保留磁盘与超时约束。")
        ]
        case .network: [
            ("监听边界", "服务默认只监听回环地址；LAN 访问继续通过本机 HTTPS 反向代理。"),
            ("宿主控制", "应用配置与重启仅由 0600 Unix Socket 控制通道执行。"),
            ("失败回滚", "变更必须校验、试运行、近期认证并在健康检查失败时恢复旧配置。")
        ]
        case .tasks: [
            ("资料库扫描", "只触发扫描，不在网页增删媒体源或修改来源路径。"),
            ("索引维护", "重建索引与元数据任务进入持久化队列并公开进度。"),
            ("失败结果", "结果只包含稳定错误码和脱敏摘要。")
        ]
        case .storage: [
            ("缓存", "查看占用并清理已结束的转码缓存。"),
            ("备份", "创建和下载 SQLite 备份，文件与操作都进入审计。"),
            ("恢复与诊断", "恢复要求近期认证、预检与回滚；诊断导出会移除敏感数据。")
        ]
        case .security: [
            ("身份与会话", "记录认证、密码变更、会话撤销和权限变更。"),
            ("危险操作", "配置、网络、备份恢复和清理使用独立审计事件。"),
            ("敏感信息", "令牌、密码、来源路径、上游 URL 和命令行参数不会进入日志。")
        ]
        case .logs: [
            ("结构化字段", "按时间、级别、类别和稳定事件代码筛选。"),
            ("容量边界", "保留期和最大容量都有硬上限，旧日志按策略回收。"),
            ("安全导出", "导出前再次脱敏，且不包含请求 Cookie、令牌或客户端完整地址。")
        ]
        }
        return definitions.map { title, detail in
            """
            <section class="ui-card operations-card">
              <div class="ui-card-head"><h2 class="ui-card-title">\(ServerWebHTML.escape(title))</h2><span class="ui-status ui-status-idle">受保护</span></div>
              <p class="t-footnote t-tertiary">\(ServerWebHTML.escape(detail))</p>
              <div class="operations-data" aria-live="polite">等待服务数据</div>
            </section>
            """
        }.joined()
    }

    static let style = #"""
    .operations-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:var(--space-5); }
    .operations-card { min-height:190px; }
    .operations-data { margin-top:auto; padding-top:var(--space-4); border-top:var(--hairline) solid var(--border); color:var(--text-secondary); font-size:var(--type-footnote-size); }
    .operations-footnote { margin-top:var(--space-5); }
    @media (max-width: 420px) { .operations-grid { grid-template-columns:minmax(0,1fr); } }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const refresh = document.getElementById('operations-refresh');
      const message = document.getElementById('operations-state-text');
      const content = document.getElementById('operations-content');
      if (!refresh || !message || !content) return;
      async function load() {
        refresh.disabled = true;
        const section = content.dataset.section || '';
        try {
          const endpoint = section === 'playback' ? '/api/v1/admin/settings' : section === 'jobs' ? '/api/v1/admin/jobs?limit=50' : '/api/v1/admin/dashboard';
          const response = await fetch(endpoint, { credentials:'same-origin', headers:{Accept:'application/json'} });
          if (!response.ok) throw new Error('status-' + response.status);
          await response.json();
          message.textContent = '管理数据已刷新。';
        } catch (_) {
          message.textContent = '当前宿主尚未提供此页的动态数据，安全边界保持不变。';
        } finally { refresh.disabled = false; }
      }
      refresh.addEventListener('click', load);
      load();
    })();
    """#
}
