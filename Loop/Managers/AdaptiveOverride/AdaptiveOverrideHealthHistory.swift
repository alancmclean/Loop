//
//  AdaptiveOverrideHealthHistory.swift
//  Loop
//
//  Loop keeps only the last 7 days of glucose, insulin and carbs on the phone
//  (LOOP_LOCAL_CACHE_DURATION_DAYS). It also writes them to Apple Health, which keeps
//  everything, so older history is read from there: the weekly report's comparisons and
//  4-week patterns, and the pattern learning (30 days) and day model (60 days).
//

import Foundation
import HealthKit

struct AOHealthHistoryReader {
    let healthStore: HKHealthStore

    static let automaticallyIssuedKey = "com.loopkit.InsulinKit.MetadataKeyAutomaticallyIssued"

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for id in [HKQuantityTypeIdentifier.bloodGlucose, .insulinDelivery, .dietaryCarbohydrates] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// Glucose written by this app (Loop stores your CGM readings in Health). Falls back to all
    /// sources, de-duplicated, if this app hasn't written any (e.g. after reinstalling).
    func glucose(start: Date, end: Date) async throws -> [AOGlucosePoint] {
        guard end > start, let type = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return [] }
        let unit = HKUnit.milligramsPerDeciliter
        var samples = try await quantities(type, start: start, end: end, ownSourceOnly: true)
        if samples.isEmpty { samples = try await quantities(type, start: start, end: end, ownSourceOnly: false) }
        var out: [AOGlucosePoint] = []
        for s in samples.sorted(by: { $0.startDate < $1.startDate }) {
            if let last = out.last, s.startDate.timeIntervalSince(last.date) < 4 * 60 { continue }
            out.append(AOGlucosePoint(date: s.startDate, mgdl: s.quantity.doubleValue(for: unit)))
        }
        return out
    }

    /// Insulin delivery written by this app: basal (including temp basals) and boluses, with
    /// Loop's "automatically issued" flag telling automatic boluses from yours.
    func insulin(start: Date, end: Date) async throws -> [AOInsulinDose] {
        guard end > start, let type = HKObjectType.quantityType(forIdentifier: .insulinDelivery) else { return [] }
        return try await quantities(type, start: start, end: end, ownSourceOnly: true).map { s in
            let reason = (s.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)?.intValue
            let isBolus = reason == HKInsulinDeliveryReason.bolus.rawValue
            let automatic = (s.metadata?[Self.automaticallyIssuedKey] as? NSNumber)?.boolValue ?? false
            return AOInsulinDose(start: s.startDate, end: s.endDate, units: s.quantity.doubleValue(for: .internationalUnit()),
                                 isBolus: isBolus, isManual: isBolus && !automatic)
        }.sorted { $0.start < $1.start }
    }

    /// Carbs from any source (only used to see whether a low was treated).
    func carbs(start: Date, end: Date) async throws -> [AOCarbEntry] {
        guard end > start, let type = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates) else { return [] }
        return try await quantities(type, start: start, end: end, ownSourceOnly: false)
            .map { AOCarbEntry(date: $0.startDate, grams: $0.quantity.doubleValue(for: .gram())) }
            .sorted { $0.date < $1.date }
    }

    private func quantities(_ type: HKQuantityType, start: Date, end: Date, ownSourceOnly: Bool) async throws -> [HKQuantitySample] {
        var predicates = [HKQuery.predicateForSamples(withStart: start, end: end, options: [])]
        if ownSourceOnly { predicates.append(HKQuery.predicateForObjects(from: HKSource.default())) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    let code = (error as? HKError)?.code
                    if code == .errorAuthorizationDenied || code == .errorAuthorizationNotDetermined || code == .errorNoData {
                        continuation.resume(returning: [])
                    } else {
                        // Includes "database inaccessible" while the phone is locked: callers retry later.
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
            }
            healthStore.execute(query)
        }
    }
}

/// Joins Health history (older) with Loop's local store (recent), without overlap.
enum AOHistoryMerge {
    static func glucose(local: [AOGlucosePoint], health: [AOGlucosePoint]) -> [AOGlucosePoint] {
        guard let firstLocal = local.map(\.date).min() else { return health.sorted { $0.date < $1.date } }
        return (health.filter { $0.date < firstLocal.addingTimeInterval(-60) } + local).sorted { $0.date < $1.date }
    }

    static func doses(local: [AOInsulinDose], health: [AOInsulinDose]) -> [AOInsulinDose] {
        guard let firstLocal = local.map(\.start).min() else { return health.sorted { $0.start < $1.start } }
        return (health.filter { $0.start < firstLocal.addingTimeInterval(-60) } + local).sorted { $0.start < $1.start }
    }

    static func carbs(local: [AOCarbEntry], health: [AOCarbEntry]) -> [AOCarbEntry] {
        guard let firstLocal = local.map(\.date).min() else { return health.sorted { $0.date < $1.date } }
        return (health.filter { $0.date < firstLocal.addingTimeInterval(-60) } + local).sorted { $0.date < $1.date }
    }
}
