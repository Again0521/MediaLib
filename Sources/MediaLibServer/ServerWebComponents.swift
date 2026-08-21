import Foundation

/// Server-side builders for the primitives in `ServerWebPrimitives`.
///
/// The CSS alone was not enough to stop drift: each page still hand-wrote its own
/// button and empty-state markup, so class names, icon placement and ARIA came
/// out slightly different every time.  Going through these builders makes the
/// correct markup the easy markup.
enum ServerWebUI {
    // MARK: - Buttons

    enum ButtonVariant: String {
        case primary = "ui-btn-primary"
        case secondary = "ui-btn-secondary"
        case tinted = "ui-btn-tinted"
        case ghost = "ui-btn-ghost"
        case destructive = "ui-btn-destructive"
    }

    enum ControlSize: String {
        case small = "ui-btn-sm"
        case medium = ""
        case large = "ui-btn-lg"
    }

    static func button(
        _ label: String,
        variant: ButtonVariant = .secondary,
        size: ControlSize = .medium,
        icon: ServerWebIcon? = nil,
        id: String? = nil,
        type: String = "button",
        disabled: Bool = false,
        extraClass: String = "",
        attributes: String = ""
    ) -> String {
        let classes = classList(["ui-btn", variant.rawValue, size.rawValue, extraClass])
        let glyph = icon.map { $0.html(size: .sm) } ?? ""
        return #"<button class="\#(classes)" type="\#(type)"\#(ServerWebHTML.attribute("id", id))\#(ServerWebHTML.flag("disabled", disabled))\#(attributes)>\#(glyph)<span>\#(ServerWebHTML.escape(label))</span></button>"#
    }

    /// An icon-only control must still say what it does: the label becomes the
    /// accessible name and the tooltip, never nothing at all.
    static func iconButton(
        _ icon: ServerWebIcon,
        label: String,
        variant: ButtonVariant = .ghost,
        size: ControlSize = .medium,
        id: String? = nil,
        type: String = "button",
        disabled: Bool = false,
        extraClass: String = "",
        attributes: String = ""
    ) -> String {
        let classes = classList(["ui-btn", "ui-btn-icon", variant.rawValue, size.rawValue, extraClass])
        let safeLabel = ServerWebHTML.escape(label)
        return #"<button class="\#(classes)" type="\#(type)" aria-label="\#(safeLabel)" title="\#(safeLabel)"\#(ServerWebHTML.attribute("id", id))\#(ServerWebHTML.flag("disabled", disabled))\#(attributes)>\#(icon.html(size: .md))</button>"#
    }

    static func linkButton(
        _ label: String,
        href: String,
        variant: ButtonVariant = .secondary,
        size: ControlSize = .medium,
        icon: ServerWebIcon? = nil,
        extraClass: String = "",
        attributes: String = ""
    ) -> String {
        let classes = classList(["ui-btn", variant.rawValue, size.rawValue, extraClass])
        let glyph = icon.map { $0.html(size: .sm) } ?? ""
        return #"<a class="\#(classes)" href="\#(ServerWebHTML.escape(href))"\#(attributes)>\#(glyph)<span>\#(ServerWebHTML.escape(label))</span></a>"#
    }

    // MARK: - Search

    /// The product's one search field.
    ///
    /// Search belongs in the page header's trailing slot, level with the title —
    /// the same place on every page — rather than as a loose block that each page
    /// positioned differently.  It stays inside a real `<form>` with a real
    /// `action`, so it still submits and deep-links if the page script never
    /// arrives; pages that filter live simply listen to the input.
    static func searchField(
        id: String,
        name: String = "q",
        label: String,
        placeholder: String,
        action: String,
        value: String = "",
        hiddenFields: [(name: String, value: String)] = [],
        formID: String? = nil,
        extraClass: String = ""
    ) -> String {
        let hidden = hiddenFields.map {
            #"<input type="hidden" name="\#(ServerWebHTML.escape($0.name))" value="\#(ServerWebHTML.escape($0.value))">"#
        }.joined()
        let classes = classList(["app-page-search", extraClass])
        let valueAttribute = value.isEmpty ? "" : #" value="\#(ServerWebHTML.escape(value))""#
        return #"""
        <form class="\#(classes)"\#(ServerWebHTML.attribute("id", formID)) action="\#(ServerWebHTML.escape(action))" method="get" role="search">\#(hidden)\#
        <label class="visually-hidden" for="\#(ServerWebHTML.escape(id))">\#(ServerWebHTML.escape(label))</label>\#
        <div class="ui-search">\#(ServerWebIcon.search.html(size: .sm))\#
        <input class="ui-input" id="\#(ServerWebHTML.escape(id))" name="\#(ServerWebHTML.escape(name))" type="search" \#
        maxlength="128" autocomplete="off"\#(valueAttribute) placeholder="\#(ServerWebHTML.escape(placeholder))"></div></form>
        """#
    }

    // MARK: - Filter bar

    /// One pill in a control bar's tray.
    ///
    /// `href` decides the backing: `nil` makes it a radio that filters the page in
    /// place, a value makes it an anchor that navigates.  Both render identically
    /// — see the `.ui-segmented` rules in `ServerWebPrimitives`.
    struct ControlChip {
        let label: String
        let value: String
        let href: String?
        let selected: Bool

        init(label: String, value: String = "", href: String? = nil, selected: Bool = false) {
            self.label = label
            self.value = value
            self.href = href
            self.selected = selected
        }
    }

    /// The product's one filter/sort row.
    ///
    /// Pages used to each grow their own: a bare `<form>` on the library, two
    /// stacked glass toolbars on music, a third shape on photos and a fourth on
    /// the queue — so the same three controls sat at three heights on three
    /// materials.  This mirrors the desktop client's `AppAdaptiveControlBar`: a
    /// card, a sunken tray of state pills, then the dropdowns pushed to the end.
    ///
    /// - Parameters:
    ///   - formID: When non-nil the bar renders as a `<form>`, so the filters
    ///     still submit and deep-link if the page script never arrives.
    ///   - chipsName: The radio group name.  Ignored when the chips carry `href`.
    static func controlBar(
        label: String,
        chipsLabel: String,
        chips: [ControlChip],
        chipsName: String = "",
        chipsGroupID: String? = nil,
        trailing: String = "",
        id: String? = nil,
        formID: String? = nil,
        extraClass: String = ""
    ) -> String {
        let items = chips.map { chip -> String in
            if let href = chip.href {
                let current = chip.selected ? #" aria-current="page""# : ""
                return #"<a href="\#(ServerWebHTML.escape(href))"\#(current)><span>\#(ServerWebHTML.escape(chip.label))</span></a>"#
            }
            let checked = chip.selected ? " checked" : ""
            return #"""
            <label><input type="radio" name="\#(ServerWebHTML.escape(chipsName))" value="\#(ServerWebHTML.escape(chip.value))"\#(checked)>\#
            <span>\#(ServerWebHTML.escape(chip.label))</span></label>
            """#
        }.joined()
        let tray = items.isEmpty ? "" : #"""
        <div class="ui-control-tray">\#
        <div class="ui-segmented"\#(ServerWebHTML.attribute("id", chipsGroupID)) role="group" aria-label="\#(ServerWebHTML.escape(chipsLabel))">\#(items)</div></div>
        """#
        let trailingMarkup = trailing.isEmpty ? "" : #"<div class="ui-control-bar-trailing">\#(trailing)</div>"#
        let classes = classList(["ui-control-bar", extraClass])
        let tag = formID == nil ? "section" : "form"
        let formAttributes = formID.map { #" id="\#(ServerWebHTML.escape($0))" role="search""# } ?? ""
        return #"""
        <\#(tag) class="\#(classes)"\#(ServerWebHTML.attribute("id", id))\#(formAttributes) aria-label="\#(ServerWebHTML.escape(label))">\#
        \#(tray)\#(trailingMarkup)</\#(tag)>
        """#
    }

    /// A labelled `<select>`.  The label is visually hidden because the control's
    /// own first option already names it ("全部类型"), and a floating label above a
    /// dropdown inside a single-row bar would double the bar's height.
    static func select(
        id: String,
        name: String,
        label: String,
        options: [(value: String, label: String, selected: Bool)],
        extraClass: String = ""
    ) -> String {
        let markup = options.map { option in
            let selected = option.selected ? " selected" : ""
            return #"<option value="\#(ServerWebHTML.escape(option.value))"\#(selected)>\#(ServerWebHTML.escape(option.label))</option>"#
        }.joined()
        let classes = classList(["ui-select", extraClass])
        return #"""
        <label class="visually-hidden" for="\#(ServerWebHTML.escape(id))">\#(ServerWebHTML.escape(label))</label>\#
        <select class="\#(classes)" id="\#(ServerWebHTML.escape(id))" name="\#(ServerWebHTML.escape(name))">\#(markup)</select>
        """#
    }

    /// Sort key plus direction.
    ///
    /// The client folds the direction into the same menu — choosing the selected
    /// mode again flips it — which a native `<select>` cannot express, since
    /// re-picking the current option fires no `change`.  So the key stays a
    /// `<select>` and the direction becomes its own toggle beside it; together
    /// they read as the client's "最近更新 · 正序".
    static func sortControl(
        selectID: String,
        orderButtonID: String,
        label: String = "排序",
        name: String = "sort",
        options: [(value: String, label: String, selected: Bool)],
        isReversed: Bool
    ) -> String {
        let orderLabel = isReversed ? "倒序" : "正序"
        let glyph = isReversed ? ServerWebIcon.arrowUp : ServerWebIcon.arrowDown
        return #"""
        <div class="ui-sort-control">\#
        \#(select(id: selectID, name: name, label: label, options: options))\#
        <button class="ui-sort-order" id="\#(ServerWebHTML.escape(orderButtonID))" type="button" \#
        aria-pressed="\#(isReversed ? "true" : "false")" aria-label="\#(orderLabel)" title="\#(orderLabel)">\#(glyph.html(size: .sm))</button></div>
        """#
    }

    // MARK: - Status & feedback

    enum Tone: String {
        case info, success, warning, error

        var alertClass: String {
            switch self {
            case .info: return ""
            case .success: return "ui-alert-success"
            case .warning: return "ui-alert-warning"
            case .error: return "ui-alert-error"
            }
        }

        var icon: ServerWebIcon {
            switch self {
            case .info: return .info
            case .success: return .checkCircle
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    /// An inline, persistent message.  Errors additionally take `role="alert"` so
    /// a screen reader announces them the moment they appear.
    /// 行内的、常驻的一条消息。
    ///
    /// 文案落在**内层**的 `.ui-alert-body` 上，并可以带自己的 id：脚本要更新这条
    /// 消息时写的是那个节点，而不是整块。往外层写 `textContent` 会把图标一起抹掉，
    /// 然后这条提示就退化成一行没有语气的字——两个页面此前各手搓一份 notice，
    /// 正是因为公共组件"看起来不好更新"。
    static func alert(
        _ tone: Tone,
        title: String? = nil,
        message: String,
        id: String? = nil,
        messageID: String? = nil,
        role: String? = nil,
        hidden: Bool = false
    ) -> String {
        let resolvedRole = role ?? ((tone == .error) ? "alert" : nil)
        let roleAttribute = ServerWebHTML.attribute("role", resolvedRole)
        let live = resolvedRole == "status" ? #" aria-live="polite""# : ""
        let heading = title.map { #"<span class="ui-alert-title">\#(ServerWebHTML.escape($0))</span> "# } ?? ""
        let classes = classList(["ui-alert", tone.alertClass])
        return #"<div class="\#(classes)"\#(ServerWebHTML.attribute("id", id))\#(roleAttribute)\#(live)\#(ServerWebHTML.flag("hidden", hidden))>\#(tone.icon.html(size: .md))<div class="ui-alert-body"\#(ServerWebHTML.attribute("id", messageID))>\#(heading)\#(ServerWebHTML.escape(message))</div></div>"#
    }

    /// An empty state names the cause and offers the next step.  A bare "no
    /// results" leaves someone stuck wondering whether the product is broken.
    static func emptyState(
        icon: ServerWebIcon,
        title: String,
        message: String,
        action: String? = nil,
        actionHref: String? = nil,
        id: String? = nil,
        hidden: Bool = false
    ) -> String {
        var cta = ""
        if let action, let actionHref {
            cta = linkButton(action, href: actionHref, variant: .primary, size: .medium)
        }
        return #"""
        <div class="ui-empty"\#(ServerWebHTML.attribute("id", id))\#(ServerWebHTML.flag("hidden", hidden))>\#
        \#(ServerWebIcon.tile(icon, size: .lg, tone: .quiet, extraClass: "ui-empty-icon"))\#
        <p class="ui-empty-title">\#(ServerWebHTML.escape(title))</p>\#
        <p class="ui-empty-body">\#(ServerWebHTML.escape(message))</p>\#(cta)</div>
        """#
    }

    static func statusPill(_ tone: Tone, _ label: String, id: String? = nil) -> String {
        let toneClass: String
        switch tone {
        case .success: toneClass = "ui-status-ok"
        case .warning: toneClass = "ui-status-warn"
        case .error: toneClass = "ui-status-error"
        case .info: toneClass = "ui-status-idle"
        }
        return #"<span class="ui-status \#(toneClass)"\#(ServerWebHTML.attribute("id", id))>\#(ServerWebHTML.escape(label))</span>"#
    }

    /// Placeholder cards shown while a grid loads.  They reserve the real card's
    /// footprint, so content arriving does not shove the page around.
    static func posterSkeletons(_ count: Int) -> String {
        (0..<max(0, count)).map { _ in
            #"""
            <div class="ui-media-card" aria-hidden="true">\#
            <div class="ui-skeleton ui-skeleton-poster"></div>\#
            <div class="ui-skeleton ui-skeleton-line"></div>\#
            <div class="ui-skeleton ui-skeleton-line-sm"></div></div>
            """#
        }.joined()
    }

    // MARK: - Structure

    /// 区块头。整个产品只有这一种。
    ///
    /// **出口挂在标题上，不是行尾。** 两个参考页（App Store「探索」、Apple Music
    /// 「新发现」）都是标题后面直接跟一个 `›`，点标题就进完整列表。行尾那条独立的
    /// 「更多」文本链接要读者先扫到标题、再横跨一整行去找出口，而那一行中间什么
    /// 都没有。`moreLabel`/`moreHref` 保留给确实需要具名尾链接的页面（例如概览
    /// 区块通往「仪表盘」——那不是"这一栏的完整列表"，是另一个地方）。
    ///
    /// `tint` 挂在区块头本身：底板、胶囊、徽章靠继承拿色，调用点只声明一次。
    static func sectionHeader(
        _ title: String,
        subtitle: String? = nil,
        icon: ServerWebIcon? = nil,
        tint: ServerWebIcon.Tint? = nil,
        titleID: String? = nil,
        href: String? = nil,
        moreLabel: String? = nil,
        moreHref: String? = nil
    ) -> String {
        var trailing = ""
        if let moreLabel, let moreHref {
            trailing = #"<a class="ui-section-more" href="\#(ServerWebHTML.escape(moreHref))">\#(ServerWebHTML.escape(moreLabel))\#(ServerWebIcon.chevronRight.html(size: .xs))</a>"#
        }
        let sub = subtitle.map { #"<p class="t-footnote t-tertiary">\#(ServerWebHTML.escape($0))</p>"# } ?? ""
        let idAttribute = ServerWebHTML.attribute("id", titleID)
        let heading: String
        if let href {
            heading = #"<h2\#(idAttribute)><a class="ui-section-link" href="\#(ServerWebHTML.escape(href))" data-native-navigation="true">\#(ServerWebHTML.escape(title))\#(ServerWebIcon.chevronRight.html(size: .md, extraClass: "ui-section-chevron"))</a></h2>"#
        } else {
            heading = #"<h2\#(idAttribute)>\#(ServerWebHTML.escape(title))</h2>"#
        }
        // 底板和标题是**一组**。多一个直接子元素，`space-between` 会把三样东西
        // 均分开，标题飘到行中央——`.ui-section-identity` 存在的原因就是这个。
        let identity = icon.map {
            #"<div class="ui-section-identity">\#(ServerWebIcon.tile($0, size: .sm, tone: .tint))<div>\#(heading)\#(sub)</div></div>"#
        } ?? #"<div class="ui-section-identity"><div>\#(heading)\#(sub)</div></div>"#
        return #"<div class="ui-section-head"\#(tint?.attribute ?? "")>\#(identity)\#(trailing)</div>"#
    }

    /// 外观切换器。产品里只有这一个。
    ///
    /// 它此前有两份：侧栏底部那三颗**没有任何 class** 的裸 button（靠
    /// `.app-appearance button` 这种后代选择器上样式），以及账户页那三颗
    /// `.ui-btn-secondary` 外加一条页面私有的选中态规则。同一个控件、两种外观、
    /// 两套选中态——而两边操作的是同一个存储键。
    ///
    /// `compact` 是侧栏那一档：只有图标，可读的名字走 `aria-label` + `title`。
    /// 两档共用 `.ui-segmented`，于是选中态也只有一份（凹托盘里的凸胶囊）。
    static func appearanceSwitcher(compact: Bool = false) -> String {
        let options: [(mode: String, label: String, icon: ServerWebIcon)] = [
            ("light", "浅色", .sun),
            ("dark", "深色", .moon),
            ("auto", "跟随系统", .display)
        ]
        let buttons = options.map { option -> String in
            let name = ServerWebHTML.escape(option.label)
            let glyph = option.icon.html(size: .sm)
            let text = compact ? "" : #"<span>\#(name)</span>"#
            let accessibleName = compact ? #" aria-label="\#(name)" title="\#(name)""# : ""
            return #"""
            <button type="button" data-appearance-mode="\#(option.mode)" \#
            role="radio" aria-checked="false"\#(accessibleName)>\#(glyph)\#(text)</button>
            """#
        }.joined()
        let classes = classList(["ui-segmented", "app-appearance", compact ? "ui-segmented-compact" : ""])
        return #"<div class="\#(classes)" role="radiogroup" aria-label="界面外观">\#(buttons)</div>"#
    }

    /// The back affordance used by every detail page.  It is a real link, so it
    /// deep-links and middle-clicks like one, rather than a scripted history hop.
    static func backLink(_ label: String, href: String) -> String {
        #"<a class="ui-btn ui-btn-ghost ui-btn-sm app-back" href="\#(ServerWebHTML.escape(href))">\#(ServerWebIcon.chevronLeft.html(size: .sm))<span>\#(ServerWebHTML.escape(label))</span></a>"#
    }

    static func breadcrumb(_ trail: [(label: String, href: String?)]) -> String {
        guard trail.count > 1 else { return "" }
        let items = trail.map { entry -> String in
            if let href = entry.href {
                return #"<li><a href="\#(ServerWebHTML.escape(href))">\#(ServerWebHTML.escape(entry.label))</a></li>"#
            }
            return #"<li aria-current="page">\#(ServerWebHTML.escape(entry.label))</li>"#
        }.joined()
        return #"<nav aria-label="面包屑"><ol class="ui-breadcrumb">\#(items)</ol></nav>"#
    }

    static func classList(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
