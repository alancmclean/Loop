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

    func testTargetOnlyOverrideAfterExercise() {
        var i = input([], [:], glucose: glucose(130, at: t0))
        i.targetFloor = 150
        guard case .apply(let scale, let reasons) = AODecisionEngine(config: enabledConfig).decide(i) else { return XCTFail() }
        XCTAssertEqual(scale, 1.0)
        XCTAssertTrue(reasons.contains("Target raised to 150"))
    }

    func testExtraFactorsCombineAndClamp() {
        var config = enabledConfig
        config.minScale = 0.5
        var i = input([.exerciseEarly], [.exerciseEarly: 0.8], glucose: glucose(130, at: t0))
        i.extraFactors = [(reason: "Workout soon", factor: 0.85), (reason: "Time of day", factor: 0.9)]
        guard case .apply(let scale, _) = AODecisionEngine(config: config).decide(i) else { return XCTFail() }
        XCTAssertEqual(scale, 0.8 * 0.85 * 0.9, accuracy: 0.011)
    }

    func testTimeOfDayProfileLowersInsulinBeforeLowHours() {
        // 7 days: lows 10% of the time at 17:00, highs 30% at 10:00, fine otherwise.
        var g: [AOGlucosePoint] = []
        var t = h(0)
        var i = 0
        while t < h(24 * 7) {
            let hour = utc.component(.hour, from: t)
            let v: Double = hour == 17 ? (i % 10 == 0 ? 60 : 110) : hour == 10 ? (i % 10 < 3 ? 200 : 120) : 120
            g.append(AOGlucosePoint(date: t, mgdl: v)); t = m(5, from: t); i += 1
        }
        var p = AOTimeOfDayProfile()
        p.update(glucose: g, now: h(24 * 7), calendar: utc)
        XCTAssertEqual(p.factors[16] ?? 0, 0.98, accuracy: 0.0001); XCTAssertEqual(p.factors[15] ?? 0, 0.98, accuracy: 0.0001)
        XCTAssertEqual(p.factors[9] ?? 0, 1.015, accuracy: 0.0001)
        XCTAssertNil(p.factors[12])
        for _ in 0..<50 { p.update(glucose: g, now: h(24 * 7), calendar: utc) }
        XCTAssertEqual(p.factors[16] ?? 0, 0.7, accuracy: 0.0001)   // bounded
        XCTAssertEqual(p.factors[9] ?? 0, 1.15, accuracy: 0.0001)
    }

    func testWorkoutHabitsAndPrep() {
        // Rides at 16:30 on most weekdays for 4 weeks.
        var workouts: [AOWorkout] = []
        for d in 0..<28 {
            let day = utc.startOfDay(for: h(Double(d * 24)))
            if !utc.isDateInWeekend(day) && d % 5 != 0 {
                workouts.append(AOWorkout(start: m(16 * 60 + 30, from: day), end: m(17 * 60 + 5, from: day)))
            }
        }
        let learner = AOWorkoutHabitLearner(calendar: utc)
        let habits = learner.habits(workouts: workouts, start: h(0), end: h(28 * 24))
        XCTAssertTrue(habits.contains { !$0.weekend && abs($0.minuteOfDay - (16 * 60 + 30)) <= 30 })
        var day = utc.startOfDay(for: h(30 * 24))
        while utc.isDateInWeekend(day) { day = day.addingTimeInterval(24 * 3600) }
        XCTAssertTrue(learner.prepActive(habits: habits, workouts: workouts, now: m(15 * 60 + 45, from: day)))
        XCTAssertFalse(learner.prepActive(habits: habits, workouts: workouts, now: m(12 * 60, from: day)))
        let started = workouts + [AOWorkout(start: m(16 * 60, from: day), end: m(16 * 60 + 40, from: day))]
        XCTAssertFalse(learner.prepActive(habits: habits, workouts: started, now: m(16 * 60 + 50, from: day)))
    }

    func testStackingGuard() {
        let flat = glucose(120, at: t0)
        XCTAssertTrue(AOStackingGuard().active(iob: 6, typicalIOB: 3, glucose: flat))
        XCTAssertFalse(AOStackingGuard().active(iob: 4, typicalIOB: 3, glucose: flat))
        XCTAssertFalse(AOStackingGuard().active(iob: 6, typicalIOB: 3, glucose: glucose(200, at: t0)))
        XCTAssertFalse(AOStackingGuard().active(iob: 6, typicalIOB: nil, glucose: flat))
    }

    func testMotionSessionsDetectOngoingRide() {
        let d = AOMotionWorkoutDetector()
        let samples = [
            AOMotionSample(start: m(0, from: t0), kind: .other, confidence: 2),
            AOMotionSample(start: m(10, from: t0), kind: .cycling, confidence: 2),
            AOMotionSample(start: m(22, from: t0), kind: .other, confidence: 1),     // 2-min stop at a light
            AOMotionSample(start: m(24, from: t0), kind: .cycling, confidence: 1),
        ]
        // Still riding at +40 min → one ongoing session from +10 to now.
        let s = d.sessions(from: samples, now: m(40, from: t0))
        XCTAssertEqual(s, [AOWorkout(start: m(10, from: t0), end: m(40, from: t0))])
        // Only 8 minutes so far → not yet.
        XCTAssertTrue(d.sessions(from: Array(samples.prefix(2)), now: m(18, from: t0)).isEmpty)
        // Low confidence or other activities don't count.
        XCTAssertTrue(d.sessions(from: [AOMotionSample(start: t0, kind: .cycling, confidence: 0)], now: m(30, from: t0)).isEmpty)
    }

    func testMotionMergePrefersHealthWorkouts() {
        let health = [AOWorkout(start: m(5, from: t0), end: m(45, from: t0))]
        let motion = [AOWorkout(start: m(10, from: t0), end: m(44, from: t0)), AOWorkout(start: h(5), end: h(5.5))]
        XCTAssertEqual(AOMotionWorkoutDetector.merge(health: health, motion: motion), [health[0], motion[1]])
    }

    func testOngoingMotionRideActivatesExerciseSignal() {
        let ongoing = AOWorkout(start: m(-20, from: t0), end: t0)
        XCTAssertEqual(signals(at: t0, AOContext(workouts: [ongoing])), [.exerciseEarly])
    }

    // MARK: Day model

    private func summary(daysAgo: Int, from now: Date, morning: Bool, homeMinute: Int?, steps: Double, before10: Double,
                         insulin: Double = 30, glucose: Double = 120) -> AODaySummary {
        let day = utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86400))
        return AODaySummary(day: day, weekday: utc.component(.weekday, from: day), morningRide: morning,
                            afternoonRideMinute: homeMinute, steps: steps, stepsBefore10: before10,
                            daytimeInsulin: insulin, daytimeMeanGlucose: glucose)
    }

    func testRideHomeForecastLearnsTimeAndProbability() {
        let now = m(17 * 60 + 10, from: utc.startOfDay(for: h(24 * 60)))
        var hist: [AODaySummary] = []
        for d in 1...20 {
            // Morning rides most days; ride home ~18:00 on 4 of 5.
            hist.append(summary(daysAgo: d, from: now, morning: true, homeMinute: d % 5 == 0 ? nil : 18 * 60 + (d % 3) * 10,
                                steps: 9000, before10: 3000))
        }
        let model = AODayModel(history: hist, calendar: utc)
        guard let f = model.rideHomeForecast(now: now, morningRideToday: true, afternoonRideStarted: false) else { return XCTFail() }
        XCTAssertGreaterThan(f.probability, 0.65); XCTAssertLessThan(f.probability, 0.9)
        XCTAssertTrue(f.window.contains(now))                       // 17:10 is inside ~17:00-18:35
        XCTAssertNil(model.rideHomeForecast(now: now, morningRideToday: false, afternoonRideStarted: false))
        XCTAssertNil(model.rideHomeForecast(now: now, morningRideToday: true, afternoonRideStarted: true))
    }

    func testRecentWeeksOutweighOldPattern() {
        // Old pattern: this weekday was always a quiet home day. Last 3 weeks: active.
        let now = m(9 * 60, from: utc.startOfDay(for: h(24 * 120)))
        var hist: [AODaySummary] = []
        for wk in 1...12 {
            let recent = wk <= 3
            hist.append(summary(daysAgo: wk * 7, from: now, morning: false, homeMinute: nil,
                                steps: recent ? 12000 : 2500, before10: recent ? 4000 : 800))
            // Other weekdays: mixed, to give the step threshold something to learn from.
            hist.append(summary(daysAgo: wk * 7 + 1, from: now, morning: false, homeMinute: nil, steps: 7000, before10: 2000))
            hist.append(summary(daysAgo: wk * 7 + 2, from: now, morning: false, homeMinute: nil, steps: 3000, before10: 900))
        }
        let model = AODayModel(history: hist, calendar: utc)
        let p = model.sedentaryProbability(now: now, rodeToday: false, stepsBefore10: nil)
        // Same history but without the change in the last 3 weeks:
        let unchanged = hist.map { s -> AODaySummary in
            guard s.steps == 12000 else { return s }
            return AODaySummary(day: s.day, weekday: s.weekday, morningRide: false, afternoonRideMinute: nil, steps: 2500,
                                stepsBefore10: 800, daytimeInsulin: s.daytimeInsulin, daytimeMeanGlucose: s.daytimeMeanGlucose)
        }
        let pUnchanged = AODayModel(history: unchanged, calendar: utc).sedentaryProbability(now: now, rodeToday: false, stepsBefore10: nil)
        // 3 recent active weeks outweigh 9 older quiet ones about equally → the estimate moves a lot.
        XCTAssertLessThan(p, pUnchanged - 0.3)
        XCTAssertEqual(model.sedentaryProbability(now: now, rodeToday: true, stepsBefore10: nil), 0.05)
    }

    func testMorningStepsUpdateQuietDayProbability() {
        let now = m(10 * 60 + 30, from: utc.startOfDay(for: h(24 * 60)))
        var hist: [AODaySummary] = []
        for d in 1...30 {
            let quiet = d % 2 == 0
            hist.append(summary(daysAgo: d, from: now, morning: false, homeMinute: nil,
                                steps: quiet ? 3000 : 10000, before10: quiet ? 800 : 3500))
        }
        let model = AODayModel(history: hist, calendar: utc)
        let lowSteps = model.sedentaryProbability(now: now, rodeToday: false, stepsBefore10: 600)
        let highSteps = model.sedentaryProbability(now: now, rodeToday: false, stepsBefore10: 4000)
        XCTAssertGreaterThan(lowSteps, highSteps + 0.3)
    }

    func testSedentaryFactorLearnedAndBounded() {
        let now = h(24 * 60)
        var hist: [AODaySummary] = []
        for d in 1...30 {
            let quiet = d % 2 == 0
            hist.append(summary(daysAgo: d, from: now, morning: false, homeMinute: nil, steps: quiet ? 3000 : 10000,
                                before10: 1000, insulin: quiet ? 36 : 30, glucose: quiet ? 135 : 120))
        }
        let f = AODayModel(history: hist, calendar: utc).sedentaryFactor(isf: 32)
        XCTAssertGreaterThan(f, 1.05); XCTAssertLessThanOrEqual(f, 1.15)
        XCTAssertEqual(AODayModel(history: [], calendar: utc).sedentaryFactor(isf: 32), 1.0)
    }

    func testRecentMovementSignal() {
        let steps = [AOMetricSample(date: m(-90, from: t0), value: 700), AOMetricSample(date: m(-20, from: t0), value: 500)]
        XCTAssertTrue(signals(at: t0, AOContext(steps: steps)).contains(.recentMovement))
        XCTAssertFalse(signals(at: t0, AOContext(steps: [AOMetricSample(date: m(-30, from: t0), value: 300)])).contains(.recentMovement))
    }

    // MARK: Site failure

    func testSiteFailureDetected() {
        let now = h(3)
        let g = stride(from: 0.0, through: 150, by: 5).map { (x: Double) -> AOGlucosePoint in
            let value: Double = 230 + x / 10
            return AOGlucosePoint(date: m(x - 150, from: now), mgdl: value)
        }
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
        let doses = (0..<96).map { (i: Int) -> AOInsulinDose in
            let minutes = Double(i * 5)
            return AOInsulinDose(start: m(minutes, from: t0), end: m(minutes + 5, from: t0), units: 1.0 / 12)
        }
        XCTAssertEqual(AOInsulinModel.activity(of: doses, in: h(7)..<h(8)), 1.0, accuracy: 0.02)
    }

    func testAutosensComparesWithYourOwnBaseline() {
        // 30 days fasting at 1.2 U/h (settings say 1.0 — that's a settings issue, not a change),
        // then a day at 1.5 U/h → 25% above *your* normal, shrunk by hours of evidence.
        var g: [AOGlucosePoint] = []
        var t = h(0)
        while t < h(24 * 31) { g.append(AOGlucosePoint(date: t, mgdl: 130)); t = m(5, from: t) }
        let doses = (0..<(24 * 31)).map { (i: Int) -> AOInsulinDose in
            let hour = Double(i)
            let units: Double = i < 24 * 30 ? 1.2 : 1.5
            return AOInsulinDose(start: h(hour), end: h(hour + 1), units: units)
        }
        let buckets = AOBucketBuilder(rules: rules).build(glucose: g, doses: doses, context: AOContext(), start: h(0), end: h(24 * 31))
        let est = AOAutosens().estimate(buckets: buckets, now: h(24 * 31), isf: { _ in 50 }, basal: { _ in 1.0 })
        XCTAssertEqual(est.hours, 24)
        XCTAssertGreaterThan(est.factor, 1.1)
        XCTAssertLessThan(est.factor, 1.25 * 1.0 + 0.01)
        // Steady 1.2 U/h every day → no adjustment, even though it's above scheduled basal.
        let steady = (0..<(24 * 31)).map { (i: Int) -> AOInsulinDose in
            let hour = Double(i)
            return AOInsulinDose(start: h(hour), end: h(hour + 1), units: 1.2)
        }
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
        let doses = (0..<(24 * 14)).map { (i: Int) -> AOInsulinDose in
            let hour = Double(i)
            return AOInsulinDose(start: h(hour), end: h(hour + 1), units: 1.0)
        }
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
