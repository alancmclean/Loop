//
//  AdaptiveOverrideCore.swift
//  Loop
//
//  Pure, HealthKit-free logic for the adaptive override layer:
//   - which lifestyle / physiology / site signals are active at a given time
//   - meal detection from glucose (no carb data needed)
//   - the real-time decision, under hard safety limits
//
//  Nothing in here touches dosing directly. The output is an `insulinNeedsScaleFactor`
//  that Loop's existing override mechanism applies to basal, ISF and carb ratio.
//

import Foundation

// MARK: - Input data

struct AOGlucosePoint: Equatable {
    let date: Date
    let mgdl: Double
}

struct AOInsulinDose: Equatable {
    let start: Date
    let end: Date
    let units: Double
    /// True for boluses (manual or automatic), false for basal / temp basal delivery.
    var isBolus: Bool = false
    /// True only for boluses the user gave (not Loop's automatic boluses).
    var isManual: Bool = false
}

struct AOWorkout: Equatable {
    let start: Date
    let end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct AOSleepInterval: Equatable {
    let start: Date
    let end: Date
}

struct AOSleepNight: Equatable {
    let wake: Date
    let asleepDuration: TimeInterval
}

/// A single physiology reading (HRV in ms, resting heart rate in bpm, wrist temperature in °C).
struct AOMetricSample: Equatable {
    let date: Date
    let value: Double
}

struct AOSiteChange: Codable, Equatable {
    let date: Date
    /// Body location, if the user logged one.
    var location: String?
}

enum AOLogKind: String, Codable, CaseIterable {
    case alcohol, illness, stress

    var displayName: String {
        switch self {
        case .alcohol: return "Alcohol"
        case .illness: return "Feeling sick"
        case .stress: return "Stressed"
        }
    }
}

struct AOLogEntry: Codable, Equatable {
    let kind: AOLogKind
    let date: Date
}

/// Everything the signal rules look at, besides glucose and insulin.
struct AOContext {
    var workouts: [AOWorkout] = []
    var nights: [AOSleepNight] = []
    var siteChanges: [AOSiteChange] = []
    var hrv: [AOMetricSample] = []
    var restingHeartRate: [AOMetricSample] = []
    var wristTemperature: [AOMetricSample] = []
    var logs: [AOLogEntry] = []
    var meals: [Date] = []
    /// Step counts (hourly totals from Health, plus a live pedometer top-up for the last 2 h).
    var steps: [AOMetricSample] = []
}

// MARK: - Signals

struct AOSignal: Hashable, Codable, Comparable {
    let id: String

    static let exerciseEarly = AOSignal(id: "exerciseEarly")
    static let exerciseLate = AOSignal(id: "exerciseLate")
    static let shortSleep = AOSignal(id: "shortSleep")
    static let newSite = AOSignal(id: "siteNew")
    static let oldSite = AOSignal(id: "siteOld")
    static let lowHRV = AOSignal(id: "lowHRV")
    static let elevatedRestingHR = AOSignal(id: "elevatedRestingHR")
    static let elevatedTemperature = AOSignal(id: "elevatedTemperature")
    static let alcohol = AOSignal(id: "alcohol")
    static let illness = AOSignal(id: "illness")
    static let stress = AOSignal(id: "stress")
    static let weekend = AOSignal(id: "weekend")
    /// 1,000+ steps in the last 2 hours (walking around, errands).
    static let recentMovement = AOSignal(id: "recentMovement")

    static func siteLocation(_ name: String) -> AOSignal {
        AOSignal(id: locationPrefix + name.trimmingCharacters(in: .whitespaces).lowercased())
    }
    private static let locationPrefix = "siteLocation."

    /// Context signals describe "which kind of normal" you're in (weekend, which body site).
    /// They're learned against each other, and ignored when learning the other signals.
    var isContext: Bool { self == .weekend || id.hasPrefix(Self.locationPrefix) }

    var displayName: String {
        switch self {
        case .exerciseEarly: return "Recent exercise"
        case .exerciseLate: return "Exercise earlier (delayed effect)"
        case .shortSleep: return "Short sleep last night"
        case .newSite: return "New site (first 12 h)"
        case .oldSite: return "Site day 3+"
        case .lowHRV: return "Low HRV (stress / strain)"
        case .elevatedRestingHR: return "Raised resting heart rate"
        case .elevatedTemperature: return "Raised wrist temperature"
        case .alcohol: return "Alcohol (logged)"
        case .illness: return "Sick (logged)"
        case .stress: return "Stress (logged)"
        case .weekend: return "Weekend"
        case .recentMovement: return "Moving around (last 2 h)"
        default:
            if id.hasPrefix(Self.locationPrefix) {
                return "Site: " + id.dropFirst(Self.locationPrefix.count).capitalized
            }
            return id
        }
    }

    static func < (lhs: AOSignal, rhs: AOSignal) -> Bool { lhs.id < rhs.id }
}

struct AOSignalRules {
    var minWorkoutDuration: TimeInterval = 20 * 60
    var exerciseEarlyWindow: TimeInterval = 3 * 3600
    var exerciseLateWindow: TimeInterval = 12 * 3600
    var shortSleepThreshold: TimeInterval = 6 * 3600
    var shortSleepEffectWindow: TimeInterval = 8 * 3600
    var sleepMergeGap: TimeInterval = 2 * 3600
    var minNightDuration: TimeInterval = 2 * 3600
    var newSiteWindow: TimeInterval = 12 * 3600
    var oldSiteAge: TimeInterval = 48 * 3600
    /// Alcohol tends to cause delayed lows; the window starts 2 h after logging and runs overnight.
    var alcoholWindow: ClosedRange<TimeInterval> = (2 * 3600)...(16 * 3600)
    var illnessWindow: TimeInterval = 24 * 3600
    var stressWindow: TimeInterval = 6 * 3600
    var physiologyBaselineDays: Double = 30
    var recentMovementSteps: Double = 1000
    var minBaselineSamples = 7
    var calendar = Calendar.current

    // MARK: Sleep

    /// Groups raw asleep intervals (possibly overlapping, from several sources) into nights.
    func nights(from intervals: [AOSleepInterval]) -> [AOSleepNight] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [AOSleepInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = AOSleepInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        var nights: [AOSleepNight] = []
        var clusterEnd: Date?
        var clusterTotal: TimeInterval = 0
        for interval in merged {
            if let end = clusterEnd, interval.start.timeIntervalSince(end) <= sleepMergeGap {
                clusterTotal += interval.end.timeIntervalSince(interval.start)
                clusterEnd = interval.end
            } else {
                if let end = clusterEnd, clusterTotal >= minNightDuration {
                    nights.append(AOSleepNight(wake: end, asleepDuration: clusterTotal))
                }
                clusterEnd = interval.end
                clusterTotal = interval.end.timeIntervalSince(interval.start)
            }
        }
        if let end = clusterEnd, clusterTotal >= minNightDuration {
            nights.append(AOSleepNight(wake: end, asleepDuration: clusterTotal))
        }
        return nights
    }

    // MARK: Physiology

    enum Deviation { case low, high }

    /// Whether the last 24 h of a metric differs from your own baseline (the 30 days before that).
    func deviates(_ samples: [AOMetricSample], at date: Date, direction: Deviation,
                  minAbsolute: Double, sdMultiplier: Double, minRelative: Double = 0) -> Bool {
        let recentStart = date.addingTimeInterval(-24 * 3600)
        let baselineStart = recentStart.addingTimeInterval(-physiologyBaselineDays * 24 * 3600)
        var recent: [Double] = [], baseline: [Double] = []
        for s in samples {
            if s.date >= recentStart && s.date < date { recent.append(s.value) }
            else if s.date >= baselineStart && s.date < recentStart { baseline.append(s.value) }
        }
        guard !recent.isEmpty, baseline.count >= minBaselineSamples else { return false }
        let r = recent.reduce(0, +) / Double(recent.count)
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let sd = sqrt(baseline.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(baseline.count - 1))
        let threshold = max(minAbsolute, sdMultiplier * sd, minRelative * abs(mean))
        switch direction {
        case .low: return r < mean - threshold
        case .high: return r > mean + threshold
        }
    }

    // MARK: Active signals

    /// Signals active at `date`, each with an identifier for the episode that caused it
    /// (used to count independent episodes when learning).
    func activeSignals(at date: Date, context c: AOContext) -> [AOSignal: Date] {
        var result: [AOSignal: Date] = [:]

        for workout in c.workouts where workout.duration >= minWorkoutDuration {
            let sinceEnd = date.timeIntervalSince(workout.end)
            if date >= workout.start && sinceEnd < exerciseEarlyWindow {
                result[.exerciseEarly] = workout.start
            } else if sinceEnd >= exerciseEarlyWindow && sinceEnd < exerciseLateWindow {
                result[.exerciseLate] = workout.start
            }
        }

        for night in c.nights where night.asleepDuration < shortSleepThreshold {
            let sinceWake = date.timeIntervalSince(night.wake)
            if sinceWake >= 0 && sinceWake < shortSleepEffectWindow {
                result[.shortSleep] = night.wake
            }
        }

        if let site = c.siteChanges.last(where: { $0.date <= date }) {
            let age = date.timeIntervalSince(site.date)
            if age < newSiteWindow { result[.newSite] = site.date }
            else if age >= oldSiteAge { result[.oldSite] = site.date }
            if let location = site.location, !location.isEmpty {
                result[.siteLocation(location)] = site.date
            }
        }

        let day = calendar.startOfDay(for: date)
        if deviates(c.hrv, at: date, direction: .low, minAbsolute: 3, sdMultiplier: 1.0, minRelative: 0.15) {
            result[.lowHRV] = day
        }
        if deviates(c.restingHeartRate, at: date, direction: .high, minAbsolute: 4, sdMultiplier: 1.5) {
            result[.elevatedRestingHR] = day
        }
        if deviates(c.wristTemperature, at: date, direction: .high, minAbsolute: 0.5, sdMultiplier: 2.0) {
            result[.elevatedTemperature] = day
        }

        for log in c.logs {
            let since = date.timeIntervalSince(log.date)
            switch log.kind {
            case .alcohol where alcoholWindow.contains(since): result[.alcohol] = log.date
            case .illness where since >= 0 && since < illnessWindow: result[.illness] = log.date
            case .stress where since >= 0 && since < stressWindow: result[.stress] = log.date
            default: break
            }
        }

        if AOSignalRules.steps(in: c.steps, before: date) >= recentMovementSteps {
            result[.recentMovement] = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }

        // Weekend is not used as a signal: in simulation it produced false patterns
        // (e.g. "40% less insulin on weekends" with no real effect), and on real data it showed none.
        return result
    }
}

// MARK: - Meal detection (no carb data)

struct AOMealDetector {
    /// Rise (mg/dL) within `riseWindow` that counts as a meal.
    var minRise = 40.0
    var riseWindow: TimeInterval = 60 * 60
    /// A manual bolus given at or below this glucose is treated as a meal bolus (not a correction).
    var mealBolusMaxGlucose = 150.0
    var minMealBolus = 1.0
    var dedupeWindow: TimeInterval = 90 * 60

    func meals(glucose: [AOGlucosePoint], doses: [AOInsulinDose]) -> [Date] {
        let g = glucose.sorted { $0.date < $1.date }
        var starts: [Date] = []

        // 1. Glucose rises: from a point, does glucose climb ≥ minRise within the window?
        var i = 0
        while i < g.count {
            var j = i + 1
            var found: Int?
            while j < g.count && g[j].date.timeIntervalSince(g[i].date) <= riseWindow {
                if g[j].mgdl - g[i].mgdl >= minRise { found = j; break }
                j += 1
            }
            if let peakIndex = found {
                starts.append(g[i].date)
                // Skip past this rise so one meal isn't detected many times.
                var k = peakIndex
                while k + 1 < g.count && g[k + 1].mgdl >= g[k].mgdl { k += 1 }
                i = k + 1
            } else {
                i += 1
            }
        }

        // 2. Meal boluses: manual bolus at non-high glucose.
        for dose in doses where dose.isManual && dose.isBolus && dose.units >= minMealBolus {
            if let bg = g.last(where: { $0.date <= dose.start && dose.start.timeIntervalSince($0.date) < 15 * 60 }),
               bg.mgdl <= mealBolusMaxGlucose {
                starts.append(dose.start)
            }
        }

        // Dedupe, keeping the earliest in each cluster (bolus usually precedes the rise).
        var result: [Date] = []
        for s in starts.sorted() {
            if let last = result.last, s.timeIntervalSince(last) < dedupeWindow { continue }
            result.append(s)
        }
        return result
    }

    /// Hours around meals are left out of learning: meal insulin and carb-count errors are noise.
    static func isNearMeal(_ date: Date, meals: [Date], before: TimeInterval = 30 * 60, after: TimeInterval = 3 * 3600) -> Bool {
        meals.contains { date >= $0.addingTimeInterval(-before) && date < $0.addingTimeInterval(after) }
    }
}

// MARK: - Real-time decision

struct AOConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case suggest, automatic }

    /// Hard limits no setting can exceed. The defaults below stay at 80–120%; you can widen
    /// them up to these in settings. (In simulation, widening to 50–150% cut lows slightly
    /// more but raised highs — see AdaptiveAdjustmentsValidation/README.md.)
    static let absoluteMinScale = 0.5
    static let absoluteMaxScale = 1.5

    var enabled = false
    var mode: Mode = .suggest
    var minScale = 0.8
    var maxScale = 1.2
    var maxStepPerUpdate = 0.05
    var lowGlucoseMgdl = 90.0
    var fallingRateMgdlPerMin = -2.0
    var glucoseStaleAfter: TimeInterval = 15 * 60
    var deadband = 0.03

    /// Off by default: on real data, day-to-day estimates were noise (no carry-over from one day to the next).
    var useAutosens = false
    var autosensRange: ClosedRange<Double> = 0.85...1.15
    var siteFailureAlerts = true
    var preBolusReminders = true
    /// Raise Loop's target after a workout is recorded (Loop backs off on its own; can't overshoot).
    var postExerciseTarget = true
    var postExerciseTargetMgdl = 150.0
    var postExerciseWindow: TimeInterval = 3 * 3600
    /// Learn a time-of-day profile from where your lows and highs actually happen.
    var useTimeOfDayProfile = true
    /// Learn your usual workout times and prepare beforehand. Off by default: on real data
    /// only ~30% of predicted windows were followed by a workout. Use "Workout soon" instead.
    var autoWorkoutPrep = false
    /// 25% less insulin (basal, and meal boluses via the carb ratio) from up to 90 minutes before:
    /// the combination that worked best around exercise in an AID study (bolus −25% + announce 90 min before).
    var workoutPrepScale = 0.75
    var workoutPrepTargetMgdl = 150.0
    var workoutPrepDuration: TimeInterval = 2 * 3600
    /// Detect running and cycling live from the iPhone's motion sensors (Health only gets workouts when they end).
    var useMotionDetection = true
    /// After a morning ride, prepare before your usual ride-home time (learned, ~78% accurate on your data).
    var predictRideHome = true
    /// Small learned increase on days that look quiet and sedentary (updated through the day).
    var quietDayAdjustment = true
    /// Raise target when insulin on board is unusually high for the time of day and glucose
    /// isn't rising. Off by default: weak predictor of lows on real data.
    var stackingGuard = false
    /// Signals switched off by you, or automatically by the effectiveness check.
    var disabledSignals: Set<AOSignal> = []

    var effectiveRange: ClosedRange<Double> {
        let lo = min(max(minScale, Self.absoluteMinScale), 1.0)
        let hi = max(min(maxScale, Self.absoluteMaxScale), 1.0)
        return lo...hi
    }

    init() {}

    // Tolerant decoding so new fields don't wipe stored settings after an update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AOConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        minScale = try c.decodeIfPresent(Double.self, forKey: .minScale) ?? d.minScale
        maxScale = try c.decodeIfPresent(Double.self, forKey: .maxScale) ?? d.maxScale
        maxStepPerUpdate = try c.decodeIfPresent(Double.self, forKey: .maxStepPerUpdate) ?? d.maxStepPerUpdate
        lowGlucoseMgdl = try c.decodeIfPresent(Double.self, forKey: .lowGlucoseMgdl) ?? d.lowGlucoseMgdl
        fallingRateMgdlPerMin = try c.decodeIfPresent(Double.self, forKey: .fallingRateMgdlPerMin) ?? d.fallingRateMgdlPerMin
        glucoseStaleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .glucoseStaleAfter) ?? d.glucoseStaleAfter
        deadband = try c.decodeIfPresent(Double.self, forKey: .deadband) ?? d.deadband
        useAutosens = try c.decodeIfPresent(Bool.self, forKey: .useAutosens) ?? d.useAutosens
        autosensRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .autosensRange) ?? d.autosensRange
        siteFailureAlerts = try c.decodeIfPresent(Bool.self, forKey: .siteFailureAlerts) ?? d.siteFailureAlerts
        preBolusReminders = try c.decodeIfPresent(Bool.self, forKey: .preBolusReminders) ?? d.preBolusReminders
        disabledSignals = try c.decodeIfPresent(Set<AOSignal>.self, forKey: .disabledSignals) ?? d.disabledSignals
        postExerciseTarget = try c.decodeIfPresent(Bool.self, forKey: .postExerciseTarget) ?? d.postExerciseTarget
        postExerciseTargetMgdl = try c.decodeIfPresent(Double.self, forKey: .postExerciseTargetMgdl) ?? d.postExerciseTargetMgdl
        postExerciseWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .postExerciseWindow) ?? d.postExerciseWindow
        useTimeOfDayProfile = try c.decodeIfPresent(Bool.self, forKey: .useTimeOfDayProfile) ?? d.useTimeOfDayProfile
        autoWorkoutPrep = try c.decodeIfPresent(Bool.self, forKey: .autoWorkoutPrep) ?? d.autoWorkoutPrep
        workoutPrepScale = try c.decodeIfPresent(Double.self, forKey: .workoutPrepScale) ?? d.workoutPrepScale
        workoutPrepTargetMgdl = try c.decodeIfPresent(Double.self, forKey: .workoutPrepTargetMgdl) ?? d.workoutPrepTargetMgdl
        workoutPrepDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .workoutPrepDuration) ?? d.workoutPrepDuration
        stackingGuard = try c.decodeIfPresent(Bool.self, forKey: .stackingGuard) ?? d.stackingGuard
        useMotionDetection = try c.decodeIfPresent(Bool.self, forKey: .useMotionDetection) ?? d.useMotionDetection
        predictRideHome = try c.decodeIfPresent(Bool.self, forKey: .predictRideHome) ?? d.predictRideHome
        quietDayAdjustment = try c.decodeIfPresent(Bool.self, forKey: .quietDayAdjustment) ?? d.quietDayAdjustment
    }
}

enum AODecision: Equatable {
    case apply(scale: Double, reasons: [String])
    case clear(reason: String)
    case noChange(reason: String)
}

struct AODecisionInput {
    var now: Date
    var activeSignals: Set<AOSignal>
    var factors: AOLearnedFactors
    var autosens: Double = 1.0
    var recentGlucose: [AOGlucosePoint]
    var siteFailureSuspected = false
    var currentOwnScale: Double?
    var otherOverrideActive = false
    /// Multipliers from the time-of-day profile, workout prep and stacking guard, with reasons.
    var extraFactors: [(reason: String, factor: Double)] = []
    /// Minimum target to set (mg/dL), e.g. after exercise. nil = keep your normal target.
    var targetFloor: Double?
}

struct AODecisionEngine {
    var config: AOConfig

    func decide(_ input: AODecisionInput) -> AODecision {
        guard config.enabled else {
            return input.currentOwnScale == nil ? .noChange(reason: "Disabled") : .clear(reason: "Disabled")
        }
        if input.otherOverrideActive {
            return .noChange(reason: "Another override is active")
        }

        let sorted = input.recentGlucose.sorted { $0.date < $1.date }
        guard let latest = sorted.last, input.now.timeIntervalSince(latest.date) <= config.glucoseStaleAfter else {
            return .clear(reason: "No recent glucose")
        }
        var rate: Double?
        if sorted.count >= 2 {
            let prev = sorted[sorted.count - 2]
            let minutes = latest.date.timeIntervalSince(prev.date) / 60
            if minutes >= 4 && minutes <= 16 { rate = (latest.mgdl - prev.mgdl) / minutes }
        }

        var target = 1.0
        var reasons: [String] = []
        for signal in input.activeSignals.sorted() where !config.disabledSignals.contains(signal) {
            let f = input.factors.factor(for: signal)
            if abs(f - 1.0) >= 0.01 {
                target *= f
                reasons.append("\(signal.displayName): \(Self.percent(f))")
            }
        }
        if config.useAutosens {
            let a = min(max(input.autosens, config.autosensRange.lowerBound), config.autosensRange.upperBound)
            if abs(a - 1.0) >= 0.01 {
                target *= a
                reasons.append("Recent sensitivity: \(Self.percent(a))")
            }
        }

        for extra in input.extraFactors where abs(extra.factor - 1.0) >= 0.01 {
            target *= extra.factor
            reasons.append("\(extra.reason): \(Self.percent(extra.factor))")
        }
        if let floor = input.targetFloor {
            reasons.append("Target raised to \(Int(floor))")
        }

        let range = config.effectiveRange
        target = min(max(target, range.lowerBound), range.upperBound)

        let lowOrFalling = latest.mgdl < config.lowGlucoseMgdl || (rate.map { $0 <= config.fallingRateMgdlPerMin } ?? false)
        if lowOrFalling && target > 1.0 {
            target = 1.0
            reasons.append("Increase blocked: glucose low or falling")
        }
        if input.siteFailureSuspected && target > 1.0 {
            // More insulin into a failing site doesn't help and stacks up for when it's fixed.
            target = 1.0
            reasons.append("Increase blocked: possible site problem")
        }

        let current = input.currentOwnScale ?? 1.0
        let downStep = lowOrFalling ? config.maxStepPerUpdate * 2 : config.maxStepPerUpdate
        let stepped = min(max(target, current - downStep), current + config.maxStepPerUpdate)

        if abs(stepped - 1.0) < config.deadband && abs(target - 1.0) < config.deadband {
            if input.targetFloor != nil {
                // Target-only override (e.g. after exercise).
                return .apply(scale: 1.0, reasons: reasons)
            }
            return input.currentOwnScale == nil ? .noChange(reason: "No adjustment needed") : .clear(reason: "Signals ended")
        }
        if let own = input.currentOwnScale, abs(stepped - own) < 0.005 {
            return .noChange(reason: "Already at target")
        }
        return .apply(scale: (stepped * 100).rounded() / 100, reasons: reasons)
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
}

// MARK: - Site failure detection

struct AOSiteFailureDetector {
    var minGlucose = 200.0
    var window: TimeInterval = 2 * 3600
    /// Insulin delivered over the window vs scheduled basal for it.
    var minInsulinRatio = 1.5
    var maxDropAllowed = 10.0

    /// High and not coming down despite extra insulin, with no meal to explain it.
    func suspected(now: Date, glucose: [AOGlucosePoint], doses: [AOInsulinDose],
                   scheduledBasalUnits: Double, meals: [Date]) -> Bool {
        let g = glucose.sorted { $0.date < $1.date }
        guard let latest = g.last, now.timeIntervalSince(latest.date) < 15 * 60, latest.mgdl >= minGlucose,
              let earlier = g.last(where: { $0.date <= now.addingTimeInterval(-window) }),
              now.timeIntervalSince(earlier.date) < window + 20 * 60 else { return false }
        if meals.contains(where: { $0 >= now.addingTimeInterval(-3 * 3600) && $0 <= now }) { return false }
        guard latest.mgdl >= earlier.mgdl - maxDropAllowed else { return false }
        // Glucose must have stayed high the whole window, not just spiked at the end.
        guard g.filter({ $0.date >= earlier.date }).allSatisfy({ $0.mgdl >= minGlucose - 30 }) else { return false }
        let range = now.addingTimeInterval(-window)..<now
        let delivered = doses.reduce(0.0) { $0 + AOPatternLearner.units(of: $1, in: range) }
        return scheduledBasalUnits > 0 && delivered >= minInsulinRatio * scheduledBasalUnits
    }
}

// MARK: - Workout prep, time-of-day profile, stacking guard

struct AOWorkoutHabit: Codable, Equatable, Hashable {
    let weekend: Bool
    let minuteOfDay: Int
    let frequency: Double
}

struct AOWorkoutHabitLearner {
    var slotMinutes = 30
    var minFrequency = 0.35
    var minOccurrences = 4
    var calendar = Calendar.current

    func habits(workouts: [AOWorkout], start: Date, end: Date) -> [AOWorkoutHabit] {
        var dayCount: [Bool: Int] = [true: 0, false: 0]
        var day = calendar.startOfDay(for: start)
        while day < end {
            dayCount[calendar.isDateInWeekend(day), default: 0] += 1
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        var slotDays: [Bool: [Int: Set<Date>]] = [true: [:], false: [:]]
        for w in workouts where w.start >= start && w.start < end && w.duration >= 20 * 60 {
            let c = calendar.dateComponents([.hour, .minute], from: w.start)
            let slot = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / slotMinutes
            slotDays[calendar.isDateInWeekend(w.start), default: [:]][slot, default: []].insert(calendar.startOfDay(for: w.start))
        }
        var result: [AOWorkoutHabit] = []
        for weekend in [false, true] {
            let days = dayCount[weekend] ?? 0
            guard days > 0 else { continue }
            let slots = slotDays[weekend] ?? [:]
            var candidates: [(slot: Int, freq: Double)] = []
            for (slot, set) in slots {
                let merged = set.union(slots[slot - 1] ?? []).union(slots[slot + 1] ?? [])
                let freq = Double(merged.count) / Double(days)
                if merged.count >= minOccurrences && freq >= minFrequency { candidates.append((slot: slot, freq: freq)) }
            }
            candidates.sort { $0.freq > $1.freq }
            var kept: [(slot: Int, freq: Double)] = []
            for c in candidates where !kept.contains(where: { abs($0.slot - c.slot) <= 2 }) { kept.append(c) }
            result += kept.map { AOWorkoutHabit(weekend: weekend, minuteOfDay: $0.slot * slotMinutes, frequency: $0.freq) }
        }
        return result
    }

    /// 75 min before a usual workout time until 30 min after it, unless a workout already started.
    func prepActive(habits: [AOWorkoutHabit], workouts: [AOWorkout], now: Date) -> Bool {
        let weekend = calendar.isDateInWeekend(now)
        let dayStart = calendar.startOfDay(for: now)
        for h in habits where h.weekend == weekend {
            let slot = dayStart.addingTimeInterval(TimeInterval(h.minuteOfDay * 60))
            guard now >= slot.addingTimeInterval(-75 * 60), now <= slot.addingTimeInterval(30 * 60) else { continue }
            if !workouts.contains(where: { $0.start >= slot.addingTimeInterval(-120 * 60) && $0.start <= now }) { return true }
        }
        return false
    }
}

/// Outcome-based time-of-day profile, learned from glucose only (no carbs, no insulin model).
/// Each day: for any hour with lows more than 4% of the time, the 1–2 hours *before* it get 2% less
/// insulin; hours with highs over 20% and almost no lows get 1.5% more. Bounded, and it settles
/// once outcomes improve, because it only looks at the last 7 days.
struct AOTimeOfDayProfile: Codable, Equatable {
    var factors: [Int: Double] = [:]
    var updatedAt: Date = .distantPast

    var stepDown = 0.02
    var stepUp = 0.015
    var lowThreshold = 0.04
    var highThreshold = 0.20
    var range: ClosedRange<Double> = 0.7...1.15

    func factor(at date: Date, calendar: Calendar = .current) -> Double {
        factors[calendar.component(.hour, from: date)] ?? 1.0
    }

    mutating func update(glucose: [AOGlucosePoint], now: Date, calendar: Calendar = .current) {
        var byHour: [Int: [Double]] = [:]
        for p in glucose where p.date >= now.addingTimeInterval(-7 * 24 * 3600) && p.date < now {
            byHour[calendar.component(.hour, from: p.date), default: []].append(p.mgdl)
        }
        for (hour, values) in byHour where values.count >= 36 {
            let low = Double(values.filter { $0 < 70 }.count) / Double(values.count)
            let high = Double(values.filter { $0 > 180 }.count) / Double(values.count)
            for lead in [1, 2] {
                let k = (hour - lead + 24) % 24
                let current = factors[k] ?? 1.0
                if low > lowThreshold {
                    factors[k] = max(range.lowerBound, current - stepDown)
                } else if high > highThreshold && low < lowThreshold / 2 {
                    factors[k] = min(range.upperBound, current + stepUp)
                }
            }
        }
        updatedAt = now
    }

    enum CodingKeys: String, CodingKey { case factors, updatedAt }
}

struct AOStackingGuard {
    var minIOB = 2.0
    var multipleOfTypical = 1.8
    var maxGlucose = 150.0
    var maxRiseMgdlPerMin = 0.5

    func active(iob: Double, typicalIOB: Double?, glucose: [AOGlucosePoint]) -> Bool {
        guard let typical = typicalIOB else { return false }
        let g = glucose.sorted { $0.date < $1.date }
        guard let latest = g.last, latest.mgdl < maxGlucose else { return false }
        var rate = 0.0
        if let prev = g.dropLast().last(where: { latest.date.timeIntervalSince($0.date) >= 9 * 60 }) {
            rate = (latest.mgdl - prev.mgdl) / (latest.date.timeIntervalSince(prev.date) / 60)
        }
        return iob > max(minIOB, multipleOfTypical * typical) && rate <= maxRiseMgdlPerMin
    }
}

extension AOInsulinModel {
    /// Total insulin on board (all delivered insulin, including basal) at `date`.
    static func onBoard(_ doses: [AOInsulinDose], at date: Date) -> Double {
        doses.reduce(0.0) { total, d in
            guard d.start <= date else { return total }
            let mid = d.start.addingTimeInterval(d.end.timeIntervalSince(d.start) / 2)
            return total + d.units * onBoardFraction(after: date.timeIntervalSince(mid))
        }
    }
}
