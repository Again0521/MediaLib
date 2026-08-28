import XCTest
@testable import MediaLibServer

final class ServerWebScriptMutabilityTests: XCTestCase {
    func testInteractiveWebScriptsKeepTheirMutableStateWritable() {
        assertMutableBindings(
            [
                "isStarting", "resumeApplied", "playbackStartedReported", "lastProgressBucket",
                "playbackTracksPromise", "playbackCompleted", "playerLayout",
                "playbackMode", "remuxOffset", "remuxAudioTrack", "playbackTracks",
                "activeEpisodeSeason", "episodeOffset", "episodeHasMore", "episodeLoading",
                "overlayHideTimer", "transportFrame", "preference", "nextSeasonIndex"
            ],
            in: ServerWebMediaDetailPage.script,
            name: "player.js"
        )
        assertMutableBindings(
            ["playbackFilter", "preferenceFilter", "reversed", "offset", "total", "controller", "requestedType", "requestedGroup", "hash"],
            in: ServerWebLibraryPage.script,
            name: "library.js"
        )
        assertMutableBindings(
            ["index", "offset", "velocity", "target", "frame", "lastFrameTime", "bounce", "timer", "drag", "suppressClickUntil", "next"],
            in: ServerWebHomePage.script,
            name: "home.js"
        )
        assertMutableBindings(["offset", "loading"], in: ServerWebPhotosPage.script, name: "photos.js")
        assertMutableBindings(["searchTimer"], in: ServerWebPeoplePage.script, name: "people.js")
        // `descending` 不再是一段独立的可变状态：排序方向已经并进排序选择的值里
        // （`title:asc`），由那一个控件单独决定。
        assertMutableBindings(["visible"], in: ServerWebMusicPage.script, name: "music.js")
        assertMutableBindings(
            ["refreshPromise", "navigationSerial", "activeNavigationRequest", "navigationFallbackTimer", "navigationWarmTimer", "navigationWarmURL", "requestedType", "requestedGroup"],
            in: ServerWebShellScript.script,
            name: "app-shell.js"
        )
        XCTAssertTrue(ServerWebShellScript.script.contains("scheduleDock"))
        assertMutableBindings(["availableLibraries", "editingUser", "failures"], in: ServerWebAdministrationPage.script, name: "admin.js")
        XCTAssertFalse(ServerWebAdministrationPage.script.contains("var usersByID ="))
    }

    private func assertMutableBindings(_ bindings: [String], in script: String, name: String) {
        for binding in bindings {
            XCTAssertTrue(script.contains("var \(binding) ="), "\(name) must declare \(binding) with var")
            XCTAssertFalse(script.contains("let \(binding) ="), "\(name) must not redeclare mutable \(binding) with let")
        }
    }
}
