//
//  AdaptiveOverrideReport.swift
//  Loop
//
//  Weekly report: looks back at a week, explains what happened, and suggests dosing and
//  habit changes. Pure logic (no HealthKit, no UI), so it can be unit tested.
//
//  Works whether or not adaptive adjustments are on, and with either dosing algorithm.
//  Thresholds were set on a real week of data (see AdaptiveAdjustmentsValidation/README.md).
//  Nothing here changes dosing: suggestions are for you (and your care team) to review.
//

import Foundation

// MARK: - Input

struct AOCarbEntry: Equatable {
    let date: Date
    let grams: Double
}

struct AOReportInput {
    var start: Date
    var end: Date
    /// Glucose from at least 28 days before `end` (for last week's comparison and 4-week patterns).
    var glucose: [AOGlucosePoint]
    /// Insulin from at least 28 days (+ 8 hours) before `end`.
    var doses: [AOInsulinDose]
    var carbs: [AOCarbEntry] = []
    var workouts: [AOWorkout] = []
    var nights: [AOSleepNight] = []
    var siteChanges: [AOSiteChange] = []
    var ticks: [AOTickRecord] = []
    var siteAlerts: [Date] = []
    var effectivenessNotes: [String] = []
    var settingsSuggestions = AOSettingsSuggestions()
    var scheduledBasal: (Date) -> Double? = { _ in nil }
    var carbRatio: (Date) -> Double? = { _ in nil }
    var algorithm = "Loop"
    var adaptiveEnabled = false
    var adaptiveMode = "Off"
    var calendar = Calendar.current
}

// MARK: - Report model (persisted)

struct AOGlucoseMetrics: Codable, Equatable {
    var readings: Int
    /// Fraction of expected 5-minute readings present.
    var coverage: Double
    var mean: Double
    var sd: Double
    var timeInRange: Double
    var timeInTightRange: Double
    var below70: Double
    var below54: Double
    var above180: Double
    var above250: Double

    var gmi: Double { 3.31 + 0.02392 * mean }
    var cv: Double { mean > 0 ? sd / mean : 0 }

    static func compute(_ values: [Double], days: Double) -> AOGlucoseMetrics? {
        guard values.count >= 144 else { return nil }   // at least half a day
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let sd = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(n - 1, 1))
        func frac(_ p: (Double) -> Bool) -> Double { Double(values.filter(p).count) / n }
        return AOGlucoseMetrics(readings: values.count, coverage: min(n / (days * 288), 1), mean: mean, sd: sd,
                                timeInRange: frac { $0 >= 70 && $0 <= 180 },
                                timeInTightRange: frac { $0 >= 70 && $0 <= 140 },
                                below70: frac { $0 < 70 }, below54: frac { $0 < 54 },
                                above180: frac { $0 > 180 }, above250: frac { $0 > 250 })
    }
}

struct AOReportDay: Codable, Equatable, Identifiable {
    var date: Date
    var id: Date { date }
    var timeInRange: Double
    var below70: Double
    var above180: Double
    var mean: Double
    var rode: Bool
}

struct AOReportHour: Codable, Equatable, Identifiable {
    var hour: Int
    var id: Int { hour }
    var p10: Double, p25: Double, p50: Double, p75: Double, p90: Double
}

enum AOLowContext: String, Codable, CaseIterable {
    case duringRide, afterRide, afterHigh, overnight, afterMeal, other
    var displayName: String {
        switch self {
        case .duringRide: return "During or just after a ride"
        case .afterRide: return "1–12 hours after a ride"
        case .afterHigh: return "After a high (over-correction)"
        case .overnight: return "Overnight"
        case .afterMeal: return "After a meal"
        case .other: return "Other"
        }
    }
}

enum AOHighContext: String, Codable, CaseIterable {
    case rebound, afterMeal, overnight, unexplained
    var displayName: String {
        switch self {
        case .rebound: return "Rebound after a low"
        case .afterMeal: return "After a meal"
        case .overnight: return "Overnight"
        case .unexplained: return "No meal or low before it"
        }
    }
}

struct AOEpisodeSummary: Codable, Equatable {
    var count = 0
    /// Lows below 54, or highs above 250.
    var severe = 0
    var byContext: [String: Int] = [:]
    var medianMinutes: Double?
    var previousCount: Int?

    var topContext: (name: String, count: Int)? {
        byContext.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

struct AORollercoaster: Codable, Equatable {
    var highs = 0
    var highsFollowedByLow = 0
    var lows = 0
    var lowsFollowedByHigh = 0
}

struct AOCorrectionSummary: Codable, Equatable {
    var manualBolusesPerDay: Double = 0
    /// Manual boluses given above 180 this week.
    var correctionsThisWeek = 0
    /// …of which with ≥ 4 U of bolus insulin already active.
    var correctionsOnActiveInsulinThisWeek = 0
    /// Last 4 weeks: corrections above 180, how often a low followed within 4 hours, and the same for other boluses.
    var corrections4w = 0
    var correctionLowRate4w: Double?
    var otherBolusLowRate4w: Double?
    var medianActiveInsulinAtCorrection4w: Double?
    var lowsWithCarbsLogged = 0
    var lows = 0
}

struct AOMealSlot: Codable, Equatable, Identifiable {
    var name: String
    var id: String { name }
    var count: Int
    var medianPeak: Double
    var over180: Double
    var medianRise: Double
}

struct AOBasalBlock: Codable, Equatable, Identifiable {
    var name: String
    var id: String { name }
    var startHour: Int
    var fastingHours: Int
    /// Insulin Loop or OpenAPS delivered (basal + automatic boluses) ÷ your scheduled basal, in fasting hours.
    var deliveredRatio: Double
    var scheduledRate: Double?
    var lowsInBlock: Int
}

struct AOInsulinSummary: Codable, Equatable {
    var totalPerDay: Double = 0
    var basalPerDay: Double = 0
    var manualBolusPerDay: Double = 0
    var automaticBolusPerDay: Double = 0
    var previousTotalPerDay: Double?
    var blocks: [AOBasalBlock] = []
}

struct AORideItem: Codable, Equatable, Identifiable {
    var start: Date
    var id: Date { start }
    var minutes: Int
    var activeInsulin: Double
    var lowestGlucose: Double?
    var wentLow: Bool { (lowestGlucose ?? 100) < 70 }
}

struct AORideSummary: Codable, Equatable {
    var rides: [AORideItem] = []
    var lowsLater = 0
    var rideDayTIR: Double?
    var otherDayTIR: Double?
}

struct AOSleepSummary: Codable, Equatable {
    var nights: Int
    var medianHours: Double
    var shortNights: Int
    var tirAfterShort4w: Double?
    var tirAfterNormal4w: Double?
}

struct AOSiteSummary: Codable, Equatable {
    var changes: Int
    var alerts: Int
    /// Time in range on day 1, day 2 and day 3+ of a site, over the last 4 weeks.
    var tirByDay: [Double?]
}

struct AOAdaptiveSummary: Codable, Equatable {
    var enabled: Bool
    var mode: String
    var hoursAdjusted: Int
    var averageScale: Double
    var topSignals: [String]
    var notes: [String]
}

struct AOInsight: Codable, Equatable, Hashable, Identifiable {
    enum Tone: String, Codable { case good, neutral, watch, problem }
    var id: String
    var tone: Tone
    var symbol: String
    var title: String
    var detail: String
}

struct AOSuggestion: Codable, Equatable, Hashable, Identifiable {
    enum Category: String, Codable, CaseIterable {
        case safety, dosing, habit
        var displayName: String {
            switch self {
            case .safety: return "Safety"
            case .dosing: return "Dosing settings"
            case .habit: return "Habits"
            }
        }
    }
    var id: String
    var category: Category
    var priority: Int
    var title: String
    var detail: String
    var evidence: String
}

struct AOReport: Codable, Equatable, Identifiable {
    enum Trigger: String, Codable { case scheduled, manual }
    enum Tone: String, Codable { case good, mixed, tough }

    var id = UUID()
    var version = 1
    var generatedAt: Date
    var start: Date
    var end: Date
    var trigger: Trigger
    var algorithm: String
    var headline: String
    var tone: Tone
    var metrics: AOGlucoseMetrics
    var previous: AOGlucoseMetrics?
    var days: [AOReportDay]
    var hours: [AOReportHour]
    var lows: AOEpisodeSummary
    var highs: AOEpisodeSummary
    var rollercoaster: AORollercoaster
    var corrections: AOCorrectionSummary
    var meals: [AOMealSlot]
    var insulin: AOInsulinSummary
    var rides: AORideSummary
    var sleep: AOSleepSummary?
    var sites: AOSiteSummary?
    var adaptive: AOAdaptiveSummary
    var insights: [AOInsight]
    var suggestions: [AOSuggestion]
}

// MARK: - Analysis

struct AOReportAnalyzer {
    /// Bolus insulin still active above which a correction counts as "on top of" earlier insulin.
    var stackedInsulinUnits = 4.0
    var lowWithin: TimeInterval = 4 * 3600

    struct Episode: Equatable {
        var start: Date
        var end: Date
        var extreme: Double
        var readings: Int
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    func make(_ input: AOReportInput, trigger: AOReport.Trigger, now: Date = Date()) -> AOReport? {
        let cal = input.calendar
        let start = input.start, end = input.end
        let days = end.timeIntervalSince(start) / 86400
        let glucose = input.glucose.sorted { $0.date < $1.date }
        let week = glucose.filter { $0.date >= start && $0.date < end }
        guard let metrics = AOGlucoseMetrics.compute(week.map(\.mgdl), days: days) else { return nil }
        let prevStart = start.addingTimeInterval(-(end.timeIntervalSince(start)))
        let previous = AOGlucoseMetrics.compute(glucose.filter { $0.date >= prevStart && $0.date < start }.map(\.mgdl), days: days)
        let fourWeeksStart = end.addingTimeInterval(-28 * 86400)

        let doses = input.doses.sorted { $0.start < $1.start }
        let boluses = doses.filter(\.isBolus)
        let manual = boluses.filter(\.isManual)
        let workouts = input.workouts.filter { $0.duration >= 15 * 60 }.sorted { $0.start < $1.start }
        let meals = AOMealDetector().meals(glucose: glucose.filter { $0.date >= fourWeeksStart.addingTimeInterval(-86400) }, doses: doses)

        let allLows = episodes(glucose, mergeGap: 15 * 60, minDuration: 10 * 60) { $0 < 70 }
        let allHighs = episodes(glucose, mergeGap: 30 * 60, minDuration: 30 * 60) { $0 > 180 }
        let lows = allLows.filter { $0.start >= start && $0.start < end }
        let highs = allHighs.filter { $0.start >= start && $0.start < end }

        // Lows and highs, by what came before them.
        var lowSummary = AOEpisodeSummary(count: lows.count, severe: lows.filter { $0.extreme < 54 }.count)
        lowSummary.previousCount = allLows.filter { $0.start >= prevStart && $0.start < start }.count
        lowSummary.medianMinutes = lows.map { $0.duration / 60 }.median
        for low in lows {
            let c = lowContext(low, workouts: workouts, highs: allHighs, meals: meals, calendar: cal)
            lowSummary.byContext[c.rawValue, default: 0] += 1
        }
        var highSummary = AOEpisodeSummary(count: highs.count, severe: highs.filter { $0.extreme > 250 }.count)
        highSummary.previousCount = allHighs.filter { $0.start >= prevStart && $0.start < start }.count
        highSummary.medianMinutes = highs.map { $0.duration / 60 }.median
        for high in highs {
            highSummary.byContext[highContext(high, lows: allLows, meals: meals, calendar: cal).rawValue, default: 0] += 1
        }

        var coaster = AORollercoaster(highs: highs.count, lows: lows.count)
        coaster.highsFollowedByLow = highs.filter { h in allLows.contains { $0.start > h.end && $0.start <= h.end.addingTimeInterval(5 * 3600) } }.count
        coaster.lowsFollowedByHigh = lows.filter { l in allHighs.contains { $0.start > l.end && $0.start <= l.end.addingTimeInterval(3 * 3600) } }.count

        let corrections = correctionSummary(glucose: glucose, boluses: boluses, manual: manual, lows: lows,
                                            carbs: input.carbs, start: start, end: end, fourWeeksStart: fourWeeksStart, days: days)
        let mealSlots = mealSlotSummary(meals: meals.filter { $0 >= start && $0 < end }, glucose: glucose, calendar: cal)
        let insulin = insulinSummary(input: input, doses: doses, meals: meals, manual: manual, glucose: glucose,
                                     lows: lows, start: start, end: end, prevStart: prevStart, days: days)
        let dayStats = daySummaries(week: week, workouts: workouts, start: start, end: end, calendar: cal)
        var rides = rideSummary(workouts: workouts.filter { $0.start >= start && $0.start < end }, boluses: boluses, glucose: glucose)
        rides.lowsLater = lowSummary.byContext[AOLowContext.afterRide.rawValue] ?? 0
        let rideDays = dayStats.filter(\.rode), otherDays = dayStats.filter { !$0.rode }
        if rideDays.count >= 2 && otherDays.count >= 2 {
            rides.rideDayTIR = rideDays.map(\.timeInRange).mean
            rides.otherDayTIR = otherDays.map(\.timeInRange).mean
        }
        let sleep = sleepSummary(nights: input.nights, glucose: glucose, start: start, end: end, fourWeeksStart: fourWeeksStart)
        let sites = siteSummary(input: input, glucose: glucose, start: start, end: end, fourWeeksStart: fourWeeksStart)
        let adaptive = adaptiveSummary(input: input, start: start, end: end)

        var report = AOReport(
            generatedAt: now, start: start, end: end, trigger: trigger, algorithm: input.algorithm,
            headline: "", tone: .mixed, metrics: metrics, previous: previous,
            days: dayStats, hours: hourProfile(week, calendar: cal),
            lows: lowSummary, highs: highSummary, rollercoaster: coaster, corrections: corrections,
            meals: mealSlots, insulin: insulin, rides: rides, sleep: sleep, sites: sites, adaptive: adaptive,
            insights: [], suggestions: [])
        report.insights = insights(report)
        report.suggestions = suggestions(report, input: input)
        (report.headline, report.tone) = headline(report)
        return report
    }

    // MARK: Episodes

    func episodes(_ glucose: [AOGlucosePoint], mergeGap: TimeInterval, minDuration: TimeInterval,
                  _ condition: (Double) -> Bool) -> [Episode] {
        var out: [Episode] = []
        var current: Episode?
        for p in glucose where condition(p.mgdl) {
            if var c = current, p.date.timeIntervalSince(c.end) <= mergeGap {
                c.end = p.date
                c.extreme = p.mgdl < 100 ? min(c.extreme, p.mgdl) : max(c.extreme, p.mgdl)
                c.readings += 1
                current = c
            } else {
                if let c = current { out.append(c) }
                current = Episode(start: p.date, end: p.date, extreme: p.mgdl, readings: 1)
            }
        }
        if let c = current { out.append(c) }
        return out.filter { $0.readings >= 2 && $0.duration >= minDuration }
    }

    func lowContext(_ low: Episode, workouts: [AOWorkout], highs: [Episode], meals: [Date], calendar: Calendar) -> AOLowContext {
        let s = low.start
        if workouts.contains(where: { $0.start <= s && s <= $0.end.addingTimeInterval(3600) }) { return .duringRide }
        if workouts.contains(where: { s > $0.end.addingTimeInterval(3600) && s <= $0.end.addingTimeInterval(12 * 3600) }) { return .afterRide }
        if highs.contains(where: { $0.start < s && $0.end >= s.addingTimeInterval(-5 * 3600) }) { return .afterHigh }
        if calendar.component(.hour, from: s) < 6 { return .overnight }
        if meals.contains(where: { $0 < s && $0 >= s.addingTimeInterval(-4 * 3600) }) { return .afterMeal }
        return .other
    }

    func highContext(_ high: Episode, lows: [Episode], meals: [Date], calendar: Calendar) -> AOHighContext {
        let s = high.start
        if lows.contains(where: { $0.end < s && $0.end >= s.addingTimeInterval(-3 * 3600) }) { return .rebound }
        if meals.contains(where: { $0 <= s.addingTimeInterval(15 * 60) && $0 >= s.addingTimeInterval(-3 * 3600) }) { return .afterMeal }
        if calendar.component(.hour, from: s) < 6 { return .overnight }
        return .unexplained
    }

    // MARK: Corrections and low treatment

    private func reading(at date: Date, in glucose: [AOGlucosePoint], within: TimeInterval = 15 * 60) -> Double? {
        // Latest reading at or before `date` (glucose is sorted).
        var lo = 0, hi = glucose.count
        while lo < hi { let mid = (lo + hi) / 2; if glucose[mid].date <= date { lo = mid + 1 } else { hi = mid } }
        guard lo > 0, date.timeIntervalSince(glucose[lo - 1].date) <= within else { return nil }
        return glucose[lo - 1].mgdl
    }

    private func activeBolusInsulin(_ boluses: [AOInsulinDose], at date: Date) -> Double {
        AOInsulinModel.onBoard(boluses.filter { $0.start < date && $0.start > date.addingTimeInterval(-7 * 3600) }, at: date)
    }

    private func lowFollows(_ date: Date, glucose: [AOGlucosePoint], within: TimeInterval) -> Bool {
        glucose.contains { $0.date > date && $0.date <= date.addingTimeInterval(within) && $0.mgdl < 70 }
    }

    func correctionSummary(glucose: [AOGlucosePoint], boluses: [AOInsulinDose], manual: [AOInsulinDose], lows: [Episode],
                           carbs: [AOCarbEntry], start: Date, end: Date, fourWeeksStart: Date, days: Double) -> AOCorrectionSummary {
        var s = AOCorrectionSummary()
        s.manualBolusesPerDay = Double(manual.filter { $0.start >= start && $0.start < end }.count) / max(days, 1)
        var corrLow = 0, corrN = 0, otherLow = 0, otherN = 0
        var corrIOB: [Double] = []
        // Only judge boluses whose 4-hour follow-up is complete.
        for b in manual where (b.start >= fourWeeksStart && b.start < end.addingTimeInterval(-lowWithin)) || (b.start >= start && b.start < end) {
            guard let g = reading(at: b.start, in: glucose) else { continue }
            let iob = activeBolusInsulin(boluses, at: b.start)
            let thisWeek = b.start >= start && b.start < end
            if g > 180 && thisWeek {
                s.correctionsThisWeek += 1
                if iob >= stackedInsulinUnits { s.correctionsOnActiveInsulinThisWeek += 1 }
            }
            guard b.start < end.addingTimeInterval(-lowWithin) else { continue }
            let low = lowFollows(b.start, glucose: glucose, within: lowWithin)
            if g > 180 { corrN += 1; corrIOB.append(iob); if low { corrLow += 1 } }
            else { otherN += 1; if low { otherLow += 1 } }
        }
        s.corrections4w = corrN
        s.correctionLowRate4w = corrN >= 5 ? Double(corrLow) / Double(corrN) : nil
        s.otherBolusLowRate4w = otherN >= 5 ? Double(otherLow) / Double(otherN) : nil
        s.medianActiveInsulinAtCorrection4w = corrIOB.median
        s.lows = lows.count
        s.lowsWithCarbsLogged = lows.filter { l in
            carbs.contains { $0.date >= l.start.addingTimeInterval(-10 * 60) && $0.date <= l.end.addingTimeInterval(30 * 60) && $0.grams > 0 }
        }.count
        return s
    }

    // MARK: Meals

    static func slotName(hour: Int) -> String {
        switch hour {
        case 4..<11: return "Breakfast"
        case 11..<16: return "Lunch"
        case 16..<21: return "Dinner"
        default: return "Late"
        }
    }

    static let slotHours: [String: ClosedRange<Int>] = ["Breakfast": 4...10, "Lunch": 11...15, "Dinner": 16...20, "Late": 21...23]

    func mealSlotSummary(meals: [Date], glucose: [AOGlucosePoint], calendar: Calendar) -> [AOMealSlot] {
        var bySlot: [String: [(peak: Double, rise: Double)]] = [:]
        for m in meals {
            let window = glucose.filter { $0.date > m && $0.date <= m.addingTimeInterval(3 * 3600) }
            guard window.count >= 24, let base = reading(at: m.addingTimeInterval(60), in: glucose, within: 20 * 60),
                  let peak = window.map(\.mgdl).max() else { continue }
            bySlot[Self.slotName(hour: calendar.component(.hour, from: m)), default: []].append((peak, peak - base))
        }
        return ["Breakfast", "Lunch", "Dinner", "Late"].compactMap { name in
            guard let items = bySlot[name], !items.isEmpty else { return nil }
            return AOMealSlot(name: name, count: items.count, medianPeak: items.map(\.peak).median ?? 0,
                              over180: Double(items.filter { $0.peak > 180 }.count) / Double(items.count),
                              medianRise: items.map(\.rise).median ?? 0)
        }
    }

    // MARK: Insulin and basal

    /// Units of `dose` delivered within `range` (basal spread evenly over its interval).
    private func units(_ dose: AOInsulinDose, in range: Range<Date>) -> Double {
        if dose.isBolus || dose.end <= dose.start { return range.contains(dose.start) ? dose.units : 0 }
        let overlap = min(dose.end, range.upperBound).timeIntervalSince(max(dose.start, range.lowerBound))
        return overlap > 0 ? dose.units * overlap / dose.end.timeIntervalSince(dose.start) : 0
    }

    func insulinSummary(input: AOReportInput, doses: [AOInsulinDose], meals: [Date], manual: [AOInsulinDose],
                        glucose: [AOGlucosePoint], lows: [Episode], start: Date, end: Date, prevStart: Date, days: Double) -> AOInsulinSummary {
        var s = AOInsulinSummary()
        let week = start..<end
        let inWeek = doses.filter { $0.end > start && $0.start < end }
        let basal = inWeek.filter { !$0.isBolus }.reduce(0) { $0 + units($1, in: week) }
        let manualU = inWeek.filter { $0.isBolus && $0.isManual }.reduce(0) { $0 + units($1, in: week) }
        let autoU = inWeek.filter { $0.isBolus && !$0.isManual }.reduce(0) { $0 + units($1, in: week) }
        s.basalPerDay = basal / days; s.manualBolusPerDay = manualU / days; s.automaticBolusPerDay = autoU / days
        s.totalPerDay = (basal + manualU + autoU) / days
        let prevRange = prevStart..<start
        let prev = doses.filter { $0.end > prevStart && $0.start < start }.reduce(0) { $0 + units($1, in: prevRange) }
        // Only compare when last week's insulin history looks complete (some basal every day).
        if prev > 0.3 * (basal + manualU + autoU) { s.previousTotalPerDay = prev / days }

        // Fasting hours: no meal and no manual bolus in the 4 hours before, glucose present.
        let cal = input.calendar
        let tickScale = Dictionary(input.ticks.map { ($0.hourStart, $0.meanScale) }, uniquingKeysWith: { a, _ in a })
        let blocks: [(String, Range<Int>)] = [("12–6am", 0..<6), ("6am–12pm", 6..<12), ("12–6pm", 12..<18), ("6pm–12am", 18..<24)]
        var delivered = [Int: Double](), scheduled = [Int: Double](), hours = [Int: Int]()
        var hour = cal.dateInterval(of: .hour, for: start)?.start ?? start
        while hour < end {
            defer { hour = hour.addingTimeInterval(3600) }
            let next = hour.addingTimeInterval(3600)
            let h = cal.component(.hour, from: hour)
            guard let bi = blocks.firstIndex(where: { $0.1.contains(h) }), let rate = input.scheduledBasal(hour.addingTimeInterval(1800)) else { continue }
            let lookback = hour.addingTimeInterval(-4 * 3600)
            if meals.contains(where: { $0 >= lookback && $0 < next }) { continue }
            if manual.contains(where: { $0.start >= lookback && $0.start < next }) { continue }
            if glucose.filter({ $0.date >= hour && $0.date < next }).count < 6 { continue }
            let d = doses.filter { $0.end > hour && $0.start < next && !($0.isBolus && $0.isManual) }.reduce(0) { $0 + units($1, in: hour..<next) }
            delivered[bi, default: 0] += d
            scheduled[bi, default: 0] += rate * (tickScale[hour] ?? 1)
            hours[bi, default: 0] += 1
        }
        for (i, b) in blocks.enumerated() {
            guard let n = hours[i], n >= 6, let sch = scheduled[i], sch > 0 else { continue }
            let lowsInBlock = lows.filter { b.1.contains(cal.component(.hour, from: $0.start)) }.count
            let atHour = cal.startOfDay(for: end).addingTimeInterval(Double(b.1.lowerBound) * 3600 + 1800)
            s.blocks.append(AOBasalBlock(name: b.0, startHour: b.1.lowerBound, fastingHours: n,
                                         deliveredRatio: (delivered[i] ?? 0) / sch,
                                         scheduledRate: input.scheduledBasal(atHour), lowsInBlock: lowsInBlock))
        }
        return s
    }

    // MARK: Days and hours

    func daySummaries(week: [AOGlucosePoint], workouts: [AOWorkout], start: Date, end: Date, calendar: Calendar) -> [AOReportDay] {
        var out: [AOReportDay] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let v = week.filter { $0.date >= day && $0.date < next }.map(\.mgdl)
            if v.count >= 144 {
                let n = Double(v.count)
                out.append(AOReportDay(date: day, timeInRange: Double(v.filter { $0 >= 70 && $0 <= 180 }.count) / n,
                                       below70: Double(v.filter { $0 < 70 }.count) / n,
                                       above180: Double(v.filter { $0 > 180 }.count) / n,
                                       mean: v.reduce(0, +) / n,
                                       rode: workouts.contains { $0.start >= day && $0.start < next }))
            }
            day = next
        }
        return out
    }

    func hourProfile(_ week: [AOGlucosePoint], calendar: Calendar) -> [AOReportHour] {
        var byHour = [Int: [Double]]()
        for p in week { byHour[calendar.component(.hour, from: p.date), default: []].append(p.mgdl) }
        return (0..<24).compactMap { h in
            guard let v = byHour[h]?.sorted(), v.count >= 12 else { return nil }
            func q(_ p: Double) -> Double {
                let x = p * Double(v.count - 1), i = Int(x), f = x - Double(i)
                return i + 1 < v.count ? v[i] * (1 - f) + v[i + 1] * f : v[i]
            }
            return AOReportHour(hour: h, p10: q(0.1), p25: q(0.25), p50: q(0.5), p75: q(0.75), p90: q(0.9))
        }
    }

    // MARK: Rides, sleep, sites, adaptive

    func rideSummary(workouts: [AOWorkout], boluses: [AOInsulinDose], glucose: [AOGlucosePoint]) -> AORideSummary {
        var s = AORideSummary()
        for w in workouts {
            let window = glucose.filter { $0.date >= w.start && $0.date <= w.end.addingTimeInterval(3600) }
            s.rides.append(AORideItem(start: w.start, minutes: Int((w.duration / 60).rounded()),
                                      activeInsulin: activeBolusInsulin(boluses, at: w.start),
                                      lowestGlucose: window.map(\.mgdl).min()))
        }
        return s
    }

    func sleepSummary(nights: [AOSleepNight], glucose: [AOGlucosePoint], start: Date, end: Date, fourWeeksStart: Date) -> AOSleepSummary? {
        let week = nights.filter { $0.wake >= start && $0.wake < end && $0.asleepDuration >= 2 * 3600 }
        guard week.count >= 3 else { return nil }
        func tirAfter(_ n: AOSleepNight) -> Double? {
            let v = glucose.filter { $0.date >= n.wake && $0.date < n.wake.addingTimeInterval(14 * 3600) }.map(\.mgdl)
            return v.count >= 100 ? Double(v.filter { $0 >= 70 && $0 <= 180 }.count) / Double(v.count) : nil
        }
        let recent = nights.filter { $0.wake >= fourWeeksStart && $0.wake < end && $0.asleepDuration >= 2 * 3600 }
        let short = recent.filter { $0.asleepDuration < 6 * 3600 }.compactMap(tirAfter)
        let normal = recent.filter { $0.asleepDuration >= 6 * 3600 }.compactMap(tirAfter)
        return AOSleepSummary(nights: week.count, medianHours: week.map { $0.asleepDuration / 3600 }.median ?? 0,
                              shortNights: week.filter { $0.asleepDuration < 6 * 3600 }.count,
                              tirAfterShort4w: short.count >= 2 ? short.mean : nil,
                              tirAfterNormal4w: normal.count >= 3 ? normal.mean : nil)
    }

    func siteSummary(input: AOReportInput, glucose: [AOGlucosePoint], start: Date, end: Date, fourWeeksStart: Date) -> AOSiteSummary? {
        let changes = input.siteChanges.map(\.date).sorted()
        let recent = changes.filter { $0 >= fourWeeksStart.addingTimeInterval(-4 * 86400) && $0 < end }
        guard !recent.isEmpty else { return nil }
        var inRange = [0, 0, 0], total = [0, 0, 0]
        for p in glucose where p.date >= fourWeeksStart && p.date < end {
            guard let last = recent.last(where: { $0 <= p.date }) else { continue }
            let day = min(Int(p.date.timeIntervalSince(last) / 86400), 2)
            total[day] += 1
            if p.mgdl >= 70 && p.mgdl <= 180 { inRange[day] += 1 }
        }
        let tir: [Double?] = (0..<3).map { total[$0] >= 288 ? Double(inRange[$0]) / Double(total[$0]) : nil }
        return AOSiteSummary(changes: changes.filter { $0 >= start && $0 < end }.count,
                             alerts: input.siteAlerts.filter { $0 >= start && $0 < end }.count, tirByDay: tir)
    }

    func adaptiveSummary(input: AOReportInput, start: Date, end: Date) -> AOAdaptiveSummary {
        let ticks = input.ticks.filter { $0.hourStart >= start && $0.hourStart < end }
        let adjusted = ticks.filter { abs($0.meanScale - 1) >= 0.02 }
        var counts = [String: Int]()
        for t in ticks { for s in t.signals { counts[s, default: 0] += 1 } }
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map { "\(AOSignal(id: $0.key).displayName) (\($0.value) h)" }
        return AOAdaptiveSummary(enabled: input.adaptiveEnabled, mode: input.adaptiveMode, hoursAdjusted: adjusted.count,
                                 averageScale: ticks.isEmpty ? 1 : ticks.map(\.meanScale).reduce(0, +) / Double(ticks.count),
                                 topSignals: Array(top), notes: Array(input.effectivenessNotes.suffix(3)))
    }

    // MARK: Words

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    static func pct1(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
    static func points(_ x: Double) -> String {
        let p = Int((x * 100).rounded())
        return p == 0 ? "no change" : "\(p > 0 ? "up" : "down") \(abs(p)) point\(abs(p) == 1 ? "" : "s")"
    }
    static func units(_ x: Double) -> String { String(format: "%.1f U", x) }

    func headline(_ r: AOReport) -> (String, AOReport.Tone) {
        let m = r.metrics
        var text = "\(Self.pct(m.timeInRange)) in range"
        if let p = r.previous { text += ", \(Self.points(m.timeInRange - p.timeInRange)) from the week before" }
        let tone: AOReport.Tone
        if m.timeInRange < 0.6 || m.below70 > 0.05 || m.below54 > 0.01 { tone = .tough }
        else if m.timeInRange >= 0.7 && m.below70 < 0.04 && (r.previous.map { m.timeInRange >= $0.timeInRange - 0.03 } ?? true) { tone = .good }
        else { tone = .mixed }
        return (text, tone)
    }

    func insights(_ r: AOReport) -> [AOInsight] {
        var out: [AOInsight] = []
        let m = r.metrics
        if let p = r.previous {
            let d = m.timeInRange - p.timeInRange
            out.append(AOInsight(id: "tir", tone: d >= 0.02 ? .good : d <= -0.03 ? .watch : .neutral,
                                 symbol: d >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                                 title: "Time in range \(Self.points(d))",
                                 detail: "\(Self.pct(m.timeInRange)) this week vs \(Self.pct(p.timeInRange)). Below 70: \(Self.pct1(m.below70)) (was \(Self.pct1(p.below70))). Above 180: \(Self.pct(m.above180)) (was \(Self.pct(p.above180)))."))
        }
        if m.coverage < 0.7 {
            out.append(AOInsight(id: "coverage", tone: .watch, symbol: "antenna.radiowaves.left.and.right.slash",
                                 title: "CGM data was missing \(Self.pct(1 - m.coverage)) of the week",
                                 detail: "Numbers in this report are less reliable than usual."))
        }
        if r.lows.count > 0 {
            var title = "\(r.lows.count) low\(r.lows.count == 1 ? "" : "s")"
            if r.lows.severe > 0 { title += ", \(r.lows.severe) below 54" }
            var detail = ""
            if let top = r.lows.topContext, let context = AOLowContext(rawValue: top.name) {
                detail = "Most common: \(context.displayName.lowercased()) (\(top.count))."
            }
            if let previous = r.lows.previousCount { detail += " The week before: \(previous)." }
            let tone: AOInsight.Tone = r.lows.severe > 0 || m.below70 > 0.04 ? .problem : .watch
            out.append(AOInsight(id: "lows", tone: tone, symbol: "arrow.down.to.line.circle.fill", title: title, detail: detail))
        } else {
            out.append(AOInsight(id: "lows", tone: .good, symbol: "checkmark.circle.fill", title: "No lows", detail: "No time below 70 lasting 10 minutes or more."))
        }
        if r.highs.count > 0 {
            var detail = ""
            if let top = r.highs.topContext, let context = AOHighContext(rawValue: top.name) {
                detail = "Most common: \(context.displayName.lowercased()) (\(top.count))."
            }
            if let minutes = r.highs.medianMinutes { detail += " Typical length \(Int(minutes.rounded())) min." }
            let tone: AOInsight.Tone = m.above180 > 0.25 ? .problem : .watch
            out.append(AOInsight(id: "highs", tone: tone, symbol: "arrow.up.to.line.circle.fill",
                                 title: "\(r.highs.count) high\(r.highs.count == 1 ? "" : "s") over 180", detail: detail))
        }
        let rc = r.rollercoaster
        if rc.highsFollowedByLow + rc.lowsFollowedByHigh >= 3 {
            out.append(AOInsight(id: "coaster", tone: .problem, symbol: "waveform.path",
                                 title: "Roller coaster",
                                 detail: "\(rc.highsFollowedByLow) of \(rc.highs) highs were followed by a low within 5 hours, and \(rc.lowsFollowedByHigh) of \(rc.lows) lows bounced back above 180 within 3 hours."))
        }
        let c = r.corrections
        if let rate = c.correctionLowRate4w, c.corrections4w >= 5 {
            var detail = "Last 4 weeks: \(c.corrections4w) manual boluses above 180"
            if let iob = c.medianActiveInsulinAtCorrection4w { detail += ", usually with \(Self.units(iob)) of bolus insulin already active" }
            if let other = c.otherBolusLowRate4w { detail += ". Other boluses: \(Self.pct(other))." } else { detail += "." }
            detail += " You gave about \(Int(c.manualBolusesPerDay.rounded())) manual boluses a day this week."
            let tone: AOInsight.Tone = rate >= 0.4 ? .problem : .neutral
            out.append(AOInsight(id: "corrections", tone: tone, symbol: "syringe",
                                 title: "Corrections above 180 ended low \(Self.pct(rate)) of the time", detail: detail))
        }
        if let best = r.days.max(by: { $0.timeInRange < $1.timeInRange }), let worst = r.days.min(by: { $0.timeInRange < $1.timeInRange }), r.days.count >= 3, best != worst {
            let f = DateFormatter(); f.dateFormat = "EEEE"
            out.append(AOInsight(id: "days", tone: .neutral, symbol: "calendar",
                                 title: "Best day \(f.string(from: best.date)), toughest \(f.string(from: worst.date))",
                                 detail: "\(Self.pct(best.timeInRange)) vs \(Self.pct(worst.timeInRange)) in range (average \(Int(worst.mean.rounded())) mg/dL on \(f.string(from: worst.date)))."))
        }
        if let rideTIR = r.rides.rideDayTIR, let other = r.rides.otherDayTIR {
            out.append(AOInsight(id: "ridedays", tone: .neutral, symbol: "bicycle",
                                 title: "Ride days \(Self.pct(rideTIR)) vs other days \(Self.pct(other))",
                                 detail: "\(r.rides.rides.count) rides or workouts this week; \(r.rides.rides.filter(\.wentLow).count) went below 70 during or within an hour after."))
        }
        if let peakHour = r.hours.max(by: { $0.p50 < $1.p50 }), peakHour.p50 > 160 {
            out.append(AOInsight(id: "peakhour", tone: .watch, symbol: "clock",
                                 title: "Highest time of day: \(Self.hourName(peakHour.hour))",
                                 detail: "Median \(Int(peakHour.p50.rounded())) mg/dL at that hour; 1 in 10 readings above \(Int(peakHour.p90.rounded()))."))
        }
        if let slot = r.meals.filter({ $0.count >= 3 }).max(by: { $0.medianPeak < $1.medianPeak }), slot.medianPeak > 180 {
            out.append(AOInsight(id: "meals", tone: .watch, symbol: "fork.knife",
                                 title: "\(slot.name) spikes the most",
                                 detail: "\(slot.count) \(slot.name.lowercased())s detected; median peak \(Int(slot.medianPeak.rounded())) mg/dL, \(Self.pct(slot.over180)) went above 180."))
        }
        let ins = r.insulin
        var insulinTitle = "\(Int(ins.totalPerDay.rounded())) U a day"
        if let previous = ins.previousTotalPerDay, previous > 0 {
            insulinTitle += " (\(Self.signedPct(ins.totalPerDay / previous - 1)) vs the week before)"
        }
        out.append(AOInsight(id: "insulin", tone: .neutral, symbol: "drop.fill",
                             title: insulinTitle,
                             detail: "Basal \(Self.units(ins.basalPerDay)), your boluses \(Self.units(ins.manualBolusPerDay)), automatic boluses \(Self.units(ins.automaticBolusPerDay)) a day."))
        if let s = r.sleep, s.shortNights > 0 {
            var d = "\(s.shortNights) of \(s.nights) nights under 6 hours (median \(String(format: "%.1f", s.medianHours)) h)."
            if let a = s.tirAfterShort4w, let b = s.tirAfterNormal4w { d += " Over 4 weeks, days after short nights averaged \(Self.pct(a)) in range vs \(Self.pct(b))." }
            out.append(AOInsight(id: "sleep", tone: .neutral, symbol: "bed.double.fill", title: "Sleep", detail: d))
        }
        if let s = r.sites {
            var d = "\(s.changes) site change\(s.changes == 1 ? "" : "s")"
            if s.alerts > 0 { d += ", \(s.alerts) site alert\(s.alerts == 1 ? "" : "s")" }
            d += "."
            let labels = ["day 1", "day 2", "day 3+"]
            let parts = zip(labels, s.tirByDay).compactMap { l, v in v.map { "\(l) \(Self.pct($0))" } }
            if parts.count >= 2 { d += " Time in range by site age (4 weeks): " + parts.joined(separator: ", ") + "." }
            out.append(AOInsight(id: "sites", tone: .neutral, symbol: "bandage.fill", title: "Infusion sites", detail: d))
        }
        let a = r.adaptive
        if a.enabled {
            var detail = "Average \(Self.pct(a.averageScale)) (\(a.mode.lowercased()) mode)."
            if !a.topSignals.isEmpty { detail += " Most active: " + a.topSignals.joined(separator: ", ") + "." }
            if !a.notes.isEmpty { detail += " " + a.notes.joined(separator: " ") }
            out.append(AOInsight(id: "adaptive", tone: .neutral, symbol: "waveform.path.ecg",
                                 title: "Adaptive adjustments: \(a.hoursAdjusted) hours adjusted", detail: detail))
        }
        return out
    }

    static func signedPct(_ x: Double) -> String { "\(x >= 0 ? "+" : "−")\(Int((abs(x) * 100).rounded()))%" }
    static func hourName(_ h: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "ha"
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        let e = Calendar.current.date(bySettingHour: (h + 1) % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return "\(f.string(from: d).lowercased())–\(f.string(from: e).lowercased())"
    }
    static func rate(_ x: Double) -> String { String(format: "%.2f U/h", x) }
    static func roundTo(_ x: Double, _ step: Double) -> Double { (x / step).rounded() * step }

    func suggestions(_ r: AOReport, input: AOReportInput) -> [AOSuggestion] {
        var out: [AOSuggestion] = []
        let m = r.metrics
        let lowCount = { (c: AOLowContext) in r.lows.byContext[c.rawValue] ?? 0 }

        // Safety first.
        if m.below54 > 0.01 || r.lows.severe >= 3 {
            let top = r.lows.topContext.flatMap { AOLowContext(rawValue: $0.name) }
            let action: String
            switch top {
            case .duringRide?, .afterRide?: action = "Most were around rides: see the ride suggestion below."
            case .afterHigh?: action = "Most came after a high: see the correction suggestion below."
            case .overnight?: action = "Most were overnight: see the overnight basal suggestion below."
            default: action = "Look at what came before each one in the daily chart."
            }
            out.append(AOSuggestion(id: "safety.lows", category: .safety, priority: 0,
                                    title: "Cut down serious lows",
                                    detail: "\(Self.pct1(m.below54)) of the week was below 54 (target under 1%). \(action) Keep fast carbs with you, and treat early.",
                                    evidence: "\(r.lows.severe) lows below 54 this week."))
        }

        // Over-correction: the biggest driver of the roller coaster in your data.
        let c = r.corrections
        if let rate = c.correctionLowRate4w, c.corrections4w >= 8, rate >= 0.4, rate >= (c.otherBolusLowRate4w ?? 0) + 0.1 {
            let iob = c.medianActiveInsulinAtCorrection4w.map { Self.units($0) } ?? "a lot"
            out.append(AOSuggestion(id: "habit.corrections", category: .habit, priority: 1,
                                    title: "Let corrections finish before adding more",
                                    detail: "Before a correction, check the insulin already working. With more than \(Int(stackedInsulinUnits)) U of bolus insulin active, wait 60–90 minutes: Loop is already correcting, and the earlier insulin hasn't peaked yet. If you're still high and flat after that, give a smaller correction.",
                                    evidence: "Last 4 weeks: \(Self.pct(rate)) of your \(c.corrections4w) corrections above 180 were followed by a low within 4 hours (other boluses: \(c.otherBolusLowRate4w.map(Self.pct) ?? "n/a")). The usual insulin already active at those corrections: \(iob). This week: \(c.correctionsOnActiveInsulinThisWeek) of \(c.correctionsThisWeek) corrections were on top of \(Int(stackedInsulinUnits))+ U."))
        }

        // Rebounds and low treatment.
        let rc = r.rollercoaster
        if rc.lows >= 3, rc.lowsFollowedByHigh >= 3, Double(rc.lowsFollowedByHigh) / Double(rc.lows) >= 0.3 {
            var detail = "Treat with a measured 15–20 g of fast carbs, wait 15 minutes, and repeat only if still under 70. Eating until you feel better usually overshoots."
            if c.lowsWithCarbsLogged * 2 < c.lows {
                detail += " Log the carbs in Loop (fast absorption), so it expects the rise and doesn't add a correction on top."
            }
            out.append(AOSuggestion(id: "habit.lowtreatment", category: .habit, priority: 2,
                                    title: "Treat lows with a measured amount",
                                    detail: detail,
                                    evidence: "\(rc.lowsFollowedByHigh) of \(rc.lows) lows went above 180 within 3 hours. Carbs were logged for \(c.lowsWithCarbsLogged) of \(c.lows) lows."))
        }

        // Rides.
        let rides = r.rides.rides
        let lowRides = rides.filter(\.wentLow)
        if lowRides.count >= 2 || (lowRides.count == 1 && rides.count <= 3) {
            let lowIOB = lowRides.map(\.activeInsulin).median ?? 0
            let okIOB = rides.filter { !$0.wentLow }.map(\.activeInsulin).median
            var rideEvidence = "\(lowRides.count) of \(rides.count) rides went below 70. Insulin active at the start: \(Self.units(lowIOB)) for those"
            rideEvidence += okIOB.map { " vs \(Self.units($0)) for the rest." } ?? "."
            out.append(AOSuggestion(id: "habit.rides", category: .habit, priority: 3,
                                    title: "Less bolus insulin going into rides",
                                    detail: "Rides that went low started with more insulin active. On ride days, bolus earlier and smaller for the meal before you leave, and skip corrections in the hour before the ride. Adaptive adjustments already trim insulin before your usual rides; this is the part only you can change.",
                                    evidence: rideEvidence))
        }
        if r.rides.lowsLater >= 2 {
            out.append(AOSuggestion(id: "habit.afterride", category: .habit, priority: 4,
                                    title: "Watch the hours after a ride",
                                    detail: "Muscles keep pulling glucose in for up to 12 hours after exercise. On ride days, consider a smaller dinner bolus (around 20% less) and a bedtime glucose check.",
                                    evidence: "\(r.rides.lowsLater) lows started 1–12 hours after a ride this week."))
        }

        // Basal from what the algorithm actually delivered in fasting hours.
        for b in r.insulin.blocks where b.fastingHours >= 10 {
            guard let current = b.scheduledRate else { continue }
            if b.deliveredRatio >= 1.15 && b.lowsInBlock == 0 {
                let suggested = Self.roundTo(current * min(b.deliveredRatio, 1.1), 0.05)
                guard suggested > current else { continue }
                out.append(AOSuggestion(id: "dosing.basal.\(b.startHour)", category: .dosing, priority: 5,
                                        title: "Basal \(b.name): \(Self.rate(current)) → \(Self.rate(suggested))",
                                        detail: "Without meals or boluses, \(r.algorithm) kept adding insulin above your schedule in these hours. A slightly higher basal lets it do less catching up.",
                                        evidence: "Delivered \(Self.pct(b.deliveredRatio)) of scheduled basal in \(b.fastingHours) fasting hours, with no lows in this block."))
            } else if b.deliveredRatio <= 0.8 {
                let suggested = Self.roundTo(current * max(b.deliveredRatio, 0.9), 0.05)
                guard suggested < current else { continue }
                out.append(AOSuggestion(id: "dosing.basal.\(b.startHour)", category: .dosing, priority: 5,
                                        title: "Basal \(b.name): \(Self.rate(current)) → \(Self.rate(suggested))",
                                        detail: "Without meals or boluses, \(r.algorithm) kept cutting back your basal in these hours, so the schedule is probably a little high.",
                                        evidence: "Delivered \(Self.pct(b.deliveredRatio)) of scheduled basal in \(b.fastingHours) fasting hours" + (b.lowsInBlock > 0 ? ", with \(b.lowsInBlock) low\(b.lowsInBlock == 1 ? "" : "s") in this block." : ".")))
            }
        }
        // Overnight lows that aren't explained by a ride or a high.
        if lowCount(.overnight) >= 2, !out.contains(where: { $0.id == "dosing.basal.0" }),
           let rate = input.scheduledBasal(input.calendar.startOfDay(for: r.end).addingTimeInterval(3 * 3600)) {
            let suggested = Self.roundTo(rate * 0.9, 0.05)
            out.append(AOSuggestion(id: "dosing.basal.0", category: .dosing, priority: 5,
                                    title: "Basal 12–6am: \(Self.rate(rate)) → \(Self.rate(suggested))",
                                    detail: "Lows overnight with no ride or high before them point to overnight basal.",
                                    evidence: "\(lowCount(.overnight)) overnight lows this week."))
        }
        // Settings suggestions from the 4-week tuner (fasting basal and clean corrections).
        if let isf = input.settingsSuggestions.isf {
            out.append(AOSuggestion(id: "dosing.isf", category: .dosing, priority: 6,
                                    title: "Sensitivity (ISF): \(Int(isf.current)) → \(Int(isf.suggested)) mg/dL/U",
                                    detail: "From corrections with no food or exercise around them.",
                                    evidence: "\(isf.episodes) clean corrections over 4 weeks."))
        }

        // Meals.
        if let slot = r.meals.filter({ $0.count >= 3 && $0.over180 >= 0.6 && $0.medianPeak >= 190 }).max(by: { $0.medianPeak < $1.medianPeak }) {
            out.append(AOSuggestion(id: "habit.prebolus.\(slot.name)", category: .habit, priority: 7,
                                    title: "Bolus earlier for \(slot.name.lowercased())",
                                    detail: "Give the \(slot.name.lowercased()) bolus 15–20 minutes before eating (longer if you're above 150), so insulin is working when the carbs arrive.",
                                    evidence: "\(Self.pct(slot.over180)) of \(slot.count) \(slot.name.lowercased())s went above 180; median peak \(Int(slot.medianPeak.rounded())) mg/dL, a rise of \(Int(slot.medianRise.rounded()))."))
            if let hours = Self.slotHours[slot.name], let cr = input.carbRatio(input.calendar.startOfDay(for: r.end).addingTimeInterval(Double(hours.lowerBound + 2) * 3600)) {
                let suggested = Self.roundTo(cr * 0.9, 0.5)
                if suggested < cr {
                    out.append(AOSuggestion(id: "dosing.cr.\(slot.name)", category: .dosing, priority: 8,
                                            title: "Carb ratio around \(slot.name.lowercased()): \(Self.trim(cr)) → \(Self.trim(suggested)) g/U",
                                            detail: "If you already pre-bolus and still spike, the ratio for those hours (or your usual estimate for that meal) is probably low. Try one step at a time.",
                                            evidence: "Same \(slot.name.lowercased()) spikes as above."))
                }
            }
        }

        // Sites and sleep.
        if let s = r.sites, s.tirByDay.count == 3, let d3 = s.tirByDay[2] {
            let early = s.tirByDay[0...1].compactMap { $0 }.max()
            if let early, early - d3 >= 0.08 {
                out.append(AOSuggestion(id: "habit.sites", category: .habit, priority: 9,
                                        title: "Change sites a day sooner",
                                        detail: "Your third day on a site does noticeably worse. Try changing on day 2–2½, and rotate away from areas that have been used a lot.",
                                        evidence: "4 weeks: \(Self.pct(d3)) in range on day 3+ vs \(Self.pct(early)) earlier."))
            }
        }
        if let s = r.sleep, s.shortNights >= 2, let a = s.tirAfterShort4w, let b = s.tirAfterNormal4w, b - a >= 0.08 {
            out.append(AOSuggestion(id: "habit.sleep", category: .habit, priority: 10,
                                    title: "Protect your sleep",
                                    detail: "Short nights are followed by tougher days for you. Adaptive adjustments learn this too, but more sleep helps more.",
                                    evidence: "4 weeks: \(Self.pct(a)) in range after nights under 6 hours vs \(Self.pct(b)) after longer nights."))
        }
        if (r.highs.byContext[AOHighContext.unexplained.rawValue] ?? 0) >= 3 {
            out.append(AOSuggestion(id: "habit.unexplained", category: .habit, priority: 11,
                                    title: "Check unexplained highs",
                                    detail: "Highs with no meal or low before them are often a site or cannula problem, or a snack without a bolus. If they come on day 3 of a site, change it.",
                                    evidence: "\(r.highs.byContext[AOHighContext.unexplained.rawValue] ?? 0) highs this week with no meal or low before them."))
        }
        return out.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }

    static func trim(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
}

// MARK: - Plain-text version (for sharing)

extension AOReport {
    var dateRangeText: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
    }

    var plainText: String {
        typealias A = AOReportAnalyzer
        var lines = ["Weekly report \(dateRangeText) (\(algorithm))", headline, ""]
        let m = metrics
        lines.append("In range \(A.pct(m.timeInRange)) · tight range \(A.pct(m.timeInTightRange)) · below 70 \(A.pct1(m.below70)) · below 54 \(A.pct1(m.below54)) · above 180 \(A.pct(m.above180)) · above 250 \(A.pct(m.above250))")
        lines.append("Average \(Int(m.mean.rounded())) mg/dL · GMI \(String(format: "%.1f", m.gmi))% · CV \(A.pct(m.cv)) · CGM \(A.pct(m.coverage))")
        lines.append("")
        lines.append("What happened")
        lines += insights.map { "• \($0.title). \($0.detail)" }
        if !suggestions.isEmpty {
            lines.append("")
            lines.append("Suggestions")
            lines += suggestions.map { "• [\($0.category.displayName)] \($0.title). \($0.detail) (\($0.evidence))" }
        }
        lines.append("")
        lines.append("Suggestions are for review with your care team; nothing is changed automatically.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Storage (one file per report, so a format change can't lose the others)

final class AOReportStore {
    private let directory: URL
    private let keep: Int
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init(directory: URL? = nil, keep: Int = 104) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("WeeklyReports", isDirectory: true)
        self.keep = keep
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Newest first.
    func all() -> [AOReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(AOReport.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.end, $0.generatedAt) > ($1.end, $1.generatedAt) }
    }

    func save(_ report: AOReport) {
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url(for: report.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let reports = all()
        for old in reports.dropFirst(keep) { delete(old.id) }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}

/// When the automatic weekly report runs.
struct AOReportSettings: Codable, Equatable {
    var automatic = true
    /// Calendar weekday (1 = Sunday … 7 = Saturday). The report covers the 7 days before that day's midnight.
    var weekday = 2
    /// Earliest hour on that day to create it and notify.
    var hour = 7
    var notify = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AOReportSettings()
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? d.automatic
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? d.weekday
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? d.notify
    }

    /// The most recent scheduled report boundary (midnight starting `weekday`) at or before `now`,
    /// or nil if this week's report time (`hour`) hasn't been reached yet.
    func dueBoundary(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let back = (calendar.component(.weekday, from: today) - weekday + 7) % 7
        guard let boundary = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
        let releaseTime = boundary.addingTimeInterval(Double(hour) * 3600)
        if now >= releaseTime { return boundary }
        return calendar.date(byAdding: .day, value: -7, to: boundary)
    }
}
