import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class TrackPreferenceStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TrackPreferenceStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testAudioLanguageUsesParentSeriesKeyAndTrimsInput() {
        let episodeOne = item(id: "episode-1", parentID: "series-1")
        let episodeTwo = item(id: "episode-2", parentID: "series-1")
        let otherSeriesEpisode = item(id: "episode-3", parentID: "series-2")

        TrackPreferenceStore.setAudioLanguage("  ja-JP  ", for: episodeOne, defaults: defaults)

        XCTAssertEqual(TrackPreferenceStore.audioLanguage(for: episodeTwo, defaults: defaults), "ja-JP")
        XCTAssertNil(TrackPreferenceStore.audioLanguage(for: otherSeriesEpisode, defaults: defaults))

        TrackPreferenceStore.setAudioLanguage(" \n\t ", for: episodeTwo, defaults: defaults)

        XCTAssertNil(TrackPreferenceStore.audioLanguage(for: episodeOne, defaults: defaults))
    }

    func testPlaybackRateStoresOnlyMeaningfulFiniteRates() {
        let movie = item(id: "movie-1")

        TrackPreferenceStore.setPlaybackRate(1.25, for: movie, defaults: defaults)
        XCTAssertEqual(TrackPreferenceStore.playbackRate(for: movie, defaults: defaults), 1.25)

        TrackPreferenceStore.setPlaybackRate(1.0, for: movie, defaults: defaults)
        XCTAssertNil(TrackPreferenceStore.playbackRate(for: movie, defaults: defaults))

        TrackPreferenceStore.setPlaybackRate(1.5, for: movie, defaults: defaults)
        TrackPreferenceStore.setPlaybackRate(.nan, for: movie, defaults: defaults)
        XCTAssertNil(TrackPreferenceStore.playbackRate(for: movie, defaults: defaults))

        TrackPreferenceStore.setPlaybackRate(0, for: movie, defaults: defaults)
        XCTAssertNil(TrackPreferenceStore.playbackRate(for: movie, defaults: defaults))
    }

    func testSubtitleStoresOffLanguageAndEmptyLanguageClears() {
        let episode = item(id: "episode-1", parentID: "series-1")

        TrackPreferenceStore.setSubtitle(.off, for: episode, defaults: defaults)
        XCTAssertEqual(TrackPreferenceStore.subtitle(for: episode, defaults: defaults), .off)

        TrackPreferenceStore.setSubtitle(.language("  zh-Hans  "), for: episode, defaults: defaults)
        XCTAssertEqual(TrackPreferenceStore.subtitle(for: episode, defaults: defaults), .language("zh-Hans"))

        TrackPreferenceStore.setSubtitle(.language(" \n "), for: episode, defaults: defaults)
        XCTAssertNil(TrackPreferenceStore.subtitle(for: episode, defaults: defaults))
    }

    func testMovieAndEmptyParentIDFallBackToOwnItemID() {
        let movieWithEmptyParent = item(id: "movie-1", parentID: "")
        let sameMovieWithoutParent = item(id: "movie-1")
        let differentMovie = item(id: "movie-2")

        TrackPreferenceStore.setAudioLanguage("en-US", for: movieWithEmptyParent, defaults: defaults)

        XCTAssertEqual(TrackPreferenceStore.audioLanguage(for: sameMovieWithoutParent, defaults: defaults), "en-US")
        XCTAssertNil(TrackPreferenceStore.audioLanguage(for: differentMovie, defaults: defaults))
    }

    func testInjectedDefaultsDoNotTouchStandardDefaults() {
        let uniqueItem = item(id: "track-pref-\(UUID().uuidString)")

        TrackPreferenceStore.setAudioLanguage("fr-FR", for: uniqueItem, defaults: defaults)
        TrackPreferenceStore.setPlaybackRate(1.4, for: uniqueItem, defaults: defaults)
        TrackPreferenceStore.setSubtitle(.off, for: uniqueItem, defaults: defaults)

        XCTAssertEqual(TrackPreferenceStore.audioLanguage(for: uniqueItem, defaults: defaults), "fr-FR")
        XCTAssertEqual(TrackPreferenceStore.playbackRate(for: uniqueItem, defaults: defaults), 1.4)
        XCTAssertEqual(TrackPreferenceStore.subtitle(for: uniqueItem, defaults: defaults), .off)
        XCTAssertNil(TrackPreferenceStore.audioLanguage(for: uniqueItem))
        XCTAssertNil(TrackPreferenceStore.playbackRate(for: uniqueItem))
        XCTAssertNil(TrackPreferenceStore.subtitle(for: uniqueItem))
    }

    private func item(id: String, parentID: String? = nil) -> MediaItem {
        MediaItem(id: id, type: .episode, title: id, parentID: parentID)
    }
}
