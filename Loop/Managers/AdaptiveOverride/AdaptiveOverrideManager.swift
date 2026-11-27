//
//  AdaptiveOverrideManager.swift
//  Loop
//
//  Runs the adaptive override layer in real time.
//
//  Every 5 minutes (and when Apple Health records a new workout or sleep sample):
//   - works out which signals are active (exercise, sleep, site age/location, HRV,
//     resting heart rate, wrist temperature, quick logs, weekend)
//   - estimates recent overall sensitivity from fasting hours
//   - checks for a possible site failure
//   - applies a bounded Loop custom override (or only suggests it, in suggest mode)
//   - sends pre-bolus reminders around your usual meal times
//
//  Once a day it re-learns from the last 30 days, learns meal habits, and runs the
//  effectiveness check. Once a week it suggests settings changes and sends a report.
//
//  The override is a normal Loop custom override: it shows in the app, in Nightscout and
//  in override history, and you can cancel it at any time. It expires after an hour and
//  is refreshed while wanted, so if this layer stops, Loop returns to your normal settings.
//

import Foundation
import HealthKit
import LoopKit
import UserNotifications
import CoreMotion
import os.log

extension Notification.Name {
    static let adaptiveOverrideStatusDidChange = Notification.Name("com.loopkit.Loop.AdaptiveOverride.statusDidChange")
}

struct AOStatus: Equatable {
    var updatedAt: Date?
    var activeSignals: [AOSignal] = []
    var autosens: Double = 1.0
    var autosensHours = 0
    var appliedScale: Double?
    var lastDecision: String = "Not run yet"
    var siteFailureSuspected = false
    /// e.g. "Ride home likely around 6:00 PM (78%)" or "Probably a quiet day (70%)".
    var dayForecast: String?
}

final class AdaptiveOverrideManager {

    /// Set at app launch so the settings screen can reach it.
    private(set) static weak var shared: AdaptiveOverrideManager?

    private let healthStore: HKHealthStore
    private let glucoseStore: GlucoseStore
    private let doseStore: DoseStore
    private let loopManager: LoopDataManager
    private let defaults: UserDefaults
    private let log = OSLog(category: "AdaptiveOverrideManager")

    private var rules = AOSignalRules()
    private let overrideLifetime: TimeInterval = 60 * 60
    private let refreshWhenRemaining: TimeInterval = 20 * 60
    private let updateInterval: TimeInterval = 5 * 60
    private let learningLookback: TimeInterval = 30 * 24 * 3600
    private let relearnInterval: TimeInterval = 24 * 3600
    private let weeklyInterval: TimeInterval = 7 * 24 * 3600
    private let siteAlertCooldown: TimeInterval = 3 * 3600

    private var timer: Timer?
    private let motion = AOMotionActivityReader()
    private let pedometer = CMPedometer()
    /// Target floor wanted by the latest update (used when building / refreshing our override).
    private var desiredTargetFloor: Double?
    private var observerQueries: [HKObserverQuery] = []
    private var isRunning = false
    private var physiologyCache: (fetchedAt: Date, hrv: [AOMetricSample], rhr: [AOMetricSample], temp: [AOMetricSample])?

    private(set) var status = AOStatus() {
        didSet {
            guard status != oldValue else { return }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .adaptiveOverrideStatusDidChange, object: self) }
        }
    }

    init(healthStore: HKHealthStore, glucoseStore: GlucoseStore, doseStore: DoseStore, loopManager: LoopDataManager,
         defaults: UserDefaults = .appGroup ?? .standard) {
        self.healthStore = healthStore
        self.glucoseStore = glucoseStore
        self.doseStore = doseStore
        self.loopManager = loopManager
        self.defaults = defaults
        Self.shared = self
    }

    // MARK: - Persistent state

    private enum Key: String {
        case config, factors, snapshot, ownSyncIdentifier, enabledAt, logs, manualSites, ticks, habits
        case suggestions, report, lastWeeklyAt, siteAlerts, remindedHabits, effectivenessNotes, lastSuggestedScale
        case todProfile, workoutHabits, workoutPrepUntil, typicalIOB, daySummaries
        var full: String { "com.loopkit.Loop.AdaptiveOverride." + rawValue }
    }

    private func load<T: Decodable>(_ key: Key, as type: T.Type) -> T? {
        defaults.data(forKey: key.full).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T?, _ key: Key) {
        if let value { defaults.set(try? JSONEncoder().encode(value), forKey: key.full) }
        else { defaults.removeObject(forKey: key.full) }
    }

    var config: AOConfig {
        get { load(.config, as: AOConfig.self) ?? AOConfig() }
        set {
            let old = config
            save(newValue, .config)
            if newValue.enabled && !old.enabled {
                // Starting fresh: record when, so the effectiveness check has a before/after.
                save(Date(), .enabledAt)
                save(nil as AOBaselineSnapshot?, .snapshot)
                save(nil as AOLearnedFactors?, .factors)
                requestHealthAuthorization()
                if newValue.useMotionDetection { motion.requestAuthorization() }
            }
            Task { await update() }
        }
    }

    private(set) var learnedFactors: AOLearnedFactors {
        get { load(.factors, as: AOLearnedFactors.self) ?? .neutral }
        set { save(newValue, .factors) }
    }

    var enabledAt: Date? { load(.enabledAt, as: Date.self) }
    var mealHabits: [AOMealHabit] { load(.habits, as: [AOMealHabit].self) ?? [] }
    var timeOfDayProfile: AOTimeOfDayProfile { load(.todProfile, as: AOTimeOfDayProfile.self) ?? AOTimeOfDayProfile() }
    var workoutHabits: [AOWorkoutHabit] { load(.workoutHabits, as: [AOWorkoutHabit].self) ?? [] }
    var workoutPrepUntil: Date? { load(.workoutPrepUntil, as: Date.self) }
    private var typicalIOB: [Int: Double] { load(.typicalIOB, as: [Int: Double].self) ?? [:] }

    /// "Workout soon": less insulin and a higher target for the next 90 minutes (or until a workout is recorded).
    func startWorkoutPrep(at date: Date = Date()) {
        save(date.addingTimeInterval(config.workoutPrepDuration), .workoutPrepUntil)
        Task { await update() }
    }

    func cancelWorkoutPrep() {
        save(nil as Date?, .workoutPrepUntil)
        Task { await update() }
    }
    var suggestions: AOSettingsSuggestions { load(.suggestions, as: AOSettingsSuggestions.self) ?? AOSettingsSuggestions() }
    var weeklyReport: AOWeeklyReport? { load(.report, as: AOWeeklyReport.self) }
    var effectivenessNotes: [String] { load(.effectivenessNotes, as: [String].self) ?? [] }
    var logs: [AOLogEntry] { load(.logs, as: [AOLogEntry].self) ?? [] }
    var manualSiteChanges: [AOSiteChange] { load(.manualSites, as: [AOSiteChange].self) ?? [] }
    private var ticks: [AOTickRecord] { load(.ticks, as: [AOTickRecord].self) ?? [] }
    private var siteAlerts: [Date] { load(.siteAlerts, as: [Date].self) ?? [] }

    private var ownSyncIdentifier: UUID? {
        get { defaults.string(forKey: Key.ownSyncIdentifier.full).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.ownSyncIdentifier.full) }
    }

    // MARK: - Quick logs

    func addLog(_ kind: AOLogKind, at date: Date = Date()) {
        var all = logs.filter { $0.date > date.addingTimeInterval(-60 * 24 * 3600) }
        all.append(AOLogEntry(kind: kind, date: date))
        save(all, .logs)
        Task { await update() }
    }

    /// Log a site change (optionally with body location). If the pump already recorded a
    /// change within 3 hours, the location is attached to that one instead.
    func logSiteChange(location: String?, at date: Date = Date()) {
        var all = manualSiteChanges.filter { $0.date > date.addingTimeInterval(-120 * 24 * 3600) }
        all.append(AOSiteChange(date: date, location: location?.trimmingCharacters(in: .whitespaces)))
        save(all, .manualSites)
        Task { await update() }
    }

    /// Body locations you've used before, most recent first.
    var knownSiteLocations: [String] {
        var seen = Set<String>(), result: [String] = []
        for s in manualSiteChanges.reversed() {
            if let l = s.location, !l.isEmpty, seen.insert(l.lowercased()).inserted { result.append(l) }
        }
        return result
    }

    func setSignal(_ signal: AOSignal, enabled: Bool) {
        var c = config
        if enabled { c.disabledSignals.remove(signal) } else { c.disabledSignals.insert(signal) }
        config = c
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { await self?.update() }
        }
        let observedTypes: [HKSampleType] = [HKObjectType.workoutType(), HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
        for type in observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                if error == nil { Task { await self?.update() } }
                completion()
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }
        Task { await update() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observerQueries.forEach { healthStore.stop($0) }
        observerQueries = []
    }

    static var healthReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
        for id in [HKQuantityTypeIdentifier.heartRateVariabilitySDNN, .restingHeartRate, .appleSleepingWristTemperature, .stepCount] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    func requestHealthAuthorization() {
        healthStore.requestAuthorization(toShare: nil, read: Self.healthReadTypes) { [log] _, error in
            if let error { log.error("Health authorization failed: %{public}@", String(describing: error)) }
        }
    }

    // MARK: - Schedules

    private func isf(at date: Date) -> Double? {
        loopManager.settings.insulinSensitivitySchedule?.quantity(at: date).doubleValue(for: .milligramsPerDeciliter)
    }

    private func basal(at date: Date) -> Double? {
        loopManager.settings.basalRateSchedule?.value(at: date)
    }

    // MARK: - Real-time update

    func update(now: Date = Date()) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            let config = self.config
            if config.enabled && now.timeIntervalSince(learnedFactors.learnedAt) > relearnInterval {
                try await relearn(now: now)
            }

            let dayAgo = now.addingTimeInterval(-24 * 3600)
            async let glucoseTask = glucoseStore.getGlucoseSamples(start: dayAgo.addingTimeInterval(-3600), end: now)
            async let dosesTask = doseStore.getDoses(start: dayAgo.addingTimeInterval(-4 * 3600), end: now)
            async let contextTask = fetchContext(start: dayAgo.addingTimeInterval(-rules.exerciseLateWindow), end: now, now: now)
            let (glucoseSamples, rawDoses, baseContext) = try await (glucoseTask, dosesTask, contextTask)

            let glucose = glucoseSamples.map(Self.point)
            let doses = rawDoses.map(Self.dose)
            var context = baseContext
            context.meals = AOMealDetector().meals(glucose: glucose, doses: doses)

            let activeAll = rules.activeSignals(at: now, context: context)
            let active = Set(activeAll.keys).subtracting(config.disabledSignals)

            let recentBuckets = AOBucketBuilder(rules: rules).build(glucose: glucose, doses: doses, context: context, start: dayAgo, end: now)
            let autosens = AOAutosens().estimate(buckets: recentBuckets, now: now,
                                                 isf: { [weak self] in self?.isf(at: $0) },
                                                 basal: { [weak self] in self?.basal(at: $0) })

            let siteFailure = config.siteFailureAlerts && AOSiteFailureDetector().suspected(
                now: now, glucose: glucose, doses: doses,
                scheduledBasalUnits: (basal(at: now) ?? 0) * 2, meals: context.meals)

            let current = loopManager.settings.scheduleOverride.flatMap { $0.hasFinished(relativeTo: now) ? nil : $0 }
            let ownActive = current.flatMap { $0.syncIdentifier == ownSyncIdentifier ? $0 : nil }

            // New strategies: time-of-day profile, workout prep, post-exercise target, stacking guard.
            var extras: [(reason: String, factor: Double)] = []
            var targetFloor: Double?
            func raiseTarget(_ value: Double) { targetFloor = max(targetFloor ?? 0, value) }
            if config.useTimeOfDayProfile {
                extras.append((reason: "Time of day", factor: timeOfDayProfile.factor(at: now, calendar: rules.calendar)))
            }
            let workoutStartedRecently = context.workouts.contains { $0.end > now.addingTimeInterval(-config.postExerciseWindow) }
            var prep = false
            if let until = workoutPrepUntil {
                if now < until && !context.workouts.contains(where: { $0.end > until.addingTimeInterval(-config.workoutPrepDuration) }) {
                    prep = true
                } else {
                    save(nil as Date?, .workoutPrepUntil)
                }
            }
            if !prep && config.autoWorkoutPrep {
                prep = AOWorkoutHabitLearner(calendar: rules.calendar).prepActive(habits: workoutHabits, workouts: context.workouts, now: now)
            }
            if prep {
                extras.append((reason: "Workout soon", factor: config.workoutPrepScale))
                raiseTarget(config.workoutPrepTargetMgdl)
            }
            if config.postExerciseTarget && workoutStartedRecently {
                raiseTarget(config.postExerciseTargetMgdl)
            }

            // What kind of day is this? Learned from recent weeks, updated by today's movement.
            var dayForecast: String?
            let dayModel = AODayModel(history: daySummaries, calendar: rules.calendar)
            let dayStart = rules.calendar.startOfDay(for: now)
            func minute(_ d: Date) -> Int { Int(d.timeIntervalSince(dayStart) / 60) }
            let todaysRides = context.workouts.filter { $0.start >= dayStart && $0.duration >= 15 * 60 }
            let morningRide = todaysRides.contains { dayModel.morningWindow.contains(minute($0.start)) }
            let afternoonRide = todaysRides.contains { minute($0.start) >= dayModel.afternoonWindow.lowerBound }
            if config.predictRideHome, !prep,
               let forecast = dayModel.rideHomeForecast(now: now, morningRideToday: morningRide, afternoonRideStarted: afternoonRide) {
                let time = DateFormatter.localizedString(from: forecast.window.start.addingTimeInterval(60 * 60), dateStyle: .none, timeStyle: .short)
                dayForecast = "Ride home likely around \(time) (\(Int((forecast.probability * 100).rounded()))%)"
                if forecast.probability >= 0.6 && forecast.window.contains(now) {
                    extras.append((reason: "Ride home likely", factor: config.workoutPrepScale))
                    raiseTarget(config.workoutPrepTargetMgdl)
                }
            }
            if config.quietDayAdjustment, todaysRides.isEmpty, let isfNow = isf(at: now) {
                let hour = rules.calendar.component(.hour, from: now)
                let stepsBefore10 = hour >= 10 ? AOSignalRules.steps(in: context.steps, before: dayStart.addingTimeInterval(10 * 3600), window: 10 * 3600) : nil
                let pQuiet = dayModel.sedentaryProbability(now: now, rodeToday: false, stepsBefore10: stepsBefore10)
                let factor = dayModel.sedentaryFactor(isf: isfNow)
                if pQuiet >= 0.5 { dayForecast = dayForecast ?? "Probably a quiet day (\(Int((pQuiet * 100).rounded()))%)" }
                let movingNow = active.contains(.recentMovement) || active.contains(.exerciseEarly) || active.contains(.exerciseLate)
                if (9..<20).contains(hour), !movingNow, factor > 1.0 {
                    extras.append((reason: "Quiet day", factor: 1 + (factor - 1) * pQuiet))
                }
            }
            if config.stackingGuard {
                let hour = rules.calendar.component(.hour, from: now)
                if AOStackingGuard().active(iob: AOInsulinModel.onBoard(doses, at: now), typicalIOB: typicalIOB[hour],
                                            glucose: glucose.filter { $0.date >= now.addingTimeInterval(-20 * 60) }) {
                    extras.append((reason: "High insulin on board", factor: 0.9))
                    raiseTarget(140)
                }
            }

            let decision = AODecisionEngine(config: config).decide(AODecisionInput(
                now: now,
                activeSignals: active,
                factors: learnedFactors,
                autosens: autosens.factor,
                recentGlucose: glucose.filter { $0.date >= now.addingTimeInterval(-30 * 60) },
                siteFailureSuspected: siteFailure,
                currentOwnScale: ownActive?.settings.insulinNeedsScaleFactor,
                otherOverrideActive: current != nil && ownActive == nil,
                extraFactors: extras,
                targetFloor: targetFloor))
            desiredTargetFloor = targetFloor

            log.default("Signals %{public}@ autosens %{public}@ -> %{public}@",
                        String(describing: active.map(\.id).sorted()), String(describing: autosens), String(describing: decision))

            let applied = await act(on: decision, mode: config.mode, ownActive: ownActive, now: now)
            if config.enabled {
                recordTick(now: now, scale: applied ?? 1.0, signals: active)
                if siteFailure { await alertSiteFailure(now: now) }
                if config.preBolusReminders { await remindPreBolusIfDue(now: now, glucose: glucose, doses: doses) }
            }

            status = AOStatus(updatedAt: now, activeSignals: active.sorted(), autosens: autosens.factor,
                              autosensHours: autosens.hours, appliedScale: applied,
                              lastDecision: Self.describe(decision, mode: config.mode), siteFailureSuspected: siteFailure,
                              dayForecast: dayForecast)
        } catch {
            log.error("Adaptive override update failed: %{public}@", String(describing: error))
        }
    }

    /// Returns the scale our override is at after acting (nil if none).
    private func act(on decision: AODecision, mode: AOConfig.Mode, ownActive: TemporaryScheduleOverride?, now: Date) async -> Double? {
        switch decision {
        case .apply(let scale, let reasons):
            if mode == .suggest {
                await suggest(scale: scale, reasons: reasons)
                return ownActive?.settings.insulinNeedsScaleFactor
            }
            let id = UUID()
            let override = TemporaryScheduleOverride(
                context: .custom,
                settings: Self.overrideSettings(scale: scale, targetFloor: desiredTargetFloor),
                startDate: now,
                duration: .finite(overrideLifetime),
                enactTrigger: .local,
                syncIdentifier: id)
            ownSyncIdentifier = id
            await loopManager.enactOverride(override)
            let previous = ownActive?.settings.insulinNeedsScaleFactor ?? 1.0
            // Notify on meaningful changes only, not every 5% ramp step.
            let previousFloor = ownActive?.settings.targetRange?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            if abs(scale - previous) >= 0.1 || ownActive == nil || previousFloor != desiredTargetFloor {
                let title = abs(scale - 1.0) < 0.005 && desiredTargetFloor != nil
                    ? "Target raised to \(Int(desiredTargetFloor!))"
                    : "Insulin adjusted to \(AODecisionEngine.percent(scale))"
                await notify(id: "AdaptiveOverride", title: title,
                             body: reasons.joined(separator: "\n"))
            }
            return scale

        case .clear(let reason):
            defaults.removeObject(forKey: Key.lastSuggestedScale.full)
            guard ownActive != nil, loopManager.settings.scheduleOverride?.syncIdentifier == ownSyncIdentifier else { return nil }
            await loopManager.enactOverride(nil)
            ownSyncIdentifier = nil
            await notify(id: "AdaptiveOverride", title: "Insulin back to 100%", body: reason)
            return nil

        case .noChange:
            guard var own = ownActive else { return nil }
            let ownFloor = own.settings.targetRange?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            if mode == .automatic, ownFloor != desiredTargetFloor {
                // Same scale, different target (e.g. post-exercise window ended): update in place.
                own.settings = Self.overrideSettings(scale: own.settings.insulinNeedsScaleFactor ?? 1.0, targetFloor: desiredTargetFloor)
                own.scheduledEndDate = now.addingTimeInterval(overrideLifetime)
                await loopManager.enactOverride(own)
            } else if mode == .automatic, own.scheduledEndDate.timeIntervalSince(now) < refreshWhenRemaining {
                own.scheduledEndDate = now.addingTimeInterval(overrideLifetime)
                await loopManager.enactOverride(own)
            }
            return own.settings.insulinNeedsScaleFactor
        }
    }

    private static func overrideSettings(scale: Double, targetFloor: Double?) -> TemporaryScheduleOverrideSettings {
        let range = targetFloor.map {
            HKQuantity(unit: .milligramsPerDeciliter, doubleValue: $0)...HKQuantity(unit: .milligramsPerDeciliter, doubleValue: $0 + 10)
        }
        return TemporaryScheduleOverrideSettings(targetRange: range, insulinNeedsScaleFactor: scale)
    }

    private static func describe(_ d: AODecision, mode: AOConfig.Mode) -> String {
        switch d {
        case .apply(let s, let r):
            return (mode == .suggest ? "Suggesting " : "Applied ") + AODecisionEngine.percent(s) + (r.isEmpty ? "" : " — " + r.joined(separator: "; "))
        case .clear(let r): return "Normal settings — \(r)"
        case .noChange(let r): return r
        }
    }

    private func recordTick(now: Date, scale: Double, signals: Set<AOSignal>) {
        let hour = rules.calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var all = ticks.filter { $0.hourStart > now.addingTimeInterval(-60 * 24 * 3600) }
        if let i = all.lastIndex(where: { $0.hourStart == hour }) {
            all[i].scaleSum += scale; all[i].count += 1; all[i].signals.formUnion(signals.map(\.id))
        } else {
            all.append(AOTickRecord(hourStart: hour, scaleSum: scale, count: 1, signals: Set(signals.map(\.id))))
        }
        save(all, .ticks)
    }

    // MARK: - Alerts and reminders

    private func alertSiteFailure(now: Date) async {
        var alerts = siteAlerts.filter { $0 > now.addingTimeInterval(-30 * 24 * 3600) }
        if let last = alerts.last, now.timeIntervalSince(last) < siteAlertCooldown { return }
        alerts.append(now)
        save(alerts, .siteAlerts)
        await notify(id: "AdaptiveOverride.site", title: "Check your infusion site",
                     body: "Glucose has stayed high for 2 hours despite extra insulin and no meal. Check for a kinked cannula, leak or bubble, and consider changing the site. Extra insulin from adaptive adjustments is paused meanwhile.")
    }

    private func remindPreBolusIfDue(now: Date, glucose: [AOGlucosePoint], doses: [AOInsulinDose]) async {
        guard let habit = AOHabitLearner(calendar: rules.calendar).dueReminder(habits: mealHabits, now: now) else { return }
        let dayKey = ISO8601DateFormatter.string(from: rules.calendar.startOfDay(for: now), timeZone: .current, formatOptions: [.withFullDate])
        let key = "\(dayKey)-\(habit.minuteOfDay)"
        var reminded = (load(.remindedHabits, as: [String].self) ?? []).suffix(50).map { $0 }
        guard !reminded.contains(key) else { return }
        // Skip if you've just bolused, or are already low-ish.
        if doses.contains(where: { $0.isManual && $0.isBolus && $0.start > now.addingTimeInterval(-60 * 60) }) { return }
        if let latest = glucose.max(by: { $0.date < $1.date }), latest.mgdl < 90 { return }
        reminded.append(key)
        save(reminded, .remindedHabits)
        await notify(id: "AdaptiveOverride.prebolus", title: "Meal around \(habit.timeString)?",
                     body: "You usually eat about now (\(Int((habit.frequency * 100).rounded()))% of days). Pre-bolusing 10–20 minutes ahead helps with the spike. A rough carb estimate is fine.")
    }

    private func suggest(scale: Double, reasons: [String]) async {
        let last = defaults.object(forKey: Key.lastSuggestedScale.full) as? Double
        guard last.map({ abs($0 - scale) >= 0.05 }) ?? true else { return }
        defaults.set(scale, forKey: Key.lastSuggestedScale.full)
        await notify(id: "AdaptiveOverride", title: "Suggested override: \(AODecisionEngine.percent(scale))",
                     body: reasons.joined(separator: "\n"))
    }

    private func notify(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Learning (daily) and weekly analysis

    func relearn(now: Date = Date(), forceWeekly: Bool = false) async throws {
        let start = now.addingTimeInterval(-learningLookback)
        async let glucoseTask = glucoseStore.getGlucoseSamples(start: start, end: now)
        async let dosesTask = doseStore.getDoses(start: start.addingTimeInterval(-4 * 3600), end: now)
        async let contextTask = fetchContext(start: start.addingTimeInterval(-rules.exerciseLateWindow), end: now, now: now, physiologyDays: 62)
        let (glucoseSamples, rawDoses, baseContext) = try await (glucoseTask, dosesTask, contextTask)

        let glucose = glucoseSamples.map(Self.point)
        let doses = rawDoses.map(Self.dose)
        var context = baseContext
        context.meals = AOMealDetector().meals(glucose: glucose, doses: doses)
        let buckets = AOBucketBuilder(rules: rules).build(glucose: glucose, doses: doses, context: context, start: start, end: now)

        if let isfNow = isf(at: now) {
            learnedFactors = AOPatternLearner().learn(buckets: buckets, isfMgdlPerUnit: isfNow, learnedAt: now)
        }
        save(AOHabitLearner(calendar: rules.calendar).habits(meals: context.meals, start: start, end: now), .habits)
        save(AOWorkoutHabitLearner(calendar: rules.calendar).habits(workouts: context.workouts,
                                                                    start: now.addingTimeInterval(-28 * 24 * 3600), end: now), .workoutHabits)
        var profile = timeOfDayProfile
        profile.update(glucose: glucose, now: now, calendar: rules.calendar)
        save(profile, .todProfile)
        // Typical insulin on board by hour (last 14 days), for the stacking guard.
        var iobByHour: [Int: [Double]] = [:]
        var sampleTime = now.addingTimeInterval(-14 * 24 * 3600)
        while sampleTime < now {
            iobByHour[rules.calendar.component(.hour, from: sampleTime), default: []].append(AOInsulinModel.onBoard(
                doses.filter { $0.start > sampleTime.addingTimeInterval(-7 * 3600) && $0.start <= sampleTime }, at: sampleTime))
            sampleTime = sampleTime.addingTimeInterval(20 * 60)
        }
        save(iobByHour.compactMapValues { $0.median }, .typicalIOB)

        // Day summaries for the last 60 days (needs its own, longer fetch of workouts and steps).
        let dayStart = now.addingTimeInterval(-60 * 24 * 3600)
        async let longWorkouts = fetchWorkouts(start: dayStart, end: now)
        async let longSteps = fetchHourlySteps(start: dayStart, end: now)
        async let longGlucose = glucoseStore.getGlucoseSamples(start: dayStart, end: now)
        async let longDoses = doseStore.getDoses(start: dayStart, end: now)
        let (lw, ls, lg, ld) = try await (longWorkouts, longSteps, longGlucose, longDoses)
        let lgPoints = lg.map(Self.point), ldDoses = ld.map(Self.dose)
        var summaries: [AODaySummary] = []
        var day = rules.calendar.startOfDay(for: dayStart)
        let today = rules.calendar.startOfDay(for: now)
        while day < today {
            summaries.append(AODayModel.summarize(day: day, workouts: lw, hourlySteps: ls, glucose: lgPoints, doses: ldDoses, calendar: rules.calendar))
            day = rules.calendar.date(byAdding: .day, value: 1, to: day)!
        }
        save(summaries, .daySummaries)

        // Effectiveness: snapshot "before" once, then judge "after" against it.
        var notes = effectivenessNotes
        if let enabledAt {
            var snapshot = load(.snapshot, as: AOBaselineSnapshot.self)
            if snapshot == nil {
                let before = buckets.filter { $0.start < enabledAt }
                if before.count >= 118 {   // ~7 days of usable hours
                    snapshot = AOEffectivenessEvaluator.snapshot(buckets: before, takenAt: now)
                    save(snapshot, .snapshot)
                }
            }
            if let snapshot {
                let result = AOEffectivenessEvaluator().evaluate(snapshot: snapshot,
                                                                 bucketsSinceEnabled: buckets.filter { $0.start >= enabledAt },
                                                                 ticks: ticks, now: now)
                if !result.signalsToDisable.isEmpty || result.demoteToSuggest {
                    var c = config
                    c.disabledSignals.formUnion(result.signalsToDisable)
                    if result.demoteToSuggest { c.mode = .suggest }
                    save(c, .config)
                    notes.append(contentsOf: result.messages)
                    save(Array(notes.suffix(20)), .effectivenessNotes)
                    await notify(id: "AdaptiveOverride.effectiveness", title: "Adaptive adjustments changed themselves",
                                 body: result.messages.joined(separator: "\n"))
                }
            }
        }

        // Weekly: settings suggestions + report.
        let lastWeekly = load(.lastWeeklyAt, as: Date.self) ?? .distantPast
        if forceWeekly || now.timeIntervalSince(lastWeekly) >= weeklyInterval {
            let tuner = AOSettingsTuner()
            let isfFn: (Date) -> Double? = { [weak self] in self?.isf(at: $0) }
            let basalFn: (Date) -> Double? = { [weak self] in self?.basal(at: $0) }
            let recent = buckets.filter { $0.start >= now.addingTimeInterval(-28 * 24 * 3600) }
            let s = AOSettingsSuggestions(basal: tuner.suggestBasal(buckets: recent, isf: isfFn, basal: basalFn),
                                          isf: tuner.suggestISF(glucose: glucose, doses: doses, meals: context.meals,
                                                                isf: isfFn, basal: basalFn, now: now),
                                          generatedAt: now)
            save(s, .suggestions)

            let weekStart = now.addingTimeInterval(-7 * 24 * 3600)
            let weekNotes = Array(notes.suffix(5)) + (s.isEmpty ? [String]() : ["New settings suggestions to review in Adaptive Adjustments."])
            if let report = AOWeeklyReport.make(glucose: glucose, ticks: ticks,
                                                siteAlerts: siteAlerts.filter { $0 >= weekStart }.count,
                                                notes: Array(weekNotes), start: weekStart, end: now, calendar: rules.calendar) {
                save(report, .report)
                await notify(id: "AdaptiveOverride.report", title: "Your week", body: report.summary)
            }
            save(now, .lastWeeklyAt)
        }
        log.default("Relearned: factors %{public}@", String(describing: learnedFactors.factors))
    }

    // MARK: - Data fetching

    private static func point(_ s: StoredGlucoseSample) -> AOGlucosePoint {
        AOGlucosePoint(date: s.startDate, mgdl: s.quantity.doubleValue(for: .milligramsPerDeciliter))
    }

    private static func dose(_ d: DoseEntry) -> AOInsulinDose {
        AOInsulinDose(start: d.startDate, end: d.endDate, units: d.deliveredUnits ?? d.programmedUnits,
                      isBolus: d.type == .bolus, isManual: d.type == .bolus && d.automatic != true)
    }

    private func fetchContext(start: Date, end: Date, now: Date, physiologyDays: Double = 32) async throws -> AOContext {
        async let workouts = fetchWorkouts(start: start, end: end)
        async let sleep = fetchSleep(start: start.addingTimeInterval(-24 * 3600), end: end)
        async let pumpSites = fetchPumpSiteChanges(since: start.addingTimeInterval(-10 * 24 * 3600))
        async let physiology = fetchPhysiology(days: physiologyDays, now: now)
        // Motion log covers the last 7 days at most; recent hours are what matter for live detection.
        let motionStart = max(start, now.addingTimeInterval(-13 * 3600))
        let (w, s, p, phys) = try await (workouts, sleep, pumpSites, physiology)
        let motionSamples: [AOMotionSample] = config.useMotionDetection ? await motion.samples(from: motionStart, to: end) : []
        let liveSessions = AOMotionWorkoutDetector().sessions(from: motionSamples, now: end)
        var steps = try await fetchHourlySteps(start: max(start, now.addingTimeInterval(-32 * 24 * 3600)), end: end)
        // Live top-up: Health's step totals lag; the pedometer knows the last 2 h now.
        if let live = await pedometerSteps(from: end.addingTimeInterval(-2 * 3600), to: end) {
            let inHealth = AOSignalRules.steps(in: steps, before: end)
            if live > inHealth { steps.append(AOMetricSample(date: end.addingTimeInterval(-60), value: live - inHealth)) }
        }
        return AOContext(workouts: AOMotionWorkoutDetector.merge(health: w, motion: liveSessions), nights: rules.nights(from: s),
                         siteChanges: mergeSiteChanges(pump: p, manual: manualSiteChanges),
                         hrv: phys.hrv, restingHeartRate: phys.rhr, wristTemperature: phys.temp,
                         logs: logs, steps: steps)
    }

    /// Pump-reported changes are the source of truth for timing; a manual log within 3 h
    /// adds its location. Manual logs with no matching pump event count on their own.
    private func mergeSiteChanges(pump: [Date], manual: [AOSiteChange]) -> [AOSiteChange] {
        var result = pump.map { AOSiteChange(date: $0, location: nil) }
        for m in manual {
            if let i = result.firstIndex(where: { abs($0.date.timeIntervalSince(m.date)) < 3 * 3600 }) {
                result[i].location = m.location ?? result[i].location
            } else {
                result.append(m)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private func fetchPumpSiteChanges(since: Date) async throws -> [Date] {
        let events: [PersistedPumpEvent] = try await withCheckedThrowingContinuation { continuation in
            doseStore.getPumpEventValues(since: since) { result in
                switch result {
                case .success(let events): continuation.resume(returning: events)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        var dates: [Date] = []
        for e in events.sorted(by: { $0.date < $1.date }) {
            guard let type = e.type else { continue }
            let isSiteChange: Bool
            switch type {
            case .replaceComponent(componentType: .pump), .replaceComponent(componentType: .infusionSet), .prime:
                isSiteChange = true
            default:
                isSiteChange = false
            }
            // Several events (rewind, prime, fill cannula) belong to one change.
            if isSiteChange, dates.last.map({ e.date.timeIntervalSince($0) > 3 * 3600 }) ?? true {
                dates.append(e.date)
            }
        }
        return dates
    }

    private func fetchPhysiology(days: Double, now: Date) async throws -> (hrv: [AOMetricSample], rhr: [AOMetricSample], temp: [AOMetricSample]) {
        if days <= 32, let cache = physiologyCache, now.timeIntervalSince(cache.fetchedAt) < 3600 {
            return (cache.hrv, cache.rhr, cache.temp)
        }
        let start = now.addingTimeInterval(-days * 24 * 3600)
        async let hrv = fetchQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: now)
        async let rhr = fetchQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: now)
        async let temp = fetchQuantity(.appleSleepingWristTemperature, unit: .degreeCelsius(), start: start, end: now)
        let result = try await (hrv, rhr, temp)
        if days <= 32 { physiologyCache = (now, result.0, result.1, result.2) }
        return result
    }

    private func fetchQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> [AOMetricSample] {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return [] }
        return try await fetchSamples(type: type, start: start, end: end)
            .compactMap { $0 as? HKQuantitySample }
            .map { AOMetricSample(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    var daySummaries: [AODaySummary] { load(.daySummaries, as: [AODaySummary].self) ?? [] }

    /// Hourly step totals from Health (de-duplicated across iPhone and Watch by Health's statistics).
    private func fetchHourlySteps(start: Date, end: Date) async throws -> [AOMetricSample] {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let anchor = rules.calendar.startOfDay(for: start)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type,
                                                    quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                                                    options: .cumulativeSum, anchorDate: anchor, intervalComponents: DateComponents(hour: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    let code = (error as? HKError)?.code
                    if code == .errorAuthorizationDenied || code == .errorAuthorizationNotDetermined || code == .errorNoData {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                var out: [AOMetricSample] = []
                collection?.enumerateStatistics(from: start, to: end) { stat, _ in
                    if let q = stat.sumQuantity() {
                        // Stamp mid-hour so "steps before t" counts a whole hour only once it has mostly passed.
                        out.append(AOMetricSample(date: stat.startDate.addingTimeInterval(30 * 60), value: q.doubleValue(for: .count())))
                    }
                }
                continuation.resume(returning: out)
            }
            healthStore.execute(query)
        }
    }

    private func pedometerSteps(from start: Date, to end: Date) async -> Double? {
        guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() == .authorized else { return nil }
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                continuation.resume(returning: data?.numberOfSteps.doubleValue)
            }
        }
    }

    private func fetchWorkouts(start: Date, end: Date) async throws -> [AOWorkout] {
        try await fetchSamples(type: HKObjectType.workoutType(), start: start, end: end)
            .map { AOWorkout(start: $0.startDate, end: $0.endDate) }
    }

    private func fetchSleep(start: Date, end: Date) async throws -> [AOSleepInterval] {
        let notAsleep: Set<Int> = [HKCategoryValueSleepAnalysis.inBed.rawValue, HKCategoryValueSleepAnalysis.awake.rawValue]
        return try await fetchSamples(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, start: start, end: end)
            .compactMap { $0 as? HKCategorySample }
            .filter { !notAsleep.contains($0.value) }
            .map { AOSleepInterval(start: $0.startDate, end: $0.endDate) }
    }

    private func fetchSamples(type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    // No permission or no data means "no signal", not a failed update.
                    let code = (error as? HKError)?.code
                    if code == .errorAuthorizationDenied || code == .errorAuthorizationNotDetermined || code == .errorNoData {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }
}
