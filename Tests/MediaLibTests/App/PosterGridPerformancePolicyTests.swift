import CoreGraphics
import XCTest
@testable import MediaLib

final class PosterGridPerformancePolicyTests: XCTestCase {
    func testPosterGridDecodeBucketCoversCurrentCardWidthWithoutUsingTheLegacyOversizedBucket() {
        XCTAssertEqual(ArtworkImageCache.posterGridTargetSize, CGSize(width: 256, height: 384))
        XCTAssertLessThan(
            ArtworkImageCache.posterGridTargetSize.width * ArtworkImageCache.posterGridTargetSize.height,
            300 * 450
        )
    }
}
