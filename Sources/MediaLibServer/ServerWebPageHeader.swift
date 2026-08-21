import Foundation

/// The single page-header contract.
///
/// Previously five pages used this component while eight rolled their own
/// heading, so the title size, the eyebrow, the action placement and the back
/// link differed from page to page.  Every authenticated page now renders through
/// here, which also gives breadcrumbs, a back affordance and a primary-action
/// slot one consistent position.
///
/// The header's icon comes from `ServerWebIcon`, the product's one icon family.
/// The previous 48×48 filled, multi-colour set — with its own hardcoded blue
/// gradient and pink and orange accents — was a second visual language that
/// existed for these headings alone and matched nothing else on screen.
enum ServerWebPageHeader {
    /// Kept as a thin alias so existing call sites read the same, while the
    /// artwork is shared with the sidebar and every other surface.
    enum Icon {
        case library, queue, status, account, sources, administration, people, collections, photos, series
        case home, music, playlist, search, favorites, watchlist, ratings, history, vault
        /// The mediums a scoped category page can name.  Without these a category
        /// page had to reach outside this family for its glyph.
        case movie, anime, documentary, variety, otherVideo

        /// The same family glyph, exposed so a page's empty state can use the
        /// icon that identifies it rather than one generic mark.
        var emptyStateGlyph: ServerWebIcon { glyph }

        fileprivate var glyph: ServerWebIcon {
            switch self {
            case .library: return .library
            case .queue: return .queue
            case .status: return .dashboard
            case .account: return .settings
            case .sources: return .source
            case .administration: return .users
            case .people: return .people
            case .collections: return .collections
            case .photos: return .photos
            case .series: return .series
            case .home: return .home
            case .music: return .music
            case .playlist: return .playlist
            case .search: return .search
            case .favorites: return .heart
            case .watchlist: return .bookmark
            case .ratings: return .star
            case .history: return .history
            case .vault: return .vault
            case .movie: return .film
            case .anime: return .anime
            case .documentary: return .documentary
            case .variety: return .show
            case .otherVideo: return .video
            }
        }
    }

    /// - Parameters:
    ///   - breadcrumb: Rendered only from three levels deep, where orientation
    ///     actually needs help; a two-item trail is noise beside the sidebar,
    ///     which already shows the section.
    ///   - back: A real link, so it deep-links, middle-clicks and shows its target
    ///     in the status bar — unlike a scripted history hop.
    ///   - actions: Pre-rendered controls. The emphasised one goes last so the
    ///     primary action sits in the same place on every page.
    ///   - search: A `ServerWebUI.searchField`. It leads the trailing slot, so
    ///     search sits in one fixed place across the product instead of floating
    ///     mid-page on some views and being absent on others.
    ///   - countID: The live item count, appended to the subtitle as " · 128 项"
    ///     exactly as the client writes it. Pages used to put this in six
    ///     different places — a heading below the filters, a span inside a
    ///     toolbar, a loose paragraph — so the same fact appeared at a different
    ///     spot on every view. Keep each page's existing element id here: the
    ///     page scripts already address it.
    ///   - iconOverride: Pre-escaped markup replacing the family glyph, for the
    ///     one case that genuinely has no glyph — a person's monogram.
    static func render(
        icon: Icon,
        eyebrow: String,
        title: String,
        subtitle: String,
        countID: String? = nil,
        countUnit: String = "项",
        initialCount: Int? = nil,
        breadcrumb: [(label: String, href: String?)] = [],
        back: (label: String, href: String)? = nil,
        search: String = "",
        actions: String = "",
        titleID: String = "page-title",
        iconID: String? = nil,
        iconOverride: String? = nil
    ) -> String {
        let crumbs = ServerWebUI.breadcrumb(breadcrumb)
        let backLink = back.map { ServerWebUI.backLink($0.label, href: $0.href) } ?? ""
        let countMarkup: String = {
            guard let countID else { return "" }
            let text = initialCount.map { " · \($0) \(countUnit)" } ?? ""
            return #"""
            <span class="app-subtitle-count t-numeric" id="\#(ServerWebHTML.escape(countID))" \#
            role="status" aria-live="polite">\#(ServerWebHTML.escape(text))</span>
            """#
        }()
        let subtitleMarkup = subtitle.isEmpty && countMarkup.isEmpty
            ? ""
            : #"<p class="app-subtitle">\#(ServerWebHTML.escape(subtitle))\#(countMarkup)</p>"#
        let eyebrowMarkup = eyebrow.isEmpty
            ? ""
            : #"<p class="app-eyebrow">\#(ServerWebHTML.escape(eyebrow))</p>"#
        let trailing = search + actions
        let actionsMarkup = trailing.isEmpty ? "" : #"<div class="app-page-actions">\#(trailing)</div>"#
        // 人物详情页用姓名首字母代替字形，所以底板要能装下一段文字而不只是
        // 一枚 svg——`iconOverride` 走的就是这条路。
        let glyph = iconOverride ?? ServerWebIcon.render(icon.glyph, size: .lg, variant: .duotone)

        return """
        <header class="app-page-head" aria-labelledby="\(titleID)">
          \(backLink)\(crumbs)
          <div class="app-page-head-main">
            <div class="app-page-head-copy">
              <div class="app-page-identity">
                <span class="ui-icon-tile ui-icon-tile-lg ui-icon-tile-tint app-page-icon"\(ServerWebHTML.attribute("id", iconID)) aria-hidden="true">\(glyph)</span>
                <div>\(eyebrowMarkup)<h1 id="\(titleID)">\(ServerWebHTML.escape(title))</h1></div>
              </div>
              \(subtitleMarkup)
            </div>
            \(actionsMarkup)
          </div>
        </header>
        """
    }
}
