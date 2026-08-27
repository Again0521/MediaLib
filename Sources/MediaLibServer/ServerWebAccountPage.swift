import Foundation
import MediaLibServerProtocol

/// 当前认证用户自己的账户页。个人资料由受权 API 读取，注销只撤销当前会话；网页从不
/// 读取 Cookie、令牌或其它用户资料。
enum ServerWebAccountPage {
    static func render(serverName: String, csrfToken: String, showAdministration: Bool, categories: [ServerLibraryCategory] = [], sidebarExtras: ServerWebSidebarExtras) -> String {
        let sidebar = ServerWebNavigation.render(
            active: .account, showAdministration: showAdministration, note: .none, categories: categories,
            extras: sidebarExtras
        )
        let administrationEntry = showAdministration
            ? ServerWebUI.linkButton("管理控制台", href: "/admin", variant: .secondary, icon: .dashboard)
            : ""
        let content = """
        \(ServerWebPageHeader.render(
            icon: .account,
            eyebrow: "Account",
            title: "设置",
            subtitle: "你的账号，以及你能访问哪些内容。"
        ))
        <div class="account-stack">
          <section class="ui-card" aria-labelledby="profile-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="profile-title">登录身份</h2></div>
            <p id="profile-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite">正在加载账户资料…</p>
            <!-- 名字与用户名从两列定宽表格里搬出来，做成一张身份卡：这是这一页
                 唯一一处"这是谁"的信息，读者第一眼要看的就是它，不该和"已生效
                 权限"并列成 dl 里的第三行。首字母底板由脚本填，不占服务端渲染。 -->
            <div id="profile" class="account-identity" hidden>
              <span id="account-monogram" class="ui-icon-tile ui-icon-tile-lg ui-icon-tile-tint account-monogram" aria-hidden="true"></span>
              <div class="account-identity-copy">
                <strong id="display-name" class="t-title-3">—</strong>
                <span id="username" class="t-callout t-tertiary">—</span>
              </div>
              <dl class="account-meta">
                <dt>角色</dt><dd id="roles" class="account-pills">—</dd>
                <dt>已生效权限</dt><dd id="permissions" class="account-pills">—</dd>
              </dl>
              \(administrationEntry)
            </div>
          </section>

          <section class="ui-card" aria-labelledby="personal-data-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="personal-data-title">我的数据</h2></div>
            <p class="t-footnote t-tertiary">这些记录只属于当前账号，其他用户看不到，也不会覆盖桌面端的全局状态。</p>
            <div class="account-personal-links">
              \(ServerWebUI.linkButton("我的评分", href: "/ratings", variant: .secondary, icon: .star))
              \(ServerWebUI.linkButton("播放历史", href: "/history", variant: .secondary, icon: .history))
              \(ServerWebUI.linkButton("播放队列", href: "/queue", variant: .secondary, icon: .queue))
            </div>
          </section>

          <section class="ui-card" aria-labelledby="preferences-title">
            <div class="ui-card-head">
              <div><h2 class="ui-card-title" id="preferences-title">播放与界面偏好</h2><p class="t-footnote t-tertiary">这些默认值跟随账号；当前媒体的手动音轨选择仍拥有最高优先级。</p></div>
              \(ServerWebUI.button("恢复升级前默认值", variant: .ghost, id: "preferences-reset"))
            </div>
            <form id="preferences-form" class="account-preferences">
              <div class="account-preference-grid">
                \(selectField("界面语言", id: "pref-language", options: [("", "自动（浏览器语言）"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English")]))
                \(selectField("主题", id: "pref-appearance", options: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]))
                \(selectField("首页默认入口", id: "pref-landing", options: [("/", "首页"), ("/watching", "继续观看"), ("/category/video", "视频"), ("/music/songs", "音乐"), ("/albums", "相册")]))
                \(selectField("内容密度", id: "pref-density", options: [("comfortable", "舒适"), ("compact", "紧凑")]))
                \(selectField("动效", id: "pref-motion", options: [("system", "跟随系统"), ("reduced", "减少动态效果")]))
                \(selectField("默认画质", id: "pref-quality", options: [("auto", "自动"), ("original", "原画"), ("2160p", "2160p"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p")]))
                \(textField("首选音频语言", id: "pref-audio-language", placeholder: "自动，例如 zh-Hans"))
                \(textField("首选字幕语言", id: "pref-subtitle-language", placeholder: "自动，例如 en"))
                \(numberField("远程码率上限（Mbps）", id: "pref-bitrate", min: 1, max: 200, placeholder: "自动"))
                \(selectField("字幕启用规则", id: "pref-subtitle-mode", options: [("off", "关闭"), ("manual", "手动"), ("foreignAudio", "仅外语音频"), ("always", "始终"), ("preferForced", "优先强制字幕")]))
                \(selectField("SDH 偏好", id: "pref-sdh", options: [("automatic", "自动"), ("prefer", "优先 SDH"), ("avoid", "避免 SDH")]))
              </div>
              <fieldset class="account-toggle-list">
                <legend class="ui-label">播放行为</legend>
                \(toggle("自动连播下一集", id: "pref-autoplay"))
                \(toggle("从上次位置继续播放", id: "pref-resume"))
                \(toggle("记住媒体与剧集的音轨选择", id: "pref-remember-tracks"))
              </fieldset>
              <fieldset class="subtitle-style-fields">
                <legend class="ui-label">字幕样式</legend>
                <div class="account-preference-grid">
                  \(selectField("字体", id: "pref-subtitle-font", options: [("system", "系统字体"), ("sansSerif", "无衬线"), ("serif", "衬线"), ("monospace", "等宽")]))
                  \(numberField("字号（%）", id: "pref-subtitle-scale", min: 75, max: 200, placeholder: "100"))
                  \(selectField("字重", id: "pref-subtitle-weight", options: [("400", "常规"), ("500", "中等"), ("600", "半粗"), ("700", "粗体"), ("800", "特粗")]))
                  <div class="ui-field"><label class="ui-label" for="pref-subtitle-color">文字颜色</label><input class="ui-input account-color" id="pref-subtitle-color" type="color" value="#FFFFFF"></div>
                  \(numberField("背景透明度（%）", id: "pref-subtitle-background", min: 0, max: 100, placeholder: "55"))
                  \(selectField("边缘效果", id: "pref-subtitle-edge", options: [("none", "无"), ("shadow", "阴影"), ("outline", "描边")]))
                  \(numberField("垂直位置（%）", id: "pref-subtitle-position", min: 60, max: 95, placeholder: "88"))
                </div>
                <div class="subtitle-preview" aria-label="字幕样式预览"><span id="subtitle-preview-text">MediaLIB 字幕预览 · Subtitle Preview</span></div>
                <p class="ui-help">WebVTT 与转换后的 ASS 可使用此样式；PGS、VobSub 等图形字幕不可重绘，选择后需要烧录转码。</p>
              </fieldset>
              <div class="account-preference-actions">\(ServerWebUI.button("保存偏好", variant: .primary, icon: .check, id: "preferences-submit", type: "submit"))</div>
              <p id="preferences-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite">正在加载偏好…</p>
            </form>
          </section>

          <section class="ui-card" aria-labelledby="password-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="password-title">修改密码</h2></div>
            <p class="t-footnote t-tertiary">验证当前密码后，所有已登录设备都会退出；请使用新密码重新登录。</p>
            <form id="change-password" class="account-form">
              <div class="ui-field">
                <label class="ui-label" for="current-password">当前密码</label>
                <input class="ui-input" id="current-password" type="password" autocomplete="current-password" maxlength="1024" required>
              </div>
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="new-password">新密码</label>
                <input class="ui-input" id="new-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required aria-describedby="new-password-help">
                <p class="ui-help" id="new-password-help">至少 12 个字符。</p>
              </div>
              <div class="ui-field">
                <label class="ui-label ui-label-required" for="confirm-password">确认新密码</label>
                <input class="ui-input" id="confirm-password" type="password" autocomplete="new-password" minlength="12" maxlength="1024" required>
              </div>
              \(ServerWebUI.button("修改密码并退出所有设备", variant: .primary, icon: .key, id: "change-password-submit", type: "submit"))
              <p id="password-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite"></p>
            </form>
          </section>

          <section class="ui-card" aria-labelledby="logout-title">
            <div class="ui-card-head"><h2 class="ui-card-title" id="logout-title">当前设备</h2></div>
            <p class="t-footnote t-tertiary">退出只会撤销当前浏览器会话；其它设备仍可在服务管理页按权限单独处理。</p>
            <div class="account-actions">\(ServerWebUI.button("退出当前账户", variant: .destructive, icon: .logout, id: "logout"))</div>
            <p id="logout-state" class="ui-state-line account-state t-footnote t-tertiary" role="status" aria-live="polite"></p>
          </section>
        </div>
        """
        return ServerWebDocument.render(
            title: "设置",
            serverName: serverName,
            csrfToken: csrfToken,
            sidebar: sidebar,
            content: content,
            pageStylesheets: ["/assets/account.css"],
            pageScripts: ["/assets/overlays.js", "/assets/account.js"],
            tint: .admin
        )
    }

    private static func selectField(_ label: String, id: String, options: [(String, String)]) -> String {
        let markup = options.map { #"<option value="\#(ServerWebHTML.escape($0.0))">\#(ServerWebHTML.escape($0.1))</option>"# }.joined()
        return #"<div class="ui-field"><label class="ui-label" for="\#(id)">\#(ServerWebHTML.escape(label))</label><select class="ui-select" id="\#(id)">\#(markup)</select></div>"#
    }

    private static func textField(_ label: String, id: String, placeholder: String) -> String {
        #"<div class="ui-field"><label class="ui-label" for="\#(id)">\#(ServerWebHTML.escape(label))</label><input class="ui-input" id="\#(id)" type="text" maxlength="35" placeholder="\#(ServerWebHTML.escape(placeholder))"></div>"#
    }

    private static func numberField(_ label: String, id: String, min: Int, max: Int, placeholder: String) -> String {
        #"<div class="ui-field"><label class="ui-label" for="\#(id)">\#(ServerWebHTML.escape(label))</label><input class="ui-input" id="\#(id)" type="number" min="\#(min)" max="\#(max)" inputmode="numeric" placeholder="\#(placeholder)"></div>"#
    }

    private static func toggle(_ label: String, id: String) -> String {
        #"<label class="account-toggle" for="\#(id)"><span>\#(ServerWebHTML.escape(label))</span><input id="\#(id)" type="checkbox"></label>"#
    }

    /// Cacheable account-page presentation. Identity and session data are fetched
    /// only through authenticated, non-cacheable endpoints.
    static let style = #"""
    /* Settings is a reading-and-editing page, so it keeps a narrow measure rather
       than stretching forms across the full content width. */
    .account-stack { display: grid; max-width: 760px; gap: var(--space-5); }

    .account-identity {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      align-items: center;
      gap: var(--space-3) var(--space-4);
    }
    .account-identity-copy { display: grid; min-width: 0; gap: 2px; }
    .account-monogram { font-size: var(--type-title2-size); font-weight: var(--weight-bold); }
    /* 角色与权限跨满整行落在名字下面：它们是这个人的属性，不是他的名字的一部分。 */
    .account-identity .account-meta { grid-column: 1 / -1; padding-top: var(--space-3); border-top: var(--hairline) solid var(--divider); }
    .account-identity > .ui-btn { grid-column: 1 / -1; justify-self: start; }
    .account-meta {
      display: grid;
      grid-template-columns: 120px minmax(0, 1fr);
      gap: var(--space-3) var(--space-4);
      font-size: var(--type-callout-size);
    }
    .account-meta dt { color: var(--text-tertiary); font-size: var(--type-subhead-size); }
    .account-meta dd { margin: 0; overflow-wrap: anywhere; }
    .account-pills { display: flex; flex-wrap: wrap; gap: var(--space-2); }

    .account-form { display: grid; gap: var(--space-4); max-width: 460px; }
    .account-form .ui-btn { justify-self: start; }
    .account-actions { display: flex; }
    .account-personal-links { display: flex; flex-wrap: wrap; gap: var(--space-2); }
    .account-preferences { display:grid; gap:var(--space-5); }
    .account-preference-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:var(--space-4); }
    .account-toggle-list, .subtitle-style-fields { display:grid; gap:var(--space-3); margin:0; padding:var(--space-4); border:var(--hairline) solid var(--border); border-radius:var(--radius-md); background:var(--surface-sunken); }
    .account-toggle-list legend, .subtitle-style-fields legend { padding:0 var(--space-2); }
    .account-toggle { display:flex; min-height:var(--control-height-lg); align-items:center; justify-content:space-between; gap:var(--space-4); cursor:pointer; }
    .account-toggle input { width:22px; height:22px; flex:none; accent-color:var(--accent); }
    .account-color { min-height:var(--control-height-lg); padding:6px; }
    .account-preference-actions { display:flex; }
    .subtitle-preview { position:relative; display:grid; min-height:180px; overflow:hidden; place-items:end center; padding:var(--space-5); border-radius:var(--radius-md); background:linear-gradient(150deg,#27313e,#080b10 64%); }
    .subtitle-preview::before { content:""; position:absolute; inset:0; background:radial-gradient(circle at 28% 20%,rgba(255,255,255,.18),transparent 36%); }
    #subtitle-preview-text { position:relative; max-width:92%; padding:.18em .45em; text-align:center; line-height:1.25; }

    @media (max-width: 719px) {
      .account-meta { grid-template-columns: minmax(0, 1fr); gap: var(--space-1); }
      .account-meta dt { margin-top: var(--space-2); }
      .account-preference-grid { grid-template-columns:minmax(0,1fr); }
      .account-form .ui-btn, .account-actions .ui-btn, .account-preference-actions .ui-btn { width: 100%; }
    }
    @media (prefers-contrast: more) { .subtitle-preview { border:2px solid currentColor; } }
    """#

    static let script = #"""
    (() => {
      'use strict';
      const byID = (id) => document.getElementById(id);
      const profileState = byID('profile-state');
      const profile = byID('profile');
      const logoutButton = byID('logout');
      const logoutState = byID('logout-state');
      const passwordForm = byID('change-password');
      const passwordSubmit = byID('change-password-submit');
      const passwordState = byID('password-state');
      const preferencesForm = byID('preferences-form');
      const preferencesSubmit = byID('preferences-submit');
      const preferencesReset = byID('preferences-reset');
      const preferencesState = byID('preferences-state');
      let preferencesVersion = 0;
      let preferenceDocument = null;
      const preferenceDefaults = {
        schemaVersion:1, interfaceLanguage:null, appearance:'system', defaultLandingPath:'/',
        homeSectionOrder:[], hiddenHomeSections:[], contentDensity:'comfortable', motion:'system',
        autoplayNext:true, resumePlayback:true, defaultQuality:'auto', remoteBitrateMbps:null,
        preferredAudioLanguage:null, preferredSubtitleLanguage:null, subtitleMode:'foreignAudio',
        subtitleSDHPreference:'automatic', rememberTrackSelections:true,
        subtitleStyle:{fontFamily:'system',fontScalePercent:100,fontWeight:600,textColor:'#FFFFFF',backgroundOpacityPercent:55,edgeStyle:'shadow',verticalPositionPercent:88}
      };
      const appendPills = (id, values, empty) => {
        const target = byID(id);
        target.replaceChildren();
        const items = Array.isArray(values) ? values.filter((value) => typeof value === 'string' && value.length <= 128) : [];
        if (!items.length) { target.textContent = empty; return; }
        items.forEach((value) => {
          const pill = document.createElement('span');
          pill.className = 'ui-chip';
          pill.textContent = value;
          target.append(pill);
        });
      };
      async function loadProfile() {
        try {
          const controller = new AbortController();
          const timer = window.setTimeout(() => controller.abort(), 10000);
          let response;
          try {
            response = await fetch('/api/v1/auth/me', { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: controller.signal });
          } finally { window.clearTimeout(timer); }
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('暂时读不到你的账号信息');
          const data = await response.json();
          if (typeof data.username !== 'string' || typeof data.displayName !== 'string') throw new Error('账号信息读取失败');
          byID('display-name').textContent = data.displayName;
          byID('username').textContent = `@${data.username}`;
          // 首字母而不是头像：产品里没有头像这回事，一个占位人形只是噪声。
          const initial = (data.displayName || data.username || '').trim().slice(0, 1).toUpperCase();
          byID('account-monogram').textContent = initial;
          appendPills('roles', data.roleIDs, '未分配角色');
          appendPills('permissions', data.permissionIDs, '没有额外权限');
          profile.hidden = false;
          profileState.textContent = '已更新。';
        } catch (error) {
          profileState.classList.add('error');
          profileState.textContent = error && error.message ? error.message : '暂时读不到你的账号信息。';
        }
      }
      const stringOrNull = (value) => {
        const normalized = String(value || '').trim().replace(/_/g, '-');
        return normalized ? normalized : null;
      };
      const setValue = (id, value) => { const field = byID(id); if (field) field.value = value == null ? '' : String(value); };
      function updateSubtitlePreview() {
        const preview = byID('subtitle-preview-text');
        if (!preview) return;
        const family = {system:'system-ui',sansSerif:'ui-sans-serif',serif:'ui-serif',monospace:'ui-monospace'}[byID('pref-subtitle-font').value] || 'system-ui';
        const scale = Math.min(200, Math.max(75, Number(byID('pref-subtitle-scale').value) || 100));
        const background = Math.min(100, Math.max(0, Number(byID('pref-subtitle-background').value) || 0)) / 100;
        const position = Math.min(95, Math.max(60, Number(byID('pref-subtitle-position').value) || 88));
        preview.style.fontFamily = family;
        preview.style.fontSize = `${scale}%`;
        preview.style.fontWeight = byID('pref-subtitle-weight').value || '600';
        preview.style.color = byID('pref-subtitle-color').value || '#FFFFFF';
        preview.style.backgroundColor = `rgba(0,0,0,${background})`;
        preview.style.transform = `translateY(${Math.round((88 - position) * 1.2)}px)`;
        const edge = byID('pref-subtitle-edge').value;
        preview.style.textShadow = edge === 'outline' ? '-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000' : edge === 'shadow' ? '0 2px 4px rgba(0,0,0,.95)' : 'none';
      }
      function hydratePreferences(value) {
        const source = value || preferenceDefaults;
        const style = source.subtitleStyle || preferenceDefaults.subtitleStyle;
        setValue('pref-language', source.interfaceLanguage);
        setValue('pref-appearance', source.appearance || 'system');
        setValue('pref-landing', source.defaultLandingPath || '/');
        setValue('pref-density', source.contentDensity || 'comfortable');
        setValue('pref-motion', source.motion || 'system');
        setValue('pref-quality', source.defaultQuality || 'auto');
        setValue('pref-bitrate', source.remoteBitrateMbps);
        setValue('pref-audio-language', source.preferredAudioLanguage);
        setValue('pref-subtitle-language', source.preferredSubtitleLanguage);
        setValue('pref-subtitle-mode', source.subtitleMode || 'foreignAudio');
        setValue('pref-sdh', source.subtitleSDHPreference || 'automatic');
        byID('pref-autoplay').checked = source.autoplayNext !== false;
        byID('pref-resume').checked = source.resumePlayback !== false;
        byID('pref-remember-tracks').checked = source.rememberTrackSelections !== false;
        setValue('pref-subtitle-font', style.fontFamily || 'system');
        setValue('pref-subtitle-scale', style.fontScalePercent ?? 100);
        setValue('pref-subtitle-weight', style.fontWeight ?? 600);
        setValue('pref-subtitle-color', style.textColor || '#FFFFFF');
        setValue('pref-subtitle-background', style.backgroundOpacityPercent ?? 55);
        setValue('pref-subtitle-edge', style.edgeStyle || 'shadow');
        setValue('pref-subtitle-position', style.verticalPositionPercent ?? 88);
        if (window.__medialibAppearance) window.__medialibAppearance.set(source.appearance === 'system' ? 'auto' : source.appearance);
        updateSubtitlePreview();
      }
      function preferencesFromForm() {
        const previous = preferenceDocument || preferenceDefaults;
        const bitrate = Number(byID('pref-bitrate').value);
        return {
          schemaVersion:1,
          interfaceLanguage:stringOrNull(byID('pref-language').value),
          appearance:byID('pref-appearance').value,
          defaultLandingPath:byID('pref-landing').value,
          homeSectionOrder:Array.isArray(previous.homeSectionOrder) ? previous.homeSectionOrder : [],
          hiddenHomeSections:Array.isArray(previous.hiddenHomeSections) ? previous.hiddenHomeSections : [],
          contentDensity:byID('pref-density').value,
          motion:byID('pref-motion').value,
          autoplayNext:byID('pref-autoplay').checked,
          resumePlayback:byID('pref-resume').checked,
          defaultQuality:byID('pref-quality').value,
          remoteBitrateMbps:Number.isFinite(bitrate) && bitrate > 0 ? bitrate : null,
          preferredAudioLanguage:stringOrNull(byID('pref-audio-language').value),
          preferredSubtitleLanguage:stringOrNull(byID('pref-subtitle-language').value),
          subtitleMode:byID('pref-subtitle-mode').value,
          subtitleSDHPreference:byID('pref-sdh').value,
          rememberTrackSelections:byID('pref-remember-tracks').checked,
          subtitleStyle:{
            fontFamily:byID('pref-subtitle-font').value,
            fontScalePercent:Number(byID('pref-subtitle-scale').value),
            fontWeight:Number(byID('pref-subtitle-weight').value),
            textColor:byID('pref-subtitle-color').value.toUpperCase(),
            backgroundOpacityPercent:Number(byID('pref-subtitle-background').value),
            edgeStyle:byID('pref-subtitle-edge').value,
            verticalPositionPercent:Number(byID('pref-subtitle-position').value)
          }
        };
      }
      async function loadPreferences() {
        try {
          const response = await fetch('/api/v1/me/preferences', {credentials:'same-origin',headers:{Accept:'application/json'}});
          if (response.status === 401) { window.location.assign('/login'); return; }
          if (!response.ok) throw new Error('暂时读不到偏好设置。');
          const data = await response.json();
          if (!data.account || !data.account.value || !Number.isInteger(data.account.version)) throw new Error('偏好数据格式不正确。');
          preferencesVersion = data.account.version;
          preferenceDocument = data.account.value;
          hydratePreferences(data.effective || data.account.value);
          preferencesState.textContent = data.device ? '已应用账号默认值和当前设备覆盖。' : '已应用账号默认值。';
        } catch (error) {
          preferencesState.classList.add('error');
          preferencesState.textContent = error && error.message ? error.message : '暂时读不到偏好设置。';
          hydratePreferences(preferenceDefaults);
        }
      }
      preferencesForm.addEventListener('input', updateSubtitlePreview);
      byID('pref-appearance').addEventListener('change', () => {
        const appearance = byID('pref-appearance').value;
        if (window.__medialibAppearance) window.__medialibAppearance.set(appearance === 'system' ? 'auto' : appearance);
      });
      preferencesReset.addEventListener('click', () => {
        preferenceDocument = {...preferenceDefaults, subtitleStyle:{...preferenceDefaults.subtitleStyle}};
        hydratePreferences(preferenceDocument);
        preferencesState.classList.remove('error');
        preferencesState.textContent = '已恢复为升级前默认值；点击“保存偏好”后同步到账号。';
      });
      preferencesForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { preferencesState.classList.add('error'); preferencesState.textContent = '请刷新页面后再试。'; return; }
        const value = preferencesFromForm();
        preferencesSubmit.disabled = true;
        preferencesState.classList.remove('error');
        preferencesState.textContent = '正在保存…';
        try {
          const response = await fetch('/api/v1/me/preferences', {
            method:'PATCH', credentials:'same-origin',
            headers:{'Accept':'application/json','Content-Type':'application/json','If-Match':`"${preferencesVersion}"`,'X-MediaLIB-CSRF':token},
            body:JSON.stringify(value)
          });
          if (response.status === 409) throw new Error('偏好已在另一页面更新，请刷新后重试。');
          if (!response.ok) throw new Error(response.status === 429 ? '操作太频繁了，等一会儿再试。' : '偏好没有保存。');
          const saved = await response.json();
          preferencesVersion = saved.version;
          preferenceDocument = saved.value;
          preferencesState.textContent = '偏好已保存。';
        } catch (error) {
          preferencesState.classList.add('error');
          preferencesState.textContent = error && error.message ? error.message : '偏好没有保存。';
        } finally { preferencesSubmit.disabled = false; }
      });
      logoutButton.addEventListener('click', async () => {
        if (!window.confirm('确定要退出登录吗？')) return;
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { logoutState.classList.add('error'); logoutState.textContent = '请刷新页面后再试。'; return; }
        logoutButton.disabled = true;
        logoutState.classList.remove('error');
        logoutState.textContent = '正在退出…';
        try {
          const response = await fetch('/api/v1/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'X-MediaLIB-CSRF': token } });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作太频繁了，等一会儿再试。' : '暂时退不出去。');
        } catch (error) {
          logoutState.classList.add('error');
          logoutState.textContent = error && error.message ? error.message : '没能退出，请稍后再试。';
          logoutButton.disabled = false;
        }
      });
      passwordForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        const currentField = byID('current-password');
        const newField = byID('new-password');
        const confirmField = byID('confirm-password');
        const currentPassword = currentField.value;
        const newPassword = newField.value;
        if (newPassword.length < 12 || newPassword !== confirmField.value) {
          passwordState.classList.add('error');
          passwordState.textContent = newPassword.length < 12 ? '新密码至少要 12 个字符。' : '两次输入的新密码不一致。';
          return;
        }
        const token = document.querySelector('meta[name="medialib-csrf-token"]')?.getAttribute('content');
        if (!token) { passwordState.classList.add('error'); passwordState.textContent = '请刷新页面后再试。'; return; }
        passwordSubmit.disabled = true;
        passwordState.classList.remove('error');
        passwordState.textContent = '正在更新密码…';
        try {
          const response = await fetch('/api/v1/auth/password', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json', 'X-MediaLIB-CSRF': token },
            body: JSON.stringify({ currentPassword, newPassword })
          });
          if (response.status === 401 || response.status === 204) { window.location.assign('/login'); return; }
          throw new Error(response.status === 429 ? '操作太频繁了，等一会儿再试。' : '没能改密码。确认一下当前密码是否输对了。');
        } catch (error) {
          passwordState.classList.add('error');
          passwordState.textContent = error && error.message ? error.message : '没能改密码，请稍后再试。';
          passwordSubmit.disabled = false;
        } finally {
          currentField.value = '';
          newField.value = '';
          confirmField.value = '';
        }
      });
      loadProfile();
      loadPreferences();
    })();
    """#

}
