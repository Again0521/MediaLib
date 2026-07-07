#!/usr/bin/env python3
"""Check that the Swift home rewrite still tracks the bundled vivid home reference."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "MediaLIB 焕彩首页.html"
SWIFT_FILES = [
    ROOT / "Sources/MediaLib/Views/HomeVividComponents.swift",
    ROOT / "Sources/MediaLib/Views/HomeView.swift",
    ROOT / "Sources/MediaLib/Views/ContentView.swift",
    ROOT / "Sources/MediaLib/Views/PosterGridView.swift",
]

REQUIRED_HEX = [
    "2E90FA",
    "36BFFA",
    "22D3A8",
    "FF9F45",
    "FF5C8A",
    "D946EF",
    "1B2230",
    "8A93A6",
    "EEF1F6",
]

REQUIRED_REFERENCE_TEXT = [
    "欢迎回来",
    "为你精选",
    "今日精选",
    "运行状态",
    "继续观看 · 剧集",
    "剧集推荐",
    "最近添加 · 剧集",
    "音乐推荐",
    "继续听",
    "照片墙",
    "搜索全部媒体",
]

REQUIRED_SWIFT_SYMBOLS = [
    "HomeVividTokens",
    "HomeVividPageBackground",
    "HomeVividHeader",
    "HomeVividHeroCarousel",
    "HomeVividHero",
    "HomeVividStatsGrid",
    "HomeVividDashboard",
    "HomeVividPosterRow",
    "HomeVividMusicRecommendation",
    "HomeVividContinueListening",
    "HomeVividPhotoWall",
]


def normalized_hexes(text: str) -> set[str]:
    return {match.upper().lstrip("#") for match in re.findall(r"#[0-9a-fA-F]{6}\b", text)}


def main() -> int:
    missing_files = [str(path) for path in [REFERENCE, *SWIFT_FILES] if not path.exists()]
    if missing_files:
        print("FAILED: missing files:")
        for path in missing_files:
            print(f"  - {path}")
        return 1

    reference_text = REFERENCE.read_text(errors="replace")
    swift_text = "\n".join(path.read_text(errors="replace") for path in SWIFT_FILES)

    failures: list[str] = []

    reference_hexes = normalized_hexes(reference_text)
    swift_hexes = {token.upper() for token in re.findall(r'"([0-9a-fA-F]{6})"', swift_text)}
    for token in REQUIRED_HEX:
        if token not in reference_hexes:
            failures.append(f"reference HTML no longer contains color #{token}")
        if token not in swift_hexes:
            failures.append(f"Swift HomeVivid tokens missing #{token}")

    for text in REQUIRED_REFERENCE_TEXT:
        if text not in reference_text:
            failures.append(f"reference HTML missing text: {text}")
        if text not in swift_text:
            failures.append(f"Swift home implementation missing text: {text}")

    for symbol in REQUIRED_SWIFT_SYMBOLS:
        if symbol not in swift_text:
            failures.append(f"Swift home implementation missing symbol: {symbol}")

    if "PageHeader(title: greeting" in swift_text:
        failures.append("HomeView should not render the old PageHeader for the vivid home path")

    if "AlbumPaletteCache.palette(for: colorPath)" not in swift_text:
        failures.append("Home hero should derive its banner atmosphere from artwork palette")

    if "Timer.publish(every: 5" not in swift_text:
        failures.append("Home hero should keep the multi-page auto-rotating banner")

    if ".frame(height: 246)" not in swift_text:
        failures.append("Home hero should keep the taller 2/5-adjusted banner height")

    if "Text(\"今天，\")" not in swift_text or "今晚" in swift_text:
        failures.append("Home header and hero fallback copy should use today-aware wording, not evening-only copy")

    if ".overlay(alignment: .bottomTrailing)" not in swift_text or ".padding(.trailing, 18)" not in swift_text:
        failures.append("Home hero pagination should be a frameless bottom-right control")

    if "carouselButton(direction:" in swift_text:
        failures.append("Home hero should not show explicit previous/next arrow buttons")

    if "event.momentumPhase == []" not in swift_text or "lastManualStepAt" not in swift_text:
        failures.append("Home hero horizontal paging should suppress momentum and throttle one-step swipes")

    if "static let posterWidth: CGFloat = 158" not in swift_text:
        failures.append("Home poster cards should stay compact enough to fit more items")

    if "scaleEffect(active && !reduceMotion ? 1 : 0.55)" in swift_text:
        failures.append("Home poster cards should not reveal the old hover play button")

    if "Color.black.opacity(active ? 0.24 : 0.13)" in swift_text:
        failures.append("Home poster cards should not keep the default bottom shadow")

    if ".shadow(color: Color.black.opacity(0.12), radius: 26, y: 12)" in swift_text:
        failures.append("Home photo wall tiles should not keep the default bottom shadow")

    for token in [
        "HomeVividSourceGroup",
        "HomeVividTaskSummary",
        "sourceGroups: dashboardSourceGroups",
        "tasks: dashboardTaskSummaries",
        "媒体源健康度",
        "元数据健康度",
        "无任务",
    ]:
        if token not in swift_text:
            failures.append(f"Home dashboard missing redesigned status token: {token}")

    if ".prefix(30)" not in swift_text or "最近常听" not in swift_text:
        failures.append("Music recommendations should show the recent frequent 30-track list")

    if "ScrollView(.vertical, showsIndicators: true)" not in swift_text:
        failures.append("Music recommendation list should keep its visible right-side scrollbar")

    if "每日推荐" in swift_text:
        failures.append("Music playlist cards should not draw the old daily recommendation badge")

    for token in ["rotations: [Double]", "offsets: [CGSize]", "playlistCover", "zIndex(Double(offset))"]:
        if token not in swift_text:
            failures.append(f"Music playlist cards missing stacked-card cover token: {token}")

    for token in [
        "HomeVividHorizontalScrollBridge",
        "firstBackdropPath(await appState.loadDetailSnapshot(for: item))",
        "localPath ?? $0.fullURL",
        "titleScrim",
    ]:
        if token not in swift_text:
            failures.append(f"Home hero missing landscape banner or paging token: {token}")

    for token in ['iconName: "movie"', 'iconName: "series"', 'iconName: "episodes"', 'iconName: "unwatched"']:
        if token not in swift_text:
            failures.append(f"Home stats missing semantic icon token: {token}")

    if "appState.sources.filter { $0.mediaType != .privateCollection }" not in swift_text:
        failures.append("Home source status card should follow visible media source list and never show vault sources")

    if "static let hoverShadowOpacity: Double = 0.18" not in swift_text:
        failures.append("Home widgets should share the photo-wall hover shadow style")

    if "AngularGradient(" in swift_text or "还有 \\(sourceGroups.count - maxRows) 个来源" in swift_text:
        failures.append("Home source status should use non-gradient pie segments and show all visible sources")

    for token in ["sourceSegments", "ForEach(sourceGroups)", "ScrollView(.vertical, showsIndicators: false)"]:
        if token not in swift_text:
            failures.append(f"Home source status missing complete implicit source list token: {token}")

    if ".frame(width: 26, alignment: .trailing)" not in swift_text:
        failures.append("Music track index should reserve enough width for two-digit numbers")

    for token in [
        "case highRated",
        "static let vividVisibleOrder",
        ".hero,\n        .stats,\n        .seriesRecommendations,\n        .continueWatching,\n        .musicRecommendations,\n        .continueListening,\n        .recentSeries,\n        .highRated,\n        .photoWall,\n        .dashboard",
        "highRatedFeaturedItems",
    ]:
        if token not in swift_text:
            failures.append(f"Home vivid module order missing requested visible module token: {token}")

    for token in [
        "HomeVividPosterCollectionPage",
        "focusedVividCollection",
        "focusedVividCollectionPage",
        "action: { focusedVividCollection = .seriesRecommendations }",
        "action: { focusedVividCollection = .recentSeries }",
        "action: { focusedVividCollection = .highRated }",
    ]:
        if token not in swift_text:
            failures.append(f"Series recommendation collection page missing token: {token}")

    for token in [
        "replaceMusicQueueAndPlay(tracks, startingAt: track)",
        "trackIDs: musicRecommendationItems.map",
        "trackIDs: tracks.prefix(30).map",
        "VideoItemContextMenuItems(item: item)",
        "Button { appState.startRadio(seed: track) }",
        "Label(item.type == .homeVideo ? \"查看视频\" : \"查看图片\"",
    ]:
        if token not in swift_text:
            failures.append(f"Home context menu or queue behavior missing token: {token}")

    for token in ["static let moduleSpacing: CGFloat = 22", "static let hoverShadowY: CGFloat = 8", "homeVividHorizontalMouseDragScroll"]:
        if token not in swift_text:
            failures.append(f"Home spacing/shadow normalization missing token: {token}")

    if "homeVividScrollClipDisabledIfAvailable" in swift_text or ".scrollClipDisabled()" in swift_text:
        failures.append("Home horizontal rows should stay clipped inside page bounds")

    if ".padding(.bottom, 22)" in swift_text:
        failures.append("Home poster rows should not keep the bottom spacer that creates a hidden clipped area")

    for token in ["PosterCardView", "posterMetadataLine", "HomeVividTokens.hoverShadowRadius", "LinearGradient(\n                colors: [.clear, .black.opacity(0.12), .black.opacity(0.78)]"]:
        if token not in swift_text:
            failures.append(f"Global poster wall home-style token missing: {token}")

    for section_name, next_marker in [
        ("struct HomeVividDashboard", "private extension View"),
        ("struct HomeVividMusicRecommendation", "private struct HomeVividTrackRow"),
    ]:
        start = swift_text.find(section_name)
        end = swift_text.find(next_marker, start)
        if start >= 0 and end > start and "ViewThatFits" in swift_text[start:end]:
            failures.append(f"{section_name} should not collapse into the screenshot-breaking vertical layout")

    photo_wall_start = swift_text.find("struct HomeVividPhotoWall")
    photo_wall_end = swift_text.find("private struct HomeVividPhotoTile")
    if photo_wall_start >= 0 and photo_wall_end > photo_wall_start:
        photo_wall_text = swift_text[photo_wall_start:photo_wall_end]
        if "LazyVGrid(columns: Array(repeating:" in photo_wall_text:
            failures.append("Home photo wall should not use mixed-height adaptive LazyVGrid layout")
        for token in ["photoStack", "photoButton", ".frame(height: photoWallHeight)"]:
            if token not in photo_wall_text:
                failures.append(f"Home photo wall missing stable collage token: {token}")

    if "夏日 · 海边" in swift_text or "城市夜景" in swift_text:
        failures.append("Home photo wall tiles should not draw text labels over photos")

    if "HomeVividPhotoWall(\n                    items: items" not in swift_text or "onSelect: openPhotoWallItem" not in swift_text:
        failures.append("Home photo wall clicks should open the image viewer instead of detail")

    for token in [
        "onOpenVideoSection: { section in",
        "selection = .video(section)",
        "selection = .music(section)",
        "selection = .album(section)",
        "action: { onOpenVideoSection(.watching) }",
        "onOpenMusic: { onOpenMusicSection(.songs) }",
        "onOpenAlbum: { onOpenAlbumSection(.all) }",
    ]:
        if token not in swift_text:
            failures.append(f"Home vivid section action missing navigation token: {token}")

    for token in ["photoWallViewerOverlay", "MediaImageViewer(", "openPhotoWallItem"]:
        if token not in swift_text:
            failures.append(f"Home photo wall image viewer flow missing token: {token}")

    if failures:
        print("FAILED: Home vivid reference check")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Home vivid reference check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
