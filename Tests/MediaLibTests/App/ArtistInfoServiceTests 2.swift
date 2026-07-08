import XCTest
@testable import MediaLib

final class ArtistInfoServiceTests: XCTestCase {
    func testCleanedBioRejectsNilBlankAndHTMLOnlyInput() {
        XCTAssertNil(ArtistInfoService.cleanedBio(nil))
        XCTAssertNil(ArtistInfoService.cleanedBio(""))
        XCTAssertNil(ArtistInfoService.cleanedBio(" \n\t "))
        XCTAssertNil(ArtistInfoService.cleanedBio("<p> </p><br />\n"))
    }

    func testCleanedBioStripsHTMLTagsAndTrimsWhitespace() {
        XCTAssertEqual(
            ArtistInfoService.cleanedBio(" \n<p><strong>Cher</strong> is an artist.</p><br /> "),
            "Cher is an artist."
        )
    }

    func testCleanedBioCutsReadMoreLinkTail() {
        XCTAssertEqual(
            ArtistInfoService.cleanedBio("Artist bio. <a href=\"https://last.fm/music/Cher\">Read more on Last.fm</a>"),
            "Artist bio."
        )
    }

    func testCleanedBioDecodesCommonHTMLEntities() {
        XCTAssertEqual(
            ArtistInfoService.cleanedBio("Rock &amp; pop &quot;artist&quot; &#39;solo&#39; &lt;tag&gt;"),
            "Rock & pop \"artist\" 'solo' <tag>"
        )
    }

    func testCleanedNamesTrimDropBlankAndPreserveOrder() {
        let names = ArtistInfoService.cleanedNames([
            "  synth-pop  ",
            nil,
            "",
            "\nrock\t",
            "电子",
            "   "
        ])

        XCTAssertEqual(names, ["synth-pop", "rock", "电子"])
    }

    func testLastfmQueryItemsIncludeRequiredFieldsAndChineseLanguageHint() {
        let query = dictionary(from: ArtistInfoService.lastfmQueryItems(
            artist: "周杰伦",
            apiKey: "api-key",
            language: "zh-Hans"
        ))

        XCTAssertEqual(query["method"], "artist.getinfo")
        XCTAssertEqual(query["artist"], "周杰伦")
        XCTAssertEqual(query["api_key"], "api-key")
        XCTAssertEqual(query["format"], "json")
        XCTAssertEqual(query["lang"], "zh")
    }

    func testLastfmQueryItemsTreatChineseLanguageCaseInsensitively() {
        let query = dictionary(from: ArtistInfoService.lastfmQueryItems(
            artist: "Artist",
            apiKey: "api-key",
            language: "ZH-cn"
        ))

        XCTAssertEqual(query["lang"], "zh")
    }

    func testLastfmQueryItemsSkipLanguageHintForNonChineseLanguage() {
        let query = dictionary(from: ArtistInfoService.lastfmQueryItems(
            artist: "Artist",
            apiKey: "api-key",
            language: "en-US"
        ))

        XCTAssertNil(query["lang"])
    }

    func testPreferredDeezerImageUsesLargestAvailableImage() {
        XCTAssertEqual(
            ArtistInfoService.preferredDeezerImage(
                pictureXL: " https://example.test/xl.jpg ",
                pictureBig: "https://example.test/big.jpg",
                pictureMedium: "https://example.test/medium.jpg"
            ),
            "https://example.test/xl.jpg"
        )
    }

    func testPreferredDeezerImageFallsBackThroughBigAndMedium() {
        XCTAssertEqual(
            ArtistInfoService.preferredDeezerImage(
                pictureXL: nil,
                pictureBig: " \nhttps://example.test/big.jpg\t",
                pictureMedium: "https://example.test/medium.jpg"
            ),
            "https://example.test/big.jpg"
        )
        XCTAssertEqual(
            ArtistInfoService.preferredDeezerImage(
                pictureXL: "",
                pictureBig: "   ",
                pictureMedium: "https://example.test/medium.jpg"
            ),
            "https://example.test/medium.jpg"
        )
    }

    func testPreferredDeezerImageReturnsNilWhenAllCandidatesAreBlank() {
        XCTAssertNil(ArtistInfoService.preferredDeezerImage(
            pictureXL: nil,
            pictureBig: "\n",
            pictureMedium: "   "
        ))
    }

    private func dictionary(from items: [URLQueryItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}
