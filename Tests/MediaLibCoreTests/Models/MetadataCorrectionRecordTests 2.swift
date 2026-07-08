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

    func testRecordDecoderDefaultsUnknownFieldAndKeepsValidValues() throws {
        let json = """
        {
          "id": "record-1",
          "batchID": "batch-1",
          "mediaID": "media-1",
          "field": "futureField",
          "oldValue": "old",
          "newValue": "new",
          "source": "tmdb",
          "createdAt": 1000,
          "undoneAt": 2000
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(MetadataCorrectionRecord.self, from: json)

        XCTAssertEqual(record.id, "record-1")
        XCTAssertEqual(record.batchID, "batch-1")
        XCTAssertEqual(record.mediaID, "media-1")
        XCTAssertEqual(record.field, .title)
        XCTAssertEqual(record.oldValue, "old")
        XCTAssertEqual(record.newValue, "new")
        XCTAssertEqual(record.source, "tmdb")
        XCTAssertEqual(record.createdAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(record.undoneAt, Date(timeIntervalSinceReferenceDate: 2000))
    }

    func testBatchSummaryDecoderFiltersUnknownFieldsAndClampsFieldCount() throws {
        let json = """
        {
          "batchID": "batch-2",
          "mediaID": "media-2",
          "source": "manual",
          "createdAt": 3000,
          "fieldCount": -5,
          "fields": ["title", "futureField", "rating", "futureScore"]
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MetadataCorrectionBatchSummary.self, from: json)

        XCTAssertEqual(summary.batchID, "batch-2")
        XCTAssertEqual(summary.mediaID, "media-2")
        XCTAssertEqual(summary.source, "manual")
        XCTAssertEqual(summary.createdAt, Date(timeIntervalSinceReferenceDate: 3000))
        XCTAssertEqual(summary.fieldCount, 0)
        XCTAssertEqual(summary.fields, [.title, .rating])
        XCTAssertEqual(summary.id, "media-2-batch-2")
    }
}
