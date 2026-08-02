import Foundation

/// Shared ordinary-page heading used by the Web surface.
///
/// The homepage and expanded music page intentionally keep their own visual
/// language. Every other page gets the same 56px title illustration, eyebrow,
/// title and readable subtitle so the Web shell follows the desktop page
/// contract instead of accumulating one-off headings.
enum ServerWebPageHeader {
    enum Icon {
        case library, queue, status, account, sources, administration, people, collections, photos, series

        fileprivate var paths: String {
            switch self {
            case .library:
                return ##"<rect x="7" y="8" width="27" height="25" rx="4" fill="url(#page-icon-blue)"></rect><path d="M13 15h15M13 21h11" stroke="#fff" stroke-width="2.4" stroke-linecap="round"></path><path d="m9 37 7-4 7 4V20l-7-4-7 4Z" fill="#ff7f9f" opacity=".92"></path><path d="m16 23 3 2 3-2v8l-3-2-3 2Z" fill="#fff" opacity=".88"></path>"##
            case .queue:
                return ##"<path d="M10 8h25" stroke="url(#page-icon-blue)" stroke-width="5" stroke-linecap="round"></path><path d="M10 20h25" stroke="#36bffa" stroke-width="5" stroke-linecap="round"></path><path d="M10 32h17" stroke="#ff7f9f" stroke-width="5" stroke-linecap="round"></path><circle cx="7" cy="8" r="3" fill="#2e90fa"></circle><circle cx="7" cy="20" r="3" fill="#36bffa"></circle><circle cx="7" cy="32" r="3" fill="#ff7f9f"></circle>"##
            case .status:
                return ##"<path d="M6 28c4-13 8 8 12-6 3-10 6 6 12-5 2-4 4-5 7-5" fill="none" stroke="url(#page-icon-blue)" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"></path><circle cx="37" cy="12" r="5" fill="#ff7f9f"></circle><path d="m35 12 2 2 4-5" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>"##
            case .account:
                return ##"<circle cx="24" cy="17" r="9" fill="url(#page-icon-blue)"></circle><path d="M8 40c1-9 7-14 16-14s15 5 16 14" fill="#36bffa" opacity=".9"></path><circle cx="24" cy="17" r="4" fill="#fff" opacity=".86"></circle>"##
            case .sources:
                return ##"<rect x="7" y="8" width="34" height="11" rx="4" fill="url(#page-icon-blue)"></rect><rect x="7" y="25" width="34" height="11" rx="4" fill="#36bffa"></rect><circle cx="14" cy="13.5" r="2" fill="#fff"></circle><circle cx="14" cy="30.5" r="2" fill="#fff"></circle><path d="M20 13.5h14M20 30.5h14" stroke="#fff" stroke-width="2.2" stroke-linecap="round" opacity=".9"></path>"##
            case .administration:
                return ##"<circle cx="17" cy="17" r="8" fill="url(#page-icon-blue)"></circle><circle cx="33" cy="19" r="6" fill="#ff7f9f"></circle><path d="M5 40c1-8 6-12 12-12s11 4 12 12" fill="#36bffa"></path><path d="M28 30c7 0 11 3 12 10" fill="#ff9f45"></path>"##
            case .people:
                return ##"<circle cx="24" cy="15" r="9" fill="url(#page-icon-blue)"></circle><path d="M8 40c1-9 7-14 16-14s15 5 16 14" fill="#36bffa"></path><circle cx="24" cy="15" r="4" fill="#fff" opacity=".8"></circle>"##
            case .collections:
                return ##"<rect x="8" y="8" width="27" height="25" rx="4" fill="url(#page-icon-blue)"></rect><path d="M14 15h15M14 22h11" stroke="#fff" stroke-width="2.4" stroke-linecap="round"></path><path d="m35 15 6 5v17a3 3 0 0 1-3 3H17" fill="none" stroke="#ff7f9f" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"></path>"##
            case .photos:
                return ##"<rect x="6" y="10" width="36" height="28" rx="5" fill="url(#page-icon-blue)"></rect><circle cx="16" cy="19" r="3" fill="#fff"></circle><path d="m9 34 10-10 7 7 5-5 8 8" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"></path><path d="M13 6h10" stroke="#ff7f9f" stroke-width="4" stroke-linecap="round"></path>"##
            case .series:
                return ##"<rect x="7" y="8" width="34" height="28" rx="5" fill="url(#page-icon-blue)"></rect><path d="M13 16h22M13 22h16M13 28h10" stroke="#fff" stroke-width="2.4" stroke-linecap="round"></path><circle cx="35" cy="30" r="6" fill="#ff7f9f"></circle><path d="m33 27 5 3-5 3Z" fill="#fff"></path>"##
            }
        }
    }

    static func render(icon: Icon, eyebrow: String, title: String, subtitle: String) -> String {
        """
        <header class="page-heading" aria-labelledby="page-title">
          <span class="page-title-icon" aria-hidden="true"><svg viewBox="0 0 48 48" fill="none" overflow="visible"><defs><linearGradient id="page-icon-blue" x1="7" y1="7" x2="41" y2="40" gradientUnits="userSpaceOnUse"><stop stop-color="#2e90fa"></stop><stop offset="1" stop-color="#36bffa"></stop></linearGradient></defs>\(icon.paths)</svg></span>
          <div class="page-title-copy"><p class="eyebrow">\(escape(eyebrow))</p><h1 id="page-title">\(escape(title))</h1><p class="subtitle">\(escape(subtitle))</p></div>
        </header>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
