import XCTest
@testable import MediaLibCore

final class MetadataCorrectionRecordTests: XCTestCase {
    func testRatingEncodingPreservesFiniteValuesAndTrimsTrailingZeros() {
        let item = MediaItem(
            id: "finite-rating",
            type: .movie,
            title: "Finite Rating",
            rating: 8.25,
            userRating: 4.0
        )

        XCTAssertEqual(MetadataCorrectionField.rating.encodedValue(from: item), "8.25")
        XCTAssertEqual(MetadataCorrectionField.userRating.encodedValue(from: item), "4")
    }

    func testRatingEncodingDropsNonFiniteValues() {
        let values: [(String, Double)] = [
            ("nan", .nan),
            ("positive infinity", .infinity),
            ("negative infinity", -.infinity)
        ]

        for (label, value) in values {
            let item = MediaItem(
                id: "non-finite-\(label)",
                type: .movie,
                title: "Non-finite Rating",
                rating: value,
                userRating: value
            )

            XCTAssertNil(MetadataCorrectionField.rating.encodedValue(from: item), label)
            XCTAssertNil(MetadataCorrectionField.userRating.encodedValue(from: item), label)
        }
    }

    func testDroppingNonFiniteRatingDoesNotAffectOtherFieldEncoding() {
        let item = MediaItem(
            id: "mixed-fields",
            type: .movie,
            title: "Mixed Fields",
            year: 2026,
            rating: .nan,
            userRating: .infinity,
            runtime: 123
        )

        XCTAssertEqual(MetadataCorrectionField.title.encodedValue(from: item), "Mixed Fields")
        XCTAssertEqual(MetadataCorrectionField.year.encodedValue(from: item), "2026")
        XCTAssertEqual(MetadataCorrectionField.runtime.encodedValue(from: item), "123")
        XCTAssertNil(MetadataCorrectionField.rating.encodedValue(from: item))
        XCTAssertNil(MetadataCorrectionField.userRating.encodedValue(from: item))
    }
}
