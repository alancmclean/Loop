//
//  AdaptiveOverrideMotion.swift
//  Loop
//
//  Live exercise detection from the iPhone's motion coprocessor (Core Motion).
//
//  Apple Health only receives a workout when it ends (and Strava rides only after upload),
//  so on its own the adaptive layer can only react after exercise. iOS keeps a rolling log of
//  motion activity (stationary / walking / running / cycling / automotive) on the motion chip,
//  even while Loop is suspended. Each 5-minute update reads the last few hours of that log and
//  turns sustained running or cycling into an in-progress workout.
//

import Foundation
import CoreMotion

/// One motion-activity state change, as iOS reports it (the state lasts until the next one).
struct AOMotionSample: Equatable {
    enum Kind: Equatable { case cycling, running, other }
    let start: Date
    let kind: Kind
    /// 0 = low, 1 = medium, 2 = high (CMMotionActivityConfidence raw values).
    let confidence: Int
}

struct AOMotionWorkoutDetector {
    /// Sustained activity needed before it counts as exercise (filters short rides to the shop, bumpy car rides).
    var minimumDuration: TimeInterval = 10 * 60
    /// Short interruptions (traffic lights, a pause) that still belong to the same session.
    var maxGap: TimeInterval = 4 * 60
    var minimumConfidence = 1

    /// Workouts detected from motion. A session still going at `now` ends at `now`.
    func sessions(from samples: [AOMotionSample], now: Date) -> [AOWorkout] {
        let sorted = samples.sorted { $0.start < $1.start }
        var intervals: [(start: Date, end: Date)] = []
        for (i, s) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].start : now
            guard s.kind != .other, s.confidence >= minimumConfidence, end > s.start else { continue }
            if let last = intervals.last, s.start.timeIntervalSince(last.end) <= maxGap {
                intervals[intervals.count - 1].end = max(last.end, end)
            } else {
                intervals.append((start: s.start, end: end))
            }
        }
        return intervals
            .filter { $0.end.timeIntervalSince($0.start) >= minimumDuration }
            .map { AOWorkout(start: $0.start, end: min($0.end, now)) }
    }

    /// Combine with Apple Health workouts. Where they overlap, Health's start and end win
    /// (more precise); motion sessions that Health hasn't seen yet are kept as they are.
    static func merge(health: [AOWorkout], motion: [AOWorkout]) -> [AOWorkout] {
        var result = health
        for m in motion where !health.contains(where: { $0.start < m.end && $0.end > m.start }) {
            result.append(m)
        }
        return result.sorted { $0.start < $1.start }
    }
}

/// Reads the motion-activity log. Requires NSMotionUsageDescription and Motion & Fitness permission.
final class AOMotionActivityReader {
    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue()

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    static var isAuthorized: Bool { CMMotionActivityManager.authorizationStatus() == .authorized }
    static var isDenied: Bool {
        let s = CMMotionActivityManager.authorizationStatus()
        return s == .denied || s == .restricted
    }

    /// Triggers the permission prompt the first time (a tiny query is the documented way).
    func requestAuthorization() {
        guard Self.isAvailable, !Self.isAuthorized, !Self.isDenied else { return }
        let now = Date()
        manager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: queue) { _, _ in }
    }

    func samples(from start: Date, to end: Date) async -> [AOMotionSample] {
        guard Self.isAvailable, Self.isAuthorized else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: queue) { activities, _ in
                let samples = (activities ?? []).map { a -> AOMotionSample in
                    let kind: AOMotionSample.Kind
                    if a.cycling && !a.automotive { kind = .cycling }
                    else if a.running && !a.automotive { kind = .running }
                    else { kind = .other }
                    return AOMotionSample(start: a.startDate, kind: kind, confidence: a.confidence.rawValue)
                }
                continuation.resume(returning: samples)
            }
        }
    }
}
