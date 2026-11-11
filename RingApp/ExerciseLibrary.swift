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

    @State private var works: String?   // muscle group key; nil = all
    @State private var uses: String?    // equipment key, "none"; nil = any

    private struct GearFilter: Identifiable {
        let id: String      // matched against the exercise's equipment
        let title: String
    }

    private static let gearFilters: [GearFilter] = [
        GearFilter(id: "mat", title: "Mat"),
        GearFilter(id: "dumbbell", title: "Dumbbells"),
        GearFilter(id: "ab roller", title: "Ab roller"),
        GearFilter(id: "treadmill", title: "Treadmill"),
        GearFilter(id: "none", title: "No equipment"),
    ]

    /// "ab_roller" / "Ab-Roller" -> "ab roller"
    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    private static func matchesWorks(_ ex: WorkoutExercise, _ groupKey: String) -> Bool {
        guard let g = MuscleMap.group(groupKey) else { return true }
        let muscles: [String] = (ex.primaryMuscles ?? []) + (ex.secondaryMuscles ?? [])
        return muscles.contains { g.muscles.contains($0) }
    }

    private static func matchesUses(_ ex: WorkoutExercise, _ gear: String) -> Bool {
        let have: [String] = (ex.equipment ?? []).map(norm)
        if gear == "none" {
            return have.isEmpty || have.contains { $0 == "bodyweight" || $0 == "body weight" || $0 == "none" }
        }
        return have.contains { $0.contains(gear) }
    }

    private var shown: [WorkoutExercise] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { ex in
            if let w = works, !Self.matchesWorks(ex, w) { return false }
            if let u = uses, !Self.matchesUses(ex, u) { return false }
            if q.isEmpty { return true }
            if ex.exerciseName.lowercased().contains(q) { return true }
            let muscles: [String] = (ex.primaryMuscles ?? []) + (ex.secondaryMuscles ?? [])
            if muscles.contains(where: { $0.lowercased().contains(q) || MuscleMap.label($0).lowercased().contains(q) }) {
                return true
            }
            return MuscleMap.groupKeys(muscles).contains { MuscleMap.groupLabel($0).lowercased().contains(q) }
        }
    }

    private var filtering: Bool { !query.isEmpty || works != nil || uses != nil }

    /// "Works" and "Uses" chip rows.
    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow("Works") {
                chip("All", on: works == nil, color: Section2.activity.accent) { works = nil }
                ForEach(MuscleMap.groups) { g in
                    chip(g.label, on: works == g.id, color: g.color) { works = works == g.id ? nil : g.id }
                }
            }
            chipRow("Uses") {
                chip("Any", on: uses == nil, color: Section2.activity.accent) { uses = nil }
                ForEach(Self.gearFilters) { f in
                    chip(f.title, on: uses == f.id, color: Section2.activity.accent) {
                        uses = uses == f.id ? nil : f.id
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chipRow<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.1)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
            }
        }
    }

    private func chip(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(on ? Color.black : color)
                .background(on ? color : color.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        List {
            filters
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
            if let error {
                Text(error).foregroundStyle(.secondary).listRowBackground(Palette.card)
            }
            if loaded && shown.isEmpty && error == nil {
                Text(!filtering ? "No exercises yet."
                     : query.isEmpty ? "Nothing matches these filters." : "Nothing matches \"\(query)\".")
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

    /// "Arms · Biceps, Forearms · Dumbbells"
    private var subtitle: String {
        var parts: [String] = []
        let muscles: [String] = MuscleMap.unique(ex.primaryMuscles ?? [])
        let groups: [String] = MuscleMap.groupKeys(muscles).map(MuscleMap.groupLabel)
        if !groups.isEmpty { parts.append(groups.joined(separator: ", ")) }
        if !muscles.isEmpty { parts.append(muscles.prefix(3).map(MuscleMap.label).joined(separator: ", ")) }
        let gear: [String] = (ex.equipment ?? []).map(MuscleMap.gearLabel)
        if !gear.isEmpty { parts.append(gear.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var groupColor: Color? {
        MuscleMap.groupKeys(ex.primaryMuscles ?? []).first.map(MuscleMap.color)
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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let c = groupColor { Circle().fill(c).frame(width: 7, height: 7) }
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if let t = ex.recommended?.text, !t.isEmpty {
                    Text(t).font(.caption2.weight(.medium)).foregroundStyle(Section2.activity.accent)
                        .lineLimit(1)
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

/// "Recommended for you": the server's suggested sets/reps/time, how to count
/// them, and why (how often you train, what you did last time).
struct RecommendedBlock: View {
    let rec: ExerciseRecommendation
    private let accent = Section2.activity.accent

    static func hasContent(_ r: ExerciseRecommendation) -> Bool {
        !(r.text ?? "").isEmpty
    }

    private var howLine: String? {
        switch rec.how ?? "" {
        case "reps": return "Count reps: do each set, rest, repeat."
        case "seconds": return "Count seconds: hold or keep moving for the time, rest, repeat."
        case "time": return "Go by time or distance."
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recommended for you", systemImage: "sparkles")
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
            if let t = rec.text, !t.isEmpty {
                Text(t).font(.subheadline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let n = rec.note, !n.isEmpty {
                Text(n).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let h = howLine {
                Text(h).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rec.why ?? [], id: \.self) { w in
                Text(w).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One exercise: muscles and equipment, then the full how-to.
struct ExerciseDetailScreen: View {
    let ex: WorkoutExercise
    let inSheet: Bool       // opened from a muscle group sheet: pills push, no new sheet
    private let accent = Section2.activity.accent

    init(ex: WorkoutExercise, inSheet: Bool = false) {
        self.ex = ex
        self.inSheet = inSheet
    }

    static func pretty(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var gear: [String] { MuscleMap.unique((ex.equipment ?? []).map(MuscleMap.gearLabel)) }

    private var hasMuscles: Bool { !(ex.primaryMuscles ?? []).isEmpty || !(ex.secondaryMuscles ?? []).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MusclePills(primary: ex.primaryMuscles ?? [], secondary: ex.secondaryMuscles ?? [],
                            tap: inSheet ? .push : .sheet)
                // The pills above are the legend for this picture.
                if hasMuscles {
                    BodyDiagram(primary: ex.primaryMuscles ?? [], secondary: ex.secondaryMuscles ?? [],
                                height: 170, showLegend: false)
                        .padding(.vertical, 4)
                }
                if !gear.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Image(systemName: "dumbbell.fill").font(.caption).foregroundStyle(.secondary)
                            ForEach(gear, id: \.self) { t in
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
                if let r = ex.recommended, RecommendedBlock.hasContent(r) {
                    Card { RecommendedBlock(rec: r) }
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
