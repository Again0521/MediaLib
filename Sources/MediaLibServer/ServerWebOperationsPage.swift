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
            case .logs: return "审计日志"
            }
        }

        var subtitle: String {
            switch self {
            case .playback: return "在安全范围内调整转码引擎、并发和资源边界。"
            case .network: return "检查监听与 HTTPS 边界；没有桌面宿主控制通道时保持只读。"
            case .tasks: return "查看扫描、索引和元数据任务的状态与脱敏结果。"
            case .storage: return "查看缓存、备份和诊断能力，危险操作保持分级确认。"
            case .security: return "审阅认证、权限与危险操作的结构化审计。"
            case .logs: return "筛选有容量和保留期上限、且经过脱敏的安全事件。"
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
        switch section {
        case .playback:
            return """
            <form class="operations-form" id="playback-settings-form">
              \(card("转码策略", "浏览器不支持的音频始终转 AAC。", id: "playback-engine", controls: """
              <div class="ui-field"><label class="ui-label" for="setting-engine">编码引擎</label><select class="ui-select" id="setting-engine"><option value="automatic">自动</option><option value="videoToolbox">VideoToolbox</option><option value="software">软件编码</option></select></div>
              <div class="ui-field"><label class="ui-label" for="setting-bitrate">默认远程码率（Mbps）</label><input class="ui-input" id="setting-bitrate" type="number" min="1" max="200" inputmode="numeric"></div>
              """))
              \(card("并发与会话", "并发只允许在安全范围 1–4 内调整。", id: "playback-session", controls: """
              <div class="ui-field"><label class="ui-label" for="setting-concurrency">最大并发转码</label><input class="ui-input" id="setting-concurrency" type="number" min="1" max="4" inputmode="numeric"></div>
              <div class="ui-field"><label class="ui-label" for="setting-idle">空闲回收（分钟）</label><input class="ui-input" id="setting-idle" type="number" min="5" max="240" inputmode="numeric"></div>
              """))
              \(card("临时空间", "容量与磁盘保留量均有服务端硬边界。", id: "playback-storage", controls: """
              <div class="ui-field"><label class="ui-label" for="setting-temp">临时空间上限（GB）</label><input class="ui-input" id="setting-temp" type="number" min="1" max="1024" inputmode="numeric"></div>
              <div class="ui-field"><label class="ui-label" for="setting-free">最少保留磁盘（GB）</label><input class="ui-input" id="setting-free" type="number" min="1" max="1024" inputmode="numeric"></div>
              <div class="ui-field"><label class="ui-label" for="setting-retention">遥测保留（小时）</label><input class="ui-input" id="setting-retention" type="number" min="1" max="168" inputmode="numeric"></div>
              """))
              <div class="operations-actions"><button class="ui-btn ui-btn-primary" type="submit" id="playback-save">保存播放设置</button></div>
            </form>
            """
        case .network:
            return """
            <form class="operations-form" id="network-settings-form">
            \(card(
                "监听与 HTTPS 边界",
                "没有桌面宿主时保持只读；任何模式都不会启用明文 0.0.0.0 监听。",
                id: "network-readiness",
                controls: """
                <div class="ui-field"><label class="ui-label" for="network-name">服务器名称</label><input class="ui-input" id="network-name" maxlength="80" autocomplete="off"></div>
                <div class="ui-field"><label class="ui-label" for="network-port">端口</label><input class="ui-input" id="network-port" type="number" min="1024" max="65535" inputmode="numeric"></div>
                <div class="ui-field"><label class="ui-label" for="network-mode">访问模式</label><select class="ui-select" id="network-mode"><option value="loopback">仅本机/HTTPS 反代</option><option value="lan-https">内建 LAN HTTPS</option></select></div>
                """
            ))
            \(card("公开 Origin 与可信代理", "仅接受 HTTPS Origin 与精确 IPv4；LAN HTTPS 模式由宿主管理这些值。", id: "network-proxy", controls: """
                <div class="ui-field"><label class="ui-label" for="network-origin">公开 HTTPS Origin</label><input class="ui-input" id="network-origin" type="url" inputmode="url" autocomplete="url" placeholder="https://media.example.com"></div>
                <div class="ui-field"><label class="ui-label" for="network-proxies">可信代理 IPv4（逗号分隔）</label><input class="ui-input" id="network-proxies" autocomplete="off" placeholder="127.0.0.1"></div>
                """))
            \(card(
                "宿主控制",
                "配置应用必须经过 0600 Unix Socket、随机令牌、近期密码确认、健康检查与失败回滚。",
                id: "network-host-control",
                controls: """
                <div class="ui-field"><label class="ui-label" for="network-password">当前管理员密码</label><input class="ui-input" id="network-password" type="password" maxlength="1024" autocomplete="current-password"></div>
                <div class="operations-button-row"><button class="ui-btn ui-btn-secondary" type="button" id="network-validate">校验配置</button><button class="ui-btn ui-btn-primary" type="submit" id="network-apply">应用并重启</button></div>
                """
            ))
            </form>
            """
        case .tasks:
            return card("资料库任务", "只触发已有本地普通媒体库，不提供来源增删改。", id: "task-actions", controls: """
              <div class="operations-button-row"><button class="ui-btn ui-btn-primary" type="button" id="task-scan">扫描资料库</button><button class="ui-btn ui-btn-secondary" type="button" id="task-reindex">重建索引</button><button class="ui-btn ui-btn-secondary" type="button" id="task-metadata">刷新本地元数据</button></div>
            """) + card(
              "任务队列",
              "显示持久化进度与稳定结果代码；筛选与计数均在数据库内完成。",
              id: "task-list",
              controls: """
              <div class="operations-list-filters">
                \(ServerWebUI.searchField(
                  id: "task-search",
                  label: "筛选任务",
                  placeholder: "搜索任务或结果代码",
                  action: "/admin/tasks",
                  formID: "task-search-form"
                ))
                <div class="ui-field"><label class="ui-label" for="task-kind">类型</label><select class="ui-select" id="task-kind"><option value="">全部</option><option value="library.scan">资料库扫描</option><option value="library.reindex">重建索引</option><option value="metadata.refresh">刷新元数据</option></select></div>
                <div class="ui-field"><label class="ui-label" for="task-state">状态</label><select class="ui-select" id="task-state"><option value="">全部</option><option value="queued">排队中</option><option value="running">进行中</option><option value="succeeded">已完成</option><option value="failed">失败</option><option value="cancelled">已取消</option></select></div>
              </div>
              """,
              footer: taskLoadMoreButton
            )
        case .storage:
            return card(
              "数据库备份",
              "创建与恢复均需再次确认；下载和恢复只使用不透明 ID。",
              id: "backup-list",
              controls: """
              <div class="operations-list-toolbar">
                <div class="ui-field"><label class="ui-label" for="backup-kind">备份类型</label><select class="ui-select" id="backup-kind"><option value="">全部</option><option value="manual">手动备份</option><option value="automatic">升级前备份</option><option value="safety">恢复前安全快照</option><option value="other">其它</option></select></div>
                <button class="ui-btn ui-btn-primary" type="button" id="backup-create">创建备份</button>
              </div>
              """,
              footer: backupLoadMoreButton
            ) + card("恢复与清理", "恢复要求当前密码、完整性预检、审计和失败自动回滚；清理转码缓存会终止当前转码会话。", id: "storage-protected", controls: """
              <div class="ui-field"><label class="ui-label" for="restore-password">当前管理员密码</label><input class="ui-input" id="restore-password" type="password" maxlength="1024" autocomplete="current-password"></div>
              <div class="operations-button-row"><button class="ui-btn ui-btn-destructive" type="button" id="cache-clear">清理转码缓存</button><a class="ui-btn ui-btn-secondary" href="/api/v1/admin/diagnostics" download>导出脱敏诊断</a></div>
            """) + card(
              "维护任务",
              "备份、恢复和缓存清理在有界后台队列执行。",
              id: "storage-job-list",
              controls: """
              <div class="ui-field operations-compact-filter"><label class="ui-label" for="storage-job-state">状态</label><select class="ui-select" id="storage-job-state"><option value="">全部</option><option value="queued">排队中</option><option value="running">进行中</option><option value="succeeded">已完成</option><option value="failed">失败</option><option value="cancelled">已取消</option></select></div>
              """,
              footer: storageJobLoadMoreButton
            )
        case .security:
            return card(
                "安全审计",
                "认证、权限、会话与危险操作使用结构化事件。",
                id: "security-events",
                footer: auditLoadMoreButton
            )
        case .logs:
            return card(
                "结构化审计日志",
                "仅显示有界、脱敏字段；不包含令牌、路径、URL 或命令行。",
                id: "log-events",
                controls: """
                <div class="operations-log-filters">
                  \(ServerWebUI.searchField(
                    id: "log-search",
                    label: "筛选审计日志",
                    placeholder: "搜索操作或稳定标识",
                    action: "/admin/logs",
                    formID: "log-search-form"
                  ))
                  <div class="ui-field"><label class="ui-label" for="log-category">类别</label><select class="ui-select" id="log-category"><option value="">全部</option><option value="authentication">认证</option><option value="identity">身份</option><option value="authorization">授权</option><option value="session">会话</option></select></div>
                  <div class="ui-field"><label class="ui-label" for="log-outcome">结果</label><select class="ui-select" id="log-outcome"><option value="">全部</option><option value="success">成功</option><option value="failure">失败</option><option value="denied">已拒绝</option></select></div>
                </div>
                """,
                footer: auditLoadMoreButton
            )
        }
    }

    private static let auditLoadMoreButton = ServerWebUI.button(
        "载入更多",
        variant: .ghost,
        size: .small,
        icon: .chevronDown,
        id: "audit-load-more",
        attributes: " hidden"
    )

    private static let taskLoadMoreButton = ServerWebUI.button(
        "载入更多任务",
        variant: .ghost,
        size: .small,
        icon: .chevronDown,
        id: "task-load-more",
        attributes: " hidden"
    )

    private static let backupLoadMoreButton = ServerWebUI.button(
        "载入更多备份",
        variant: .ghost,
        size: .small,
        icon: .chevronDown,
        id: "backup-load-more",
        attributes: " hidden"
    )

    private static let storageJobLoadMoreButton = ServerWebUI.button(
        "载入更多维护任务",
        variant: .ghost,
        size: .small,
        icon: .chevronDown,
        id: "storage-job-load-more",
        attributes: " hidden"
    )

    private static func card(
        _ title: String,
        _ detail: String,
        id: String,
        controls: String = "",
        footer: String = ""
    ) -> String {
        """
        <section class="ui-card operations-card" id="\(id)-card">
          <div class="ui-card-head"><h2 class="ui-card-title">\(ServerWebHTML.escape(title))</h2><span class="ui-status ui-status-idle" id="\(id)-status">受保护</span></div>
          <p class="t-footnote t-tertiary">\(ServerWebHTML.escape(detail))</p>
          \(controls)
          <div class="operations-data" id="\(id)" aria-live="polite">等待服务数据</div>
          \(footer)
        </section>
        """
    }

    static let style = #"""
    .operations-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:var(--space-5); }
    .operations-card { min-height:190px; display:flex; flex-direction:column; gap:var(--space-3); }
    .operations-data { margin-top:auto; padding-top:var(--space-4); border-top:var(--hairline) solid var(--border); color:var(--text-secondary); font-size:var(--type-footnote-size); }
    .operations-form { grid-column:1/-1; display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:var(--space-5); }
    .operations-form .operations-actions { grid-column:1/-1; display:flex; justify-content:flex-end; }
    .operations-button-row { display:flex; flex-wrap:wrap; gap:var(--space-2); }
    .operations-log-filters, .operations-list-filters { display:grid; grid-template-columns:minmax(180px,1fr) repeat(2,minmax(120px,auto)); gap:var(--space-3); align-items:end; }
    .operations-log-filters .app-page-search, .operations-list-filters .app-page-search { width:100%; }
    .operations-list-toolbar { display:flex; flex-wrap:wrap; align-items:end; justify-content:space-between; gap:var(--space-3); }
    .operations-compact-filter { max-width:220px; }
    #audit-load-more, #task-load-more, #backup-load-more, #storage-job-load-more { align-self:center; min-height:44px; }
    .operations-list { display:grid; gap:var(--space-2); margin:0; padding:0; list-style:none; }
    .operations-list-item { display:flex; align-items:center; justify-content:space-between; gap:var(--space-3); min-height:44px; padding:var(--space-2) 0; border-bottom:var(--hairline) solid var(--border); }
    .operations-list-item:last-child { border-bottom:0; }
    .operations-list-copy { min-width:0; display:grid; gap:2px; }
    .operations-list-copy strong, .operations-list-copy span { overflow-wrap:anywhere; }
    .operations-job-progress { width:min(260px,100%); height:4px; margin-top:var(--space-1); }
    .operations-facts { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:var(--space-2) var(--space-4); margin:0; }
    .operations-facts dt { color:var(--text-secondary); }
    .operations-facts dd { margin:0; color:var(--text-primary); text-align:right; }
    .operations-footnote { margin-top:var(--space-5); }
    @media (max-width: 420px) {
      .operations-grid, .operations-form { grid-template-columns:minmax(0,1fr); }
      .operations-form .operations-actions, .operations-form .operations-actions .ui-btn { width:100%; }
      .operations-list-item { align-items:flex-start; flex-direction:column; }
      .operations-log-filters, .operations-list-filters { grid-template-columns:minmax(0,1fr); }
      .operations-list-toolbar, .operations-list-toolbar > * { width:100%; }
      .operations-compact-filter { max-width:none; }
      #audit-load-more, #task-load-more, #backup-load-more, #storage-job-load-more { width:100%; }
    }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const refresh = document.getElementById('operations-refresh');
      const message = document.getElementById('operations-state-text');
      const content = document.getElementById('operations-content');
      const csrf = document.querySelector('meta[name="medialib-csrf-token"]')?.content || '';
      if (!refresh || !message || !content) return;
      let settingsETag = '';
      let logEvents = [];
      let logTotal = 0;
      let logLoading = false;
      let logRevision = 0;
      let jobRows = [];
      let jobTotal = 0;
      let jobLoading = false;
      let jobRevision = 0;
      let jobPollTimer = null;
      let backupRows = [];
      let backupTotal = 0;
      let backupLoading = false;
      let backupRevision = 0;
      let hostControlAvailable = false;
      const byID = id => document.getElementById(id);
      const setMessage = (text, failed = false) => {
        message.textContent = text;
        message.closest('.ui-alert')?.classList.toggle('ui-alert-error', failed);
      };
      const requestJSON = async (url, options = {}) => {
        const response = await fetch(url, {
          credentials:'same-origin',
          ...options,
          headers:{Accept:'application/json', ...(options.headers || {})}
        });
        if (response.status === 401) { window.location.assign('/login'); throw new Error('unauthorized'); }
        if (!response.ok) throw new Error(`status-${response.status}`);
        if (response.status === 204) return { response, value:null };
        return { response, value:await response.json() };
      };
      const empty = (target, text) => {
        if (!target) return;
        target.replaceChildren();
        const note = document.createElement('p');
        note.className = 't-footnote t-tertiary';
        note.textContent = text;
        target.append(note);
      };
      const facts = (target, entries) => {
        if (!target) return;
        const list = document.createElement('dl');
        list.className = 'operations-facts';
        entries.forEach(([label, value]) => {
          const term = document.createElement('dt');
          const detail = document.createElement('dd');
          term.textContent = label;
          detail.textContent = String(value);
          list.append(term, detail);
        });
        target.replaceChildren(list);
      };
      const stateLabel = value => ({queued:'排队中',running:'进行中',succeeded:'已完成',failed:'失败',cancelled:'已取消'})[value] || '未知';
      const jobTitle = kind => ({
        'library.scan':'资料库扫描',
        'library.reindex':'重建索引',
        'metadata.refresh':'刷新本地元数据',
        'database.backup':'创建数据库备份',
        'database.restore':'恢复数据库',
        'transcode-cache.clear':'清理转码缓存'
      })[kind] || '维护任务';
      const renderJobs = () => {
        const isStorage = content.dataset.section === 'storage';
        const target = byID(isStorage ? 'storage-job-list' : 'task-list');
        if (!target) return;
        const more = byID(isStorage ? 'storage-job-load-more' : 'task-load-more');
        if (more) more.hidden = jobRows.length >= jobTotal;
        if (jobRows.length === 0) { empty(target, '没有符合条件的任务。'); return; }
        const list = document.createElement('ul');
        list.className = 'operations-list';
        jobRows.forEach(job => {
          const item = document.createElement('li');
          item.className = 'operations-list-item';
          const copy = document.createElement('span');
          copy.className = 'operations-list-copy';
          const title = document.createElement('strong');
          const detail = document.createElement('span');
          title.textContent = jobTitle(String(job.kind || ''));
          const progress = Math.round(Math.min(1, Math.max(0, Number(job.progress) || 0)) * 100);
          const created = new Date(job.createdAt);
          detail.textContent = `${Number.isNaN(created.valueOf()) ? '时间未知' : created.toLocaleString()} · ${stateLabel(job.state)} · ${progress}%${job.resultCode ? ` · ${String(job.resultCode)}` : ''}`;
          const progressTrack = document.createElement('span');
          progressTrack.className = 'ui-progress operations-job-progress';
          progressTrack.setAttribute('role', 'progressbar');
          progressTrack.setAttribute('aria-label', `${title.textContent}：${stateLabel(job.state)}`);
          progressTrack.setAttribute('aria-valuemin', '0');
          progressTrack.setAttribute('aria-valuemax', '100');
          progressTrack.setAttribute('aria-valuenow', String(progress));
          const progressFill = document.createElement('span');
          progressFill.style.width = `${progress}%`;
          progressTrack.append(progressFill);
          copy.append(title, detail, progressTrack);
          const badge = document.createElement('span');
          badge.className = `ui-status ${job.state === 'failed' ? 'ui-status-error' : job.state === 'succeeded' ? 'ui-status-success' : 'ui-status-idle'}`;
          badge.textContent = stateLabel(job.state);
          item.append(copy, badge);
          list.append(item);
        });
        target.replaceChildren(list);
      };
      const backupKindLabel = kind => ({manual:'手动备份',automatic:'升级前备份',safety:'恢复前安全快照',other:'其它备份'})[kind] || '数据库备份';
      const renderBackups = () => {
        const target = byID('backup-list');
        if (!target) return;
        const more = byID('backup-load-more');
        if (more) more.hidden = backupRows.length >= backupTotal;
        if (backupRows.length === 0) { empty(target, '没有符合条件的可下载备份。'); return; }
        const list = document.createElement('ul');
        list.className = 'operations-list';
        backupRows.forEach(backup => {
          if (!/^[0-9a-f]{32}$/.test(String(backup.id || ''))) return;
          const item = document.createElement('li');
          item.className = 'operations-list-item';
          const copy = document.createElement('span');
          copy.className = 'operations-list-copy';
          const title = document.createElement('strong');
          const detail = document.createElement('span');
          title.textContent = backupKindLabel(String(backup.kind || 'other'));
          const bytes = Math.max(0, Number(backup.byteLength) || 0);
          detail.textContent = `${new Date(backup.createdAt).toLocaleString()} · ${(bytes / 1048576).toFixed(1)} MB`;
          copy.append(title, detail);
          const actions = document.createElement('span');
          actions.className = 'operations-button-row';
          const link = document.createElement('a');
          link.className = 'ui-btn ui-btn-secondary';
          link.href = `/api/v1/admin/backups/${encodeURIComponent(backup.id)}/download`;
          link.textContent = '下载';
          const restore = document.createElement('button');
          restore.className = 'ui-btn ui-btn-destructive';
          restore.type = 'button';
          restore.textContent = '恢复';
          restore.addEventListener('click', () => { void beginRestore(String(backup.id), restore); });
          actions.append(link, restore);
          item.append(copy, actions);
          list.append(item);
        });
        target.replaceChildren(list);
      };
      const renderLogs = () => {
        const target = byID(content.dataset.section === 'logs' ? 'log-events' : 'security-events');
        if (!target) return;
        const more = byID('audit-load-more');
        if (more) more.hidden = logEvents.length >= logTotal;
        if (logEvents.length === 0) { empty(target, '没有符合条件的事件。'); return; }
        const list = document.createElement('ul');
        list.className = 'operations-list';
        logEvents.forEach(event => {
          const item = document.createElement('li');
          item.className = 'operations-list-item';
          const copy = document.createElement('span');
          copy.className = 'operations-list-copy';
          const title = document.createElement('strong');
          const detail = document.createElement('span');
          title.textContent = String(event.action || 'unknown');
          detail.textContent = `${new Date(event.occurredAt).toLocaleString()} · ${String(event.category || 'unknown')}${event.detailCode ? ` · ${String(event.detailCode)}` : ''}`;
          copy.append(title, detail);
          const badge = document.createElement('span');
          badge.className = `ui-status ${event.outcome === 'success' ? 'ui-status-success' : 'ui-status-error'}`;
          badge.textContent = event.outcome === 'success' ? '成功' : event.outcome === 'denied' ? '已拒绝' : '失败';
          item.append(copy, badge);
          list.append(item);
        });
        target.replaceChildren(list);
      };
      const setInput = (id, value) => { const input = byID(id); if (input) input.value = String(value); };
      const formatBytes = value => {
        const bytes = Math.max(0, Number(value) || 0);
        if (bytes < 1024) return `${bytes} B`;
        const units = ['KB','MB','GB','TB'];
        let size = bytes / 1024;
        let unit = 0;
        while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit += 1; }
        return `${size.toFixed(size >= 10 ? 1 : 2)} ${units[unit]}`;
      };
      const formatUptime = value => {
        const seconds = Math.max(0, Math.floor(Number(value) || 0));
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        return days > 0 ? `${days} 天 ${hours} 小时` : hours > 0 ? `${hours} 小时 ${minutes} 分钟` : `${minutes} 分钟`;
      };
      const loadPlayback = async () => {
        const {response, value} = await requestJSON('/api/v1/admin/settings');
        const settings = value?.value;
        if (!settings) throw new Error('invalid-settings');
        settingsETag = response.headers.get('ETag') || '';
        setInput('setting-engine', settings.transcodeEngine);
        setInput('setting-bitrate', settings.defaultRemoteBitrateMbps);
        setInput('setting-concurrency', settings.maximumTranscodeSessions);
        setInput('setting-idle', settings.sessionIdleMinutes);
        setInput('setting-temp', settings.temporaryStorageLimitGB);
        setInput('setting-free', settings.minimumFreeDiskGB);
        setInput('setting-retention', settings.telemetryRetentionHours);
        facts(byID('playback-engine'), [['当前引擎', settings.transcodeEngine], ['远程码率', `${settings.defaultRemoteBitrateMbps} Mbps`]]);
        facts(byID('playback-session'), [['最大并发', settings.maximumTranscodeSessions], ['空闲回收', `${settings.sessionIdleMinutes} 分钟`]]);
        facts(byID('playback-storage'), [['临时空间', `${settings.temporaryStorageLimitGB} GB`], ['磁盘保留', `${settings.minimumFreeDiskGB} GB`]]);
      };
      const scheduleJobPoll = () => {
        if (jobPollTimer !== null) window.clearTimeout(jobPollTimer);
        jobPollTimer = null;
        if (!jobRows.some(job => job.state === 'queued' || job.state === 'running')) return;
        jobPollTimer = window.setTimeout(() => {
          if (document.body.contains(content)) void loadJobs(true, true);
        }, 2000);
      };
      const loadJobs = async (reset = true, preserveLoadedRows = false) => {
        if (jobLoading && !reset) return;
        jobLoading = true;
        const revision = reset ? ++jobRevision : jobRevision;
        const previousRows = jobRows;
        const isStorage = content.dataset.section === 'storage';
        const more = byID(isStorage ? 'storage-job-load-more' : 'task-load-more');
        if (more) more.disabled = true;
        try {
          const parameters = new URLSearchParams({
            offset:String(reset ? 0 : jobRows.length),
            limit:'50',
            scope:isStorage ? 'server' : 'library'
          });
          const state = byID(isStorage ? 'storage-job-state' : 'task-state')?.value || '';
          if (state) parameters.set('state', state);
          if (!isStorage) {
            const kind = byID('task-kind')?.value || '';
            const query = (byID('task-search')?.value || '').trim();
            if (kind) parameters.set('kind', kind);
            if (query) parameters.set('q', query);
          }
          const result = await requestJSON(`/api/v1/admin/jobs?${parameters}`);
          if (revision !== jobRevision) return;
          const rows = Array.isArray(result.value) ? result.value : [];
          const total = Number(result.response.headers.get('X-MediaLIB-Total-Count'));
          jobTotal = Number.isFinite(total) ? Math.max(rows.length, total) : rows.length;
          if (reset && preserveLoadedRows && previousRows.length > rows.length) {
            const refreshedIDs = new Set(rows.map(job => String(job.id || '')));
            jobRows = rows.concat(previousRows.filter(job => !refreshedIDs.has(String(job.id || ''))));
            jobRows = jobRows.slice(0, Math.min(jobTotal, previousRows.length));
          } else {
            jobRows = reset ? rows : jobRows.concat(rows);
          }
          jobTotal = Math.max(jobRows.length, jobTotal);
          renderJobs();
          scheduleJobPoll();
        } finally {
          if (revision === jobRevision) {
            jobLoading = false;
            if (more) more.disabled = false;
          }
        }
      };
      const loadBackups = async (reset = true) => {
        if (backupLoading && !reset) return;
        backupLoading = true;
        const revision = reset ? ++backupRevision : backupRevision;
        const more = byID('backup-load-more');
        if (more) more.disabled = true;
        try {
          const parameters = new URLSearchParams({
            offset:String(reset ? 0 : backupRows.length),
            limit:'50'
          });
          const kind = byID('backup-kind')?.value || '';
          if (kind) parameters.set('kind', kind);
          const result = await requestJSON(`/api/v1/admin/backups?${parameters}`);
          if (revision !== backupRevision) return;
          const rows = Array.isArray(result.value) ? result.value : [];
          backupRows = reset ? rows : backupRows.concat(rows);
          const total = Number(result.response.headers.get('X-MediaLIB-Total-Count'));
          backupTotal = Number.isFinite(total) ? Math.max(backupRows.length, total) : backupRows.length;
          renderBackups();
        } finally {
          if (revision === backupRevision) {
            backupLoading = false;
            if (more) more.disabled = false;
          }
        }
      };
      const loadStorage = async () => {
        await Promise.all([loadBackups(true), loadJobs(true)]);
        facts(byID('storage-protected'), [['恢复', '密码确认 · 预检 · 自动回滚'], ['缓存清理', '后台有界任务'], ['诊断导出', '仅能力、计数与稳定结果码']]);
      };
      const loadAudit = async (reset = true) => {
        if (logLoading && !reset) return;
        logLoading = true;
        const revision = reset ? ++logRevision : logRevision;
        const more = byID('audit-load-more');
        if (more) more.disabled = true;
        try {
          const endpoint = content.dataset.section === 'logs' ? '/api/v1/admin/logs' : '/api/v1/admin/security-events';
          const parameters = new URLSearchParams({offset:String(reset ? 0 : logEvents.length),limit:'50'});
          if (content.dataset.section === 'logs') {
            const category = byID('log-category')?.value || '';
            const outcome = byID('log-outcome')?.value || '';
            const query = (byID('log-search')?.value || '').trim();
            if (category) parameters.set('category', category);
            if (outcome) parameters.set('outcome', outcome);
            if (query) parameters.set('q', query);
          }
          const payload = (await requestJSON(`${endpoint}?${parameters}`)).value;
          if (revision !== logRevision) return;
          const events = Array.isArray(payload?.events) ? payload.events : [];
          logEvents = reset ? events : logEvents.concat(events);
          logTotal = Math.max(logEvents.length, Number(payload?.totalCount) || 0);
          renderLogs();
        } finally {
          if (revision === logRevision) {
            logLoading = false;
            if (more) more.disabled = false;
          }
        }
      };
      const loadDashboard = async () => {
        const dashboard = (await requestJSON('/api/v1/admin/dashboard')).value;
        if (content.dataset.section === 'network') {
          const runtime = dashboard.runtime || {};
          hostControlAvailable = runtime.hostControlAvailable === true;
          setInput('network-name', dashboard.serverName || 'MediaLIB');
          setInput('network-port', runtime.configuredPort || 8098);
          setInput('network-mode', runtime.listenerMode || 'loopback');
          setInput('network-origin', runtime.publicOrigin || '');
          setInput('network-proxies', Array.isArray(runtime.trustedProxyAddresses) ? runtime.trustedProxyAddresses.join(', ') : '');
          const applyButton = byID('network-apply');
          const password = byID('network-password');
          if (applyButton) applyButton.disabled = !hostControlAvailable;
          if (password) password.disabled = !hostControlAvailable;
          facts(byID('network-readiness'), [
            ['服务器', dashboard.serverName || 'MediaLIB'],
            ['服务版本', runtime.serviceVersion || '—'],
            ['API', dashboard.apiVersion || '—'],
            ['运行时间', formatUptime(runtime.uptimeSeconds)],
            ['数据库', runtime.databaseAccessible ? `可访问 · ${formatBytes(runtime.databaseByteLength)}` : '不可访问'],
            ['可用磁盘', runtime.availableDiskByteLength == null ? '—' : formatBytes(runtime.availableDiskByteLength)],
            ['FFmpeg / ffprobe', `${runtime.ffmpegAvailable ? '可用' : '不可用'} / ${runtime.ffprobeAvailable ? '可用' : '不可用'}`],
            ['VideoToolbox', `${runtime.videoToolboxH264Available ? 'H.264' : '—'} · ${runtime.videoToolboxHEVCAvailable ? 'HEVC' : '—'}`],
            ['LAN HTTPS', dashboard.lan?.isReady ? '已就绪' : '未就绪'],
            ['明文 LAN', '始终关闭']
          ]);
          facts(byID('network-host-control'), [
            ['监听模式', runtime.listenerMode || '—'],
            ['运行模式', runtime.hostControlAvailable ? '宿主管理' : '只读'],
            ['配置应用', runtime.hostControlAvailable ? '安全通道可用' : '需要桌面宿主'],
            ['近期安全事件', dashboard.recentSecurityEventCount ?? 0]
          ]);
          updateNetworkFieldAvailability();
        }
      };
      const updateNetworkFieldAvailability = () => {
        const isLAN = byID('network-mode')?.value === 'lan-https';
        for (const id of ['network-origin','network-proxies']) {
          const input = byID(id);
          if (input) input.disabled = isLAN;
        }
      };
      const networkRequestBody = includePassword => ({
        ...(includePassword ? {currentPassword:byID('network-password')?.value || ''} : {}),
        serverName:(byID('network-name')?.value || '').trim(),
        port:Number(byID('network-port')?.value),
        networkAccessMode:byID('network-mode')?.value || 'loopback',
        publicOrigin:byID('network-mode')?.value === 'lan-https' ? null : ((byID('network-origin')?.value || '').trim() || null),
        trustedProxyAddresses:byID('network-mode')?.value === 'lan-https' ? [] : (byID('network-proxies')?.value || '').split(',').map(value => value.trim()).filter(Boolean)
      });
      async function load() {
        refresh.disabled = true;
        const section = content.dataset.section || '';
        try {
          if (section === 'playback') await loadPlayback();
          else if (section === 'jobs') await loadJobs(true);
          else if (section === 'storage') await loadStorage();
          else if (section === 'security' || section === 'logs') await loadAudit();
          else await loadDashboard();
          setMessage('管理数据已刷新。');
        } catch (_) {
          setMessage('当前无法读取此页数据，安全边界保持不变。', true);
        } finally { refresh.disabled = false; }
      }
      byID('playback-settings-form')?.addEventListener('submit', async event => {
        event.preventDefault();
        const button = byID('playback-save');
        if (!settingsETag || !button) return;
        button.disabled = true;
        const number = id => Number(byID(id)?.value);
        const body = {
          schemaVersion:1,
          transcodeEngine:byID('setting-engine')?.value,
          maximumTranscodeSessions:number('setting-concurrency'),
          defaultRemoteBitrateMbps:number('setting-bitrate'),
          temporaryStorageLimitGB:number('setting-temp'),
          minimumFreeDiskGB:number('setting-free'),
          sessionIdleMinutes:number('setting-idle'),
          telemetryRetentionHours:number('setting-retention')
        };
        try {
          const result = await requestJSON('/api/v1/admin/settings', {
            method:'PATCH',
            headers:{'Content-Type':'application/json','X-MediaLIB-CSRF':csrf,'If-Match':settingsETag},
            body:JSON.stringify(body)
          });
          settingsETag = result.response.headers.get('ETag') || settingsETag;
          setMessage('播放设置已保存；新会话将使用更新后的边界。');
          await loadPlayback();
        } catch (_) { setMessage('保存失败，可能已被另一个页面更新，请刷新后重试。', true); }
        finally { button.disabled = false; }
      });
      byID('network-mode')?.addEventListener('change', updateNetworkFieldAvailability);
      byID('network-validate')?.addEventListener('click', async event => {
        const button = event.currentTarget;
        button.disabled = true;
        try {
          const result = await requestJSON('/api/v1/admin/runtime/validate', {
            method:'POST', headers:{'Content-Type':'application/json','X-MediaLIB-CSRF':csrf},
            body:JSON.stringify(networkRequestBody(false))
          });
          const issues = Array.isArray(result.value?.issueCodes) ? result.value.issueCodes : [];
          setMessage(issues.length === 0 ? '配置校验通过；应用时仍需当前密码与宿主健康检查。' : `配置未通过：${issues.join('、')}`, issues.length > 0);
        } catch (_) { setMessage('配置校验失败，请检查端口、HTTPS Origin 与可信代理。', true); }
        finally { button.disabled = false; }
      });
      byID('network-settings-form')?.addEventListener('submit', async event => {
        event.preventDefault();
        const button = byID('network-apply');
        const password = byID('network-password');
        if (!hostControlAvailable || !button || !password) return;
        if (!password.value) { setMessage('应用配置前请输入当前管理员密码。', true); password.focus(); return; }
        button.disabled = true;
        try {
          await requestJSON('/api/v1/admin/runtime/apply', {
            method:'POST', headers:{'Content-Type':'application/json','X-MediaLIB-CSRF':csrf},
            body:JSON.stringify(networkRequestBody(true))
          });
          password.value = '';
          setMessage('宿主已接受配置；正在重启并执行健康检查，失败时会自动回滚。');
          window.setTimeout(() => { void load(); }, 2500);
        } catch (_) { setMessage('配置未应用；密码、宿主通道或健康预检未通过。', true); }
        finally { button.disabled = !hostControlAvailable; }
      });
      const createTask = async kind => {
        try {
          await requestJSON('/api/v1/admin/jobs', {
            method:'POST', headers:{'Content-Type':'application/json','X-MediaLIB-CSRF':csrf},
            body:JSON.stringify({kind})
          });
          setMessage('任务已进入有界队列。');
          await loadJobs(true);
        } catch (_) { setMessage('任务未能入队，请检查权限或稍后重试。', true); }
      };
      byID('task-scan')?.addEventListener('click', () => void createTask('library.scan'));
      byID('task-reindex')?.addEventListener('click', () => void createTask('library.reindex'));
      byID('task-metadata')?.addEventListener('click', () => void createTask('metadata.refresh'));
      let backupConfirmationTimer = null;
      let restoreConfirmationTimer = null;
      const beginRestore = async (backupID, button) => {
        if (!/^[0-9a-f]{32}$/.test(backupID)) return;
        const password = byID('restore-password');
        if (!password?.value) {
          setMessage('恢复前请输入当前管理员密码。', true);
          password?.focus();
          return;
        }
        if (button.dataset.confirm !== 'true') {
          button.dataset.confirm = 'true';
          button.textContent = '再次点击恢复';
          setMessage('再次点击以确认恢复此备份；当前数据库会先创建安全快照。');
          if (restoreConfirmationTimer !== null) window.clearTimeout(restoreConfirmationTimer);
          restoreConfirmationTimer = window.setTimeout(() => {
            button.dataset.confirm = 'false';
            button.textContent = '恢复';
          }, 5000);
          return;
        }
        button.dataset.confirm = 'false';
        button.disabled = true;
        button.textContent = '正在预检…';
        try {
          await requestJSON(`/api/v1/admin/backups/${encodeURIComponent(backupID)}/restore`, {
            method:'POST',
            headers:{'Content-Type':'application/json','X-MediaLIB-CSRF':csrf},
            body:JSON.stringify({currentPassword:password.value})
          });
          password.value = '';
          setMessage('恢复任务已提交；完成后现有登录可能失效。失败时服务会自动恢复操作前数据库。');
          window.setTimeout(() => { void loadJobs(true); }, 250);
        } catch (_) { setMessage('恢复未提交：密码、备份预检或服务状态未通过。', true); }
        finally { button.disabled = false; button.textContent = '恢复'; }
      };
      byID('backup-create')?.addEventListener('click', async event => {
        const button = event.currentTarget;
        if (button.dataset.confirm !== 'true') {
          button.dataset.confirm = 'true';
          button.textContent = '再次点击创建备份';
          setMessage('再次点击以确认创建数据库备份。');
          if (backupConfirmationTimer !== null) window.clearTimeout(backupConfirmationTimer);
          backupConfirmationTimer = window.setTimeout(() => {
            button.dataset.confirm = 'false';
            button.textContent = '创建备份';
          }, 5000);
          return;
        }
        button.dataset.confirm = 'false';
        button.textContent = '正在创建…';
        button.disabled = true;
        try {
          await requestJSON('/api/v1/admin/backups', {
            method:'POST', headers:{'X-MediaLIB-CSRF':csrf}
          });
          setMessage('备份任务已提交。');
          window.setTimeout(() => { void loadStorage(); }, 400);
        } catch (_) { setMessage('备份任务提交失败。', true); }
        finally { button.disabled = false; button.textContent = '创建备份'; }
      });
      let cacheConfirmationTimer = null;
      byID('cache-clear')?.addEventListener('click', async event => {
        const button = event.currentTarget;
        if (button.dataset.confirm !== 'true') {
          button.dataset.confirm = 'true';
          button.textContent = '再次点击终止会话并清理';
          setMessage('再次点击以确认终止当前转码会话并清理缓存。');
          if (cacheConfirmationTimer !== null) window.clearTimeout(cacheConfirmationTimer);
          cacheConfirmationTimer = window.setTimeout(() => {
            button.dataset.confirm = 'false';
            button.textContent = '清理转码缓存';
          }, 5000);
          return;
        }
        button.dataset.confirm = 'false';
        button.disabled = true;
        button.textContent = '正在提交…';
        try {
          await requestJSON('/api/v1/admin/storage/transcode-cache', {
            method:'DELETE', headers:{'X-MediaLIB-CSRF':csrf}
          });
          setMessage('缓存清理已进入后台队列；受影响的转码会话将安全终止。');
          window.setTimeout(() => { void loadJobs(true); }, 250);
        } catch (_) { setMessage('缓存清理未能提交。', true); }
        finally { button.disabled = false; button.textContent = '清理转码缓存'; }
      });
      const resetAudit = () => { void loadAudit(true); };
      byID('log-search-form')?.addEventListener('submit', event => { event.preventDefault(); resetAudit(); });
      byID('log-category')?.addEventListener('change', resetAudit);
      byID('log-outcome')?.addEventListener('change', resetAudit);
      byID('audit-load-more')?.addEventListener('click', () => { void loadAudit(false); });
      const resetJobs = () => { void loadJobs(true); };
      byID('task-search-form')?.addEventListener('submit', event => { event.preventDefault(); resetJobs(); });
      byID('task-kind')?.addEventListener('change', resetJobs);
      byID('task-state')?.addEventListener('change', resetJobs);
      byID('storage-job-state')?.addEventListener('change', resetJobs);
      byID('task-load-more')?.addEventListener('click', () => { void loadJobs(false); });
      byID('storage-job-load-more')?.addEventListener('click', () => { void loadJobs(false); });
      byID('backup-kind')?.addEventListener('change', () => { void loadBackups(true); });
      byID('backup-load-more')?.addEventListener('click', () => { void loadBackups(false); });
      refresh.addEventListener('click', load);
      load();
    })();
    """#
}
