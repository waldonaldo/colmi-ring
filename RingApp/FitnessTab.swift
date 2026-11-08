import SwiftUI

// MARK: - Fitness tab
//
// Today's meds & supplements, today's workout, this week's plan and blood
// pressure, all from the Fitness server (Atlas #102-#104). Reminders, scoring
// and Atlas sync stay on the server; this screen only shows and updates them.

@MainActor
final class FitnessModel: ObservableObject {
    @Published private(set) var today: AppToday?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published var busyMed: Int?

    private let link = FitnessLink.shared

    func load() async {
        guard link.isConfigured else { error = FitnessAPIError.notConfigured.errorDescription; return }
        loading = true
        defer { loading = false }
        do {
            today = try await link.api("/api/app/today")
            error = nil
        } catch {
            self.error = Self.message(error)
        }
    }

    /// taken / skipped / pending (pending clears the log).
    func setMed(_ med: AppMed, _ status: String) async {
        busyMed = med.id
        defer { busyMed = nil }
        let next = med.status == status ? "pending" : status   // tap again to undo
        do {
            var body: [String: Any] = ["medication_id": med.id, "status": next,
                                       "date": today?.date ?? LocalStamp.today()]
            if let s = med.scheduleId { body["schedule_id"] = s }
            let _: EmptyReply = try await link.api("/api/app/meds/log", method: "POST", body: body)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await load()
        } catch {
            self.error = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        if let e = error as? FitnessAPIError { return e.errorDescription ?? "Error" }
        if (error as? URLError) != nil {
            return "Can't reach the Fitness server - use home Wi-Fi or Tailscale."
        }
        return error.localizedDescription
    }
}

struct FitnessTab: View {
    let capture: RingCapture?
    @StateObject private var model = FitnessModel()
    @State private var openMed: AppMed?
    @State private var openWorkout: Int?

    private let accent = Section2.activity.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error = model.error {
                        Card { Label(error, systemImage: "wifi.exclamationmark").font(.subheadline) }
                    }
                    if let t = model.today {
                        medsCard(t)
                        workoutCard(t)
                        NavigationLink { BloodPressureScreen() } label: { BPBriefCard(bp: t.bp) }
                            .buttonStyle(.plain)
                        weekCard(t)
                        links
                    } else if model.loading {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(
                ZStack(alignment: .top) {
                    Palette.background
                    Section2.activity.gradient.frame(height: 360)
                }.ignoresSafeArea())
            .navigationTitle("Fitness")
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(item: $openMed) { MedDetailSheet(med: $0) }
            .fullScreenCover(item: Binding(
                get: { openWorkout.map { WorkoutID(id: $0) } },
                set: { openWorkout = $0?.id })) { w in
                WorkoutScreen(workoutID: w.id, capture: capture) { Task { await model.load() } }
            }
        }
    }

    // MARK: Meds

    private func medsCard(_ t: AppToday) -> some View {
        Card(title: "Meds & supplements") {
            if t.meds.isEmpty {
                Text("Nothing scheduled today.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(t.medsTaken)").font(.system(size: 34, weight: .light))
                    Text("of \(t.meds.count) taken").foregroundStyle(.secondary)
                    Spacer()
                    let late = t.meds.filter(\.late).count
                    if late > 0 {
                        Text("\(late) late").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Palette.low.opacity(0.2), in: Capsule())
                            .foregroundStyle(Palette.low)
                    }
                }
                ProgressView(value: Double(t.medsTaken), total: Double(max(1, t.meds.count)))
                    .tint(Palette.optimal)
                ForEach(groups(t.meds)) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group.meds) { med in medRow(med) }
                    }
                }
            }
        }
    }

    private struct MedGroup: Identifiable {
        let id: String          // the time label, e.g. "7:00 PM"
        let meds: [AppMed]
    }

    private func groups(_ meds: [AppMed]) -> [MedGroup] {
        var order: [String] = []
        var map: [String: [AppMed]] = [:]
        for m in meds {
            if map[m.dueLabel] == nil { order.append(m.dueLabel) }
            map[m.dueLabel, default: []].append(m)
        }
        return order.map { MedGroup(id: $0, meds: map[$0] ?? []) }
    }

    private func medRow(_ med: AppMed) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(med)).frame(width: 8, height: 8)
            Button { openMed = med } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.name).strikethrough(med.status == "skipped")
                        .font(.subheadline.weight(.medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        if let d = med.dosage { Text(d) }
                        if med.late { Text("Late").foregroundStyle(Palette.low).fontWeight(.semibold) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.busyMed == med.id {
                ProgressView().frame(width: 76)
            } else {
                doseButton(med, "taken", "checkmark", Palette.optimal)
                doseButton(med, "skipped", "xmark", Palette.low)
            }
        }
        .padding(.vertical, 4)
    }

    private func doseButton(_ med: AppMed, _ status: String, _ symbol: String, _ tint: Color) -> some View {
        let on = med.status == status
        return Button { Task { await model.setMed(med, status) } } label: {
            Image(systemName: symbol).font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(on ? tint.opacity(0.25) : Color.white.opacity(0.06), in: Circle())
                .overlay(Circle().stroke(on ? tint : Palette.hairline, lineWidth: 1))
                .foregroundStyle(on ? tint : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status == "taken" ? "Taken" : "Skipped")
    }

    private func color(_ med: AppMed) -> Color {
        switch med.status {
        case "taken": return Palette.optimal
        case "skipped": return Palette.low
        default: return med.late ? Palette.fair : Color.white.opacity(0.25)
        }
    }

    // MARK: Workouts

    @ViewBuilder
    private func workoutCard(_ t: AppToday) -> some View {
        Card(title: "Today's workout") {
            if t.workoutsToday.isEmpty {
                Text("Rest day - nothing planned.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(t.workoutsToday) { w in
                Button { openWorkout = w.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: WorkoutScreen.symbol(for: w.name))
                            .font(.title3).foregroundStyle(accent).frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.name).font(.headline).multilineTextAlignment(.leading)
                            Text(statusText(w)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(w.status == "completed" ? "View" : w.status == "in_progress" ? "Resume" : "Start")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(w.status == "completed" ? Color.white.opacity(0.1) : .white, in: Capsule())
                            .foregroundStyle(w.status == "completed" ? .white : .black)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func weekCard(_ t: AppToday) -> some View {
        Card(title: "This week") {
            if t.week.isEmpty {
                Text("No workouts planned this week.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(t.week) { w in
                Button { openWorkout = w.id } label: {
                    HStack(spacing: 10) {
                        Text(dayName(w.scheduledDate)).font(.caption.weight(.semibold))
                            .frame(width: 34, alignment: .leading)
                            .foregroundStyle(w.scheduledDate == t.date ? accent : .secondary)
                        Text(w.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        statusBadge(w)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var links: some View {
        VStack(spacing: 10) {
            NavigationLink { WorkoutHistoryScreen() } label: {
                linkRow("Workout history", "clock.arrow.circlepath")
            }
            if let url = FitnessLink.shared.webURL("/health/manage") {
                Link(destination: url) { linkRow("Edit med schedules on the web", "safari") }
            }
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ title: String, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
    }

    private func statusText(_ w: WorkoutRow) -> String {
        switch w.status {
        case "completed":
            let rank = w.rank.map { "Rank \($0)" } ?? "Done"
            return [rank, w.completionPct.map { "\($0)%" }].compactMap { $0 }.joined(separator: " · ")
        case "in_progress": return "In progress"
        case "missed": return "Missed"
        default:
            let n = w.exerciseCount ?? 0
            return "\(n) exercise\(n == 1 ? "" : "s")" + (w.startTime.map { " · \(Self.clock($0))" } ?? "")
        }
    }

    @ViewBuilder
    private func statusBadge(_ w: WorkoutRow) -> some View {
        switch w.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.optimal)
        case "missed":
            Image(systemName: "xmark.circle").foregroundStyle(Palette.low)
        case "in_progress":
            Image(systemName: "play.circle.fill").foregroundStyle(accent)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func dayName(_ ymd: String?) -> String {
        guard let ymd, let d = LocalStamp.dayDate(ymd) else { return "" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    static func clock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return hhmm }
        let h = parts[0] % 12 == 0 ? 12 : parts[0] % 12
        return String(format: "%d:%02d %@", h, parts[1], parts[0] >= 12 ? "PM" : "AM")
    }
}

private struct WorkoutID: Identifiable { let id: Int }

// MARK: - Med detail (benefits, side effects, score)

struct MedDetailSheet: View {
    let med: AppMed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(med.isMedication ? "Medication" : "Supplement")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background((med.isMedication ? Section2.stress.accent : Palette.optimal).opacity(0.2),
                                        in: Capsule())
                        Text(med.dueLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = med.dosage { Text(d).font(.headline) }
                    if let text = med.description, !text.isEmpty { section("About", text) }
                    if let text = med.instructions, !text.isEmpty { section("How to take it", text) }
                    if let text = med.warnings, !text.isEmpty { section("Side effects & warnings", text, warn: true) }
                }
                .padding(16)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(med.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func section(_ title: String, _ text: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: warn ? "exclamationmark.triangle" : "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(warn ? Palette.fair : .secondary)
            Text(text).font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
