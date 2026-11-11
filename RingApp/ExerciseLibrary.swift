import SwiftUI

// MARK: - Exercise how-to browser (Fitness 2026-11-10)
//
// Every exercise on the Fitness server with its pictures/GIF, numbered steps,
// form tips and a video. For free-choice days (no plan, just pick moves) and
// for checking another exercise mid-workout. Reuses ExerciseHowTo: the
// server's /api/app/exercises uses the same field names as a workout's
// exercises.

struct ExerciseList: Decodable { let exercises: [WorkoutExercise] }

struct ExerciseLibraryScreen: View {
    @State private var all: [WorkoutExercise] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loaded = false

    private struct TypeGroup: Identifiable {
        let id: String      // exercise type
        let title: String
    }

    private static let groups: [TypeGroup] = [
        TypeGroup(id: "bodyweight", title: "Bodyweight & core"),
        TypeGroup(id: "strength", title: "Weights"),
        TypeGroup(id: "cardio", title: "Cardio"),
        TypeGroup(id: "flexibility", title: "Stretching"),
    ]

    private var shown: [WorkoutExercise] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return all }
        return all.filter { ex in
            if ex.exerciseName.lowercased().contains(q) { return true }
            let muscles: [String] = ex.primaryMuscles ?? []
            return muscles.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.secondary).listRowBackground(Palette.card)
            }
            if loaded && shown.isEmpty && error == nil {
                Text(query.isEmpty ? "No exercises yet." : "Nothing matches \"\(query)\".")
                    .foregroundStyle(.secondary).listRowBackground(Palette.card)
            }
            ForEach(Self.groups) { g in
                let rows: [WorkoutExercise] = shown.filter { $0.exerciseType == g.id }
                if !rows.isEmpty {
                    Section(g.title) {
                        ForEach(rows) { ex in
                            NavigationLink { ExerciseDetailScreen(ex: ex) } label: { ExerciseRow(ex: ex) }
                                .listRowBackground(Palette.card)
                        }
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Exercise how-to")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search exercises or muscles")
        .refreshable { await load() }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        do {
            let list: ExerciseList = try await FitnessLink.shared.api("/api/app/exercises")
            all = list.exercises
            error = nil
        } catch {
            self.error = FitnessModel.message(error)
        }
        loaded = true
    }
}

/// One row: still thumbnail, name, muscles, and what how-to it has.
struct ExerciseRow: View {
    let ex: WorkoutExercise
    @State private var thumb: UIImage?

    private var thumbPath: String? { ex.gifPath ?? ex.images?.first }

    private var subtitle: String {
        var parts: [String] = []
        let muscles: [String] = ex.primaryMuscles ?? []
        if !muscles.isEmpty { parts.append(muscles.prefix(2).map(ExerciseDetailScreen.pretty).joined(separator: ", ")) }
        if ex.gifPath != nil { parts.append("GIF") }
        else if !(ex.images ?? []).isEmpty { parts.append("Photos") }
        let steps = (ex.exerciseInstructions ?? []).count
        if steps > 0 { parts.append("\(steps) steps") }
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
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(ex.exerciseName).font(.subheadline.weight(.medium))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: ex.id) {
            guard let p = thumbPath, let img = await ExerciseMediaCache.shared.image(p) else { return }
            thumb = img.images?.first ?? img     // a GIF's first frame as the still
        }
    }
}

/// One exercise: muscles and equipment, then the full how-to.
struct ExerciseDetailScreen: View {
    let ex: WorkoutExercise
    private let accent = Section2.activity.accent

    static func pretty(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var tags: [String] {
        let muscles: [String] = (ex.primaryMuscles ?? []).map(Self.pretty)
        let gear: [String] = (ex.equipment ?? []).map(Self.pretty)
        return muscles + gear
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Text(t).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(accent.opacity(0.15), in: Capsule())
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                }
                if let d = ex.description, !d.isEmpty {
                    Text(d).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Card { ExerciseHowTo(ex: ex) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(ex.exerciseName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
