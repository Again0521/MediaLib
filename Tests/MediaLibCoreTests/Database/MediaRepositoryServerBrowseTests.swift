import Foundation
import XCTest
@testable import MediaLibCore

/// `fetchServerLibraryPage` 是 Web/Mlink 浏览的唯一入口，此前没有任何直接测试。
///
/// 这里钉住三件最容易静默出错的事：
///
/// * 每个排序键在两个方向上的顺序，以及空值永远排在最后；
/// * 按进度、按评级排序读到的必须是**当前用户**自己的行，而且没有记录的条目
///   不能因此从页面上消失（连接必须是 LEFT，绑定用户必须写在 ON 上）；
/// * 题材筛选是整词匹配，且题材名里的 LIKE 元字符不会变成通配符。
final class MediaRepositoryServerBrowseTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: MediaRepository!

    private let sourcePath = "/library"
    private let admin = ServerIdentityRepository.initialAdministratorUserID
    private let member = "member-2"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerBrowse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = MediaRepository(database: database)
        _ = try ServerIdentityRepository(database: database).createUser(
            id: member, username: "member2", displayName: "Member 2"
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func insert(
        _ id: String,
        title: String,
        year: Int? = nil,
        runtime: Int? = nil,
        rating: Double? = nil,
        genre: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) throws {
        try repository.upsert(MediaItem(
            id: id, type: .movie, title: title, year: year, rating: rating,
            runtime: runtime, sourcePath: sourcePath,
            createdAt: createdAt, updatedAt: updatedAt, genre: genre
        ))
    }

    private func page(
        sort: ServerLibraryDatabaseSort,
        order: ServerLibraryDatabaseSortOrder = .primary,
        genre: String? = nil,
        userID: String? = nil
    ) throws -> ServerLibraryDatabasePage {
        try repository.fetchServerLibraryPage(
            allowedSourcePaths: [sourcePath],
            type: nil,
            topLevelOnly: true,
            searchText: nil,
            offset: 0,
            limit: 100,
            sort: sort,
            sortOrder: order,
            genre: genre,
            userID: userID ?? admin,
            playbackFilter: nil
        )
    }

    // MARK: - Sorting

    func testEverySortKeyOrdersBothDirectionsAndKeepsMissingValuesLast() throws {
        try insert("b-2020", title: "B", year: 2020, runtime: 90, rating: 6.0,
                   createdAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200))
        try insert("a-2024", title: "A", year: 2024, runtime: 120, rating: 9.0,
                   createdAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300))
        try insert("c-none", title: "C", year: nil, runtime: nil, rating: nil,
                   createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(try page(sort: .recentlyUpdated).items.map(\.id), ["a-2024", "b-2020", "c-none"])
        XCTAssertEqual(try page(sort: .recentlyUpdated, order: .reverse).items.map(\.id), ["c-none", "b-2020", "a-2024"])
        XCTAssertEqual(try page(sort: .dateAdded).items.map(\.id), ["a-2024", "b-2020", "c-none"])
        XCTAssertEqual(try page(sort: .title).items.map(\.id), ["a-2024", "b-2020", "c-none"])
        XCTAssertEqual(try page(sort: .title, order: .reverse).items.map(\.id), ["c-none", "b-2020", "a-2024"])

        // 可空的三个键：无论正序还是倒序，没有值的条目都排在最后。把"没有年份"
        // 的条目在倒序时顶到第一页，读起来就像排序坏了。
        for sort in [ServerLibraryDatabaseSort.year, .runtime, .score] {
            XCTAssertEqual(try page(sort: sort).items.map(\.id).last, "c-none", "\(sort) 正序")
            XCTAssertEqual(try page(sort: sort, order: .reverse).items.map(\.id).last, "c-none", "\(sort) 倒序")
        }
        XCTAssertEqual(try page(sort: .year).items.map(\.id), ["a-2024", "b-2020", "c-none"])
        XCTAssertEqual(try page(sort: .year, order: .reverse).items.map(\.id), ["b-2020", "a-2024", "c-none"])
    }

    func testItemsWithTheSameSortKeyFallBackToTitleSoPagingIsStable() throws {
        let sameMoment = Date(timeIntervalSince1970: 500)
        try insert("z", title: "Zulu", updatedAt: sameMoment)
        try insert("m", title: "Mike", updatedAt: sameMoment)
        try insert("a", title: "Alpha", updatedAt: sameMoment)

        XCTAssertEqual(try page(sort: .recentlyUpdated).items.map(\.id), ["a", "m", "z"])
    }

    // MARK: - Per-user sorts

    func testProgressAndRatingSortsReadOnlyTheBoundUsersRowsAndKeepUnratedItems() throws {
        try insert("movie-1", title: "One")
        try insert("movie-2", title: "Two")
        try insert("movie-3", title: "Three")

        let states = ServerUserMediaStateRepository(database: database)
        _ = try states.update(userID: admin, mediaID: "movie-1", event: .progress, position: 90, duration: 100, at: Date())
        _ = try states.update(userID: member, mediaID: "movie-2", event: .progress, position: 90, duration: 100, at: Date())

        let preferences = ServerUserMediaPreferenceRepository(database: database)
        _ = try preferences.update(userID: admin, mediaID: "movie-1", preference: .rating(5))
        _ = try preferences.update(userID: member, mediaID: "movie-2", preference: .rating(5))

        // 每个用户看到的是自己的数据。
        XCTAssertEqual(try page(sort: .progress, userID: admin).items.map(\.id).first, "movie-1")
        XCTAssertEqual(try page(sort: .progress, userID: member).items.map(\.id).first, "movie-2")
        XCTAssertEqual(try page(sort: .rating, userID: admin).items.map(\.id).first, "movie-1")
        XCTAssertEqual(try page(sort: .rating, userID: member).items.map(\.id).first, "movie-2")

        // 且没有任何记录的条目仍然出现——这是 LEFT JOIN 那条回归的守卫。
        for sort in [ServerLibraryDatabaseSort.progress, .rating, .lastPlayed] {
            let result = try page(sort: sort, userID: admin)
            XCTAssertEqual(result.items.count, 3, "\(sort) 不应丢掉没有记录的条目")
            XCTAssertEqual(result.totalItemCount, 3, "\(sort) 加连接后总数不应改变")
            XCTAssertTrue(result.items.map(\.id).contains("movie-3"), "\(sort) 应保留从未播放/未评级的条目")
        }
    }

    // MARK: - Genre

    func testGenreFilterMatchesWholeTokensAndEscapesLikeMetacharacters() throws {
        try insert("action", title: "Action", genre: "动作, 科幻")
        try insert("mocap", title: "Mocap", genre: "动作捕捉")
        try insert("percent", title: "Percent", genre: "100%纪实")
        try insert("underscore", title: "Underscore", genre: "a_b")

        XCTAssertEqual(try page(sort: .title, genre: "动作").items.map(\.id), ["action"])
        XCTAssertEqual(try page(sort: .title, genre: "科幻").items.map(\.id), ["action"])
        XCTAssertEqual(try page(sort: .title, genre: "动作捕捉").items.map(\.id), ["mocap"])

        // `%` 与 `_` 是 LIKE 的通配符；转义之后它们只能匹配自己。
        XCTAssertEqual(try page(sort: .title, genre: "100%纪实").items.map(\.id), ["percent"])
        XCTAssertEqual(try page(sort: .title, genre: "a_b").items.map(\.id), ["underscore"])
        XCTAssertEqual(try page(sort: .title, genre: "aXb").items.map(\.id), [])
        XCTAssertEqual(try page(sort: .title, genre: "%").items.map(\.id), [])
    }

    func testContentRatingRestrictionAppliesBeforeCountAndPaginationAndFailsClosed() throws {
        try insert("general", title: "General")
        try insert("teen", title: "Teen")
        try insert("adult", title: "Adult")
        try insert("unknown", title: "Unknown")
        let details = MediaDetailRepository(database: database)
        for (id, rating) in [("general", "G"), ("teen", "PG-13"), ("adult", "R"), ("unknown", "UNRATED")] {
            try details.save(MediaDetailSnapshot(
                metadata: MediaDetailMetadata(mediaID: id, contentRating: rating, provider: "fixture", language: "en")
            ))
        }

        let restricted = try repository.fetchServerLibraryPage(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true,
            searchText: nil, offset: 0, limit: 1, sort: .title,
            userID: admin, playbackFilter: nil, maximumContentRating: "PG-13"
        )
        XCTAssertEqual(restricted.totalItemCount, 2, "受限条目不能进入分页总数")
        XCTAssertEqual(restricted.items.map(\.id), ["general"], "LIMIT 应在内容策略过滤之后执行")

        let secondPage = try repository.fetchServerLibraryPage(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true,
            searchText: nil, offset: 1, limit: 1, sort: .title,
            userID: admin, playbackFilter: nil, maximumContentRating: "PG-13"
        )
        XCTAssertEqual(secondPage.items.map(\.id), ["teen"])

        let invalidMaximum = try repository.fetchServerLibraryPage(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true,
            searchText: nil, offset: 0, limit: 100, sort: .title,
            userID: admin, playbackFilter: nil, maximumContentRating: "custom"
        )
        XCTAssertEqual(invalidMaximum.totalItemCount, 0, "无法识别的策略上限必须失败即关闭")
    }

    // MARK: - Facets

    func testFacetsAreAuthorizedBoundedAndScopedToTheCurrentUser() throws {
        try insert("a", title: "A", runtime: 100, rating: 8.0, genre: "科幻, 动作")
        try insert("b", title: "B", genre: "动作")
        try repository.upsert(MediaItem(
            id: "hidden", type: .movie, title: "Hidden", sourcePath: "/not-authorized", genre: "禁止"
        ))
        _ = try ServerUserMediaPreferenceRepository(database: database)
            .update(userID: member, mediaID: "a", preference: .rating(4))

        let adminFacets = try repository.fetchServerLibraryFacets(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true, userID: admin
        )
        XCTAssertEqual(adminFacets.genreValues.count, 2)
        XCTAssertFalse(adminFacets.genreValues.contains("禁止"), "未授权来源的题材不得出现")
        XCTAssertTrue(adminFacets.hasRuntime)
        XCTAssertTrue(adminFacets.hasProviderRating)
        // 评级是每个用户自己的：别人评过分，不代表这个用户该看到"按评级"排序。
        XCTAssertFalse(adminFacets.hasUserRating)

        let memberFacets = try repository.fetchServerLibraryFacets(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true, userID: member
        )
        XCTAssertTrue(memberFacets.hasUserRating)

        let bounded = try repository.fetchServerLibraryFacets(
            allowedSourcePaths: [sourcePath], type: nil, topLevelOnly: true,
            userID: admin, maximumDistinctGenreRows: 1
        )
        XCTAssertEqual(bounded.genreValues.count, 1, "题材去重查询必须有硬上限")
    }
}
