//
//  AdaptiveOverrideTests.swift
//  LoopTests
//

import XCTest
@testable import Loop

final class AdaptiveOverrideTests: XCTestCase {

    // On the hour in UTC; all tests use a UTC calendar.
    private let t0 = Date(timeIntervalSinceReferenceDate: 799_999_200)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private var rules: AOSignalRules { var r = AOSignalRules(); r.calendar = utc; return r }
    private func h(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
    private func m(_ minutes: Double, from date: Date) -> Date { date.addingTimeInterval(minutes * 60) }

    private var enabledConfig: AOConfig {
        var c = AOConfig(); c.enabled = true; c.mode = .automatic; c.maxStepPerUpdate = 1.0; c.useAutosens = false; return c
    }

    private func factors(_ values: [AOSignal: Double]) -> AOLearnedFactors {
        AOLearnedFactors(factors: Dictionary(uniqueKeysWithValues: values.map { ($0.key.id, $0.value) }), episodes: [:], learnedAt: t0)
    }

    private func glucose(_ mgdl: Double, at now: Date, trendPer5Min: Double = 0) -> [AOGlucosePoint] {
        [AOGlucosePoint(date: m(-5, from: now), mgdl: mgdl - trendPer5Min), AOGlucosePoint(date: now, mgdl: mgdl)]
    }

    private func input(_ signals: Set<AOSignal>, _ f: [AOSignal: Double], glucose g: [AOGlucosePoint],
                       own: Double? = nil, other: Bool = false, autosens: Double = 1.0, site: Bool = false) -> AODecisionInput {
        AODecisionInput(now: t0, activeSignals: signals, factors: factors(f), autosens: autosens, recentGlucose: g,
                        siteFailureSuspected: site, currentOwnScale: own, otherOverrideActive: other)
    }

    /// Signals at a date, ignoring the weekend context signal (t0's weekday varies with time zone).
    private func signals(at date: Date, _ context: AOContext) -> Set<AOSignal> {
        Set(rules.activeSignals(at: date, context: context).keys).subtracting([.weekend])
    }

    // MARK: Signals

    func testExerciseWindows() {
        let c = AOContext(workouts: [AOWorkout(start: h(0), end: h(1))])
        XCTAssertEqual(signals(at: h(0.5), c), [.exerciseEarly])
        XCTAssertEqual(signals(at: h(3.5), c), [.exerciseEarly])
        XCTAssertEqual(signals(at: h(5), c), [.exerciseLate])
        XCTAssertEqual(signals(at: h(14), c), [])
    }

    func testShortWorkoutIgnored() {
        XCTAssertEqual(signals(at: h(0.5), AOContext(workouts: [AOWorkout(start: h(0), end: h(0.2))])), [])
    }

    func testSleepNightsMergeOverlapsAndGaps() {
        let nights = rules.nights(from: [
            AOSleepInterval(start: h(0), end: h(2)),
            AOSleepInterval(start: h(1), end: h(3)),
            AOSleepInterval(start: h(3.5), end: h(5)),
            AOSleepInterval(start: h(14), end: h(14.5)),
        ])
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].wake, h(5))
        XCTAssertEqual(nights[0].asleepDuration, 4.5 * 3600, accuracy: 1)
        XCTAssertEqual(signals(at: h(6), AOContext(nights: nights)), [.shortSleep])
    }

    func testSiteAgeAndLocation() {
        let c = AOContext(siteChanges: [AOSiteChange(date: h(0), location: "Arm Left")])
        XCTAssertEqual(signals(at: h(2), c), [.newSite, .siteLocation("arm left")])
        XCTAssertEqual(signals(at: h(24), c), [.siteLocation("Arm Left")])
        XCTAssertEqual(signals(at: h(50), c), [.oldSite, .siteLocation("arm left")])
        XCTAssertTrue(AOSignal.siteLocation("x").isContext)
    }

    func testAlcoholWindowIsDelayed() {
        let c = AOContext(logs: [AOLogEntry(kind: .alcohol, date: h(0))])
        XCTAssertEqual(signals(at: h(1), c), [])
        XCTAssertEqual(signals(at: h(8), c), [.alcohol])
        XCTAssertEqual(signals(at: h(17), c), [])
    }

    func testRestingHeartRateDeviation() {
        // 30 days at ~60 bpm (±1), then 70 bpm today.
        var rhr = (1...30).map { AOMetricSample(date: h(Double(-24 * $0)), value: 60 + Double($0 % 3) - 1) }
        rhr.append(AOMetricSample(date: h(-2), value: 70))
        XCTAssertTrue(signals(at: h(0), AOContext(restingHeartRate: rhr)).contains(.elevatedRestingHR))
        rhr[rhr.count - 1] = AOMetricSample(date: h(-2), value: 61)
        XCTAssertFalse(signals(at: h(0), AOContext(restingHeartRate: rhr)).contains(.elevatedRestingHR))
    }

    // MARK: Meal detection

    func testMealDetectedFromRiseOnce() {
        var g: [AOGlucosePoint] = []
        for i in 0..<36 {   // 3 h: flat 100 for 30 min, rise to 200 over 60 min, then fall
            let t = m(Double(i * 5), from: t0)
            let v: Double = i < 6 ? 100 : (i < 18 ? 100 + Double(i - 5) * 8.3 : 200 - Double(i - 17) * 5)
            g.append(AOGlucosePoint(date: t, mgdl: v))
        }
        let meals = AOMealDetector().meals(glucose: g, doses: [])
        XCTAssertEqual(meals.count, 1)
        XCTAssertLessThanOrEqual(meals[0], m(35, from: t0))
    }

    func testMealBolusCountsButCorrectionDoesNot() {
        let g = [AOGlucosePoint(date: t0, mgdl: 110), AOGlucosePoint(date: h(4), mgdl: 220)]
        let meal = AOInsulinDose(start: m(2, from: t0), end: m(2, from: t0), units: 5, isBolus: true, isManual: true)
        let correction = AOInsulinDose(start: m(2, from: h(4)), end: m(2, from: h(4)), units: 2, isBolus: true, isManual: true)
        let meals = AOMealDetector().meals(glucose: g, doses: [meal, correction])
        XCTAssertEqual(meals, [m(2, from: t0)])
    }

    // MARK: Decision safety

    func testDisabledDoesNothing() {
        XCTAssertEqual(AODecisionEngine(config: AOConfig()).decide(input([.exerciseEarly], [.exerciseEarly: 0.7], glucose: glucose(150, at: t0))),
                       .noChange(reason: "Disabled"))
    }

    func testNeverOverridesUserOverride() {
        let d = AODecisionEngine(config: enabledConfig).decide(input([.exerciseEarly], [.exerciseEarly: 0.7], glucose: glucose(150, at: t0), other: true))
        guard case .noChange = d else { return XCTFail("Expected noChange, got \(d)") }
    }

    func testStaleGlucoseClears() {
        let d = AODecisionEngine(config: enabledConfig).decide(input([.shortSleep], [.shortSleep: 1.2],
            glucose: [AOGlucosePoint(date: m(-30, from: t0), mgdl: 150)], own: 1.1))
        XCTAssertEqual(d, .clear(reason: "No recent glucose"))
    }

    func testClampedToAbsoluteLimits() {
        var config = enabledConfig
        config.minScale = 0.2
        let d = AODecisionEngine(config: config).decide(input([.exerciseEarly, .lowHRV], [.exerciseEarly: 0.6, .lowHRV: 0.6], glucose: glucose(150, at: t0)))
        guard case .apply(let scale, _) = d else { return XCTFail("Expected apply, got \(d)") }
        XCTAssertEqual(scale, AOConfig.absoluteMinScale, accuracy: 0.001)
    }

    func testDisabledSignalIgnored() {
        var config = enabledConfig
        config.disabledSignals = [.shortSleep]
        XCTAssertEqual(AODecisionEngine(config: config).decide(input([.shortSleep], [.shortSleep: 1.2], glucose: glucose(160, at: t0))),
                       .noChange(reason: "No adjustment needed"))
    }

    func testIncreaseBlockedWhenLow() {
        XCTAssertEqual(AODecisionEngine(config: enabledConfig).decide(input([.shortSleep], [.shortSleep: 1.2], glucose: glucose(85, at: t0))),
                       .noChange(reason: "No adjustment needed"))
    }

    func testIncreaseRemovedWhenFallingFast() {
        let d = AODecisionEngine(config: enabledConfig).decide(input([.shortSleep], [.shortSleep: 1.2],
            glucose: glucose(160, at: t0, trendPer5Min: -15), own: 1.15))
        guard case .clear = d else { return XCTFail("Expected clear, got \(d)") }
    }

    func testIncreaseBlockedOnSiteFailure() {
        XCTAssertEqual(AODecisionEngine(config: enabledConfig).decide(input([.illness], [.illness: 1.25], glucose: glucose(250, at: t0), site: true)),
                       .noChange(reason: "No adjustment needed"))
    }

    func testAutosensClampedAndCombined() {
        var config = enabledConfig
        config.useAutosens = true
        let d = AODecisionEngine(config: config).decide(input([.exerciseEarly], [.exerciseEarly: 0.9], glucose: glucose(150, at: t0), autosens: 1.5))
        guard case .apply(let scale, _) = d else { return XCTFail("Expected apply, got \(d)") }
        XCTAssertEqual(scale, 0.9 * 1.15, accuracy: 0.011)
    }

    func testSlewLimit() {
        var config = enabledConfig
        config.maxStepPerUpdate = 0.05
        let d = AODecisionEngine(config: config).decide(input([.shortSleep], [.shortSleep: 1.2], glucose: glucose(160, at: t0)))
        guard case .apply(let scale, _) = d else { return XCTFail("Expected apply, got \(d)") }
        XCTAssertEqual(scale, 1.05, accuracy: 0.001)
    }

    // MARK: Site failure

    func testSiteFailureDetected() {
        let now = h(3)
        let g = stride(from: 0.0, through: 150, by: 5).map { AOGlucosePoint(date: m(-150 + $0, from: now), mgdl: 230 + $0 / 10) }
        let doses = [AOInsulinDose(start: h(1), end: h(3), units: 4)]   // 2 U/h vs 1 U/h scheduled
        XCTAssertTrue(AOSiteFailureDetector().suspected(now: now, glucose: g, doses: doses, scheduledBasalUnits: 2, meals: []))
        XCTAssertFalse(AOSiteFailureDetector().suspected(now: now, glucose: g, doses: doses, scheduledBasalUnits: 2, meals: [h(2)]))
        XCTAssertFalse(AOSiteFailureDetector().suspected(now: now, glucose: g, doses: [], scheduledBasalUnits: 2, meals: []))
    }

    // MARK: Learning

    /// 30 days at 1 U/h, 120 mg/dL; for 3 h after each of 8 workouts only 0.6 U/h was delivered at
    /// the same glucose. Lunch every day adds meal noise that must be ignored.
    private func syntheticMonth() -> (glucose: [AOGlucosePoint], doses: [AOInsulinDose], context: AOContext) {
        var workouts: [AOWorkout] = []
        for day in stride(from: 0, to: 30, by: 4) {
            workouts.append(AOWorkout(start: h(Double(day * 24 + 17)), end: h(Double(day * 24 + 18))))
        }
        var context = AOContext(workouts: workouts)
        var g: [AOGlucosePoint] = []
        var t = h(0)
        while t < h(24 * 30) {
            let hourOfDay = Int(t.timeIntervalSince(h(0)) / 3600) % 24
            g.append(AOGlucosePoint(date: t, mgdl: (12...13).contains(hourOfDay) ? 190 : 120))
            t = m(5, from: t)
        }
        var doses: [AOInsulinDose] = []
        var hour = h(0)
        while hour < h(24 * 30) {
            let early = rules.activeSignals(at: hour.addingTimeInterval(1800), context: context)[.exerciseEarly] != nil
            doses.append(AOInsulinDose(start: hour, end: hour.addingTimeInterval(3600), units: early ? 0.6 : 1.0))
            if Int(hour.timeIntervalSince(h(0)) / 3600) % 24 == 12 {
                doses.append(AOInsulinDose(start: hour, end: hour, units: 6, isBolus: true, isManual: true))
            }
            hour = hour.addingTimeInterval(3600)
        }
        context.meals = AOMealDetector().meals(glucose: g, doses: doses)
        return (g, doses, context)
    }

    func testLearnerFindsExerciseSensitivityAndIgnoresMeals() {
        let data = syntheticMonth()
        XCTAssertGreaterThanOrEqual(data.context.meals.count, 25)
        let buckets = AOBucketBuilder(rules: rules).build(glucose: data.glucose, doses: data.doses, context: data.context, start: h(0), end: h(24 * 30))
        let result = AOPatternLearner().learn(buckets: buckets, isfMgdlPerUnit: 50, learnedAt: t0)
        XCTAssertEqual(result.episodes[AOSignal.exerciseEarly.id], 8)
        let f = result.factor(for: .exerciseEarly)
        XCTAssertLessThan(f, 0.85)
        XCTAssertGreaterThan(f, 0.6)
        XCTAssertGreaterThan(result.factor(for: .exerciseLate), 0.9)
    }

    func testLearnerUsesReduceOnlyPriorsWithoutData() {
        let result = AOPatternLearner().learn(buckets: [], isfMgdlPerUnit: 50, learnedAt: t0)
        XCTAssertEqual(result.factor(for: .exerciseEarly), 0.8)
        XCTAssertEqual(result.factor(for: .alcohol), 0.9)
        // Nothing that would add insulin without your own evidence.
        XCTAssertEqual(result.factor(for: .shortSleep), 1.0)
        XCTAssertEqual(result.factor(for: .illness), 1.0)
    }

    func testInsulinActivityModel() {
        XCTAssertEqual(AOInsulinModel.onBoardFraction(after: 0), 1.0)
        XCTAssertEqual(AOInsulinModel.onBoardFraction(after: 400 * 60), 0.0)
        let iob2h = AOInsulinModel.onBoardFraction(after: 2 * 3600)
        XCTAssertGreaterThan(iob2h, 0.4); XCTAssertLessThan(iob2h, 0.75)
        // A constant 1 U/h delivered for 8 h acts at ~1 U/h by the end.
        let doses = (0..<96).map { AOInsulinDose(start: m(Double($0 * 5), from: t0), end: m(Double($0 * 5 + 5), from: t0), units: 1.0 / 12) }
        XCTAssertEqual(AOInsulinModel.activity(of: doses, in: h(7)..<h(8)), 1.0, accuracy: 0.02)
    }

    func testAutosensComparesWithYourOwnBaseline() {
        // 30 days fasting at 1.2 U/h (settings say 1.0 — that's a settings issue, not a change),
        // then a day at 1.5 U/h → 25% above *your* normal, shrunk by hours of evidence.
        var g: [AOGlucosePoint] = []
        var t = h(0)
        while t < h(24 * 31) { g.append(AOGlucosePoint(date: t, mgdl: 130)); t = m(5, from: t) }
        let doses = (0..<(24 * 31)).map { AOInsulinDose(start: h(Double($0)), end: h(Double($0 + 1)), units: $0 < 24 * 30 ? 1.2 : 1.5) }
        let buckets = AOBucketBuilder(rules: rules).build(glucose: g, doses: doses, context: AOContext(), start: h(0), end: h(24 * 31))
        let est = AOAutosens().estimate(buckets: buckets, now: h(24 * 31), isf: { _ in 50 }, basal: { _ in 1.0 })
        XCTAssertEqual(est.hours, 24)
        XCTAssertGreaterThan(est.factor, 1.1)
        XCTAssertLessThan(est.factor, 1.25 * 1.0 + 0.01)
        // Steady 1.2 U/h every day → no adjustment, even though it's above scheduled basal.
        let steady = (0..<(24 * 31)).map { AOInsulinDose(start: h(Double($0)), end: h(Double($0 + 1)), units: 1.2) }
        let b2 = AOBucketBuilder(rules: rules).build(glucose: g, doses: steady, context: AOContext(), start: h(0), end: h(24 * 31))
        XCTAssertEqual(AOAutosens().estimate(buckets: b2, now: h(24 * 31), isf: { _ in 50 }, basal: { _ in 1.0 }).factor, 1.0, accuracy: 0.01)
    }

    func testBasalSuggestion() {
        var g: [AOGlucosePoint] = []
        var t = h(0)
        while t < h(24 * 14) {
            // Glucose drifts up 15 mg/dL per hour between 4 and 7am (dawn phenomenon), flat otherwise.
            let hod = utc.component(.hour, from: t)
            let minute = Double(utc.component(.minute, from: t))
            g.append(AOGlucosePoint(date: t, mgdl: (4...6).contains(hod) ? 110 + minute / 4 : 110))
            t = m(5, from: t)
        }
        let doses = (0..<(24 * 14)).map { AOInsulinDose(start: h(Double($0)), end: h(Double($0 + 1)), units: 1.0) }
        let buckets = AOBucketBuilder(rules: rules).build(glucose: g, doses: doses, context: AOContext(), start: h(0), end: h(24 * 14))
        let s = AOSettingsTuner().suggestBasal(buckets: buckets, isf: { _ in 50 }, basal: { _ in 1.0 })
        XCTAssertTrue(s.contains { $0.hour == 5 && $0.suggested > 1.0 })
        XCTAssertFalse(s.contains { $0.hour == 14 })
        XCTAssertTrue(s.allSatisfy { $0.suggested <= 1.2 && $0.suggested >= 0.8 })
    }

    func testHabits() {
        var cal = utc
        cal.firstWeekday = 1
        let meals = (0..<28).map { m(Double(12 * 60 + 35), from: cal.startOfDay(for: h(Double($0 * 24)))) }
        let habits = AOHabitLearner(calendar: cal).habits(meals: meals, start: h(0), end: h(28 * 24))
        XCTAssertTrue(habits.contains { !$0.weekend && $0.minuteOfDay == 12 * 60 + 30 })
        let reminder = AOHabitLearner(calendar: cal).dueReminder(habits: habits.filter { !$0.weekend },
                                                                  now: m(12 * 60 + 10, from: cal.startOfDay(for: nextWeekday(cal))))
        XCTAssertNotNil(reminder)
    }

    private func nextWeekday(_ cal: Calendar) -> Date {
        var d = h(24 * 40)
        while cal.isDateInWeekend(d) { d = d.addingTimeInterval(24 * 3600) }
        return d
    }

    // MARK: Effectiveness

    func testEffectivenessDisablesSignalWithMoreLows() {
        let snapshot = AOBaselineSnapshot(takenAt: t0, timeBelowRange: 0.02, timeInRange: 0.7, lowFractionBySignal: ["exerciseLate": 0.02])
        let buckets = (0..<20).map { i in
            AOHourBucket(start: h(Double(i)), hour: i % 24, meanGlucose: 90, firstGlucose: 90, lastGlucose: 90,
                         lowFraction: 0.1, inRangeFraction: 0.9, insulin: 1, signals: [:], nearMeal: false, manualBolusRecently: false)
        }
        let ticks = (0..<20).map { AOTickRecord(hourStart: h(Double($0)), scaleSum: 0.85, count: 1, signals: ["exerciseLate"]) }
        let r = AOEffectivenessEvaluator().evaluate(snapshot: snapshot, bucketsSinceEnabled: buckets, ticks: ticks, now: h(20))
        XCTAssertEqual(r.signalsToDisable, [.exerciseLate])
        XCTAssertFalse(r.demoteToSuggest)   // fewer than 3 days of data
    }

    func testConfigDecodesOldStoredSettings() throws {
        let old = #"{"enabled":true,"mode":"automatic","minScale":0.85}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(AOConfig.self, from: old)
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.minScale, 0.85)
        XCTAssertTrue(c.useAutosens)
        XCTAssertEqual(try JSONDecoder().decode(AOConfig.self, from: JSONEncoder().encode(c)), c)
    }
}
