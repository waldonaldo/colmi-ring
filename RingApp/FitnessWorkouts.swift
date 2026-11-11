import SwiftUI

// MARK: - Workout screen (Atlas #104)
//
// Plan -> Start -> log sets -> Finish. The Fitness server scores the session;
// while it runs the ring streams heart rate (the same recording as "Record
// workout heart rate"), and on Finish that recording goes to Atlas as the
// workout proof, so the Atlas task ticks itself.

struct WorkoutScreen: View {
    let workoutID: Int
    let capture: RingCapture?
    var onClose: () -> Void = {}

    @EnvironmentObject private var ring: RingConnection
    @EnvironmentObject private var store: RingStore
    @Environment(\.dismiss) private var dismiss

    @State private var state: WorkoutState?
    @State private var error: String?
    @State private var entries: [String: SetEntry] = [:]
    @State private var saving: Set<String> = []
    @State private var recordTask: Task<CaptureSession?, Never>?
    @State private var recorded: CaptureSession?
    @State private var score: WorkoutScore?
    @State private var finishing = false
    @State private var confirmFinish = false
    @State private var confirmFinishAgain = false
    @State private var showLibrary = false
    @AppStorage(WorkoutPrefs.autoRecordKey) private var autoRecord = true
    @State private var confirmClose = false
    @State private var started = Date()
    @State private var howToOpen: [Int: Bool] = [:]   // workout_exercise id -> expanded

    private let link = FitnessLink.shared
    private let accent = Section2.activity.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error {
                        Card { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline) }
                    }
                    if let s = state {
                        header(s)
                        if s.status == "in_progress" { liveCard }
                        if let score { resultCard(score) }
                        else if s.status == "completed", let r = s.result { resultCard(WorkoutScore(
                            completionPct: r.completionPct, caloriesEst: r.caloriesEst, rank: r.rank,
                            durationSec: r.durationSec, plannedSets: nil, completedSets: nil)) }
                        if let recorded { AtlasProofCard(session: recorded, autoSend: true) }
                        ForEach(s.exercises) { ex in exerciseCard(ex, s) }
                        actions(s)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(
                ZStack(alignment: .top) {
                    Palette.background
                    RadialGradient(colors: [accent.opacity(0.24), .clear], center: .top,
                                   startRadius: 0, endRadius: 520)
                }.ignoresSafeArea())
            .navigationTitle(state?.name ?? "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if state?.status == "in_progress" && score == nil { confirmClose = true } else { close() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showLibrary = true } label: {
                        Label("All exercises", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showLibrary) {
                NavigationStack {
                    ExerciseLibraryScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showLibrary = false } }
                        }
                }
            }
            .task { await load() }
            // Finishing asks twice, so a stray tap near the bottom can't end it.
            .confirmationDialog("Finish this workout?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Yes, finish it") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { confirmFinishAgain = true }
                }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("You'll be asked once more before it ends.")
            }
            .alert("Really finish now?", isPresented: $confirmFinishAgain) {
                Button("Finish and score it", role: .destructive) { Task { await finish() } }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text(finishMessage)
            }
            .confirmationDialog("Leave the workout?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Leave (keeps your sets, recording continues)") { close() }
                Button("Stay", role: .cancel) {}
            } message: {
                Text("Come back from the Fitness tab and tap Resume, then Finish.")
            }
        }
        .interactiveDismissDisabled(state?.status == "in_progress" && score == nil)
    }

    private var finishMessage: String {
        let total = state?.exercises.reduce(0) { $0 + $1.setCount } ?? 0
        let done = entries.values.filter(\.done).count
        return "\(done) of \(total) sets done. After this you can't log more sets. The Fitness server scores it and the ring's heart rate goes to Atlas as proof."
    }

    private func close() {
        onClose()
        dismiss()
    }

    // MARK: Pieces

    private func header(_ s: WorkoutState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: s.name)).font(.title2).foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(.headline)
                Text(statusLine(s)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func statusLine(_ s: WorkoutState) -> String {
        let total = s.exercises.reduce(0) { $0 + $1.setCount }
        let done = entries.values.filter(\.done).count
        switch s.status {
        case "completed": return "Completed"
        case "in_progress": return "\(done) of \(total) sets done"
        default: return "\(s.exercises.count) exercises · \(total) sets"
        }
    }

    private var liveCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HEART RATE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(capture?.liveHeartRate.map(String.init) ?? "--")
                            .font(.system(size: 40, weight: .light)).monospacedDigit()
                        Text("bpm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("TIME").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(elapsedText).font(.system(size: 28, weight: .light)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Circle().fill(isRecording ? Palette.low : Color.gray).frame(width: 8, height: 8)
                    Text(isRecording ? "Ring recording" : (ring.isConnected ? "Not recording" : "Ring not connected"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            LiveZoneBar(bpm: capture?.liveHeartRate, zones: HeartZones(age: store.age))
            ringControl
          }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
        }
    }

    private var isRecording: Bool { capture?.activeKind == .workout }

    /// Up top in the live card (it used to sit by Finish at the bottom).
    @ViewBuilder
    private var ringControl: some View {
        if isRecording || capture == nil {
            EmptyView()
        } else if !ring.isConnected {
            Label("Ring not connected. Connect it to record heart rate.", systemImage: "heart.slash")
                .font(.caption).foregroundStyle(.secondary)
        } else if capture?.isCapturing == true {
            Label("The ring is busy with another recording. Stop that one to record this workout.",
                  systemImage: "waveform.path.ecg")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button { startRecording() } label: {
                Label("Start ring heart rate", systemImage: "heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(accent, in: Capsule())
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
        }
    }

    private var elapsedText: String {
        let secs = Int(Date().timeIntervalSince(started))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func resultCard(_ sc: WorkoutScore) -> some View {
        Card(title: "Result") {
            HStack(spacing: 22) {
                stat("Rank", sc.rank)
                stat("Done", "\(sc.completionPct)%")
                if let c = sc.caloriesEst { stat("kcal", "\(c)") }
                if let d = sc.durationSec { stat("Time", "\(d / 60) min") }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .light))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exerciseCard(_ ex: WorkoutExercise, _ s: WorkoutState) -> some View {
        Card(title: ex.exerciseName) {
            HStack {
                Text(ex.targetText).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let w = ex.targetWeight { Text("\(Self.num(w)) lb").font(.caption).foregroundStyle(.secondary) }
            }
            if let n = ex.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(isExpanded: Binding(
                get: { howToOpen[ex.id] ?? (ex.id == currentExerciseID(s)) },
                set: { howToOpen[ex.id] = $0 })) {
                ExerciseHowTo(ex: ex).padding(.top, 8)
            } label: {
                Label("How to", systemImage: "figure.strengthtraining.functional")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(accent)
            if s.status != "scheduled" && s.status != "missed" {
                ForEach(1...ex.setCount, id: \.self) { n in setRow(ex, n, editable: s.status == "in_progress") }
            }
        }
    }

    /// The exercise you're on: the first one with sets still to do (its how-to
    /// starts open; the rest start closed and open with a tap).
    private func currentExerciseID(_ s: WorkoutState) -> Int? {
        if s.status == "completed" { return nil }
        return s.exercises.first { ex in
            !(1...ex.setCount).allSatisfy { entries[SetEntry.key(ex.id, $0)]?.done == true }
        }?.id
    }

    private func setRow(_ ex: WorkoutExercise, _ n: Int, editable: Bool) -> some View {
        let key = SetEntry.key(ex.id, n)
        let entry = Binding(get: { entries[key] ?? SetEntry(ex) }, set: { entries[key] = $0 })
        return HStack(spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.semibold)).frame(width: 22)
                .foregroundStyle(.secondary)
            if ex.isTimed {
                field("sec", entry.seconds, editable)
            } else {
                field("reps", entry.reps, editable)
                if ex.exerciseType == "strength" { field("lb", entry.weight, editable) }
            }
            Spacer()
            if saving.contains(key) {
                ProgressView().frame(width: 38, height: 38)
            } else {
                Button { Task { await toggle(ex, n) } } label: {
                    Image(systemName: entry.wrappedValue.done ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(entry.wrappedValue.done ? Palette.optimal : .secondary)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .disabled(!editable)
            }
        }
    }

    private func field(_ unit: String, _ text: Binding<String>, _ editable: Bool) -> some View {
        HStack(spacing: 4) {
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 56, height: 36)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .disabled(!editable)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(_ s: WorkoutState) -> some View {
        switch s.status {
        case "scheduled", "missed":
            VStack(spacing: 8) {
                bigButton("Start workout") { Task { await start() } }
                Toggle("Ring heart rate starts with the workout", isOn: $autoRecord)
                    .font(.subheadline).tint(accent)
                    .padding(.horizontal, 4)
                Text(startHint)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case "in_progress" where score == nil:
            bigButton(finishing ? "Finishing…" : "Finish workout") { confirmFinish = true }
                .disabled(finishing)
        default:
            bigButton("Done") { close() }
        }
    }

    private var startHint: String {
        if !ring.isConnected { return "Ring not connected: sets still save, but there's no heart rate for Atlas." }
        return autoRecord
            ? "The ring records your heart rate the whole time - keep the phone nearby."
            : "Tap Start ring heart rate at the top of the workout when you want it recorded."
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // MARK: Server

    private func load() async {
        do {
            let s: WorkoutState = try await link.api("/api/app/workouts/\(workoutID)/state")
            apply(s)
            error = nil
        } catch {
            self.error = FitnessModel.message(error)
        }
    }

    private func apply(_ s: WorkoutState) {
        state = s
        if let at = s.startedAt, let d = ISO8601DateFormatter.flexible.date(from: at) { started = d }
        for ex in s.exercises {
            for n in 1...ex.setCount where entries[SetEntry.key(ex.id, n)] == nil {
                entries[SetEntry.key(ex.id, n)] = SetEntry(ex)
            }
        }
        for set in s.sets ?? [] {
            guard let ex = s.exercises.first(where: { $0.id == set.workoutExerciseId }) else { continue }
            var e = SetEntry(ex)
            if let r = set.reps { e.reps = String(r) }
            if let w = set.weight { e.weight = Self.num(w) }
            if let d = set.durationSec { e.seconds = String(d) }
            e.done = set.isCompleted == 1
            entries[SetEntry.key(ex.id, set.setNumber)] = e
        }
    }

    private func start() async {
        do {
            let s: WorkoutState = try await link.api("/api/app/workouts/\(workoutID)/start", method: "POST")
            apply(s)
            started = Date()
            if autoRecord { startRecording() }
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            self.error = FitnessModel.message(error)
        }
    }

    private func startRecording() {
        guard let capture, ring.isConnected, !capture.isCapturing, let name = state?.name else { return }
        let activity = Self.activity(for: name)
        recordTask = Task { await capture.record(.workout, activity: activity.rawValue) }
    }

    private func toggle(_ ex: WorkoutExercise, _ n: Int) async {
        let key = SetEntry.key(ex.id, n)
        var e = entries[key] ?? SetEntry(ex)
        e.done.toggle()
        saving.insert(key)
        defer { saving.remove(key) }
        var body: [String: Any] = ["workout_exercise_id": ex.id, "set_number": n, "is_completed": e.done]
        if let r = Int(e.reps) { body["reps"] = r }
        if let w = Double(e.weight) { body["weight"] = w }
        if let s = Int(e.seconds) { body["duration_sec"] = s }
        if let hr = capture?.liveHeartRate { body["heart_rate"] = hr }
        do {
            let _: EmptyReply = try await link.api("/api/app/workouts/\(workoutID)/sets", method: "POST", body: body)
            entries[key] = e
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            self.error = FitnessModel.message(error)
        }
    }

    private func finish() async {
        finishing = true
        defer { finishing = false }
        do {
            let reply: CompleteReply = try await link.api("/api/app/workouts/\(workoutID)/complete", method: "POST")
            score = reply.score
            UIApplication.shared.isIdleTimerDisabled = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // End the ring recording; its summary card sends it to Atlas.
            if let task = recordTask {
                capture?.finish()
                recorded = await task.value
                recordTask = nil
            }
            await load()
        } catch {
            self.error = FitnessModel.message(error)
        }
    }

    // MARK: Helpers

    static func activity(for name: String) -> WorkoutActivity {
        let n = name.lowercased()
        if n.contains("treadmill") { return .treadmill }
        if n.contains("walk") { return .walking }
        if n.contains("run") { return .running }
        if n.contains("cycl") || n.contains("bike") { return .cycling }
        if n.contains("core") || n.contains("abs") { return .core }
        if n.contains("hiit") { return .hiit }
        return .strength
    }

    static func symbol(for name: String) -> String { activity(for: name).symbol }

    static func num(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}

/// What's typed into one set row.
struct SetEntry {
    var reps = ""
    var weight = ""
    var seconds = ""
    var done = false

    init(_ ex: WorkoutExercise) {
        reps = ex.targetReps.map(String.init) ?? ""
        weight = ex.targetWeight.map(WorkoutScreen.num) ?? ""
        seconds = ex.targetDurationSec.map(String.init) ?? ""
    }

    static func key(_ exerciseID: Int, _ n: Int) -> String { "\(exerciseID)-\(n)" }
}

extension ISO8601DateFormatter {
    /// The server's timestamps, with or without fractional seconds.
    static let flexible: ISO8601DateFormatterWrapper = ISO8601DateFormatterWrapper()
}

final class ISO8601DateFormatterWrapper {
    private let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()
    func date(from s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}

// MARK: - History

struct WorkoutHistoryScreen: View {
    @State private var rows: [WorkoutRow] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            if loaded && rows.isEmpty && error == nil {
                Text("No finished workouts in the last 60 days.").foregroundStyle(.secondary)
            }
            ForEach(rows) { w in
                HStack(spacing: 12) {
                    Image(systemName: w.status == "completed" ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(w.status == "completed" ? Palette.optimal : Palette.low)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(w.name).font(.subheadline.weight(.medium))
                        Text(line(w)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let r = w.rank {
                        Text(r).font(.headline)
                            .frame(width: 34, height: 34)
                            .background(Section2.activity.accent.opacity(0.18), in: Circle())
                    }
                }
                .listRowBackground(Palette.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Workout history")
        .refreshable { await load() }
        .task { await load() }
    }

    private func line(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        if let d = w.scheduledDate.flatMap(LocalStamp.dayDate) {
            parts.append(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        }
        if w.status == "missed" { parts.append("Missed") }
        if let p = w.completionPct { parts.append("\(p)%") }
        if let c = w.caloriesEst { parts.append("\(c) kcal") }
        if let s = w.durationSec, s > 0 { parts.append("\(s / 60) min") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let h: WorkoutHistory = try await FitnessLink.shared.api("/api/app/history?days=60")
            rows = h.workouts
            error = nil
        } catch {
            self.error = FitnessModel.message(error)
        }
        loaded = true
    }
}

// MARK: - Workout settings

enum WorkoutPrefs {
    /// On (default): the ring starts recording heart rate when you tap Start
    /// workout. Off: only when you tap Start ring heart rate.
    static let autoRecordKey = "workoutAutoRecordHR"
}

struct WorkoutPrefsSection: View {
    @AppStorage(WorkoutPrefs.autoRecordKey) private var autoRecord = true

    var body: some View {
        Section {
            Toggle("Ring heart rate starts with the workout", isOn: $autoRecord)
        } header: {
            Text("Workouts")
        } footer: {
            Text("On: the ring records heart rate as soon as you tap Start workout. Off: it waits until you tap Start ring heart rate at the top of the workout screen.")
        }
    }
}
