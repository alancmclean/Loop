//
//  OrefDosingView.swift
//  Loop
//
//  Settings and side-by-side status for the OpenAPS (oref) dosing algorithm.
//

import SwiftUI
import LoopKit

final class OrefDosingViewModel: ObservableObject {
    @Published var settings = OrefDosingSettings.current
    @Published var latest: OrefCycle? = OrefDosingStatus.shared.latest
    @Published var agreement: (cycles: Int, sameDirection: Int, orefMoreInsulin: Int) = (0, 0, 0)
    @Published var confirmActive = false
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .orefCycleDidUpdate, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        latest = OrefDosingStatus.shared.latest
        // Compare the insulin each algorithm wanted over the next 30 min, for the last 24 h of cycles.
        func insulin30(_ r: AutomaticDoseRecommendation?, scheduled: Double) -> Double {
            guard let r else { return 0 }
            let temp = r.basalAdjustment.map { ($0.unitsPerHour - scheduled) * 0.5 } ?? 0
            return temp + (r.bolusUnits ?? 0)
        }
        let cycles = OrefDosingStatus.shared.history.filter { $0.result != nil }
        var same = 0, more = 0
        for c in cycles {
            let o = insulin30(c.orefRecommendation, scheduled: 0), l = insulin30(c.loopRecommendation, scheduled: 0)
            if (o - l).magnitude < 0.1 || (o > 0) == (l > 0) { same += 1 }
            if o > l + 0.1 { more += 1 }
        }
        agreement = (cycles.count, same, more)
    }

    func update(_ change: (inout OrefDosingSettings) -> Void) {
        var s = settings
        change(&s)
        OrefDosingSettings.current = s
        settings = s
    }
}

struct OrefDosingView: View {
    @ObservedObject var viewModel: OrefDosingViewModel

    var body: some View {
        List {
            Section(header: Text("Dosing algorithm"),
                    footer: Text("Shadow runs the OpenAPS algorithm (from Trio) every cycle and shows what it would do; Loop's algorithm keeps doing everything. Active switches everything that doses to OpenAPS: automatic temp basals and micro boluses, the bolus calculator, and the forecast on the main chart. Adaptive Adjustments stops changing insulin (alerts and reminders continue), and Loop's own algorithm options (dosing strategy, partial application, retrospective correction) have no effect. Overrides still scale your settings, and an override's target is passed to OpenAPS as a temp target, as in Trio. Loop's limits (max basal, max bolus, stale-data checks) still apply.")) {
                Picker("Algorithm", selection: Binding(get: { viewModel.settings.mode }, set: { mode in
                    if mode == .active && viewModel.settings.mode != .active { viewModel.confirmActive = true }
                    else { viewModel.update { $0.mode = mode } }
                })) {
                    Text("Loop").tag(OrefDosingSettings.Mode.off)
                    Text("OpenAPS (shadow)").tag(OrefDosingSettings.Mode.shadow)
                    Text("OpenAPS (active)").tag(OrefDosingSettings.Mode.active)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if viewModel.settings.mode != .off {
                statusSection
            }

            Section(header: Text("OpenAPS settings"),
                    footer: Text("Start with SMB and UAM off, as Trio recommends for new users, and turn them on once the basic settings behave well. Max IOB limits how much insulin OpenAPS may build up; by default it's twice your max bolus, the same limit Loop uses for automatic dosing.")) {
                Toggle("Super micro boluses (SMB)", isOn: Binding(get: { viewModel.settings.enableSMB }, set: { v in viewModel.update { $0.enableSMB = v } }))
                Toggle("Unannounced meals (UAM)", isOn: Binding(get: { viewModel.settings.enableUAM }, set: { v in viewModel.update { $0.enableUAM = v } }))
                    .disabled(!viewModel.settings.enableSMB)
                Stepper("Max SMB: \(Int(viewModel.settings.maxSMBBasalMinutes)) min of basal",
                        value: Binding(get: { viewModel.settings.maxSMBBasalMinutes }, set: { v in viewModel.update { $0.maxSMBBasalMinutes = v } }),
                        in: 15...120, step: 15)
                HStack {
                    Text("Max IOB")
                    Spacer()
                    Text(viewModel.settings.maxIOB.map { String(format: "%.1f U", $0) } ?? "2 × max bolus").foregroundColor(.secondary)
                }
                Stepper("Adjust max IOB", value: Binding(get: { viewModel.settings.maxIOB ?? 10 }, set: { v in viewModel.update { $0.maxIOB = v } }),
                        in: 1...30, step: 0.5)
                Stepper("Bolus calculator: \(Int((viewModel.settings.bolusFraction * 100).rounded()))% of calculated",
                        value: Binding(get: { viewModel.settings.bolusFraction }, set: { v in viewModel.update { $0.bolusFraction = v } }),
                        in: 0.3...1.0, step: 0.05)
                Toggle("High override target raises sensitivity (exercise mode)", isOn: Binding(get: { viewModel.settings.highTargetRaisesSensitivity }, set: { v in viewModel.update { $0.highTargetRaisesSensitivity = v } }))
                Toggle("Low override target lowers sensitivity", isOn: Binding(get: { viewModel.settings.lowTargetLowersSensitivity }, set: { v in viewModel.update { $0.lowTargetLowersSensitivity = v } }))
                Toggle("Dynamic ISF", isOn: Binding(get: { viewModel.settings.dynamicISF }, set: { v in viewModel.update { $0.dynamicISF = v } }))
                if viewModel.settings.dynamicISF {
                    Stepper(String(format: "Adjustment factor: %.2f", viewModel.settings.adjustmentFactor),
                            value: Binding(get: { viewModel.settings.adjustmentFactor }, set: { v in viewModel.update { $0.adjustmentFactor = v } }),
                            in: 0.5...1.5, step: 0.05)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle("OpenAPS Dosing")
        .onAppear { viewModel.refresh() }
        .alert(isPresented: $viewModel.confirmActive) {
            Alert(title: Text("Let OpenAPS dose?"),
                  message: Text("OpenAPS will set temp basals\(viewModel.settings.enableSMB ? " and give automatic micro boluses" : "") instead of Loop's algorithm. Run it in shadow mode for at least a week first and check that its decisions make sense."),
                  primaryButton: .destructive(Text("Turn on")) { viewModel.update { $0.mode = .active } },
                  secondaryButton: .cancel())
        }
    }

    private var statusSection: some View {
        Section(header: Text("Latest cycle")) {
            if let c = viewModel.latest {
                if let error = c.error {
                    Label("OpenAPS error: \(error)", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
                }
                row("OpenAPS wants", OrefDosingAdapter.describe(c.orefRecommendation))
                row("Loop wants", OrefDosingAdapter.describe(c.loopRecommendation))
                if let r = c.result {
                    if let e = r.eventualBG { row("Eventual glucose", "\(Int(e)) mg/dL") }
                    if let iob = r.iob { row("IOB / COB", String(format: "%.2f U / %.0f g", iob, r.cob ?? 0)) }
                    if let sr = r.sensitivityRatio { row("Sensitivity ratio", String(format: "%.2f", sr)) }
                    Text(r.reason).font(.footnote).foregroundColor(.secondary)
                }
                Text("Updated \(c.date, style: .time)").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Waiting for the next loop cycle.").foregroundColor(.secondary)
            }
            if viewModel.agreement.cycles > 0 {
                row("Last 24 h", "\(viewModel.agreement.cycles) cycles, agreed \(Int(Double(viewModel.agreement.sameDirection) / Double(viewModel.agreement.cycles) * 100))%, OpenAPS gave more \(Int(Double(viewModel.agreement.orefMoreInsulin) / Double(viewModel.agreement.cycles) * 100))%")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
