//
//  AdaptiveOverrideView.swift
//  Loop
//
//  Settings, status, quick logs, learned patterns, suggestions and weekly report
//  for the adaptive override layer.
//

import SwiftUI

final class AdaptiveOverrideViewModel: ObservableObject {
    private let manager: AdaptiveOverrideManager

    @Published var config: AOConfig
    @Published var status: AOStatus
    @Published var factors: AOLearnedFactors
    @Published var habits: [AOMealHabit]
    @Published var suggestions: AOSettingsSuggestions
    @Published var report: AOWeeklyReport?
    @Published var notes: [String]
    @Published var knownLocations: [String]
    @Published var isRelearning = false
    @Published var profile: AOTimeOfDayProfile
    @Published var workoutPrepUntil: Date?

    private var observer: NSObjectProtocol?

    init(manager: AdaptiveOverrideManager) {
        self.manager = manager
        config = manager.config
        status = manager.status
        factors = manager.learnedFactors
        habits = manager.mealHabits
        suggestions = manager.suggestions
        report = manager.weeklyReport
        notes = manager.effectivenessNotes
        knownLocations = manager.knownSiteLocations
        profile = manager.timeOfDayProfile
        workoutPrepUntil = manager.workoutPrepUntil
        observer = NotificationCenter.default.addObserver(forName: .adaptiveOverrideStatusDidChange, object: manager, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        config = manager.config
        status = manager.status
        factors = manager.learnedFactors
        habits = manager.mealHabits
        suggestions = manager.suggestions
        report = manager.weeklyReport
        notes = manager.effectivenessNotes
        knownLocations = manager.knownSiteLocations
        profile = manager.timeOfDayProfile
        workoutPrepUntil = manager.workoutPrepUntil
    }

    func startWorkoutPrep() { manager.startWorkoutPrep(); workoutPrepUntil = manager.workoutPrepUntil }
    func cancelWorkoutPrep() { manager.cancelWorkoutPrep(); workoutPrepUntil = nil }

    func update(_ change: (inout AOConfig) -> Void) {
        var c = config
        change(&c)
        manager.config = c
        config = manager.config
    }

    func setSignal(_ signal: AOSignal, enabled: Bool) {
        manager.setSignal(signal, enabled: enabled)
        config = manager.config
    }

    func log(_ kind: AOLogKind) { manager.addLog(kind) }

    func logSite(location: String?) {
        manager.logSiteChange(location: location)
        knownLocations = manager.knownSiteLocations
    }

    func relearnNow() {
        isRelearning = true
        Task {
            try? await manager.relearn(forceWeekly: true)
            await manager.update()
            await MainActor.run { self.isRelearning = false; self.reload() }
        }
    }
}

struct AdaptiveOverrideView: View {
    @ObservedObject var viewModel: AdaptiveOverrideViewModel
    @State private var newLocation = ""
    @State private var confirmAutomatic = false

    private let commonLocations = ["Abdomen left", "Abdomen right", "Arm left", "Arm right", "Thigh left", "Thigh right", "Back left", "Back right"]

    var body: some View {
        List {
            statusSection
            workoutSection
            controlSection
            quickLogSection
            siteSection
            patternsSection
            profileSection
            habitsSection
            suggestionsSection
            reportSection
            safetySection
        }
        .insetGroupedListStyle()
        .navigationTitle("Adaptive Adjustments")
        .onAppear { viewModel.reload() }
        .alert(isPresented: $confirmAutomatic) {
            Alert(title: Text("Turn on automatic mode?"),
                  message: Text("Loop will change your basal, ISF and carb ratio by up to \(pct(viewModel.config.effectiveRange.lowerBound))–\(pct(viewModel.config.effectiveRange.upperBound)) without asking. Use suggest mode for a week or two first to check its calls."),
                  primaryButton: .destructive(Text("Turn on")) { viewModel.update { $0.mode = .automatic } },
                  secondaryButton: .cancel())
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section(header: Text("Now")) {
            if !viewModel.config.enabled {
                Text("Off. Loop is using your normal settings.").foregroundColor(.secondary)
            } else {
                HStack {
                    Text("Adjustment")
                    Spacer()
                    Text(viewModel.status.appliedScale.map(pct) ?? "100%").bold()
                }
                Text(viewModel.status.lastDecision).font(.footnote).foregroundColor(.secondary)
                if viewModel.status.siteFailureSuspected {
                    Label("Possible site problem — check your site", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                if !viewModel.status.activeSignals.isEmpty {
                    Text("Active: " + viewModel.status.activeSignals.map(\.displayName).joined(separator: ", "))
                        .font(.footnote)
                }
                HStack {
                    Text("Recent sensitivity")
                    Spacer()
                    Text(viewModel.status.autosensHours >= 4 ? pct(viewModel.status.autosens) : "Not enough fasting data")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var controlSection: some View {
        Section(header: Text("Settings"), footer: Text("Suggest mode only sends notifications. Automatic mode applies a Loop override, which you can cancel any time from the main screen.")) {
            Toggle("Enabled", isOn: Binding(get: { viewModel.config.enabled }, set: { v in viewModel.update { $0.enabled = v } }))
            Picker("Mode", selection: Binding(get: { viewModel.config.mode }, set: { mode in
                if mode == .automatic { confirmAutomatic = true } else { viewModel.update { $0.mode = .suggest } }
            })) {
                Text("Suggest").tag(AOConfig.Mode.suggest)
                Text("Automatic").tag(AOConfig.Mode.automatic)
            }
            .pickerStyle(.segmented)
            Stepper("Lowest: \(pct(viewModel.config.effectiveRange.lowerBound))",
                    value: Binding(get: { viewModel.config.minScale }, set: { v in viewModel.update { $0.minScale = v } }),
                    in: AOConfig.absoluteMinScale...1.0, step: 0.05)
            Stepper("Highest: \(pct(viewModel.config.effectiveRange.upperBound))",
                    value: Binding(get: { viewModel.config.maxScale }, set: { v in viewModel.update { $0.maxScale = v } }),
                    in: 1.0...AOConfig.absoluteMaxScale, step: 0.05)
            Toggle("Detect rides and runs live (motion sensors)", isOn: Binding(get: { viewModel.config.useMotionDetection }, set: { v in viewModel.update { $0.useMotionDetection = v } }))
            Toggle("Higher target after exercise", isOn: Binding(get: { viewModel.config.postExerciseTarget }, set: { v in viewModel.update { $0.postExerciseTarget = v } }))
            Toggle("Time-of-day profile", isOn: Binding(get: { viewModel.config.useTimeOfDayProfile }, set: { v in viewModel.update { $0.useTimeOfDayProfile = v } }))
            Toggle("Auto-prepare at usual workout times", isOn: Binding(get: { viewModel.config.autoWorkoutPrep }, set: { v in viewModel.update { $0.autoWorkoutPrep = v } }))
            Toggle("High insulin-on-board guard", isOn: Binding(get: { viewModel.config.stackingGuard }, set: { v in viewModel.update { $0.stackingGuard = v } }))
            Toggle("Recent-sensitivity adjustment", isOn: Binding(get: { viewModel.config.useAutosens }, set: { v in viewModel.update { $0.useAutosens = v } }))
            Toggle("Site problem alerts", isOn: Binding(get: { viewModel.config.siteFailureAlerts }, set: { v in viewModel.update { $0.siteFailureAlerts = v } }))
            Toggle("Pre-bolus reminders", isOn: Binding(get: { viewModel.config.preBolusReminders }, set: { v in viewModel.update { $0.preBolusReminders = v } }))
        }
    }

    private var workoutSection: some View {
        Section(header: Text("Workout"), footer: Text("Tap up to 90 minutes before a ride: 25% less insulin (including meal boluses) and a target of 150 for 2 hours. Rides and runs are also detected live from your iPhone's motion sensors after about 10 minutes, and the target stays at 150 for 3 hours after any workout.")) {
            if let until = viewModel.workoutPrepUntil, until > Date() {
                HStack {
                    Text("Workout prep on until \(until, style: .time)")
                    Spacer()
                    Button("Cancel") { viewModel.cancelWorkoutPrep() }
                }
            } else {
                Button("Workout soon") { viewModel.startWorkoutPrep() }
            }
        }
    }

    private var profileSection: some View {
        Section(header: Text("Time-of-day profile"), footer: Text("Learned from where your lows and highs happen over the last 7 days (glucose only). Hours with lows get less insulin 1–2 hours before.")) {
            let hours: [Int] = viewModel.profile.factors.keys.filter { abs((viewModel.profile.factors[$0] ?? 1) - 1.0) >= 0.005 }.sorted()
            if hours.isEmpty {
                Text("No changes yet.").foregroundColor(.secondary)
            }
            ForEach(hours, id: \.self) { hour in
                row(String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24), pct(viewModel.profile.factors[hour] ?? 1))
            }
        }
    }

    private var quickLogSection: some View {
        Section(header: Text("Quick log"), footer: Text("Things Apple Health can't see. Each is learned like the other signals once it has happened a few times.")) {
            HStack {
                ForEach(AOLogKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { viewModel.log(kind) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var siteSection: some View {
        Section(header: Text("Log site change"), footer: Text("Pod and site changes from your pump are picked up automatically. Logging the location lets Loop learn whether some sites work better for you.")) {
            let locations = viewModel.knownLocations + commonLocations.filter { c in !viewModel.knownLocations.contains { $0.lowercased() == c.lowercased() } }
            ForEach(locations.prefix(8), id: \.self) { location in
                Button(location) { viewModel.logSite(location: location) }
            }
            HStack {
                TextField("Other location", text: $newLocation)
                Button("Log") {
                    viewModel.logSite(location: newLocation.isEmpty ? nil : newLocation)
                    newLocation = ""
                }
            }
        }
    }

    private var patternsSection: some View {
        Section(header: Text("Your patterns"), footer: Text("Insulin needed while each signal was active, compared with normal hours at the same time of day. Meal hours are left out, so carb counts don't affect these. A signal needs at least 3 episodes before it does anything.")) {
            if viewModel.factors.signals.isEmpty {
                Text("Learning… needs a few days of data.").foregroundColor(.secondary)
            }
            ForEach(viewModel.factors.signals, id: \.self) { signal in
                Toggle(isOn: Binding(get: { !viewModel.config.disabledSignals.contains(signal) },
                                     set: { viewModel.setSignal(signal, enabled: $0) })) {
                    VStack(alignment: .leading) {
                        Text(signal.displayName)
                        let n = viewModel.factors.episodes[signal.id] ?? 0
                        Text(viewModel.factors.factors[signal.id].map { "\(pct($0)) · \(n) episodes" } ?? "Not enough data (\(n) episodes)")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            Button(viewModel.isRelearning ? "Learning…" : "Re-learn now") { viewModel.relearnNow() }
                .disabled(viewModel.isRelearning)
        }
    }

    private var habitsSection: some View {
        Section(header: Text("Usual meal times"), footer: Text("Found from glucose rises and meal boluses, not logged carbs. Reminders come about 20 minutes before.")) {
            if viewModel.habits.isEmpty {
                Text("No regular meal times found yet.").foregroundColor(.secondary)
            }
            ForEach(viewModel.habits, id: \.self) { habit in
                HStack {
                    Text("\(habit.weekend ? "Weekends" : "Weekdays") \(habit.timeString)")
                    Spacer()
                    Text("\(Int((habit.frequency * 100).rounded()))% of days").foregroundColor(.secondary)
                }
            }
        }
    }

    private var suggestionsSection: some View {
        Section(header: Text("Settings suggestions"), footer: Text("From fasting hours and clean corrections over the last 4 weeks. Never applied automatically: review them, ideally with your care team, and change them in Therapy Settings if you agree. Carb ratio isn't suggested because logged carbs aren't reliable enough.")) {
            if viewModel.suggestions.isEmpty {
                Text("No changes suggested.").foregroundColor(.secondary)
            }
            ForEach(viewModel.suggestions.basal) { s in
                HStack {
                    Text(String(format: "Basal %02d:00", s.hour))
                    Spacer()
                    Text(String(format: "%.3f → %.3f U/h", s.current, s.suggested))
                        .foregroundColor(s.suggested > s.current ? .orange : .blue)
                }
            }
            if let isf = viewModel.suggestions.isf {
                HStack {
                    Text("ISF")
                    Spacer()
                    Text("\(Int(isf.current)) → \(Int(isf.suggested)) mg/dL/U (\(isf.episodes) corrections)")
                }
            }
        }
    }

    private var reportSection: some View {
        Section(header: Text("Weekly report")) {
            if let r = viewModel.report {
                row("Time in range (70–180)", pct(r.timeInRange))
                row("Below 70 / below 54", "\(pct1(r.timeBelow70)) / \(pct1(r.timeBelow54))")
                row("Above 180 / above 250", "\(pct(r.timeAbove180)) / \(pct(r.timeAbove250))")
                row("Average / GMI", "\(Int(r.meanGlucose.rounded())) mg/dL / \(String(format: "%.1f", r.gmi))%")
                row("Variability (CV)", pct(r.coefficientOfVariation))
                if let lows = r.lowsMostOften { row("Lows most often", lows) }
                if let highs = r.highsMostOften { row("Highs most often", highs) }
                row("Average adjustment", pct(r.averageScale))
                if r.siteAlerts > 0 { row("Site alerts", "\(r.siteAlerts)") }
                ForEach(r.notes, id: \.self) { Text($0).font(.footnote) }
            } else {
                Text("First report after a week of use.").foregroundColor(.secondary)
            }
            ForEach(viewModel.notes.suffix(5), id: \.self) { Text($0).font(.footnote).foregroundColor(.secondary) }
        }
    }

    private var safetySection: some View {
        Section(header: Text("Safety limits")) {
            Text("""
            • Default range 80–120%; you can widen it up to \(pct(AOConfig.absoluteMinScale))–\(pct(AOConfig.absoluteMaxScale))
            • Changes at most 5% every 5 minutes
            • No increases below 90 mg/dL, when falling fast, or when a site problem is suspected
            • Never replaces an override you or a caregiver set
            • Stops when CGM data is stale; each override expires after an hour unless renewed
            • Turns off any signal linked to more lows, and drops to suggest mode if your lows rise overall
            • Your max bolus and max basal limits still apply
            """).font(.footnote)
        }
    }

    // MARK: Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) }
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    private func pct1(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}
