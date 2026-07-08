import XCTest
@testable import MediaLibCore

// MediaType 的 rawValue 直接落库；尤其 .privateCollection 映射为 "private"（与 case 名不同），改错会读不出旧库。
final class MediaTypeTests: XCTestCase {
    func testPrivateCollectionRawValueIsPrivate() {
        XCTAssertEqual(MediaType.privateCollection.rawValue, "private")
        XCTAssertEqual(MediaType(rawValue: "private"), .privateCollection)
    }

    func testCommonRawValues() {
        XCTAssertEqual(MediaType.movie.rawValue, "movie")
        XCTAssertEqual(MediaType.tvShow.rawValue, "tvShow")
        XCTAssertEqual(MediaType.music.rawValue, "music")
        XCTAssertEqual(MediaType.episode.rawValue, "episode")
        XCTAssertEqual(MediaType.photo.rawValue, "photo")
    }

    func testCodableRoundTripForAllCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for type in MediaType.allCases {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(MediaType.self, from: data)
            XCTAssertEqual(decoded, type, "\(type) Codable round-trip 不一致")
        }
    }

    func testUnknownRawValueReturnsNil() {
        XCTAssertNil(MediaType(rawValue: "definitely-not-a-type"))
    }

    func testUnknownCodableRawValueDefaultsToOther() throws {
        let data = #""futureSpatialVideo""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaType.self, from: data)

        XCTAssertEqual(decoded, .other)
    }

    func testAllCasesCoverKnownTypes() {
        let raws = Set(MediaType.allCases.map(\.rawValue))
        XCTAssertTrue(raws.isSuperset(of: ["movie", "tvShow", "music", "episode", "photo", "private"]))
    }
}
