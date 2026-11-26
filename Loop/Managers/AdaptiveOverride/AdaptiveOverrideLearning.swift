//
//  AdaptiveOverrideLearning.swift
//  Loop
//
//  Pure learning and analysis for the adaptive override layer:
//   - hourly buckets of glucose / insulin / signals (meal hours flagged)
//   - per-signal insulin-needs factors (carb-free)
//   - "autosens": recent overall sensitivity from fasting stretches
//   - settings suggestions (basal by hour, ISF) — suggestions only, never applied
//   - meal-time habits for pre-bolus reminders
//   - effectiveness check: switches off signals linked to more lows
//   - weekly report
//

import Foundation

// MARK: - Hour buckets

struct AOHourBucket: Equatable {
    let start: Date
    let hour: Int
    let meanGlucose: Double
    let firstGlucose: Double
    let lastGlucose: Double
    let lowFraction: Double
    let inRangeFraction: Double
    let insulin: Double
    let signals: [AOSignal: Date]
    let nearMeal: Bool
    let manualBolusRecently: Bool

    var mid: Date { start.addingTimeInterval(1800) }
    var behaviouralSignals: [AOSignal] { signals.keys.filter { !$0.isContext } }
    /// No meal, no recent manual bolus, nothing unusual going on.
    var isFasting: Bool { !nearMeal && !manualBolusRecently && behaviouralSignals.isEmpty }
}

/// Loop's exponential insulin model (rapid-acting adult defaults): how much of a dose is
/// still on board t seconds after delivery. Used to measure insulin *acting* in an hour,
/// rather than insulin delivered in it, so Loop's own corrections and meal-bolus tails
/// are accounted for.
enum AOInsulinModel {
    static let delay: TimeInterval = 10 * 60
    static let peak: TimeInterval = 75 * 60
    static let duration: TimeInterval = 360 * 60
    private static let tau = peak * (1 - peak / duration) / (1 - 2 * peak / duration)
    private static let a = 2 * tau / duration
    private static let S = 1 / (1 - a + (1 + a) * exp(-duration / tau))

    static func onBoardFraction(after elapsed: TimeInterval) -> Double {
        let t = elapsed - delay
        if t <= 0 { return 1 }
        if t >= duration { return 0 }
        return 1 - S * (1 - a) * ((t * t / (tau * duration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
    }

    /// Units of insulin from `doses` acting during `range`.
    static func activity(of doses: [AOInsulinDose], in range: Range<Date>) -> Double {
        let lookback = range.lowerBound.addingTimeInterval(-(duration + delay))
        var total = 0.0
        for dose in doses where dose.end > lookback && dose.start < range.upperBound {
            let mid = dose.start.addingTimeInterval(dose.end.timeIntervalSince(dose.start) / 2)
            total += dose.units * (onBoardFraction(after: range.lowerBound.timeIntervalSince(mid))
                                   - onBoardFraction(after: range.upperBound.timeIntervalSince(mid)))
        }
        return total
    }
}

struct AOBucketBuilder {
    var rules = AOSignalRules()
    var minGlucosePointsPerHour = 6
    /// Hours this long after a detected meal are left out (meal insulin acts for ~5 h).
    var mealExclusion: TimeInterval = 5 * 3600
    var calendar: Calendar { rules.calendar }

    func build(glucose: [AOGlucosePoint], doses: [AOInsulinDose], context: AOContext,
               start: Date, end: Date) -> [AOHourBucket] {
        let g = glucose.sorted { $0.date < $1.date }
        let manualBoluses = doses.filter { $0.isManual && $0.isBolus }.map(\.start).sorted()
        var buckets: [AOHourBucket] = []
        var bucketStart = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        var gIndex = 0
        while bucketStart.addingTimeInterval(3600) <= end {
            let bucketEnd = bucketStart.addingTimeInterval(3600)
            while gIndex < g.count && g[gIndex].date < bucketStart { gIndex += 1 }
            var j = gIndex
            var values: [Double] = []
            while j < g.count && g[j].date < bucketEnd { values.append(g[j].mgdl); j += 1 }
            if values.count >= minGlucosePointsPerHour {
                let range = bucketStart..<bucketEnd
                let mid = bucketStart.addingTimeInterval(1800)
                let recentBolusStart = bucketStart.addingTimeInterval(-3 * 3600)
                buckets.append(AOHourBucket(
                    start: bucketStart,
                    hour: calendar.component(.hour, from: bucketStart),
                    meanGlucose: values.reduce(0, +) / Double(values.count),
                    firstGlucose: values.first!,
                    lastGlucose: values.last!,
                    lowFraction: Double(values.filter { $0 < 70 }.count) / Double(values.count),
                    inRangeFraction: Double(values.filter { $0 >= 70 && $0 <= 180 }.count) / Double(values.count),
                    insulin: AOInsulinModel.activity(of: doses, in: range),
                    signals: rules.activeSignals(at: mid, context: context),
                    nearMeal: AOMealDetector.isNearMeal(mid, meals: context.meals, after: mealExclusion),
                    manualBolusRecently: manualBoluses.contains { $0 >= recentBolusStart && $0 < bucketEnd }))
            }
            bucketStart = bucketEnd
        }
        return buckets
    }
}

// MARK: - Per-signal factors

struct AOLearnedFactors: Codable, Equatable {
    var factors: [String: Double]
    var episodes: [String: Int]
    var learnedAt: Date

    static let neutral = AOLearnedFactors(factors: [:], episodes: [:], learnedAt: .distantPast)

    func factor(for signal: AOSignal) -> Double { factors[signal.id] ?? 1.0 }
    var signals: [AOSignal] { Set(factors.keys).union(episodes.keys).map { AOSignal(id: $0) }.sorted() }
}

/// Estimates how much more or less insulin you needed while each signal was active,
/// compared with ordinary hours at the same time of day. Meal hours are excluded, so
/// carb counts (good or bad) never enter the estimate.
///
///   need ≈ insulinDelivered / baselineInsulin
///        + (glucose − baselineGlucose) / ISF / 3h / baselineInsulin
///
/// The first term is what Loop actually gave; the second converts glucose left above or
/// below baseline into insulin-equivalent. Estimates use the median (robust to site
/// failures and odd days), are shrunk toward 1.0 with few episodes, and are clamped.
struct AOPatternLearner {
    var minEpisodes = 4
    /// Starting points used until (and shrunk toward while) your own data builds up.
    /// Only insulin-*reducing* signals get one, from well-established effects
    /// (exercise, alcohol); anything that would add insulin needs your own evidence.
    static let priors: [AOSignal: Double] = [.exerciseEarly: 0.8, .exerciseLate: 0.9, .alcohol: 0.9]
    var shrinkagePrior = 5.0
    var learnedRange: ClosedRange<Double> = 0.6...1.4
    var minBaselineInsulinPerHour = 0.05
    var minBaselineHours = 3

    func learn(buckets: [AOHourBucket], isfMgdlPerUnit: Double, learnedAt: Date) -> AOLearnedFactors {
        guard isfMgdlPerUnit > 0 else { return .neutral }
        let usable = buckets.filter { !$0.nearMeal && !$0.manualBolusRecently }
        let allSignals = Set(usable.flatMap { $0.signals.keys })

        var result = AOLearnedFactors(factors: [:], episodes: [:], learnedAt: learnedAt)
        for signal in allSignals.sorted() {
            // Baseline: same hour of day, nothing behavioural going on, and (for context signals) not this context.
            let baselineBuckets = usable.filter { b in
                b.behaviouralSignals.isEmpty && (!signal.isContext || b.signals[signal] == nil)
            }
            var baseG: [Int: [Double]] = [:], baseI: [Int: [Double]] = [:]
            for b in baselineBuckets {
                baseG[b.hour, default: []].append(b.meanGlucose)
                baseI[b.hour, default: []].append(b.insulin)
            }

            var estimates: [Double] = []
            var episodeIDs = Set<Date>()
            for b in usable {
                guard let episode = b.signals[signal] else { continue }
                let others = b.behaviouralSignals.filter { $0 != signal }
                guard others.isEmpty,
                      let g = baseG[b.hour], g.count >= minBaselineHours,
                      let i = baseI[b.hour], i.count >= minBaselineHours else { continue }
                let baselineInsulin = i.reduce(0, +) / Double(i.count)
                guard baselineInsulin >= minBaselineInsulinPerHour else { continue }
                let baselineGlucose = g.reduce(0, +) / Double(g.count)
                let glucoseTerm = (b.meanGlucose - baselineGlucose) / isfMgdlPerUnit / 3.0 / baselineInsulin
                estimates.append(b.insulin / baselineInsulin + glucoseTerm)
                episodeIDs.insert(episode)
            }
            let n = episodeIDs.count
            result.episodes[signal.id] = n
            let prior = Self.priors[signal] ?? 1.0
            guard n >= minEpisodes, let median = estimates.median else {
                if prior != 1.0 { result.factors[signal.id] = prior }
                continue
            }
            let weight = Double(n) / (Double(n) + shrinkagePrior)
            let shrunk = prior + (median - prior) * weight
            result.factors[signal.id] = min(max(shrunk, learnedRange.lowerBound), learnedRange.upperBound)
        }
        for (signal, prior) in Self.priors where result.factors[signal.id] == nil {
            result.factors[signal.id] = prior
            result.episodes[signal.id] = result.episodes[signal.id] ?? 0
        }
        return result
    }

    /// Units of a dose delivered inside `range`, spreading temp basals evenly over their duration.
    static func units(of dose: AOInsulinDose, in range: Range<Date>) -> Double {
        let duration = dose.end.timeIntervalSince(dose.start)
        if duration <= 1 {
            return range.contains(dose.start) ? dose.units : 0
        }
        let overlapStart = max(dose.start, range.lowerBound)
        let overlapEnd = min(dose.end, range.upperBound)
        guard overlapEnd > overlapStart else { return 0 }
        return dose.units * overlapEnd.timeIntervalSince(overlapStart) / duration
    }
}

// MARK: - Recent sensitivity ("autosens")

/// How much insulin fasting hours actually needed relative to scheduled basal.
/// Catches resistance with no visible cause (stress, hormones, a slow site) without using carbs.
struct AOAutosens {
    var minHours = 4
    var shrinkagePrior = 6.0
    var lookback: TimeInterval = 24 * 3600

    static func needRatio(_ b: AOHourBucket, isf: Double, scheduledBasal: Double) -> Double? {
        guard scheduledBasal >= 0.05, isf > 0 else { return nil }
        return (b.insulin + (b.lastGlucose - b.firstGlucose) / isf) / scheduledBasal
    }

    var minBaselineHours = 20

    /// Compares the last 24 h with your own typical fasting need over the 30 days before.
    /// (Comparing with scheduled basal instead just measures how far your settings are off,
    /// which belongs in settings suggestions — on real data that biased every day upward.)
    func estimate(buckets: [AOHourBucket], now: Date, isf: (Date) -> Double?, basal: (Date) -> Double?) -> (factor: Double, hours: Int) {
        func ratio(_ b: AOHourBucket) -> Double? {
            guard let s = isf(b.mid), let r = basal(b.mid) else { return nil }
            return Self.needRatio(b, isf: s, scheduledBasal: r)
        }
        let fasting = buckets.filter(\.isFasting)
        let recentStart = now.addingTimeInterval(-lookback)
        let recent = fasting.filter { $0.start >= recentStart }.compactMap(ratio)
        let baseline = fasting.filter { $0.start < recentStart && $0.start >= now.addingTimeInterval(-30 * 24 * 3600) }.compactMap(ratio)
        guard recent.count >= minHours, baseline.count >= minBaselineHours,
              let r = recent.median, let b = baseline.median, b > 0 else { return (1.0, recent.count) }
        let weight = Double(recent.count) / (Double(recent.count) + shrinkagePrior)
        return (1.0 + (r / b - 1.0) * weight, recent.count)
    }
}

// MARK: - Settings suggestions

struct AOBasalSuggestion: Codable, Equatable, Identifiable {
    var id: Int { hour }
    let hour: Int
    let current: Double
    let suggested: Double
    let samples: Int
}

struct AOISFSuggestion: Codable, Equatable {
    let current: Double
    let suggested: Double
    let episodes: Int
}

struct AOSettingsSuggestions: Codable, Equatable {
    var basal: [AOBasalSuggestion] = []
    var isf: AOISFSuggestion?
    var generatedAt: Date = .distantPast
    var isEmpty: Bool { basal.isEmpty && isf == nil }
}

/// Like OpenAPS autotune, but carb-free: basal from fasting hours, ISF from clean corrections.
/// Carb ratio is deliberately not tuned, because logged carbs aren't reliable enough.
struct AOSettingsTuner {
    var minSamplesPerHour = 5
    var shrinkagePrior = 5.0
    var maxChange = 0.2
    var minReportedChange = 0.05
    var minCorrectionEpisodes = 5
    /// Fraction of a bolus's effect done by 3 h for rapid-acting insulin.
    var effectByThreeHours = 0.75

    func suggestBasal(buckets: [AOHourBucket], isf: (Date) -> Double?, basal: (Date) -> Double?) -> [AOBasalSuggestion] {
        var byHour: [Int: [Double]] = [:]
        var currentByHour: [Int: Double] = [:]
        for b in buckets where b.isFasting {
            guard let s = isf(b.mid), let r = basal(b.mid), let need = AOAutosens.needRatio(b, isf: s, scheduledBasal: r) else { continue }
            byHour[b.hour, default: []].append(need)
            currentByHour[b.hour] = r
        }
        var result: [AOBasalSuggestion] = []
        for hour in 0..<24 {
            guard let current = currentByHour[hour] else { continue }
            // Pool neighbouring hours: insulin acts over hours, and it smooths noise.
            let pooled = (byHour[hour] ?? []) + (byHour[(hour + 23) % 24] ?? []) + (byHour[(hour + 1) % 24] ?? [])
            guard (byHour[hour]?.count ?? 0) >= minSamplesPerHour, let median = pooled.median else { continue }
            let weight = Double(pooled.count) / (Double(pooled.count) + shrinkagePrior)
            let change = min(max((median - 1.0) * weight, -maxChange), maxChange)
            guard abs(change) >= minReportedChange else { continue }
            let suggested = (current * (1 + change) * 40).rounded() / 40   // pump-friendly 0.025 U/h steps
            result.append(AOBasalSuggestion(hour: hour, current: current, suggested: suggested, samples: byHour[hour]!.count))
        }
        return result
    }

    func suggestISF(glucose: [AOGlucosePoint], doses: [AOInsulinDose], meals: [Date],
                    isf: (Date) -> Double?, basal: (Date) -> Double?, now: Date) -> AOISFSuggestion? {
        let g = glucose.sorted { $0.date < $1.date }
        let manual = doses.filter { $0.isManual && $0.isBolus }
        var observations: [Double] = []
        for bolus in manual where bolus.units >= 0.5 {
            let t = bolus.start
            guard let g0 = g.last(where: { $0.date <= t && t.timeIntervalSince($0.date) < 10 * 60 }), g0.mgdl >= 160,
                  let g3 = g.first(where: { abs($0.date.timeIntervalSince(t.addingTimeInterval(3 * 3600))) < 10 * 60 }),
                  !meals.contains(where: { $0 >= t.addingTimeInterval(-30 * 60) && $0 <= t.addingTimeInterval(4 * 3600) && abs($0.timeIntervalSince(t)) > 60 }),
                  !manual.contains(where: { $0.start > t && $0.start <= t.addingTimeInterval(3 * 3600) }),
                  let scheduled = basal(t) else { continue }
            let window = t..<t.addingTimeInterval(3 * 3600)
            let delivered = doses.reduce(0.0) { $0 + AOPatternLearner.units(of: $1, in: window) }
            let extra = delivered - scheduled * 3
            let drop = g0.mgdl - g3.mgdl
            guard extra >= 0.3, drop > 0 else { continue }
            observations.append(drop / (extra * effectByThreeHours))
        }
        guard observations.count >= minCorrectionEpisodes, let median = observations.median, let current = isf(now) else { return nil }
        let weight = Double(observations.count) / (Double(observations.count) + shrinkagePrior)
        let change = min(max((median / current - 1.0) * weight, -maxChange), maxChange)
        guard abs(change) >= minReportedChange else { return nil }
        return AOISFSuggestion(current: current, suggested: (current * (1 + change)).rounded(), episodes: observations.count)
    }
}

// MARK: - Meal habits

struct AOMealHabit: Codable, Equatable, Hashable {
    let weekend: Bool
    /// Minutes after midnight of the start of the usual 30-minute meal slot.
    let minuteOfDay: Int
    let frequency: Double

    var timeString: String { String(format: "%d:%02d", minuteOfDay / 60, minuteOfDay % 60) }
}

struct AOHabitLearner {
    var slotMinutes = 30
    var minFrequency = 0.5
    var minOccurrences = 4
    var calendar = Calendar.current

    func habits(meals: [Date], start: Date, end: Date) -> [AOMealHabit] {
        var dayCount: [Bool: Int] = [true: 0, false: 0]
        var day = calendar.startOfDay(for: start)
        while day < end {
            dayCount[calendar.isDateInWeekend(day), default: 0] += 1
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        // Count distinct days with a meal starting in each slot.
        var slotDays: [Bool: [Int: Set<Date>]] = [true: [:], false: [:]]
        for meal in meals where meal >= start && meal < end {
            let comps = calendar.dateComponents([.hour, .minute], from: meal)
            let slot = ((comps.hour ?? 0) * 60 + (comps.minute ?? 0)) / slotMinutes
            slotDays[calendar.isDateInWeekend(meal), default: [:]][slot, default: []].insert(calendar.startOfDay(for: meal))
        }
        var result: [AOMealHabit] = []
        for weekend in [false, true] {
            let days = dayCount[weekend] ?? 0
            guard days > 0 else { continue }
            let slots = slotDays[weekend] ?? [:]
            var candidates: [(slot: Int, freq: Double)] = slots.compactMap { slot, set in
                let freq = Double(set.count) / Double(days)
                return set.count >= minOccurrences && freq >= minFrequency ? (slot: slot, freq: freq) : nil
            }
            // Adjacent slots are the same meal; keep the more frequent one.
            candidates.sort { $0.freq > $1.freq }
            var kept: [(slot: Int, freq: Double)] = []
            for c in candidates where !kept.contains(where: { abs($0.slot - c.slot) <= 1 }) { kept.append(c) }
            result += kept.map { AOMealHabit(weekend: weekend, minuteOfDay: $0.slot * slotMinutes, frequency: $0.freq) }
        }
        return result.sorted { ($0.weekend ? 1 : 0, $0.minuteOfDay) < ($1.weekend ? 1 : 0, $1.minuteOfDay) }
    }

    /// The habit to remind about now, if any: 15–25 minutes before its usual time.
    func dueReminder(habits: [AOMealHabit], now: Date) -> AOMealHabit? {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let weekend = calendar.isDateInWeekend(now)
        return habits.first { $0.weekend == weekend && (15...25).contains($0.minuteOfDay - nowMinute) }
    }
}

// MARK: - Effectiveness check

/// One record per hour of what the layer did.
struct AOTickRecord: Codable, Equatable {
    let hourStart: Date
    var scaleSum: Double
    var count: Int
    var signals: Set<String>
    var meanScale: Double { count > 0 ? scaleSum / Double(count) : 1.0 }
}

/// Your numbers before the layer was switched on — the yardstick it's judged against.
struct AOBaselineSnapshot: Codable, Equatable {
    let takenAt: Date
    let timeBelowRange: Double
    let timeInRange: Double
    let lowFractionBySignal: [String: Double]
}

struct AOEffectivenessResult: Equatable {
    var signalsToDisable: [AOSignal] = []
    var demoteToSuggest = false
    var messages: [String] = []
}

struct AOEffectivenessEvaluator {
    var minAdjustedHours = 12
    var signalLowMargin = 0.03
    var overallLowMargin = 0.02
    var overallLowFloor = 0.04

    static func snapshot(buckets: [AOHourBucket], takenAt: Date) -> AOBaselineSnapshot {
        var bySignal: [String: [Double]] = [:]
        for b in buckets { for s in b.signals.keys { bySignal[s.id, default: []].append(b.lowFraction) } }
        return AOBaselineSnapshot(
            takenAt: takenAt,
            timeBelowRange: buckets.map(\.lowFraction).mean ?? 0,
            timeInRange: buckets.map(\.inRangeFraction).mean ?? 0,
            lowFractionBySignal: bySignal.compactMapValues { $0.count >= 6 ? $0.mean : nil })
    }

    func evaluate(snapshot: AOBaselineSnapshot, bucketsSinceEnabled: [AOHourBucket], ticks: [AOTickRecord], now: Date) -> AOEffectivenessResult {
        var result = AOEffectivenessResult()
        let tickByHour = Dictionary(ticks.map { ($0.hourStart, $0) }, uniquingKeysWith: { a, _ in a })

        var adjustedLows: [String: [Double]] = [:]
        for b in bucketsSinceEnabled {
            guard let tick = tickByHour[b.start], abs(tick.meanScale - 1.0) >= 0.02 else { continue }
            for s in tick.signals { adjustedLows[s, default: []].append(b.lowFraction) }
        }
        for (id, lows) in adjustedLows.sorted(by: { $0.key < $1.key }) where lows.count >= minAdjustedHours {
            let before = snapshot.lowFractionBySignal[id] ?? snapshot.timeBelowRange
            let after = lows.mean ?? 0
            if after > before + signalLowMargin {
                let signal = AOSignal(id: id)
                result.signalsToDisable.append(signal)
                result.messages.append("Turned off \"\(signal.displayName)\": time below 70 was \(Self.pct(after)) when it adjusted, vs \(Self.pct(before)) before.")
            }
        }

        let lastWeek = bucketsSinceEnabled.filter { $0.start >= now.addingTimeInterval(-7 * 24 * 3600) }
        if lastWeek.count >= 72, let tbr = lastWeek.map(\.lowFraction).mean,
           tbr > snapshot.timeBelowRange + overallLowMargin && tbr > overallLowFloor {
            result.demoteToSuggest = true
            result.messages.append("Switched to suggest-only: time below 70 is \(Self.pct(tbr)) this week, vs \(Self.pct(snapshot.timeBelowRange)) before you turned this on.")
        }
        return result
    }

    static func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}

// MARK: - Weekly report

struct AOWeeklyReport: Codable, Equatable {
    var start: Date
    var end: Date
    var meanGlucose: Double
    var timeInRange: Double
    var timeBelow70: Double
    var timeBelow54: Double
    var timeAbove180: Double
    var timeAbove250: Double
    var gmi: Double
    var coefficientOfVariation: Double
    var lowsMostOften: String?
    var highsMostOften: String?
    var signalHours: [String: Int]
    var averageScale: Double
    var siteAlerts: Int
    var notes: [String]

    static func make(glucose: [AOGlucosePoint], ticks: [AOTickRecord], siteAlerts: Int,
                     notes: [String], start: Date, end: Date, calendar: Calendar = .current) -> AOWeeklyReport? {
        let values = glucose.filter { $0.date >= start && $0.date < end }
        guard values.count >= 288 else { return nil }   // at least ~1 day of CGM
        let v = values.map(\.mgdl)
        let n = Double(v.count)
        let mean = v.reduce(0, +) / n
        let sd = sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(n - 1, 1))
        func frac(_ p: (Double) -> Bool) -> Double { Double(v.filter(p).count) / n }

        // Which 4-hour block of the day has the most lows / highs.
        var blockLow = [Int: (Int, Int)](), blockHigh = [Int: (Int, Int)]()
        for p in values {
            let block = calendar.component(.hour, from: p.date) / 4
            blockLow[block, default: (0, 0)].1 += 1; blockHigh[block, default: (0, 0)].1 += 1
            if p.mgdl < 70 { blockLow[block, default: (0, 0)].0 += 1 }
            if p.mgdl > 180 { blockHigh[block, default: (0, 0)].0 += 1 }
        }
        func worst(_ d: [Int: (Int, Int)], minFraction: Double) -> String? {
            let best = d.max { Double($0.value.0) / Double(max($0.value.1, 1)) < Double($1.value.0) / Double(max($1.value.1, 1)) }
            guard let b = best, Double(b.value.0) / Double(max(b.value.1, 1)) >= minFraction else { return nil }
            let names = ["12–4am", "4–8am", "8am–12pm", "12–4pm", "4–8pm", "8pm–12am"]
            return names[b.key]
        }

        let weekTicks = ticks.filter { $0.hourStart >= start && $0.hourStart < end }
        var signalHours: [String: Int] = [:]
        for t in weekTicks { for s in t.signals { signalHours[s, default: 0] += 1 } }

        return AOWeeklyReport(
            start: start, end: end, meanGlucose: mean,
            timeInRange: frac { $0 >= 70 && $0 <= 180 },
            timeBelow70: frac { $0 < 70 }, timeBelow54: frac { $0 < 54 },
            timeAbove180: frac { $0 > 180 }, timeAbove250: frac { $0 > 250 },
            gmi: 3.31 + 0.02392 * mean,
            coefficientOfVariation: mean > 0 ? sd / mean : 0,
            lowsMostOften: worst(blockLow, minFraction: 0.02),
            highsMostOften: worst(blockHigh, minFraction: 0.25),
            signalHours: signalHours,
            averageScale: weekTicks.isEmpty ? 1.0 : weekTicks.map(\.meanScale).reduce(0, +) / Double(weekTicks.count),
            siteAlerts: siteAlerts,
            notes: notes)
    }

    var summary: String {
        var parts = ["In range \(Int((timeInRange * 100).rounded()))%",
                     "low \(String(format: "%.1f", timeBelow70 * 100))%",
                     "avg \(Int(meanGlucose.rounded())) mg/dL"]
        if let lows = lowsMostOften { parts.append("lows mostly \(lows)") }
        if let highs = highsMostOften { parts.append("highs mostly \(highs)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Helpers

extension Array where Element == Double {
    var median: Double? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return count % 2 == 1 ? s[count / 2] : (s[count / 2 - 1] + s[count / 2]) / 2
    }
    var mean: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
