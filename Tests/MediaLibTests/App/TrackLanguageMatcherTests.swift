import XCTest
@testable import MediaLib

final class TrackLanguageMatcherTests: XCTestCase {
    func testPrefersExactSimplifiedChineseLanguageOverGenericOrTraditional() {
        let tracks = [
            track(id: 1, language: "zh", title: "Chinese"),
            track(id: 2, language: "zh-Hant", title: "Traditional"),
            track(id: 3, language: "zh-CN", title: "Simplified")
        ]

        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "zh-CN")?.id, 3)
    }

    func testUsesTitleAndExternalFilenameAsFallbacksWithoutBeatingLanguageMetadata() {
        let tracks = [
            track(id: 1, language: nil, title: "English commentary"),
            track(id: 2, language: nil, title: nil, externalFilename: "/subs/Movie.zh-Hans.srt"),
            track(id: 3, language: "en", title: "Main audio")
        ]

        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "english")?.id, 3)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "zh-Hans")?.id, 2)
    }

    func testSelectedTrackWinsTieThenLowerIdentifierWinsNextTie() {
        let selectedTie = [
            track(id: 4, language: "en", isSelected: false),
            track(id: 5, language: "en", isSelected: true)
        ]
        let idTie = [
            track(id: 8, language: "ja"),
            track(id: 6, language: "ja")
        ]

        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: selectedTie, matching: "en")?.id, 5)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: idTie, matching: "japanese")?.id, 6)
    }

    func testRecognizesCommonAsianLanguageAliases() {
        let tracks = [
            track(id: 1, language: "jpn"),
            track(id: 2, language: "kor"),
            track(id: 3, language: nil, title: "国语"),
            track(id: 4, language: nil, title: "繁體中文字幕")
        ]

        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "日本語")?.id, 1)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "korean")?.id, 2)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "mandarin")?.id, 3)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "zh-Hant")?.id, 4)
    }

    func testRecognizesIso3AndEnglishLanguageNames() {
        let tracks = [
            track(id: 1, language: "fra"),
            track(id: 2, language: "deu"),
            track(id: 3, language: "spa"),
            track(id: 4, language: "vie")
        ]

        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "french")?.id, 1)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "german")?.id, 2)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "spanish")?.id, 3)
        XCTAssertEqual(TrackLanguageMatcher.bestTrack(in: tracks, matching: "vi")?.id, 4)
    }

    func testReturnsNilWhenPreferredLanguageOrTracksCannotBeIdentified() {
        XCTAssertNil(TrackLanguageMatcher.bestTrack(in: [track(id: 1, language: "und")], matching: "klingon"))
        XCTAssertNil(TrackLanguageMatcher.bestTrack(in: [track(id: 1, language: nil, title: "Commentary")], matching: "   "))
        XCTAssertNil(TrackLanguageMatcher.bestTrack(in: [], matching: "en"))
    }

    private func track(
        id: Int,
        language: String?,
        title: String? = nil,
        isSelected: Bool = false,
        externalFilename: String? = nil
    ) -> MpvTrack {
        MpvTrack(
            id: id,
            type: .subtitle,
            title: title,
            language: language,
            codec: nil,
            isSelected: isSelected,
            isExternal: externalFilename != nil,
            externalFilename: externalFilename
        )
    }
}
