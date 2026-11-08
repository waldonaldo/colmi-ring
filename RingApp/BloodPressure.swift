import SwiftUI
import Charts
import HealthKit

// MARK: - Blood pressure
//
// Type the cuff's numbers once: they go to Apple Health (systolic/diastolic +
// pulse) and to the Fitness server, which rates the reading 1-5, compares it
// with your goal and recent average, and keeps the log for the doctor.

enum BPHealth {
    static let store = HKHealthStore()

    static var shareTypes: Set<HKSampleType> {
        Set([HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic),
             HKQuantityType(.heartRate)])
    }

    /// Saves one reading to Apple Health. Returns an error message, or nil.
    static func save(systolic: Int, diastolic: Int, pulse: Int?, at date: Date) async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else { return "Apple Health isn't available on this device." }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: [])
            let mmHg = HKUnit.millimeterOfMercury()
            let sys = HKQuantitySample(type: HKQuantityType(.bloodPressureSystolic),
                                       quantity: HKQuantity(unit: mmHg, doubleValue: Double(systolic)),
                                       start: date, end: date)
            let dia = HKQuantitySample(type: HKQuantityType(.bloodPressureDiastolic),
                                       quantity: HKQuantity(unit: mmHg, doubleValue: Double(diastolic)),
                                       start: date, end: date)
            let bp = HKCorrelation(type: HKCorrelationType(.bloodPressure), start: date, end: date,
                                   objects: [sys, dia])
            var samples: [HKObject] = [bp]
            if let pulse {
                samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                                                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()),
                                                                     doubleValue: Double(pulse)),
                                                start: date, end: date))
            }
            try await store.save(samples)
            return nil
        } catch {
            return "Not saved to Apple Health: \(error.localizedDescription)"
        }
    }
}

extension BPCategory {
    var color: Color {
        switch key {
        case "normal": return Palette.optimal
        case "elevated": return Palette.fair
        default: return Palette.low
        }
    }
}

struct BPRatingBar: View {
    let rating: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i <= rating ? Palette.optimal : Color.white.opacity(0.12))
                    .frame(width: 14, height: 6)
            }
            Text("\(rating)/5").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .accessibilityLabel("Rating \(rating) of 5")
    }
}

struct BPBadge: View {
    let category: BPCategory
    var body: some View {
        Text(category.label).font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(category.color.opacity(0.18), in: Capsule())
            .foregroundStyle(category.color)
    }
}

/// The Fitness tab's card.
struct BPBriefCard: View {
    let bp: BPBrief

    var body: some View {
        Card(title: "Blood pressure") {
            if let l = bp.latest {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(l.systolic)/\(l.diastolic)").font(.system(size: 34, weight: .light))
                    if let p = l.pulse { Text("pulse \(p)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                HStack {
                    BPBadge(category: l.category)
                    BPRatingBar(rating: l.category.rating)
                }
                if let w = bp.week, let s = w.systolic, let d = w.diastolic {
                    Text("7-day average \(s)/\(d) · goal under \(bp.goal.systolic)/\(bp.goal.diastolic)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("No readings yet. Tap to log your first one.").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct BloodPressureScreen: View {
    @State private var sys = ""
    @State private var dia = ""
    @State private var pulse = ""
    @State private var note = ""
    @State private var when = Date()
    @State private var saving = false
    @State private var result: BPReading?
    @State private var healthMessage: String?
    @State private var error: String?
    @State private var summary: BPSummary?
    @State private var days = 30
    @FocusState private var focus: Field?

    private enum Field { case sys, dia, pulse }
    private let link = FitnessLink.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                form
                if let result { resultCard(result) }
                if let error {
                    Card { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline) }
                }
                if let s = summary {
                    overview(s)
                    chart(s)
                    insights(s)
                    recent(s)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            ZStack(alignment: .top) {
                Palette.background
                Section2.heart.gradient.frame(height: 360)
            }.ignoresSafeArea())
        .navigationTitle("Blood pressure")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Card(title: "Log a reading") {
            HStack(spacing: 10) {
                number("Top (SYS)", $sys, .sys)
                Text("/").font(.title).foregroundStyle(.secondary).padding(.top, 18)
                number("Bottom (DIA)", $dia, .dia)
                number("Pulse", $pulse, .pulse)
            }
            DatePicker("When", selection: $when, in: ...Date())
                .font(.subheadline)
            TextField("Note (optional): before meds, after coffee…", text: $note)
                .font(.subheadline)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Button { Task { await save() } } label: {
                Text(saving ? "Saving…" : "Save to Apple Health + Fitness").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(canSave ? Color.white : Color.white.opacity(0.3), in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(!canSave || saving)
            Text("Sit quietly 5 minutes first, feet flat, arm at heart level. Take 2 readings a minute apart, morning and evening.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func number(_ label: String, _ text: Binding<String>, _ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("--", text: text)
                .keyboardType(.numberPad)
                .focused($focus, equals: field)
                .font(.system(size: 28, weight: .light)).monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(height: 52)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var canSave: Bool {
        guard let s = Int(sys), let d = Int(dia) else { return false }
        return (60...260).contains(s) && (30...160).contains(d) && d < s
    }

    private func save() async {
        guard let s = Int(sys), let d = Int(dia) else { return }
        let p = Int(pulse)
        focus = nil
        saving = true
        defer { saving = false }
        error = nil
        // Apple Health first: it works offline.
        let healthError = await BPHealth.save(systolic: s, diastolic: d, pulse: p, at: when)
        healthMessage = healthError ?? "Saved to Apple Health"
        var body: [String: Any] = ["systolic": s, "diastolic": d, "taken_at": LocalStamp.string(when)]
        if let p { body["pulse"] = p }
        if !note.trimmingCharacters(in: .whitespaces).isEmpty { body["note"] = note }
        do {
            result = try await link.api("/api/app/bp", method: "POST", body: body)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            sys = ""; dia = ""; pulse = ""; note = ""; when = Date()
            await load()
        } catch {
            self.error = FitnessModel.message(error) + " The reading is not in Fitness yet - Save again when you're connected."
        }
    }

    private func resultCard(_ r: BPReading) -> some View {
        Card(title: "Just saved") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(r.systolic)/\(r.diastolic)").font(.system(size: 34, weight: .light))
                if let p = r.pulse { Text("pulse \(p)").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                BPBadge(category: r.category)
                BPRatingBar(rating: r.analysis?.rating ?? r.category.rating)
            }
            ForEach(r.analysis?.lines ?? [], id: \.self) { line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(BulletLabel())
                    .font(.subheadline)
            }
            if let h = healthMessage {
                Label(h, systemImage: h.hasPrefix("Saved") ? "heart.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(h.hasPrefix("Saved") ? Palette.optimal : Palette.fair)
            }
        }
    }

    // MARK: Summary

    private func load() async {
        do {
            summary = try await link.api("/api/app/bp?days=\(days)")
        } catch {
            self.error = FitnessModel.message(error)
        }
    }

    private func overview(_ s: BPSummary) -> some View {
        HStack(spacing: 14) {
            Card(title: "Latest") {
                if let l = s.latest {
                    Text("\(l.systolic)/\(l.diastolic)").font(.system(size: 28, weight: .light))
                    BPRatingBar(rating: l.category.rating)
                    Text(l.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("--").font(.title)
                }
            }
            Card(title: "7-day avg") {
                if let w = s.week, let sy = w.systolic, let di = w.diastolic {
                    Text("\(sy)/\(di)").font(.system(size: 28, weight: .light))
                    BPRatingBar(rating: w.category.rating)
                    Text("\(w.count) readings · \(s.weekAtGoal) at goal").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("--").font(.title)
                }
            }
        }
    }

    private func chart(_ s: BPSummary) -> some View {
        Card(title: "Trend") {
            Picker("Range", selection: $days) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
                Text("1y").tag(365)
            }
            .pickerStyle(.segmented)
            .onChange(of: days) { _, _ in Task { await load() } }
            let home = s.readings.filter { $0.source != "office" }
            if home.count < 2 {
                Text("The chart appears after 2 readings.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Chart {
                    RuleMark(y: .value("Goal", s.goal.systolic))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.white.opacity(0.3))
                    RuleMark(y: .value("Goal", s.goal.diastolic))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.white.opacity(0.3))
                    ForEach(home) { r in
                        LineMark(x: .value("Time", r.date), y: .value("mmHg", r.systolic),
                                 series: .value("Kind", "Top (SYS)"))
                            .foregroundStyle(by: .value("Kind", "Top (SYS)"))
                        PointMark(x: .value("Time", r.date), y: .value("mmHg", r.systolic))
                            .foregroundStyle(by: .value("Kind", "Top (SYS)"))
                        LineMark(x: .value("Time", r.date), y: .value("mmHg", r.diastolic),
                                 series: .value("Kind", "Bottom (DIA)"))
                            .foregroundStyle(by: .value("Kind", "Bottom (DIA)"))
                        PointMark(x: .value("Time", r.date), y: .value("mmHg", r.diastolic))
                            .foregroundStyle(by: .value("Kind", "Bottom (DIA)"))
                    }
                }
                .chartForegroundStyleScale(["Top (SYS)": Palette.low, "Bottom (DIA)": Palette.good])
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                Text("Dashed lines: goal \(s.goal.systolic)/\(s.goal.diastolic)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func insights(_ s: BPSummary) -> some View {
        Card(title: "Analysis", footnote: "General guide (2017 ACC/AHA categories), not a diagnosis. Export the log for your doctor from the Fitness web app.") {
            if s.analysis.insights.isEmpty {
                Text("Log a few readings to get an analysis.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(s.analysis.insights, id: \.self) { line in
                Label(line, systemImage: "circle.fill").labelStyle(BulletLabel()).font(.subheadline)
            }
        }
    }

    private func recent(_ s: BPSummary) -> some View {
        Card(title: "Readings") {
            ForEach(s.readings.prefix(30)) { r in
                HStack(spacing: 10) {
                    Circle().fill(r.category.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.systolic)/\(r.diastolic)" + (r.pulse.map { " · \($0) bpm" } ?? ""))
                            .font(.subheadline.weight(.medium))
                        Text(r.date.formatted(date: .abbreviated, time: .shortened)
                             + (r.source == "office" ? " · doctor's office" : "")
                             + (r.note.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text("\(r.category.rating)/5").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A small dot instead of an icon, for bullet lists.
struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.white.opacity(0.5)).frame(width: 5, height: 5).offset(y: -3)
            configuration.title
        }
    }
}
