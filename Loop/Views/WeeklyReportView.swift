//
//  WeeklyReportView.swift
//  Loop
//
//  Weekly reports: history list, "generate now", schedule settings, and a detail page
//  with charts, what happened, and suggestions. Reports can be shared as a PDF or text.
//

import SwiftUI
import Charts

// MARK: - View model

final class WeeklyReportsViewModel: ObservableObject {
    private let manager: AdaptiveOverrideManager

    @Published var reports: [AOReport] = []
    @Published var settings: AOReportSettings
    @Published var isGenerating = false
    @Published var message: String?

    private var observer: NSObjectProtocol?

    init(manager: AdaptiveOverrideManager) {
        self.manager = manager
        settings = manager.reportSettings
        reports = manager.reports
        observer = NotificationCenter.default.addObserver(forName: .adaptiveOverrideReportsDidChange, object: manager, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        reports = manager.reports
        settings = manager.reportSettings
    }

    func update(_ change: (inout AOReportSettings) -> Void) {
        var s = settings
        change(&s)
        manager.reportSettings = s
        settings = s
    }

    func generateNow() {
        guard !isGenerating else { return }
        isGenerating = true
        message = nil
        Task {
            let result: String?
            do {
                result = try await manager.generateReportNow() == nil ? "Not enough CGM data in the last 7 days for a report." : nil
            } catch {
                result = "Couldn't create the report: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.isGenerating = false
                self.message = result
                self.reload()
            }
        }
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { manager.deleteReport(reports[i].id) }
        reports.remove(atOffsets: offsets)
    }
}

// MARK: - Colors and formatting

enum AOReportStyle {
    static let veryLow = Color(red: 0.62, green: 0.05, blue: 0.10)
    static let low = Color(red: 0.90, green: 0.22, blue: 0.21)
    static let inRange = Color(red: 0.20, green: 0.68, blue: 0.38)
    static let high = Color(red: 0.98, green: 0.65, blue: 0.15)
    static let veryHigh = Color(red: 0.90, green: 0.45, blue: 0.05)
    static let accent = Color(red: 0.25, green: 0.47, blue: 0.85)

    static func color(_ tone: AOReport.Tone) -> Color {
        switch tone {
        case .good: return inRange
        case .mixed: return high
        case .tough: return low
        }
    }

    static func color(_ tone: AOInsight.Tone) -> Color {
        switch tone {
        case .good: return inRange
        case .neutral: return accent
        case .watch: return high
        case .problem: return low
        }
    }

    static func symbol(_ c: AOSuggestion.Category) -> String {
        switch c {
        case .safety: return "exclamationmark.shield.fill"
        case .dosing: return "slider.horizontal.3"
        case .habit: return "lightbulb.fill"
        }
    }

    static func color(_ c: AOSuggestion.Category) -> Color {
        switch c {
        case .safety: return low
        case .dosing: return accent
        case .habit: return veryHigh
        }
    }

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    static func pct1(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}

private struct AORing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct AOCard<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundColor(AOReportStyle.accent) }
                    Text(title).font(.headline)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// "▲ 4 pts" chip, green when the change is in the good direction.
private struct AODelta: View {
    var text: String
    var improved: Bool?

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }

    private var color: Color {
        switch improved {
        case true?: return AOReportStyle.inRange
        case false?: return AOReportStyle.low
        case nil: return .secondary
        }
    }

    /// Change in percentage points (fractions in, e.g. 0.04 → "▲ 4 pts").
    static func points(_ now: Double, _ before: Double?, higherIsBetter: Bool, decimals: Bool = false) -> AODelta? {
        guard let before else { return nil }
        let d = (now - before) * 100
        let shown = decimals ? String(format: "%.1f", abs(d)) : "\(Int(abs(d).rounded()))"
        if shown == "0" || shown == "0.0" { return AODelta(text: "same", improved: nil) }
        return AODelta(text: "\(d > 0 ? "▲" : "▼") \(shown) pts", improved: (d > 0) == higherIsBetter)
    }

    static func value(_ now: Double, _ before: Double?, format: String, higherIsBetter: Bool?) -> AODelta? {
        guard let before else { return nil }
        let d = now - before
        let shown = String(format: format, abs(d))
        if Double(shown) == 0 { return AODelta(text: "same", improved: nil) }
        return AODelta(text: "\(d > 0 ? "▲" : "▼") \(shown)", improved: higherIsBetter.map { (d > 0) == $0 })
    }
}

// MARK: - List

struct WeeklyReportsView: View {
    @StateObject private var viewModel: WeeklyReportsViewModel

    init(manager: AdaptiveOverrideManager) {
        _viewModel = StateObject(wrappedValue: WeeklyReportsViewModel(manager: manager))
    }

    private let weekdays = Calendar.current.weekdaySymbols

    var body: some View {
        List {
            Section {
                Button(action: viewModel.generateNow) {
                    HStack(spacing: 12) {
                        if viewModel.isGenerating {
                            ProgressView()
                        } else {
                            Image(systemName: "sparkles.rectangle.stack.fill").font(.title2).foregroundColor(AOReportStyle.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.isGenerating ? "Looking back at your week…" : "Generate report now").font(.headline)
                            Text("Covers the last 7 days").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .disabled(viewModel.isGenerating)
                if let message = viewModel.message {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
            }

            Section(header: Text("Reports")) {
                if viewModel.reports.isEmpty {
                    Text("No reports yet. The first one arrives on \(weekdayName(viewModel.settings.weekday)), or generate one now.")
                        .foregroundColor(.secondary)
                }
                ForEach(viewModel.reports) { report in
                    NavigationLink(destination: WeeklyReportDetailView(report: report)) {
                        WeeklyReportRow(report: report)
                    }
                }
                .onDelete(perform: viewModel.delete)
            }

            Section(header: Text("Schedule"), footer: Text("Each automatic report covers the 7 days before midnight on the day you pick. Reports are kept on this phone for 2 years; swipe one to delete it.")) {
                Toggle("Weekly report", isOn: Binding(get: { viewModel.settings.automatic }, set: { v in viewModel.update { $0.automatic = v } }))
                Picker("Day", selection: Binding(get: { viewModel.settings.weekday }, set: { v in viewModel.update { $0.weekday = v } })) {
                    ForEach(1...7, id: \.self) { Text(weekdayName($0)).tag($0) }
                }
                Toggle("Notify me", isOn: Binding(get: { viewModel.settings.notify }, set: { v in viewModel.update { $0.notify = v } }))
            }
        }
        .insetGroupedListStyle()
        .navigationTitle("Weekly Reports")
        .onAppear { viewModel.reload() }
    }

    private func weekdayName(_ weekday: Int) -> String { weekdays[(weekday - 1 + 7) % 7] }
}

private struct WeeklyReportRow: View {
    var report: AOReport

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                AORing(fraction: report.metrics.timeInRange, color: AOReportStyle.color(report.tone), lineWidth: 6)
                Text(AOReportStyle.pct(report.metrics.timeInRange)).font(.caption.weight(.bold))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(report.dateRangeText).font(.headline)
                    if report.trigger == .manual {
                        Text("Manual").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text("Below 70 \(AOReportStyle.pct1(report.metrics.below70)) · avg \(Int(report.metrics.mean.rounded())) mg/dL")
                    .font(.footnote).foregroundColor(.secondary)
                if let top = report.suggestions.first {
                    Text(top.title).font(.footnote).foregroundColor(AOReportStyle.color(top.category)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            AODelta.points(report.metrics.timeInRange, report.previous?.timeInRange, higherIsBetter: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct WeeklyReportDetailView: View {
    var report: AOReport
    @State private var pdfURL: URL?

    var body: some View {
        ScrollView {
            WeeklyReportContent(report: report)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(report.dateRangeText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "doc.richtext") }
                    }
                    ShareLink(item: report.plainText) { Label("Share as text", systemImage: "text.alignleft") }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { pdfURL = await MainActor.run { WeeklyReportPDF.make(report) } }
    }
}

enum WeeklyReportPDF {
    @MainActor
    static func make(_ report: AOReport) -> URL? {
        let content = WeeklyReportContent(report: report, forPrint: true)
            .padding(24)
            .frame(width: 612)
            .background(Color(.systemGroupedBackground))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 612, height: nil)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Loop weekly report \(f.string(from: report.start)).pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}

struct WeeklyReportContent: View {
    var report: AOReport
    var forPrint = false

    private var m: AOGlucoseMetrics { report.metrics }
    private var p: AOGlucoseMetrics? { report.previous }

    var body: some View {
        VStack(spacing: 16) {
            hero
            rangesCard
            tiles
            if !report.suggestions.isEmpty { suggestionsCard }
            if report.days.count >= 2 { dailyCard }
            if report.hours.count >= 12 { timeOfDayCard }
            insightsCard
            episodesCard
            if !report.meals.isEmpty { mealsCard }
            if !report.rides.rides.isEmpty { ridesCard }
            insulinCard
            Text("Suggestions are for you and your care team to review. Nothing in this report changes your settings or dosing. Older weeks come from Apple Health.")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: Hero

    private var hero: some View {
        let color = AOReportStyle.color(report.tone)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your week").font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.85))
                    Text(report.dateRangeText).font(.title2.weight(.bold)).foregroundColor(.white)
                }
                Spacer()
                Text(report.algorithm).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                    .foregroundColor(.white)
            }
            HStack(spacing: 18) {
                ZStack {
                    AORing(fraction: m.timeInRange, color: .white, lineWidth: 12)
                    VStack(spacing: 0) {
                        Text(AOReportStyle.pct(m.timeInRange)).font(.title.weight(.heavy)).foregroundColor(.white)
                        Text("in range").font(.caption2).foregroundColor(.white.opacity(0.85))
                    }
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.headline).font(.headline).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                    Text(toneText).font(.subheadline).foregroundColor(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    private var toneText: String {
        switch report.tone {
        case .good: return "A good week. \(report.suggestions.isEmpty ? "Keep doing what you're doing." : "A couple of things could make it even better.")"
        case .mixed: return "Some good, some to work on. The suggestions below are ordered by impact."
        case .tough: return "A tough week. Start with the first suggestion below."
        }
    }

    // MARK: Ranges

    private var rangesCard: some View {
        let parts: [(String, Double, Color)] = [
            ("Above 250", m.above250, AOReportStyle.veryHigh),
            ("181–250", m.above180 - m.above250, AOReportStyle.high),
            ("70–180", m.timeInRange, AOReportStyle.inRange),
            ("54–69", m.below70 - m.below54, AOReportStyle.low),
            ("Below 54", m.below54, AOReportStyle.veryLow),
        ]
        return AOCard(title: "Time in ranges", symbol: "chart.bar.fill") {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(parts.reversed()), id: \.0) { part in
                        if part.1 > 0.0005 {
                            Rectangle().fill(part.2).frame(width: max(3, geo.size.width * CGFloat(part.1) - 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 16)
            VStack(spacing: 6) {
                ForEach(parts, id: \.0) { part in
                    HStack {
                        Circle().fill(part.2).frame(width: 10, height: 10)
                        Text(part.0 + " mg/dL").font(.subheadline)
                        Spacer()
                        Text(part.1 < 0.1 ? AOReportStyle.pct1(part.1) : AOReportStyle.pct(part.1)).font(.subheadline.weight(.semibold))
                    }
                }
            }
            Text("Targets: over 70% in range, under 4% below 70, under 1% below 54, under 25% above 180.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let ins = report.insulin
        var items: [Tile] = []
        let averageBetter: Bool? = m.mean > 120 ? false : nil
        items.append(Tile(label: "Average", value: "\(Int(m.mean.rounded())) mg/dL",
                          delta: AODelta.value(m.mean, p?.mean, format: "%.0f", higherIsBetter: averageBetter)))
        items.append(Tile(label: "GMI", value: String(format: "%.1f%%", m.gmi),
                          delta: AODelta.value(m.gmi, p?.gmi, format: "%.1f", higherIsBetter: false)))
        items.append(Tile(label: "Variability (CV)", value: AOReportStyle.pct(m.cv),
                          delta: AODelta.points(m.cv, p?.cv, higherIsBetter: false)))
        items.append(Tile(label: "Tight range 70–140", value: AOReportStyle.pct(m.timeInTightRange),
                          delta: AODelta.points(m.timeInTightRange, p?.timeInTightRange, higherIsBetter: true)))
        var lowsValue = "\(report.lows.count)"
        if report.lows.severe > 0 { lowsValue += " (\(report.lows.severe) < 54)" }
        let previousLows: Double? = report.lows.previousCount.map { Double($0) }
        let previousHighs: Double? = report.highs.previousCount.map { Double($0) }
        items.append(Tile(label: "Lows", value: lowsValue,
                          delta: AODelta.value(Double(report.lows.count), previousLows, format: "%.0f", higherIsBetter: false)))
        items.append(Tile(label: "Highs", value: "\(report.highs.count)",
                          delta: AODelta.value(Double(report.highs.count), previousHighs, format: "%.0f", higherIsBetter: false)))
        items.append(Tile(label: "Insulin a day", value: "\(Int(ins.totalPerDay.rounded())) U",
                          delta: AODelta.value(ins.totalPerDay, ins.previousTotalPerDay, format: "%.0f", higherIsBetter: nil)))
        items.append(Tile(label: "CGM data", value: AOReportStyle.pct(m.coverage), delta: nil))
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        // Plain stacks (not lazy grids) so the PDF renderer draws every tile.
        return VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 12) {
                    ForEach(rows[r]) { tile in tileView(tile) }
                }
            }
        }
    }

    private struct Tile: Identifiable {
        var label: String
        var value: String
        var delta: AODelta?
        var id: String { label }
    }

    private func tileView(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tile.label).font(.caption).foregroundColor(.secondary)
            Text(tile.value).font(.title3.weight(.bold)).minimumScaleFactor(0.7).lineLimit(1)
            if let delta = tile.delta { delta } else { Text("same").font(.caption).hidden() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Suggestions

    private var suggestionsCard: some View {
        AOCard(title: "What to try this week", symbol: "wand.and.stars") {
            ForEach(Array(report.suggestions.enumerated()), id: \.element.id) { index, s in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: AOReportStyle.symbol(s.category))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(AOReportStyle.color(s.category)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.category.displayName.uppercased()).font(.caption2.weight(.bold)).foregroundColor(AOReportStyle.color(s.category))
                        Text(s.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(s.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Text("Why: " + s.evidence).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if report.suggestions.contains(where: { $0.category == .dosing }) {
                Text("Change one setting at a time, in Therapy Settings, and give it a week.").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Charts

    private var dailyCard: some View {
        AOCard(title: "Day by day", symbol: "calendar") {
            Chart {
                ForEach(report.days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Percent", d.below70 * 100))
                        .foregroundStyle(by: .value("Range", "Below 70"))
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Percent", d.timeInRange * 100))
                        .foregroundStyle(by: .value("Range", "In range"))
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Percent", d.above180 * 100))
                        .foregroundStyle(by: .value("Range", "Above 180"))
                        .annotation(position: .top, spacing: 2) {
                            if d.rode {
                                Image(systemName: "bicycle").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                }
            }
            .chartForegroundStyleScale(["Below 70": AOReportStyle.low, "In range": AOReportStyle.inRange, "Above 180": AOReportStyle.high])
            .chartYScale(domain: 0.0...112.0)
            .chartYAxis {
                AxisMarks(values: [0.0, 50.0, 100.0]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x))%") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .frame(height: 190)
            if report.days.contains(where: \.rode) {
                Label("Ride or workout that day", systemImage: "bicycle").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var timeOfDayCard: some View {
        AOCard(title: "Glucose by time of day", symbol: "clock") {
            Chart {
                ForEach(report.hours) { h in
                    AreaMark(x: .value("Hour", h.hour), yStart: .value("Low", h.p10), yEnd: .value("High", h.p90))
                        .foregroundStyle(by: .value("Band", "10–90% of readings"))
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Hour", h.hour), yStart: .value("Low", h.p25), yEnd: .value("High", h.p75))
                        .foregroundStyle(by: .value("Band", "Middle half"))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Hour", h.hour), y: .value("Median", h.p50))
                        .foregroundStyle(by: .value("Band", "Median"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                RuleMark(y: .value("Low", 70))
                    .foregroundStyle(AOReportStyle.low.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("High", 180))
                    .foregroundStyle(AOReportStyle.high.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartForegroundStyleScale(["10–90% of readings": AOReportStyle.accent.opacity(0.15),
                                        "Middle half": AOReportStyle.accent.opacity(0.35),
                                        "Median": AOReportStyle.accent])
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Int.self) { Text(hourLabel(h)) } }
                }
            }
            .chartYScale(domain: 40...max(300, (report.hours.map(\.p90).max() ?? 250) + 20))
            .frame(height: 200)
        }
    }

    private func hourLabel(_ h: Int) -> String {
        switch h {
        case 0: return "12a"
        case 12: return "12p"
        case 23: return "11p"
        default: return h < 12 ? "\(h)a" : "\(h - 12)p"
        }
    }

    // MARK: Insights

    private var insightsCard: some View {
        AOCard(title: "What happened", symbol: "text.magnifyingglass") {
            ForEach(Array(report.insights.enumerated()), id: \.element.id) { index, i in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: i.symbol)
                        .font(.title3)
                        .foregroundColor(AOReportStyle.color(i.tone))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(i.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if !i.detail.isEmpty {
                            Text(i.detail).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var episodesCard: some View {
        let lowRows = AOLowContext.allCases.compactMap { c in report.lows.byContext[c.rawValue].map { (c.displayName, $0) } }
        let highRows = AOHighContext.allCases.compactMap { c in report.highs.byContext[c.rawValue].map { (c.displayName, $0) } }
        let rc = report.rollercoaster
        return AOCard(title: "Lows, highs and rebounds", symbol: "waveform.path") {
            if !lowRows.isEmpty { breakdown("Lows (\(report.lows.count))", rows: lowRows, color: AOReportStyle.low) }
            if !highRows.isEmpty { breakdown("Highs over 180 (\(report.highs.count))", rows: highRows, color: AOReportStyle.high) }
            if lowRows.isEmpty && highRows.isEmpty { Text("No lows or highs worth noting.").foregroundColor(.secondary) }
            if rc.highs + rc.lows > 0 {
                HStack(spacing: 12) {
                    statPill("High → low", "\(rc.highsFollowedByLow)/\(rc.highs)", within: "within 5 h")
                    statPill("Low → high", "\(rc.lowsFollowedByHigh)/\(rc.lows)", within: "within 3 h")
                }
            }
            let c = report.corrections
            if c.lows > 0 {
                Text("Carbs logged for \(c.lowsWithCarbsLogged) of \(c.lows) lows · \(Int(c.manualBolusesPerDay.rounded())) manual boluses a day · \(c.correctionsThisWeek) corrections above 180 (\(c.correctionsOnActiveInsulinThisWeek) with 4+ U already active)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func breakdown(_ title: String, rows: [(String, Int)], color: Color) -> some View {
        let maxCount = max(rows.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(rows.sorted { $0.1 > $1.1 }, id: \.0) { row in
                HStack(spacing: 8) {
                    Text(row.0).font(.footnote).frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.8))
                            .frame(width: max(6, geo.size.width * CGFloat(row.1) / CGFloat(maxCount)))
                    }
                    .frame(height: 10)
                    Text("\(row.1)").font(.footnote.weight(.semibold)).frame(width: 24, alignment: .trailing)
                }
            }
        }
    }

    private func statPill(_ title: String, _ value: String, within: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline)
            Text(within).font(.caption2).foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
    }

    // MARK: Meals, rides, insulin

    private var mealsCard: some View {
        AOCard(title: "After meals", symbol: "fork.knife") {
            Text("Found from glucose rises and meal boluses, not carb counts.").font(.caption).foregroundColor(.secondary)
            ForEach(report.meals) { slot in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.name).font(.subheadline.weight(.semibold))
                        Text("\(slot.count) detected · rise \(Int(slot.medianRise.rounded()))").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("peak \(Int(slot.medianPeak.rounded()))").font(.subheadline.weight(.semibold))
                            .foregroundColor(slot.medianPeak > 180 ? AOReportStyle.veryHigh : .primary)
                        Text("\(AOReportStyle.pct(slot.over180)) above 180").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var ridesCard: some View {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return AOCard(title: "Rides and workouts", symbol: "bicycle") {
            ForEach(report.rides.rides) { ride in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.string(from: ride.start)).font(.subheadline.weight(.semibold))
                        Text("\(ride.minutes) min · \(String(format: "%.1f", ride.activeInsulin)) U active at start").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let lowest = ride.lowestGlucose {
                        Text("lowest \(Int(lowest.rounded()))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(ride.wentLow ? AOReportStyle.low : AOReportStyle.inRange)
                    }
                }
            }
            if report.rides.lowsLater > 0 {
                Text("\(report.rides.lowsLater) low\(report.rides.lowsLater == 1 ? "" : "s") started 1–12 hours after a ride.").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var insulinCard: some View {
        let ins = report.insulin
        let total = max(ins.totalPerDay, 0.01)
        let parts: [(String, Double, Color)] = [("Basal", ins.basalPerDay, AOReportStyle.accent.opacity(0.55)),
                                                ("Your boluses", ins.manualBolusPerDay, AOReportStyle.accent),
                                                ("Automatic", ins.automaticBolusPerDay, Color.purple.opacity(0.7))]
        return AOCard(title: "Insulin", symbol: "drop.fill") {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        if part.1 > 0 { Rectangle().fill(part.2).frame(width: max(3, geo.size.width * CGFloat(part.1 / total) - 2)) }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack {
                ForEach(parts, id: \.0) { part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) { Circle().fill(part.2).frame(width: 8, height: 8); Text(part.0).font(.caption).foregroundColor(.secondary) }
                        Text(String(format: "%.1f U", part.1)).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !ins.blocks.isEmpty {
                Divider()
                Text("Delivered vs scheduled basal, in hours without meals or boluses").font(.caption).foregroundColor(.secondary)
                ForEach(ins.blocks) { b in
                    HStack {
                        Text(b.name).font(.subheadline)
                        Text("\(b.fastingHours) h").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text(AOReportStyle.pct(b.deliveredRatio)).font(.subheadline.weight(.semibold))
                            .foregroundColor(abs(b.deliveredRatio - 1) >= 0.15 ? AOReportStyle.veryHigh : .primary)
                    }
                }
            }
        }
    }
}
