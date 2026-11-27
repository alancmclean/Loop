//
//  WeeklyReportTests.swift
//  LoopTests
//

import XCTest
@testable import Loop

final class WeeklyReportTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Monday 2026-11-30 00:00 UTC.
    private var end: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 30))! }

    /// 29 days of 5-minute glucose ending at `end`, from a function of (day index, minute of day).
    private func glucose(_ value: (Int, Int) -> Double) -> [AOGlucosePoint] {
        let start = end.addingTimeInterval(-29 * 86400)
        return (0..<(29 * 288)).map { i in
            let date = start.addingTimeInterval(Double(i) * 300)
            return AOGlucosePoint(date: date, mgdl: value(i / 288, (i % 288) * 5))
        }
    }

    private func input(glucose: [AOGlucosePoint], doses: [AOInsulinDose] = [], workouts: [AOWorkout] = []) -> AOReportInput {
        AOReportInput(start: end.addingTimeInterval(-7 * 86400), end: end, glucose: glucose, doses: doses,
                      workouts: workouts, calendar: calendar)
    }

    private func at(day: Int, minute: Int) -> Date {
        end.addingTimeInterval(-29 * 86400 + Double(day) * 86400 + Double(minute) * 60)
    }

    func testMetricsAndHeadline() throws {
        // 10% of every day below 54, 10% above 180, the rest 120.
        let g = glucose { _, m in m < 144 ? 50 : (m >= 1296 ? 200 : 120) }
        let r = try XCTUnwrap(AOReportAnalyzer().make(input(glucose: g), trigger: .manual, now: end))
        XCTAssertEqual(r.metrics.below70, 0.1, accuracy: 0.01)
        XCTAssertEqual(r.metrics.above180, 0.1, accuracy: 0.01)
        XCTAssertEqual(r.metrics.timeInRange, 0.8, accuracy: 0.01)
        XCTAssertEqual(r.metrics.coverage, 1, accuracy: 0.01)
        XCTAssertNotNil(r.previous)
        XCTAssertEqual(r.tone, .tough)   // 10% below 54
        XCTAssertEqual(r.metrics.below54, 0.1, accuracy: 0.01)
        XCTAssertTrue(r.headline.hasPrefix("80% in range"))
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.hours.count, 24)
        XCTAssertTrue(r.suggestions.contains { $0.category == .safety })
    }

    func testNotEnoughDataGivesNoReport() {
        let g = glucose { _, _ in 120 }.filter { $0.date < end.addingTimeInterval(-7 * 86400) }
        XCTAssertNil(AOReportAnalyzer().make(input(glucose: g), trigger: .manual, now: end))
    }

    func testEpisodesNeedDuration() {
        let a = AOReportAnalyzer()
        let t0 = end
        let points = [65, 64, 120, 120, 66, 65, 64, 63, 120].enumerated().map {
            AOGlucosePoint(date: t0.addingTimeInterval(Double($0.offset) * 300), mgdl: Double($0.element))
        }
        // First dip lasts 5 minutes (too short); the second, 15 minutes after it, lasts 15 minutes.
        let lows = a.episodes(points, mergeGap: 5 * 60, minDuration: 10 * 60) { $0 < 70 }
        XCTAssertEqual(lows.count, 1)
        XCTAssertEqual(lows.first?.extreme, 63)
    }

    func testRideLowAndReboundAreClassified() throws {
        // Every day: ride 17:00–18:00, low 17:40–18:10, then a rebound high 19:00–20:00.
        let g = glucose { _, m in
            if (1060..<1090).contains(m) { return 60 }
            if (1140..<1200).contains(m) { return 220 }
            return 120
        }
        let workouts = (0..<29).map { AOWorkout(start: at(day: $0, minute: 1020), end: at(day: $0, minute: 1080)) }
        let r = try XCTUnwrap(AOReportAnalyzer().make(input(glucose: g, workouts: workouts), trigger: .manual, now: end))
        XCTAssertEqual(r.lows.count, 7)
        XCTAssertEqual(r.lows.byContext[AOLowContext.duringRide.rawValue], 7)
        XCTAssertEqual(r.highs.byContext[AOHighContext.rebound.rawValue], 7)
        XCTAssertEqual(r.rollercoaster.lowsFollowedByHigh, 7)
        XCTAssertEqual(r.rides.rides.count, 7)
        XCTAssertTrue(r.rides.rides.allSatisfy(\.wentLow))
        XCTAssertTrue(r.suggestions.contains { $0.id == "habit.rides" })
        XCTAssertTrue(r.suggestions.contains { $0.id == "habit.lowtreatment" })
    }

    func testCorrectionsOnActiveInsulinSuggestWaiting() throws {
        // Every day: high 13:20–14:40, corrections at 13:30 (5 U) and 14:10 (3 U), low 16:00–16:20.
        // Meal-time boluses at 8:00 (glucose 110) are never followed by a low.
        let g = glucose { _, m in
            if (800..<880).contains(m) { return 220 }
            if (960..<985).contains(m) { return 60 }
            return 110
        }
        var doses: [AOInsulinDose] = []
        for d in 0..<29 {
            for (minute, units) in [(480, 2.0), (810, 5.0), (850, 3.0)] {
                let t = at(day: d, minute: minute)
                doses.append(AOInsulinDose(start: t, end: t, units: units, isBolus: true, isManual: true))
            }
        }
        let r = try XCTUnwrap(AOReportAnalyzer().make(input(glucose: g, doses: doses), trigger: .manual, now: end))
        let c = r.corrections
        XCTAssertGreaterThanOrEqual(c.corrections4w, 40)
        XCTAssertEqual(c.correctionLowRate4w ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(c.otherBolusLowRate4w ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(c.correctionsThisWeek, 14)
        XCTAssertEqual(c.correctionsOnActiveInsulinThisWeek, 7)   // the 14:10 ones, on top of the 13:30 bolus
        XCTAssertEqual(r.lows.byContext[AOLowContext.afterHigh.rawValue], 7)
        XCTAssertEqual(r.suggestions.first { $0.category != .safety }?.id, "habit.corrections")
    }

    func testBasalBlockFromDeliveredInsulin() throws {
        // Flat glucose, no boluses; delivered basal 1.5 U/h against a 1.0 U/h schedule.
        let g = glucose { _, _ in 120 }
        let start = end.addingTimeInterval(-29 * 86400)
        let doses = (0..<(29 * 288)).map { i -> AOInsulinDose in
            let t = start.addingTimeInterval(Double(i) * 300)
            return AOInsulinDose(start: t, end: t.addingTimeInterval(300), units: 1.5 / 12)
        }
        var inp = input(glucose: g, doses: doses)
        inp.scheduledBasal = { _ in 1.0 }
        let r = try XCTUnwrap(AOReportAnalyzer().make(inp, trigger: .manual, now: end))
        let night = try XCTUnwrap(r.insulin.blocks.first { $0.startHour == 0 })
        XCTAssertEqual(night.deliveredRatio, 1.5, accuracy: 0.02)
        XCTAssertEqual(night.fastingHours, 42)
        XCTAssertEqual(r.insulin.basalPerDay, 36, accuracy: 0.2)
        let s = try XCTUnwrap(r.suggestions.first { $0.id == "dosing.basal.0" })
        XCTAssertTrue(s.title.contains("1.00 U/h → 1.10 U/h"), s.title)   // capped at +10%
        XCTAssertEqual(r.tone, .good)
    }

    func testDueBoundary() {
        var s = AOReportSettings()
        s.weekday = 2; s.hour = 7
        let monday = end   // Monday 00:00
        XCTAssertEqual(s.dueBoundary(now: monday.addingTimeInterval(8 * 3600), calendar: calendar), monday)
        XCTAssertEqual(s.dueBoundary(now: monday.addingTimeInterval(6 * 3600), calendar: calendar), monday.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(s.dueBoundary(now: monday.addingTimeInterval(2.5 * 86400), calendar: calendar), monday)
        s.weekday = 1   // Sunday
        XCTAssertEqual(s.dueBoundary(now: monday.addingTimeInterval(8 * 3600), calendar: calendar), monday.addingTimeInterval(-86400))
    }

    func testStoreRoundTripOrderingAndLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AOReportStore(directory: dir, keep: 2)
        let g = glucose { _, m in m < 100 ? 65 : 130 }
        let base = try XCTUnwrap(AOReportAnalyzer().make(input(glucose: g), trigger: .scheduled, now: end))
        var older = base; older.id = UUID(); older.end = end.addingTimeInterval(-14 * 86400)
        var middle = base; middle.id = UUID(); middle.end = end.addingTimeInterval(-7 * 86400)
        store.save(older); store.save(middle); store.save(base)
        let all = store.all()
        XCTAssertEqual(all.map(\.id), [base.id, middle.id])   // newest first, oldest dropped
        XCTAssertEqual(all.first, base)
        store.delete(base.id)
        XCTAssertEqual(store.all().map(\.id), [middle.id])
        // A file that isn't a valid report doesn't hide the others.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertFalse(base.plainText.isEmpty)
    }

    func testHistoryMergeHasNoOverlap() {
        let t = end
        let local = [AOGlucosePoint(date: t, mgdl: 100), AOGlucosePoint(date: t.addingTimeInterval(300), mgdl: 101)]
        let health = [AOGlucosePoint(date: t.addingTimeInterval(-600), mgdl: 90),
                      AOGlucosePoint(date: t.addingTimeInterval(-300), mgdl: 95),
                      AOGlucosePoint(date: t, mgdl: 100)]
        let merged = AOHistoryMerge.glucose(local: local, health: health)
        XCTAssertEqual(merged.map(\.mgdl), [90, 95, 100, 101])
        XCTAssertEqual(AOHistoryMerge.glucose(local: [], health: health).count, 3)
    }
}
