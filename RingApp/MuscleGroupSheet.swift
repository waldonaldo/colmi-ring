import SwiftUI

// MARK: - Muscle group sheet (Fitness 2026-11-11)
//
// Tap a group pill: the group on the body, what its muscles do, why it
// matters, how to train and rest it, and the exercises that work it
// (/api/app/muscles/{group}). Inside the sheet, pills push instead of
// opening another sheet.

struct MuscleGroupInfo: Decodable {
    let key: String?
    let label: String?
    let summary: String?
    let everyday: String?
    let why: String?
    let train: String?
    let recovery: String?
    let muscles: [MuscleInfoRow]?
    let exercises: [MuscleGroupExercise]?
}

struct MuscleInfoRow: Decodable, Identifiable {
    let key: String?
    let label: String?
    let does: String?
    var id: String { key ?? label ?? "" }
}

struct MuscleGroupExercise: Decodable, Identifiable {
    let id: Int
    let name: String?
    let type: String?
    let role: String?               // main | also
    let equipment: [String]?
    let muscles: [String]?
    let thumb: String?              // media path, like a workout exercise's gifPath
    let timesPerformed: Int?
}

struct MuscleGroupSheet: View {
    let groupKey: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MuscleGroupScreen(groupKey: groupKey)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

struct MuscleGroupScreen: View {
    let groupKey: String
    @State private var info: MuscleGroupInfo?
    @State private var error: String?
    @State private var library: [Int: WorkoutExercise] = [:]   // exercise id -> how-to
    @State private var loaded = false

    private var color: Color { MuscleMap.color(groupKey) }
    private var title: String { info?.label ?? MuscleMap.groupLabel(groupKey) }
    private var mains: [MuscleGroupExercise] { (info?.exercises ?? []).filter { $0.role != "also" } }
    private var alsos: [MuscleGroupExercise] { (info?.exercises ?? []).filter { $0.role == "also" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    BodyDiagram(group: groupKey, height: 210)
                    if let s = info?.summary, !s.isEmpty {
                        Text(s).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error {
                    Card { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline) }
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                }
                if let info {
                    musclesCard(info.muscles ?? [])
                    textCard("In everyday life", info.everyday)
                    textCard("Why it matters", info.why)
                    textCard("How to train it", info.train)
                    textCard("Rest & recovery", info.recovery)
                    exercisesCard("Exercises", mains, empty: "No exercises for this group yet.")
                    if !alsos.isEmpty {
                        exercisesCard("Also works it", alsos, empty: "")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(
            ZStack(alignment: .top) {
                Palette.background
                RadialGradient(colors: [color.opacity(0.22), .clear], center: .top,
                               startRadius: 0, endRadius: 480)
            }.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
    }

    // MARK: Pieces

    @ViewBuilder
    private func musclesCard(_ rows: [MuscleInfoRow]) -> some View {
        if !rows.isEmpty {
            Card(title: "Muscles") {
                ForEach(rows) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.label ?? MuscleMap.label(m.key ?? "")).font(.subheadline.weight(.medium))
                            if let d = m.does, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textCard(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            Card(title: title) {
                Text(text).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func exercisesCard(_ title: String, _ rows: [MuscleGroupExercise], empty: String) -> some View {
        Card(title: title) {
            if rows.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows) { e in exerciseRow(e) }
        }
    }

    /// Opens the exercise's how-to when it's in the library.
    @ViewBuilder
    private func exerciseRow(_ e: MuscleGroupExercise) -> some View {
        if let ex = library[e.id] {
            NavigationLink { ExerciseDetailScreen(ex: ex, inSheet: true) } label: {
                MuscleExerciseRow(item: e, linked: true)
            }
            .buttonStyle(.plain)
        } else {
            MuscleExerciseRow(item: e, linked: false)
        }
    }

    // MARK: Server

    private func load() async {
        async let lib: [Int: WorkoutExercise] = Self.loadLibrary()
        do {
            let i: MuscleGroupInfo = try await FitnessLink.shared.api("/api/app/muscles/\(groupKey)")
            info = i
            error = nil
        } catch {
            self.error = FitnessModel.message(error)
        }
        library = await lib
        loaded = true
    }

    private static func loadLibrary() async -> [Int: WorkoutExercise] {
        do {
            let list: ExerciseList = try await FitnessLink.shared.api("/api/app/exercises")
            var out: [Int: WorkoutExercise] = [:]
            for ex in list.exercises { out[ex.exerciseId] = ex }
            return out
        } catch {
            return [:]
        }
    }
}

/// Thumbnail, name, type and the group's muscles it works.
struct MuscleExerciseRow: View {
    let item: MuscleGroupExercise
    let linked: Bool
    @State private var thumb: UIImage?

    /// "Bodyweight · Abs, Obliques · Mat"
    private var subtitle: String {
        var parts: [String] = []
        if let t = item.type, !t.isEmpty { parts.append(ExerciseDetailScreen.pretty(t)) }
        let muscles: [String] = MuscleMap.unique(item.muscles ?? [])
        if !muscles.isEmpty { parts.append(muscles.map(MuscleMap.label).joined(separator: ", ")) }
        let gear: [String] = (item.equipment ?? []).map(MuscleMap.gearLabel)
        if !gear.isEmpty { parts.append(gear.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: "figure.strengthtraining.functional").foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name ?? "Exercise").font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if linked {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .task(id: item.id) {
            guard let p = item.thumb, !p.isEmpty, let img = await ExerciseMediaCache.shared.image(p) else { return }
            thumb = img.images?.first ?? img     // a GIF's first frame as the still
        }
    }
}
