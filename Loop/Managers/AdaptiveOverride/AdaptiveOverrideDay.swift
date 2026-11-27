//
//  AdaptiveOverrideDay.swift
//  Loop
//
//  "What kind of day is this?" — learned from recent weeks, updated through the day.
//
//  Nothing here is tied to particular weekdays. Each estimate starts from what recent
//  same-weekday days looked like (recent weeks weigh more, so a schedule change is followed
//  within a couple of weeks), then today's own evidence takes over: a morning ride, how much
//  you've moved so far, and movement in the last two hours.
//
//  Findings on real data that shaped this (AdaptiveAdjustmentsValidation/README.md):
//   - after a morning commute ride, a ride home followed 78% of the time, usually 5:40–6:25pm
//   - commute days needed ~18% less daytime insulin; sedentary home days ~4–5% more than
//     home days with some movement
//   - movement in the previous 2 h raised low risk over the next 3 h (5.7% → ~9.6% of time)
//

import Foundation

/// One past day, summarised.
struct AODaySummary: Codable, Equatable {
    let day: Date
    let weekday: Int
    let morningRide: Bool
    /// Start of an afternoon/evening ride (minutes after midnight), if any.
    let afternoonRideMinute: Int?
    let steps: Double?
    let stepsBefore10: Double?
    let daytimeInsulin: Double?
    let daytimeMeanGlucose: Double?

    var anyRide: Bool { morningRide || afternoonRideMinute != nil }
}

struct AODayModel {
    var history: [AODaySummary]
    var calendar = Calendar.current
    /// Recency weighting: a day from 3 weeks ago counts about half as much as yesterday.
    var dailyDecay = 0.97
    var morningWindow: ClosedRange<Int> = (4 * 60)...(11 * 60)
    var afternoonWindow: ClosedRange<Int> = (14 * 60)...(21 * 60)

    // MARK: Building summaries

    static func summarize(day: Date, workouts: [AOWorkout], hourlySteps: [AOMetricSample],
                          glucose: [AOGlucosePoint], doses: [AOInsulinDose], calendar: Calendar = .current) -> AODaySummary {
        let start = calendar.startOfDay(for: day)
        let end = start.addingTimeInterval(24 * 3600)
        func minute(_ d: Date) -> Int { Int(d.timeIntervalSince(start) / 60) }
        let rides = workouts.filter { $0.start >= start && $0.start < end && $0.duration >= 15 * 60 }
        let morning = rides.contains { (4 * 60...11 * 60).contains(minute($0.start)) }
        let afternoon = rides.filter { (14 * 60...21 * 60).contains(minute($0.start)) }.map { minute($0.start) }.min()
        let daySteps = hourlySteps.filter { $0.date >= start && $0.date < end }
        let before10 = daySteps.filter { $0.date < start.addingTimeInterval(10 * 3600) }
        let dayStart = start.addingTimeInterval(8 * 3600), dayEnd = start.addingTimeInterval(20 * 3600)
        let g = glucose.filter { $0.date >= dayStart && $0.date < dayEnd }.map(\.mgdl)
        let insulin = doses.reduce(0.0) { $0 + AOPatternLearner.units(of: $1, in: dayStart..<dayEnd) }
        return AODaySummary(day: start, weekday: calendar.component(.weekday, from: start), morningRide: morning,
                            afternoonRideMinute: afternoon,
                            steps: daySteps.isEmpty ? nil : daySteps.reduce(0) { $0 + $1.value },
                            stepsBefore10: daySteps.isEmpty ? nil : before10.reduce(0) { $0 + $1.value },
                            daytimeInsulin: g.count >= 100 ? insulin : nil,
                            daytimeMeanGlucose: g.count >= 100 ? g.reduce(0, +) / Double(g.count) : nil)
    }

    private func weight(_ s: AODaySummary, now: Date) -> Double {
        pow(dailyDecay, max(0, now.timeIntervalSince(s.day) / 86400))
    }

    // MARK: Sedentary days (threshold learned from your own no-ride days)

    /// Steps below the 40th percentile of your recent no-ride days count as a quiet day.
    var sedentaryStepThreshold: Double? {
        let s = history.filter { !$0.anyRide }.compactMap(\.steps).sorted()
        guard s.count >= 10 else { return nil }
        return s[Int(Double(s.count) * 0.4)]
    }

    func isSedentary(_ s: AODaySummary) -> Bool? {
        guard let th = sedentaryStepThreshold, let steps = s.steps else { return nil }
        return !s.anyRide && steps <= th
    }

    /// Probability that today is a quiet, sedentary day, given what's happened so far.
    func sedentaryProbability(now: Date, rodeToday: Bool, stepsBefore10: Double?) -> Double {
        if rodeToday { return 0.05 }
        let weekday = calendar.component(.weekday, from: now)
        var yes = 0.5, total = 1.0   // gentle prior toward 50%
        for s in history where s.weekday == weekday {
            guard let sed = isSedentary(s) else { continue }
            let w = weight(s, now: now)
            total += w; if sed { yes += w }
        }
        var p = yes / total
        // Morning movement: likelihood ratio learned from your own days.
        let hour = calendar.component(.hour, from: now)
        if hour >= 10, let am = stepsBefore10, let lr = morningLikelihoodRatio(stepsBefore10: am) {
            let odds = p / (1 - p) * lr
            p = odds / (1 + odds)
        }
        return min(max(p, 0.02), 0.98)
    }

    private func morningLikelihoodRatio(stepsBefore10 am: Double) -> Double? {
        let labelled = history.compactMap { s -> (Bool, Double)? in
            guard let sed = isSedentary(s), let x = s.stepsBefore10 else { return nil }
            return (sed, x)
        }
        let sed = labelled.filter { $0.0 }.map(\.1).sorted(), other = labelled.filter { !$0.0 }.map(\.1).sorted()
        guard sed.count >= 5, other.count >= 5, let ms = sed.median, let mo = other.median, mo > ms else { return nil }
        let cut = (ms + mo) / 2
        let below = am < cut
        let pSed = (Double(sed.filter { ($0 < cut) == below }.count) + 1) / Double(sed.count + 2)
        let pOther = (Double(other.filter { ($0 < cut) == below }.count) + 1) / Double(other.count + 2)
        return min(max(pSed / pOther, 0.3), 3.0)
    }

    /// Learned insulin-needs factor for quiet days, vs. no-ride days with more movement.
    /// Uses daytime insulin plus a glucose term, so meals are included (that's where the effect shows).
    func sedentaryFactor(isf: Double, range: ClosedRange<Double> = 0.9...1.15, minDays: Int = 5, prior: Double = 5) -> Double {
        func need(_ s: AODaySummary) -> Double? {
            guard let i = s.daytimeInsulin, let g = s.daytimeMeanGlucose, isf > 0 else { return nil }
            return i + (g - 120) / isf * 4
        }
        let quiet = history.filter { isSedentary($0) == true }.compactMap(need)
        let moving = history.filter { isSedentary($0) == false && !$0.anyRide }.compactMap(need)
        guard quiet.count >= minDays, moving.count >= minDays, let q = quiet.median, let mv = moving.median, mv > 0 else { return 1.0 }
        let n = Double(min(quiet.count, moving.count))
        let f = 1 + (q / mv - 1) * n / (n + prior)
        return min(max(f, range.lowerBound), range.upperBound)
    }

    // MARK: Ride home

    struct RideForecast: Equatable {
        let probability: Double
        let window: DateInterval
    }

    /// After a morning ride, how likely is a ride later today, and when should prep run?
    func rideHomeForecast(now: Date, morningRideToday: Bool, afternoonRideStarted: Bool) -> RideForecast? {
        guard morningRideToday, !afternoonRideStarted else { return nil }
        var yes = 1.0, total = 2.0
        var starts: [Double] = []
        for s in history where s.morningRide {
            let w = weight(s, now: now)
            total += w
            if let m = s.afternoonRideMinute {
                yes += w
                if now.timeIntervalSince(s.day) < 45 * 86400 { starts.append(Double(m)) }
            }
        }
        guard starts.count >= 3 else { return nil }
        starts.sort()
        let q25 = starts[Int(Double(starts.count - 1) * 0.25)], q75 = starts[Int(Double(starts.count - 1) * 0.75)]
        let dayStart = calendar.startOfDay(for: now)
        let open = dayStart.addingTimeInterval((q25 - 60) * 60)
        let close = dayStart.addingTimeInterval((q75 + 15) * 60)
        guard close > open, close.timeIntervalSince(open) <= 3 * 3600 else { return nil }
        return RideForecast(probability: yes / total, window: DateInterval(start: open, end: close))
    }
}

extension AOSignalRules {
    /// Steps in the 2 hours before `date`.
    static func steps(in samples: [AOMetricSample], before date: Date, window: TimeInterval = 2 * 3600) -> Double {
        samples.filter { $0.date >= date.addingTimeInterval(-window) && $0.date < date }.reduce(0) { $0 + $1.value }
    }
}
