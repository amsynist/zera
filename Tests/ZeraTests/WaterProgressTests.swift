import XCTest
@testable import Zera

final class WaterProgressTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func day(_ d: Int, _ h: Int = 10) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
    private func sip(_ at: Date, hydration: Bool = true) -> CompletionEntry {
        CompletionEntry(itemKind: .reminder, refID: UUID().uuidString, title: "Drink water", occurrence: at, completedAt: at, hydration: hydration)
    }

    func testCountsOnlyThatDaysWater() {
        let log = [sip(day(9, 9)), sip(day(9, 13)), sip(day(9, 15), hydration: false), sip(day(8, 23))]
        XCTAssertEqual(WaterStats.glasses(on: day(9), in: log, calendar: cal), 2)
        XCTAssertEqual(WaterStats.glasses(on: day(8), in: log, calendar: cal), 1)
        XCTAssertEqual(WaterStats.glasses(on: day(7), in: log, calendar: cal), 0)
    }

    func testWeekIsSevenDaysOldestFirst() {
        let log = [sip(day(10)), sip(day(4)), sip(day(3))]
        let week = WaterStats.week(ending: day(10), in: log, calendar: cal)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.date, cal.startOfDay(for: day(4)))
        XCTAssertEqual(week.map(\.count), [1, 0, 0, 0, 0, 0, 1])
    }

    func testStreakCountsBackFromTodayOrYesterday() {
        let log = [sip(day(7)), sip(day(8)), sip(day(9))]
        XCTAssertEqual(WaterStats.streak(ending: day(9), in: log, calendar: cal), 3)
        // Nothing yet today: the streak still stands from yesterday.
        XCTAssertEqual(WaterStats.streak(ending: day(10), in: log, calendar: cal), 3)
        XCTAssertEqual(WaterStats.streak(ending: day(12), in: log, calendar: cal), 0)
    }

    func testGoalIsTodaysScheduledWaterOrEight() {
        XCTAssertEqual(WaterStats.goal(on: day(9), reminders: [], calendar: cal), 8)
        let water = Reminder(title: "Drink water", category: .hydration, scheduledAt: day(1, 9), rule: RepeatRule(unit: .hour, every: 2))
        let goal = WaterStats.goal(on: day(9), reminders: [water], calendar: cal)
        XCTAssertGreaterThan(goal, 0)
        XCTAssertLessThanOrEqual(goal, 24)
    }

    func testCardIsOfferedOnFridaysOrAtSevenDaysOncePerWeek() {
        let friday = day(9), thursday = day(8)   // 9 Oct 2026 is a Friday
        XCTAssertTrue(WaterStats.shouldOfferCard(now: friday, streak: 1, offeredWeek: nil, calendar: cal))
        XCTAssertFalse(WaterStats.shouldOfferCard(now: friday, streak: 1, offeredWeek: WaterStats.weekKey(friday, calendar: cal), calendar: cal))
        XCTAssertFalse(WaterStats.shouldOfferCard(now: thursday, streak: 3, offeredWeek: nil, calendar: cal))
        XCTAssertTrue(WaterStats.shouldOfferCard(now: thursday, streak: 7, offeredWeek: nil, calendar: cal))
        XCTAssertEqual(WaterStats.todayLine(count: 4, goal: 8), "4 of 8 today")
    }

    @MainActor
    func testWeekCardExportsAtFullSize() throws {
        let card = WaterWeekCardView(frame: NSRect(x: 0, y: 0, width: 360, height: 450))
        card.week = WaterStats.week(ending: day(9), in: [sip(day(9)), sip(day(8))], calendar: cal)
        card.goal = 8; card.streak = 2
        XCTAssertEqual(card.total, 2)
        let data = try XCTUnwrap(card.pngData())
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 1080)
        XCTAssertEqual(image.pixelsHigh, 1350)
    }
}
