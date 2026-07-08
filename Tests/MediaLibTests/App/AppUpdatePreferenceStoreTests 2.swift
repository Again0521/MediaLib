import XCTest
@testable import MediaLib

final class AppUpdatePreferenceStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        suiteName = "AppUpdatePreferenceStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        calendar = nil
    }

    func testMarkUpdateCheckSucceededStoresProvidedDate() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        store.markUpdateCheckSucceeded(at: date)

        XCTAssertEqual(defaults.object(forKey: "MediaLib.update.lastSuccessfulCheck") as? Date, date)
    }

    func testBackgroundAttemptRecordsAttemptWhenNoRecentAttemptOrSameDaySuccessExists() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        let now = date(year: 2026, month: 7, day: 7, hour: 10)

        XCTAssertTrue(store.recordBackgroundAttemptIfNeeded(now: now))
        XCTAssertEqual(defaults.object(forKey: "MediaLib.update.lastBackgroundAttempt") as? Date, now)
    }

    func testBackgroundAttemptIsThrottledForFourHoursAfterAttempt() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        let first = date(year: 2026, month: 7, day: 7, hour: 10)
        let second = first.addingTimeInterval(3 * 60 * 60 + 59 * 60)

        XCTAssertTrue(store.recordBackgroundAttemptIfNeeded(now: first))
        XCTAssertFalse(store.recordBackgroundAttemptIfNeeded(now: second))
        XCTAssertEqual(defaults.object(forKey: "MediaLib.update.lastBackgroundAttempt") as? Date, first)
    }

    func testBackgroundAttemptSkipsWhenSuccessfulCheckAlreadyHappenedSameDay() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        let success = date(year: 2026, month: 7, day: 7, hour: 9)
        let now = date(year: 2026, month: 7, day: 7, hour: 15)
        store.markUpdateCheckSucceeded(at: success)

        XCTAssertFalse(store.recordBackgroundAttemptIfNeeded(now: now))
        XCTAssertNil(defaults.object(forKey: "MediaLib.update.lastBackgroundAttempt"))
    }

    func testBackgroundAttemptAllowsNextDayAfterSuccessfulCheck() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        let success = date(year: 2026, month: 7, day: 7, hour: 22)
        let nextDay = date(year: 2026, month: 7, day: 8, hour: 9)
        store.markUpdateCheckSucceeded(at: success)

        XCTAssertTrue(store.recordBackgroundAttemptIfNeeded(now: nextDay))
        XCTAssertEqual(defaults.object(forKey: "MediaLib.update.lastBackgroundAttempt") as? Date, nextDay)
    }

    func testRegisterLaunchInvitesOnlyOnThirdLaunchAndOnlyOnce() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)

        XCTAssertFalse(store.registerLaunchAndShouldInvite())
        XCTAssertFalse(store.registerLaunchAndShouldInvite())
        XCTAssertTrue(store.registerLaunchAndShouldInvite())
        XCTAssertFalse(store.registerLaunchAndShouldInvite())

        XCTAssertEqual(defaults.integer(forKey: "MediaLib.launchCount"), 4)
        XCTAssertTrue(defaults.bool(forKey: "MediaLib.sponsorInvited"))
    }

    func testRegisterLaunchDoesNotInviteWhenAlreadyInvitedBeforeThirdLaunch() {
        let store = AppUpdatePreferenceStore(defaults: defaults, calendar: calendar)
        defaults.set(true, forKey: "MediaLib.sponsorInvited")
        defaults.set(2, forKey: "MediaLib.launchCount")

        XCTAssertFalse(store.registerLaunchAndShouldInvite())
        XCTAssertEqual(defaults.integer(forKey: "MediaLib.launchCount"), 3)
        XCTAssertTrue(defaults.bool(forKey: "MediaLib.sponsorInvited"))
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
