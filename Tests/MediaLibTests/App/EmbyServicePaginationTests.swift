import XCTest
@testable import MediaLib

final class EmbyServicePaginationTests: XCTestCase {
    func testItemPaginationStopsOnEmptyPage() {
        XCTAssertFalse(EmbyService.shouldContinueItemPagination(
            pageItemCount: 0,
            addedUniqueItems: 0,
            totalRecordCount: nil,
            nextStartIndex: 0,
            pageIndex: 1,
            maxPageIterations: 10_000
        ))
    }

    func testItemPaginationStopsWhenServerRepeatsNonEmptyPageWithoutTotal() {
        XCTAssertFalse(EmbyService.shouldContinueItemPagination(
            pageItemCount: 2,
            addedUniqueItems: 0,
            totalRecordCount: nil,
            nextStartIndex: 4,
            pageIndex: 2,
            maxPageIterations: 10_000
        ))
    }

    func testItemPaginationContinuesForUniqueItemsWithoutTotal() {
        XCTAssertTrue(EmbyService.shouldContinueItemPagination(
            pageItemCount: 2,
            addedUniqueItems: 2,
            totalRecordCount: nil,
            nextStartIndex: 4,
            pageIndex: 2,
            maxPageIterations: 10_000
        ))
    }

    func testItemPaginationHonorsTotalRecordCountBoundary() {
        XCTAssertTrue(EmbyService.shouldContinueItemPagination(
            pageItemCount: 2,
            addedUniqueItems: 0,
            totalRecordCount: 10,
            nextStartIndex: 4,
            pageIndex: 2,
            maxPageIterations: 10_000
        ))
        XCTAssertFalse(EmbyService.shouldContinueItemPagination(
            pageItemCount: 2,
            addedUniqueItems: 0,
            totalRecordCount: 10,
            nextStartIndex: 10,
            pageIndex: 5,
            maxPageIterations: 10_000
        ))
    }

    func testItemPaginationHonorsAbsoluteIterationCap() {
        XCTAssertFalse(EmbyService.shouldContinueItemPagination(
            pageItemCount: 2,
            addedUniqueItems: 2,
            totalRecordCount: nil,
            nextStartIndex: 20_000,
            pageIndex: 10_000,
            maxPageIterations: 10_000
        ))
    }
}
