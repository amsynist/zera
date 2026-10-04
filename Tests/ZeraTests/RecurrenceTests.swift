import XCTest
@testable import Zera

/// The recurrence engine is what the scheduler fires from, so these pin down the exact times.
final class RecurrenceTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, cal: Calendar? = nil) -> Date {
        let c = cal ?? utc
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func hours(_ dates: [Date], cal: Calendar? = nil) -> [Int] {
        dates.map { (cal ?? utc).component(.hour, from: $0) }
    }

    // Acceptance: "Drink water every 2 hours, 9 AM → 9 PM" fires 9, 11, 1, 3, 5, 7, 9 — every day.
    func testHydrationEveryTwoHoursInsideActiveHours() {
        let anchor = date(2026, 6, 15, 9)
        let day1 = Recurrence.occurrences(anchor: anchor, rule: .hours(2), activeStart: 9 * 60, activeEnd: 21 * 60,
                                          from: date(2026, 6, 15), to: date(2026, 6, 16), calendar: utc)
        XCTAssertEqual(hours(day1), [9, 11, 13, 15, 17, 19, 21])
        let day2 = Recurrence.occurrences(anchor: anchor, rule: .hours(2), activeStart: 9 * 60, activeEnd: 21 * 60,
                                          from: date(2026, 6, 16), to: date(2026, 6, 17), calendar: utc)
        XCTAssertEqual(hours(day2), [9, 11, 13, 15, 17, 19, 21])
    }

    func testStartingMidDayFollowsTheStartThenRestartsAtActiveHours() {
        let anchor = date(2026, 6, 15, 10, 30)
        let all = Recurrence.occurrences(anchor: anchor, rule: .hours(1), activeStart: 9 * 60, activeEnd: 21 * 60,
                                         from: date(2026, 6, 15), to: date(2026, 6, 17), calendar: utc)
        let first = all.filter { utc.isDate($0, inSameDayAs: anchor) }
        let second = all.filter { !utc.isDate($0, inSameDayAs: anchor) }
        XCTAssertEqual(first.first, anchor)
        XCTAssertEqual(first.count, 11)                       // 10:30 … 20:30
        XCTAssertEqual(hours(second), Array(9...21))          // 9:00 … 21:00
        XCTAssertEqual(utc.component(.minute, from: second[0]), 0)
    }

    func testNothingBeforeTheStart() {
        let anchor = date(2026, 6, 15, 13)
        let list = Recurrence.occurrences(anchor: anchor, rule: .hours(2), activeStart: 9 * 60, activeEnd: 21 * 60,
                                          from: date(2026, 6, 15), to: date(2026, 6, 16), calendar: utc)
        XCTAssertEqual(hours(list), [13, 15, 17, 19, 21])
    }

    func testActiveHoursAcrossMidnight() {
        let anchor = date(2026, 6, 15, 22)
        let list = Recurrence.occurrences(anchor: anchor, rule: .hours(1), activeStart: 22 * 60, activeEnd: 2 * 60,
                                          from: date(2026, 6, 15), to: date(2026, 6, 16, 12), calendar: utc)
        XCTAssertEqual(hours(list), [22, 23, 0, 1, 2])
    }

    func testIntervalWithoutActiveHoursRunsContinuously() {
        let anchor = date(2026, 6, 15, 23)
        let list = Recurrence.occurrences(anchor: anchor, rule: .minutes(90),
                                          from: anchor, to: date(2026, 6, 16, 3), calendar: utc)
        XCTAssertEqual(list, [anchor, anchor.addingTimeInterval(5400), anchor.addingTimeInterval(10800)])
    }

    func testNextAfterLastOfDayIsTomorrowsFirst() {
        let anchor = date(2026, 6, 15, 9)
        let next = Recurrence.next(after: date(2026, 6, 15, 21), anchor: anchor, rule: .hours(2),
                                   activeStart: 9 * 60, activeEnd: 21 * 60, calendar: utc)
        XCTAssertEqual(next, date(2026, 6, 16, 9))
    }

    func testWeekdaysOnly() {
        let anchor = date(2026, 6, 15, 8)   // a Monday
        let list = Recurrence.occurrences(anchor: anchor, rule: .weekdaysOnly, from: anchor, to: date(2026, 6, 22), calendar: utc)
        XCTAssertEqual(list.map { utc.component(.day, from: $0) }, [15, 16, 17, 18, 19])
        XCTAssertTrue(list.allSatisfy { utc.component(.hour, from: $0) == 8 })
    }

    func testEveryTwoWeeksOnChosenDays() {
        let anchor = date(2026, 6, 15, 18)  // Monday
        let rule = RepeatRule(unit: .week, every: 2, weekdays: [2, 4])   // Mon + Wed, every other week
        let list = Recurrence.occurrences(anchor: anchor, rule: rule, from: anchor, to: date(2026, 7, 6), calendar: utc)
        XCTAssertEqual(list.map { utc.component(.day, from: $0) }, [15, 17, 29, 1])
    }

    func testMonthlyKeepsTheDayWhenItCan() {
        let anchor = date(2026, 1, 31, 10)
        let list = Recurrence.occurrences(anchor: anchor, rule: .monthly, from: anchor, to: date(2026, 5, 1), calendar: utc)
        XCTAssertEqual(list.map { utc.component(.day, from: $0) }, [31, 28, 31, 30])
    }

    func testEndDateIsInclusive() {
        var rule = RepeatRule.daily
        rule.endDate = date(2026, 6, 17)
        let anchor = date(2026, 6, 15, 7)
        let list = Recurrence.occurrences(anchor: anchor, rule: rule, from: anchor, to: date(2026, 7, 1), calendar: utc)
        XCTAssertEqual(list.count, 3)
    }

    func testSkipsAheadForOldStarts() {
        let anchor = date(2020, 1, 1, 9)
        let list = Recurrence.occurrences(anchor: anchor, rule: .daily, from: date(2026, 6, 15), to: date(2026, 6, 16), calendar: utc)
        XCTAssertEqual(list, [date(2026, 6, 15, 9)])
    }

    func testOneOff() {
        let anchor = date(2026, 6, 15, 15)
        XCTAssertEqual(Recurrence.occurrences(anchor: anchor, rule: .noRepeat, from: date(2026, 6, 15), to: date(2026, 6, 16), calendar: utc), [anchor])
        XCTAssertTrue(Recurrence.occurrences(anchor: anchor, rule: .noRepeat, from: date(2026, 6, 16), to: date(2026, 6, 17), calendar: utc).isEmpty)
    }

    func testRuleTitles() {
        XCTAssertEqual(RepeatRule.hours(2).title, "Every 2 hours")
        XCTAssertEqual(RepeatRule.weekdaysOnly.title, "Every weekday")
        XCTAssertEqual(RepeatRule.daily.title, "Every day")
        XCTAssertEqual(RepeatRule.noRepeat.title, "Does not repeat")
    }

    // MARK: Reminder state

    func testDoneAndSnoozeArePerOccurrence() {
        let cal = Calendar.current
        let anchor = date(2026, 6, 15, 9, cal: cal)
        var r = Reminder(title: "Drink water", category: .hydration, scheduledAt: anchor, rule: .hours(2),
                         activeStart: 9 * 60, activeEnd: 21 * 60)
        let occ = r.occurrences(from: date(2026, 6, 15, cal: cal), to: date(2026, 6, 16, cal: cal))
        XCTAssertEqual(occ.count, 7)
        r.doneOccurrences.append(occ[1].timeIntervalSince1970)
        XCTAssertFalse(r.isDone(occ[0]))
        XCTAssertTrue(r.isDone(occ[1]))
        r.snoozedUntil = occ[2].addingTimeInterval(900)
        r.snoozedOccurrence = occ[2].timeIntervalSince1970
        XCTAssertTrue(r.isSnoozed(occ[2], now: occ[2].addingTimeInterval(60)))
        XCTAssertFalse(r.isSnoozed(occ[2], now: occ[2].addingTimeInterval(1000)))
        XCTAssertFalse(r.isSnoozed(occ[3], now: occ[2].addingTimeInterval(60)))
    }

    func testOneOffCompletedCountsAsDone() {
        var r = Reminder(title: "Call", scheduledAt: date(2026, 6, 15, 15))
        XCTAssertFalse(r.isDone(r.scheduledAt))
        r.status = .completed
        XCTAssertTrue(r.isDone(r.scheduledAt))
    }

    func testRemindersSurviveARoundTrip() throws {
        var r = Reminder(title: "Drink water", category: .hydration, scheduledAt: date(2026, 6, 15, 9), rule: .hours(2),
                         activeStart: 540, activeEnd: 1260)
        r.doneOccurrences = [date(2026, 6, 15, 11).timeIntervalSince1970]
        r.snoozedUntil = date(2026, 6, 15, 13, 15)
        r.snoozedOccurrence = date(2026, 6, 15, 13).timeIntervalSince1970
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let back = try dec.decode([Reminder].self, from: enc.encode([r]))[0]
        XCTAssertEqual(back.id, r.id)
        XCTAssertEqual(back.rule, r.rule)
        XCTAssertEqual(back.activeStart, 540)
        XCTAssertEqual(back.activeEnd, 1260)
        XCTAssertEqual(back.category, .hydration)
        XCTAssertEqual(back.doneOccurrences, r.doneOccurrences)
        XCTAssertEqual(back.snoozedUntil, r.snoozedUntil)
        XCTAssertEqual(back.snoozedOccurrence, r.snoozedOccurrence)
    }

    func testOlderFilesWithMissingFieldsStillLoad() throws {
        let json = #"[{"title":"Stretch","scheduledAt":1781514000}]"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let list = try dec.decode([Reminder].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.title, "Stretch")
        XCTAssertEqual(list.first?.rule, .noRepeat)
        XCTAssertEqual(list.first?.status, .active)
    }

    func testCalendarEventsCarryTheirSource() {
        var e = CalendarEvent(title: "Standup", startAt: date(2026, 6, 15, 10), source: .google)
        XCTAssertTrue(e.isExternal)
        e.source = .custom
        XCTAssertFalse(e.isExternal)
        e.location = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(e.joinURL?.host, "meet.google.com")
    }
}
