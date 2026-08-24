import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

/// Opt-in, local-only fixture preparation for manual browser verification.
/// It is skipped in normal test runs and refuses paths outside the system temp area.
final class ServerWebBrowserFixtureTests: XCTestCase {
    func testPrepareHomeLayoutBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_HOME_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_HOME_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式首页布局验收时准备静态夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("网页首页夹具只能写入系统临时目录。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let series = (1...8).map {
            ServerLibraryItem(id: "series-\($0)", type: "anime", title: "剧集推荐 \($0)", year: 2026 - $0, artworkAvailable: false, isSeries: true)
        }
        let movies = (1...6).map {
            ServerLibraryItem(id: "movie-\($0)", type: "movie", title: "电影与视频 \($0)", year: 2026 - $0, artworkAvailable: false)
        }
        // 前两首带真实播放痕迹：一首听了一半、一首播过。它们是"音乐不进最近播放、
        // 只进继续听"这条规则唯一能被观察到的地方——没有播放痕迹的曲目两边都不
        // 会出现，夹具也就证明不了任何事。
        let tracks = (1...12).map { index -> ServerLibraryItem in
            let state: ServerMediaUserState? = index <= 2
                ? ServerMediaUserState(
                    itemID: "music-\(index)", positionSeconds: 60, progress: index == 1 ? 0.35 : 0,
                    isWatched: false, playCount: 3, lastPlayedAt: Date(timeIntervalSince1970: 500),
                    updatedAt: Date(timeIntervalSince1970: 500)
                )
                : nil
            return ServerLibraryItem(
                id: "music-\(index)", type: "music", title: "紧凑音乐单曲 \(index)", year: 2026,
                artworkAvailable: false, userState: state
            )
        }
        let continuing = ServerLibraryItem(
            id: "continue-1", type: "episode", title: "继续观看的剧集", year: 2026,
            artworkAvailable: false,
            userState: ServerMediaUserState(
                itemID: "continue-1", positionSeconds: 600, progress: 0.42, isWatched: false,
                playCount: 1, lastPlayedAt: nil, updatedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let allItems = [continuing] + series + movies + tracks
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(
                totalItemCount: allItems.count,
                countsByType: ["anime": series.count, "movie": movies.count, "music": tracks.count, "episode": 1]
            ),
            items: ServerLibraryItemsResponse(totalItemCount: allItems.count, items: allItems)
        )
        let html = ServerWebHomePage.render(
            serverName: "MediaLIB 首页布局验收",
            snapshot: snapshot,
            csrfToken: "fixture-token",
            // 夹具验收的是"没有客户端时"的那条路径：推荐名单为空，每一栏各自回落到
            // 快照推导。有名单时的取材由 `ServerWebHomeRecommendationTests` 覆盖。
            recommendations: .empty,
            // 侧栏动态条目现在是必传的（`ServerWebSidebarExtras` 的文档：漏传会让
            // 智能集合／歌单随页面忽隐忽现，比从不显示更糟）。夹具没有这些数据。
            sidebarExtras: .empty
        )
        // Rewrite absolute, versioned asset URLs to sibling files.  The previous
        // version pinned literal `?v=` numbers, so every asset bump silently
        // turned these rewrites into no-ops and the fixture rendered unstyled.
        let localised = Self.localisingAssetURLs(in: html)
        try Data(localised.utf8).write(to: root.appendingPathComponent("index.html"), options: .atomic)
        for (name, contents) in Self.fixtureAssets {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }

    /// 音乐目录页的静态夹具。
    ///
    /// 这一页的筛选栏长期是自己手搓的一份 markup，左边还塞着「歌曲/专辑/艺术家/
    /// 歌单/最近播放」五个锚点——而 `.music-section-link` 全仓**没有任何 CSS
    /// 命中**，于是它们以零间距的纯文本渲染成一长串。这种缺陷只有把页面放进浏览
    /// 器才看得见：markup 存在、路由 200、断言全绿。
    func testPrepareMusicLayoutBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_MUSIC_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_MUSIC_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式音乐布局验收时准备静态夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("音乐夹具只能写入系统临时目录。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let artists = ["林间演出", "夜航西飞", "第七车厢"]
        let albums = ["空白频率", "长夜与灯", "回声练习"]
        // 逐个字段先算好再传：一次性写成一个大表达式会让类型检查器超时。
        let tracks: [ServerLibraryItem] = (1...24).map { index in
            let year: Int = 2020 + (index % 6)
            let artist: String = artists[index % artists.count]
            let album: String = albums[index % albums.count]
            let duration: Double = Double(150 + index * 7)
            return ServerLibraryItem(
                id: "music-\(index)",
                type: "music",
                title: "曲目名称 \(index)",
                year: year,
                artist: artist,
                album: album,
                durationSeconds: duration,
                artworkAvailable: false
            )
        }
        let html = ServerWebMusicPage.render(
            page: .songs,
            serverName: "MediaLIB 音乐布局验收",
            csrfToken: "fixture-token",
            showAdministration: false,
            categories: [],
            sidebarExtras: .empty,
            tracks: tracks
        )
        let localised = Self.localisingAssetURLs(in: html)
        try Data(localised.utf8).write(to: root.appendingPathComponent("index.html"), options: .atomic)
        for (name, contents) in Self.fixtureAssets {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The detail/playback page's own static fixture.
    ///
    /// 首页有静态夹具而详情页没有，是"背景请求了一个不存在的尺寸桶"能长期活下来
    /// 的另一半原因：这一页的版面从来没有被人在浏览器里量过。这里的三件事都只依
    /// 赖 CSS 和文本，不需要真实源站——图片 404 也不影响艺术照的几何，因为高度
    /// 由 `aspect-ratio` 决定而不是由图片固有尺寸决定。
    func testPrepareDetailLayoutBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_DETAIL_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_DETAIL_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式详情页布局验收时准备静态夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("网页详情夹具只能写入系统临时目录。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 横竖交替，正是用户截图里那条高矮不齐的带子。
        let artwork = (0..<10).map {
            ServerMediaDetailArtwork(id: "still-\($0)", index: $0, kind: "backdrop", aspectRatio: $0 % 3 == 2 ? 0.67 : 1.78)
        }
        let detail = ServerMediaItemDetail(
            id: "detail-fixture",
            type: "episode",
            title: "S01E01 与你相遇的那一夜",
            originalTitle: nil,
            year: 2026,
            // 足够长、且带硬换行——这正是把简介区撑到无限高的那种文本。
            overview: (1...12)
                .map { "第 \($0) 段简介。男高中生五条新菜梦想着成为制作雏人形面部的「头师」，全身心地投入到制作雏人形后，他离同龄人的流行话题越来越远。" }
                .joined(separator: "\n\n"),
            genres: ["动画", "喜剧", "剧情"],
            communityRating: 8.4,
            runtimeSeconds: 1_380,
            videoCodec: "h264",
            audioCodec: "aac",
            resolution: "1920x1080",
            artworkAvailable: true,
            backdropAvailable: true,
            canDirectPlay: true,
            canTranscode: false,
            episodeContext: ServerEpisodePlaybackContext(
                seriesID: "series-fixture",
                seriesTitle: "更衣人偶坠入爱河",
                seasonNumber: 1,
                episodeNumber: 1,
                seasons: []
            ),
            detailExtras: ServerMediaDetailExtras(
                status: "Ended", contentRating: "TV-14", originalLanguage: "ja", countries: ["Japan"],
                artwork: artwork
            )
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "MediaLIB 详情布局验收", detail: detail, csrfToken: "fixture-token",
            showAdministration: false, sidebarExtras: .empty
        )
        // 静态夹具没有轨道 API，正常脚本不会填充菜单。验收这一轮正好需要覆盖
        // “二十多条字幕时能否在各种窗口内滚动”，因此只在隔离夹具里放入与脚本
        // 生成结果同构的 24 个 menuitemradio；生产页面仍全部由授权 API 驱动。
        let trackItems = (1...24).map { index in
            let language = index == 23 ? "简体中文" : (index == 24 ? "繁体中文" : "字幕语言 \(index)")
            return #"<button type="button" class="player-track-item" role="menuitemradio" aria-checked="\#(index == 23 ? "true" : "false")">\#(language)</button>"#
        }.joined()
        let fixtureHTML = html
            .replacingOccurrences(
                of: #"class="player-stage" tabindex="0""#,
                with: #"class="player-stage controls-visible" tabindex="0""#
            )
            .replacingOccurrences(
                of: #"class="transport-controls player-overlay-controls" aria-label="播放控制" hidden"#,
                with: #"class="transport-controls player-overlay-controls" aria-label="播放控制""#
            )
            .replacingOccurrences(
                of: #"<details class="player-settings" id="subtitle-menu" hidden>"#,
                with: #"<details class="player-settings" id="subtitle-menu" open>"#
            )
            .replacingOccurrences(
                of: #"<div class="player-settings-panel player-track-panel" id="subtitle-panel" role="group" aria-label="字幕轨道"></div>"#,
                with: #"<div class="player-settings-panel player-track-panel" id="subtitle-panel" role="group" aria-label="字幕轨道"><p class="player-track-group">内封字幕</p>\#(trackItems)</div>"#
            )
        try Data(Self.localisingAssetURLs(in: fixtureHTML).utf8)
            .write(to: root.appendingPathComponent("index.html"), options: .atomic)
        for (name, contents) in Self.fixtureAssets {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Every stylesheet and script the static fixture needs, keyed by the file
    /// name the rewritten markup points at.
    private static let fixtureAssets: [(String, String)] = [
        ("tokens.css", ServerWebDesignTokens.css),
        ("base.css", ServerWebBaseStyle.css),
        ("primitives.css", ServerWebPrimitives.css),
        ("app-shell.css", ServerWebShellStyle.css),
        ("home.css", ServerWebHomePage.style),
        ("player.css", ServerWebMediaDetailPage.style),
        ("music.css", ServerWebMusicPage.style),
        ("appearance.js", ServerWebAppearanceScript.script),
        ("home.js", ServerWebHomePage.script),
        ("player.js", ServerWebMediaDetailPage.script),
        ("overlays.js", ServerWebOverlayScript.script),
        // The shell bundle drives progressive navigation against a live origin,
        // which a file:// fixture does not have.  Staged empty on purpose.
        ("app-shell.js", "")
    ]

    /// Turns `/assets/name.ext?v=123` into `name.ext`, whatever the version is.
    static func localisingAssetURLs(in html: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "/assets/([A-Za-z0-9._-]+)(\\?v=\\d+)?") else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.stringByReplacingMatches(in: html, range: range, withTemplate: "$1")
    }

    func testPrepareIsolatedAuthenticatedBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_BROWSER_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_BROWSER_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式网页浏览器验收时准备隔离夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("网页浏览器夹具只能写入系统临时目录。")
        }

        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        let mediaFile = mediaDirectory.appendingPathComponent("browser-fixture.mp4")
        guard FileManager.default.fileExists(atPath: mediaFile.path) else {
            throw XCTSkip("验收调用方必须先在隔离目录写入 browser-fixture.mp4。")
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let musicFile = mediaDirectory.appendingPathComponent("browser-fixture-music.mp3")
        let photoFile = mediaDirectory.appendingPathComponent("browser-fixture-photo.png")
        let fixtureBytes = try Data(contentsOf: mediaFile)
        try fixtureBytes.write(to: musicFile, options: .atomic)
        // Keep the photo assertion meaningful: the fixture must be a real image
        // so the browser can exercise the authenticated image endpoint and its
        // native decoder, rather than silently accepting a broken poster URL.
        let photoBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try photoBytes.write(to: photoFile, options: .atomic)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let database = try DatabaseManager(
            url: root.appendingPathComponent("medialib.sqlite"),
            backupDirectory: backupDirectory
        )
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let identityRepository = ServerIdentityRepository(database: database)
        let passwordHasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 7, count: count) }
        )

        try sourceRepository.save(MediaSource(
            id: "browser-fixture-library",
            name: "浏览器验收资料库",
            path: mediaDirectory.path,
            mediaType: .movie
        ))
        try mediaRepository.upsert(MediaItem(
            id: "browser-fixture-movie",
            type: .movie,
            title: "浏览器原生播放验收",
            overview: "仅用于本机隔离浏览器验收的短媒体。",
            posterPath: photoFile.path,
            sourcePath: mediaDirectory.path,
            filePath: mediaFile.path,
            duration: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        // Keep every Web sidebar group non-empty in the opt-in fixture. The
        // media bytes are intentionally shared and never played from the
        // music/photo entries; they only make real navigation and empty-state
        // behavior observable in a browser without adding user media.
        try mediaRepository.upsert(MediaItem(
            id: "browser-fixture-music",
            type: .music,
            title: "浏览器音乐分类验收",
            posterPath: photoFile.path,
            sourcePath: mediaDirectory.path,
            filePath: musicFile.path,
            duration: 1,
            updatedAt: Date(timeIntervalSince1970: 2)
        ))
        try mediaRepository.upsert(MediaItem(
            id: "browser-fixture-photo",
            type: .photo,
            title: "浏览器相册分类验收",
            posterPath: photoFile.path,
            sourcePath: mediaDirectory.path,
            filePath: photoFile.path,
            updatedAt: Date(timeIntervalSince1970: 3)
        ))
        if try !identityRepository.hasCredential(userID: ServerIdentityRepository.initialAdministratorUserID) {
            try identityRepository.setInitialCredential(
                userID: ServerIdentityRepository.initialAdministratorUserID,
                argon2idEncodedHash: try passwordHasher.hash(password: "browser fixture password")
            )
        }
    }

    /// P0 性能基线的夹具：把 `scripts/generate_media_matrix.sh` 生成的固定样本
    /// 矩阵登记成可播放条目。
    ///
    /// 它与上面的单文件夹具分开，是因为基线要求的是"每次测量都跑在同一批样本
    /// 上"：样本一变，两次测量之间的差异就分不清是代码还是素材造成的。矩阵前两
    /// 个样本额外登记为同一系列的连续两集，让"自动下一集"有真实的服务端授权
    /// 导航可走，而不是靠前端伪造一个下一集地址。
    func testPreparePlaybackMatrixBrowserFixtureWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEDIALIB_WEB_PLAYBACK_FIXTURE"] == "1",
              let rawRoot = environment["MEDIALIB_WEB_PLAYBACK_FIXTURE_DIR"],
              !rawRoot.isEmpty
        else {
            throw XCTSkip("只在显式播放基线验收时准备媒体矩阵夹具。")
        }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") || root.path.hasPrefix(privateTemporaryRoot.path + "/") else {
            throw XCTSkip("播放基线夹具只能写入系统临时目录。")
        }

        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        let samples = try FileManager.default
            .contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            .filter { ["mp4", "mkv", "webm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !samples.isEmpty else {
            throw XCTSkip("先运行 scripts/generate_media_matrix.sh 生成样本矩阵。")
        }

        let database = try DatabaseManager(
            url: root.appendingPathComponent("medialib.sqlite"),
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true)
        )
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let identityRepository = ServerIdentityRepository(database: database)
        // 夹具口令只保护一个临时资料库，因此故意用最低 Argon2 参数：验收脚本要
        // 反复登录，生产参数会让每次登录都付出秒级代价。
        let passwordHasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { count in [UInt8](repeating: 7, count: count) }
        )

        try sourceRepository.save(MediaSource(
            id: "matrix-library",
            name: "播放基线样本矩阵",
            path: mediaDirectory.path,
            mediaType: .movie
        ))

        try mediaRepository.upsert(MediaItem(
            id: "matrix-series",
            type: .tvShow,
            title: "播放基线连播系列",
            sourcePath: mediaDirectory.path,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))

        for (index, sample) in samples.enumerated() {
            let identifier = sample.deletingPathExtension().lastPathComponent
            try mediaRepository.upsert(MediaItem(
                id: identifier,
                type: .movie,
                title: sample.lastPathComponent,
                sourcePath: mediaDirectory.path,
                filePath: sample.path,
                duration: 4,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(100 + index))
            ))
            // 前两个样本再登记一份剧集身份，专供自动下一集使用。`file_path` 有
            // 唯一约束，因此连播集必须是各自的文件副本而不是同一路径的第二条记录。
            guard index < 2 else { continue }
            let episodeFile = mediaDirectory
                .appendingPathComponent("episode-\(index + 1).\(sample.pathExtension)")
            if !FileManager.default.fileExists(atPath: episodeFile.path) {
                try FileManager.default.copyItem(at: sample, to: episodeFile)
            }
            try mediaRepository.upsert(MediaItem(
                id: "matrix-episode-\(index + 1)",
                type: .episode,
                title: "连播第 \(index + 1) 集",
                sourcePath: mediaDirectory.path,
                parentID: "matrix-series",
                seasonNumber: 1,
                episodeNumber: index + 1,
                filePath: episodeFile.path,
                duration: 4,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(200 + index))
            ))
        }

        if try !identityRepository.hasCredential(userID: ServerIdentityRepository.initialAdministratorUserID) {
            try identityRepository.setInitialCredential(
                userID: ServerIdentityRepository.initialAdministratorUserID,
                argon2idEncodedHash: try passwordHasher.hash(password: "playback matrix fixture password")
            )
        }

        // 把矩阵清单交给验收脚本，避免脚本自己再猜一遍条目 ID 的构造规则。
        let manifest = samples.map { sample in
            ["file": sample.lastPathComponent,
             "itemID": sample.deletingPathExtension().lastPathComponent]
        }
        let payload: [String: Any] = [
            "items": manifest,
            "episodeItemIDs": ["matrix-episode-1", "matrix-episode-2"]
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("matrix-manifest.json"), options: .atomic)
    }
}
