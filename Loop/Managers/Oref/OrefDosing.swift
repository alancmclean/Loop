//
//  OrefDosing.swift
//  Loop
//
//  Runs the OpenAPS (oref) algorithm — Trio's native Swift implementation, linked as the
//  OrefAlgorithm package — on Loop's own data, and turns its decision into a Loop
//  AutomaticDoseRecommendation (temp basal + optional automatic "SMB" bolus).
//
//  Modes:
//   - off:    Loop's algorithm only.
//   - shadow: oref runs every cycle and its decision is shown and logged next to Loop's,
//             but Loop's algorithm still doses. Use this first.
//   - active: oref's decision replaces Loop's. Loop's own guards around dosing still apply
//             (stale CGM / pump data, bolus in progress, max basal, max bolus, IOB limit).
//
//  Overrides (including Adaptive Adjustments) still work: oref is given Loop's schedules
//  with overrides applied.
//

import Foundation
import HealthKit
import LoopKit
import OrefAlgorithm

struct OrefDosingSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case off, shadow, active }

    var mode: Mode = .off
    var enableSMB = false
    var enableUAM = false
    /// nil = Loop's automatic-dosing IOB limit (2 × max bolus).
    var maxIOB: Double?
    var maxSMBBasalMinutes = 30.0
    var dynamicISF = false
    var adjustmentFactor = 0.8
    /// Bolus calculator: share of the calculated bolus to recommend (Trio's "Recommended Bolus Percentage").
    var bolusFraction = 0.8
    /// Carbs on board the bolus calculator will dose for at most (Trio's max COB).
    var maxCOB = 120.0
    /// Trio's exercise mode: a high override target makes oref treat you as more sensitive.
    var highTargetRaisesSensitivity = false
    var lowTargetLowersSensitivity = false
    var halfBasalTarget = 160.0

    /// OpenAPS is doing all the dosing: automatic doses, bolus calculator, predictions.
    static var isActive: Bool { current.mode == .active }

    private static let key = "com.loopkit.Loop.OrefDosing.settings"

    static var current: OrefDosingSettings {
        get {
            guard let data = UserDefaults.appGroup?.data(forKey: key),
                  let s = try? JSONDecoder().decode(OrefDosingSettings.self, from: data) else { return OrefDosingSettings() }
            return s
        }
        set { UserDefaults.appGroup?.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrefDosingSettings()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        enableSMB = try c.decodeIfPresent(Bool.self, forKey: .enableSMB) ?? d.enableSMB
        enableUAM = try c.decodeIfPresent(Bool.self, forKey: .enableUAM) ?? d.enableUAM
        maxIOB = try c.decodeIfPresent(Double.self, forKey: .maxIOB)
        maxSMBBasalMinutes = try c.decodeIfPresent(Double.self, forKey: .maxSMBBasalMinutes) ?? d.maxSMBBasalMinutes
        dynamicISF = try c.decodeIfPresent(Bool.self, forKey: .dynamicISF) ?? d.dynamicISF
        adjustmentFactor = try c.decodeIfPresent(Double.self, forKey: .adjustmentFactor) ?? d.adjustmentFactor
        bolusFraction = try c.decodeIfPresent(Double.self, forKey: .bolusFraction) ?? d.bolusFraction
        maxCOB = try c.decodeIfPresent(Double.self, forKey: .maxCOB) ?? d.maxCOB
        highTargetRaisesSensitivity = try c.decodeIfPresent(Bool.self, forKey: .highTargetRaisesSensitivity) ?? d.highTargetRaisesSensitivity
        lowTargetLowersSensitivity = try c.decodeIfPresent(Bool.self, forKey: .lowTargetLowersSensitivity) ?? d.lowTargetLowersSensitivity
        halfBasalTarget = try c.decodeIfPresent(Double.self, forKey: .halfBasalTarget) ?? d.halfBasalTarget
    }
}

/// The latest oref run, next to what Loop's own algorithm wanted.
struct OrefCycle: Equatable {
    let date: Date
    let mode: OrefDosingSettings.Mode
    let result: OrefResult?
    let error: String?
    let orefRecommendation: AutomaticDoseRecommendation?
    let loopRecommendation: AutomaticDoseRecommendation?

    static func == (lhs: OrefCycle, rhs: OrefCycle) -> Bool { lhs.date == rhs.date && lhs.error == rhs.error && lhs.result == rhs.result }
}

extension Notification.Name {
    static let orefCycleDidUpdate = Notification.Name("com.loopkit.Loop.OrefDosing.cycleDidUpdate")
}

final class OrefDosingStatus {
    static let shared = OrefDosingStatus()
    private let lock = NSLock()
    private var _latest: OrefCycle?
    private var _history: [OrefCycle] = []

    var latest: OrefCycle? { lock.lock(); defer { lock.unlock() }; return _latest }
    /// Last 24 h of cycles (for comparing Loop vs oref).
    var history: [OrefCycle] { lock.lock(); defer { lock.unlock() }; return _history }

    func record(_ cycle: OrefCycle) {
        lock.lock()
        _latest = cycle
        _history.append(cycle)
        _history.removeAll { $0.date < cycle.date.addingTimeInterval(-24 * 3600) }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .orefCycleDidUpdate, object: nil) }
    }
}

enum OrefDosingAdapter {

    struct Context {
        let now: Date
        let glucose: [StoredGlucoseSample]
        let doses: [DoseEntry]
        let carbs: [StoredCarbEntry]
        let basal: BasalRateSchedule
        let sensitivity: InsulinSensitivitySchedule
        let carbRatio: CarbRatioSchedule
        /// Effective range (including any override target) — used when no override target is active.
        let targetRange: GlucoseRangeSchedule
        /// Your scheduled correction range, without overrides.
        let scheduledTargetRange: GlucoseRangeSchedule?
        /// Active override, if any. Its target is passed to oref as a temp target (Trio's model).
        let activeOverride: TemporaryScheduleOverride?
        let suspendThreshold: HKQuantity?
        let maxBasal: Double
        let maxBolus: Double
        let currentTemp: DoseEntry?
        let insulinType: InsulinType?
        let reservoir: Double?
        let tddLast24h: Double?
        let tddAverage: Double?
    }

    static func inputs(_ c: Context, settings s: OrefDosingSettings) -> OrefInputs {
        let mgdl = HKUnit.milligramsPerDeciliter
        func minutes(_ t: TimeInterval) -> Int { Int(t / 60) }

        let basal = c.basal.items.map { OrefScheduleEntry(startMinutes: minutes($0.startTime), value: $0.value) }
        let isf = c.sensitivity.items.map {
            OrefScheduleEntry(startMinutes: minutes($0.startTime),
                              value: HKQuantity(unit: c.sensitivity.unit, doubleValue: $0.value).doubleValue(for: mgdl))
        }
        let cr = c.carbRatio.items.map { OrefScheduleEntry(startMinutes: minutes($0.startTime), value: $0.value) }
        // Targets the way Trio handles them: your scheduled range as the profile, and an override's
        // target as a temp target (so oref's exercise / sensitivity options can act on it).
        var tempTarget: OrefTempTarget?
        var targets: [OrefTargetEntry]
        if let o = c.activeOverride, let range = o.settings.targetRange, let scheduled = c.scheduledTargetRange {
            targets = scheduled.items.map {
                OrefTargetEntry(startMinutes: minutes($0.startTime),
                                low: HKQuantity(unit: scheduled.unit, doubleValue: $0.value.minValue).doubleValue(for: mgdl),
                                high: HKQuantity(unit: scheduled.unit, doubleValue: $0.value.maxValue).doubleValue(for: mgdl))
            }
            let minutesLeft = o.duration == .indefinite ? 24 * 60 : max(5, o.scheduledEndDate.timeIntervalSince(c.now) / 60)
            tempTarget = OrefTempTarget(start: c.now, durationMinutes: minutesLeft,
                                        low: range.lowerBound.doubleValue(for: mgdl), high: range.upperBound.doubleValue(for: mgdl))
        } else {
            let range = c.targetRange.quantityRange(at: c.now)
            targets = [OrefTargetEntry(startMinutes: 0, low: range.lowerBound.doubleValue(for: mgdl),
                                       high: range.upperBound.doubleValue(for: mgdl))]
        }

        var doses: [OrefDose] = []
        for d in c.doses {
            switch d.type {
            case .tempBasal:
                doses.append(OrefDose(kind: .tempBasal, start: d.startDate, end: d.endDate, rate: d.unitsPerHour))
            case .bolus:
                doses.append(OrefDose(kind: .bolus, start: d.startDate, end: d.endDate,
                                      units: d.deliveredUnits ?? d.programmedUnits, automatic: d.automatic == true))
            case .suspend:
                doses.append(OrefDose(kind: .suspend, start: d.startDate, end: d.startDate))
                if d.endDate > d.startDate, d.endDate <= c.now {
                    doses.append(OrefDose(kind: .resume, start: d.endDate, end: d.endDate))
                }
            case .resume:
                doses.append(OrefDose(kind: .resume, start: d.startDate, end: d.startDate))
            case .basal:
                break   // scheduled basal: oref assumes it whenever no temp is running
            }
        }

        var settings = OrefSettings(maxBasal: c.maxBasal, maxBolus: c.maxBolus, maxIOB: s.maxIOB ?? c.maxBolus * 2)
        settings.insulin = (c.insulinType == .fiasp || c.insulinType == .lyumjev) ? .ultraRapid : .rapidActing
        settings.threshold = c.suspendThreshold?.doubleValue(for: mgdl) ?? 70
        settings.enableSMB = s.enableSMB
        settings.enableUAM = s.enableUAM && s.enableSMB
        settings.maxSMBBasalMinutes = s.maxSMBBasalMinutes
        settings.maxUAMSMBBasalMinutes = s.maxSMBBasalMinutes
        settings.dynamicISF = s.dynamicISF
        settings.adjustmentFactor = s.adjustmentFactor
        settings.highTempTargetRaisesSensitivity = s.highTargetRaisesSensitivity
        settings.lowTempTargetLowersSensitivity = s.lowTargetLowersSensitivity
        settings.halfBasalExerciseTarget = s.halfBasalTarget

        var temp: OrefCurrentTemp?
        if let t = c.currentTemp, t.endDate > c.now {
            temp = OrefCurrentTemp(rate: t.unitsPerHour, minutesRemaining: Int(t.endDate.timeIntervalSince(c.now) / 60), start: t.startDate)
        }

        var inputs = OrefInputs(
            now: c.now,
            glucose: c.glucose.map { OrefGlucose(date: $0.startDate, mgdl: $0.quantity.doubleValue(for: mgdl)) },
            doses: doses,
            carbs: c.carbs.map { OrefCarb(date: $0.startDate, grams: $0.quantity.doubleValue(for: .gram())) },
            basal: basal, isf: isf, carbRatio: cr, targets: targets, settings: settings,
            currentTemp: temp, reservoir: c.reservoir, tddLast24h: c.tddLast24h, tddAverage: c.tddAverage,
            microBolusAllowed: s.enableSMB)
        inputs.tempTarget = tempTarget
        return inputs
    }

    // MARK: Predictions

    /// The curve to show on Loop's chart: COB-based while carbs are absorbing, UAM when on, otherwise IOB.
    static func predictedGlucose(from r: OrefResult, start: Date) -> [PredictedGlucoseValue]? {
        let curve = ((r.cob ?? 0) > 0 ? r.predictions["cob"] : nil) ?? r.predictions["uam"] ?? r.predictions["iob"]
        guard let values = curve, !values.isEmpty else { return nil }
        return values.enumerated().map { i, v in
            PredictedGlucoseValue(startDate: start.addingTimeInterval(Double(i) * 300),
                                  quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(v)))
        }
    }

    // MARK: Bolus calculator (Trio-style)

    struct BolusInputs {
        let glucose: Double
        /// Change over the last 15 minutes (mg/dL).
        let delta15: Double?
        let target: Double
        let isf: Double
        let carbRatio: Double
        let iob: Double
        let cob: Double
        let newCarbs: Double
        let maxBolus: Double
        let suspendThreshold: Double?
    }

    /// Trio's calculator approach: what it takes to reach target, cover carbs on board plus the new
    /// carbs, and account for the recent trend, minus insulin on board — then scaled by the
    /// recommended-bolus percentage and capped at max bolus.
    static func manualBolus(_ b: BolusInputs, settings s: OrefDosingSettings) -> (units: Double, belowThreshold: Bool) {
        if let low = b.suspendThreshold, b.glucose < low { return (0, true) }
        let carbs = min(b.cob + b.newCarbs, s.maxCOB)
        var whole = (b.glucose - b.target) / b.isf + carbs / b.carbRatio - b.iob
        if let d = b.delta15 { whole += d / b.isf }
        let factored = whole > 0 ? whole * s.bolusFraction : 0
        return (min(max(factored, 0), b.maxBolus), false)
    }

    /// oref's decision as a Loop recommendation, clamped to Loop's limits.
    static func recommendation(from r: OrefResult, now: Date, maxBasal: Double, maxAutomaticBolus: Double,
                               lastTempBasal: DoseEntry?, rateRounder: (Double) -> Double,
                               volumeRounder: (Double) -> Double) -> AutomaticDoseRecommendation? {
        var basal: TempBasalRecommendation?
        if let rate = r.rate, let duration = r.durationMinutes {
            if duration <= 0 {
                basal = .cancel
            } else {
                let rounded = rateRounder(min(max(rate, 0), maxBasal))
                // Don't re-send an identical temp that still has time left (same rule as Loop).
                if let last = lastTempBasal, abs(last.unitsPerHour - rounded) < 0.01,
                   last.endDate.timeIntervalSince(now) > 11 * 60 {
                    basal = nil
                } else {
                    basal = TempBasalRecommendation(unitsPerHour: rounded, duration: min(duration, 30) * 60)
                }
            }
        }
        let smb = volumeRounder(min(max(r.smbUnits, 0), max(maxAutomaticBolus, 0)))
        let bolus: Double? = smb > 0 ? smb : nil
        if basal == nil && bolus == nil { return nil }
        return AutomaticDoseRecommendation(basalAdjustment: basal, bolusUnits: bolus)
    }

    static func describe(_ rec: AutomaticDoseRecommendation?) -> String {
        guard let rec else { return "no change" }
        var parts: [String] = []
        if let b = rec.basalAdjustment {
            parts.append(b.duration == 0 ? "cancel temp" : String(format: "temp %.2f U/h", b.unitsPerHour))
        }
        if let u = rec.bolusUnits, u > 0 { parts.append(String(format: "auto bolus %.2f U", u)) }
        return parts.isEmpty ? "no change" : parts.joined(separator: " + ")
    }
}
