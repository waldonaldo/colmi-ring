import SwiftUI

// MARK: - Muscle groups (Fitness 2026-11-11)
//
// The Fitness server's muscle keys, their labels, the six groups the website
// uses (with its colors), and a small pills view for exercises, workouts and
// routines.

struct MuscleGroup: Identifiable {
    let id: String          // group key, e.g. "arms"
    let label: String
    let muscles: [String]   // muscle keys
    let color: Color
}

enum MuscleMap {
    static let labels: [String: String] = [
        "chest": "Chest",
        "front-deltoids": "Front shoulders",
        "back-deltoids": "Rear shoulders",
        "biceps": "Biceps",
        "triceps": "Triceps",
        "forearm": "Forearms",
        "trapezius": "Trapezius",
        "upper-back": "Upper back",
        "lower-back": "Lower back",
        "neck": "Neck",
        "abs": "Abs",
        "obliques": "Obliques",
        "gluteal": "Glutes",
        "quadriceps": "Quads",
        "hamstring": "Hamstrings",
        "adductor": "Inner thigh",
        "abductors": "Outer hip",
        "calves": "Calves",
    ]

    static let groups: [MuscleGroup] = [
        MuscleGroup(id: "chest", label: "Chest", muscles: ["chest"], color: rgb(242, 85, 63)),
        MuscleGroup(id: "shoulders", label: "Shoulders", muscles: ["front-deltoids", "back-deltoids"],
                    color: rgb(244, 168, 58)),
        MuscleGroup(id: "arms", label: "Arms", muscles: ["biceps", "triceps", "forearm"],
                    color: rgb(233, 200, 74)),
        MuscleGroup(id: "back", label: "Back", muscles: ["trapezius", "upper-back", "lower-back", "neck"],
                    color: rgb(79, 179, 232)),
        MuscleGroup(id: "core", label: "Core", muscles: ["abs", "obliques"], color: rgb(169, 139, 242)),
        MuscleGroup(id: "legs", label: "Legs & glutes",
                    muscles: ["gluteal", "quadriceps", "hamstring", "adductor", "abductors", "calves"],
                    color: rgb(69, 196, 139)),
    ]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// "upper-back" -> "Upper back"; unknown keys get tidied up.
    static func label(_ key: String) -> String {
        if let l = labels[key] { return l }
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + String(words.dropFirst())
    }

    static func group(_ key: String) -> MuscleGroup? { groups.first { $0.id == key } }

    /// The group a muscle belongs to ("biceps" -> Arms).
    static func groupFor(muscle: String) -> MuscleGroup? { groups.first { $0.muscles.contains(muscle) } }

    static func groupLabel(_ key: String) -> String { group(key)?.label ?? label(key) }

    static func color(_ groupKey: String) -> Color { group(groupKey)?.color ?? Color.white.opacity(0.6) }

    /// Group keys for these muscles, in the usual group order.
    static func groupKeys(_ muscles: [String]) -> [String] {
        groups.filter { g in g.muscles.contains { muscles.contains($0) } }.map(\.id)
    }

    /// Drops repeats, keeps the order.
    static func unique(_ keys: [String]) -> [String] {
        var out: [String] = []
        for k in keys where !out.contains(k) { out.append(k) }
        return out
    }

    /// "Biceps, Forearms · also Abs"
    static func namesLine(primary: [String], secondary: [String]) -> String {
        let p: [String] = primary.map(label)
        let s: [String] = secondary.filter { !primary.contains($0) }.map(label)
        if p.isEmpty && s.isEmpty { return "" }
        if s.isEmpty { return p.joined(separator: ", ") }
        if p.isEmpty { return "Also " + s.joined(separator: ", ") }
        return p.joined(separator: ", ") + " · also " + s.joined(separator: ", ")
    }

    /// Equipment key -> "Ab roller".
    static func gearLabel(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + String(words.dropFirst())
    }
}

/// What tapping a group pill does: open the group's sheet, push the group's
/// screen (inside that sheet, so sheets don't stack), or nothing.
enum MusclePillTap {
    case sheet, push, off
}

/// A group key, for .sheet(item:).
struct MuscleGroupRef: Identifiable {
    let id: String
}

/// Group pills (main groups filled, secondary ones outlined) and a line of
/// muscle names. groupsOnly drops the names line. Tap a pill to read about
/// that group.
struct MusclePills: View {
    let primary: [String]
    let secondary: [String]
    let primaryGroups: [String]
    let secondaryGroups: [String]
    let groupsOnly: Bool
    let tap: MusclePillTap
    @State private var open: MuscleGroupRef?

    init(primary: [String], secondary: [String], groupsOnly: Bool = false, tap: MusclePillTap = .sheet) {
        let p: [String] = MuscleMap.unique(primary)
        let s: [String] = MuscleMap.unique(secondary).filter { !p.contains($0) }
        let pg: [String] = MuscleMap.groupKeys(p)
        self.primary = p
        self.secondary = s
        self.primaryGroups = pg
        self.secondaryGroups = MuscleMap.groupKeys(s).filter { !pg.contains($0) }
        self.groupsOnly = groupsOnly
        self.tap = tap
    }

    /// From the server's summary (a workout's or a routine's muscles).
    init(summary: MuscleSummary, groupsOnly: Bool = false, tap: MusclePillTap = .sheet) {
        let p: [String] = MuscleMap.unique(summary.primary ?? [])
        let s: [String] = MuscleMap.unique(summary.secondary ?? []).filter { !p.contains($0) }
        let pg: [String] = MuscleMap.unique(summary.groups ?? MuscleMap.groupKeys(p))
        let sg: [String] = MuscleMap.unique(summary.secondaryGroups ?? MuscleMap.groupKeys(s))
        self.primary = p
        self.secondary = s
        self.primaryGroups = pg
        self.secondaryGroups = sg.filter { !pg.contains($0) }
        self.groupsOnly = groupsOnly
        self.tap = tap
    }

    private var hasGroups: Bool { !primaryGroups.isEmpty || !secondaryGroups.isEmpty }
    private var names: String { MuscleMap.namesLine(primary: primary, secondary: secondary) }

    var body: some View {
        if hasGroups || (!groupsOnly && !names.isEmpty) {
            VStack(alignment: .leading, spacing: 5) {
                if hasGroups {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(primaryGroups, id: \.self) { g in pill(g, main: true) }
                            ForEach(secondaryGroups, id: \.self) { g in pill(g, main: false) }
                        }
                    }
                }
                if !groupsOnly && !names.isEmpty {
                    Text(names).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .sheet(item: $open) { ref in MuscleGroupSheet(groupKey: ref.id) }
        }
    }

    @ViewBuilder
    private func pill(_ key: String, main: Bool) -> some View {
        if MuscleMap.group(key) == nil {
            pillLabel(key, main: main, chevron: false)
        } else {
            switch tap {
            case .sheet:
                Button { open = MuscleGroupRef(id: key) } label: { pillLabel(key, main: main, chevron: true) }
                    .buttonStyle(.plain)
            case .push:
                NavigationLink { MuscleGroupScreen(groupKey: key) } label: { pillLabel(key, main: main, chevron: true) }
                    .buttonStyle(.plain)
            case .off:
                pillLabel(key, main: main, chevron: false)
            }
        }
    }

    private func pillLabel(_ key: String, main: Bool, chevron: Bool) -> some View {
        let c: Color = MuscleMap.color(key)
        return HStack(spacing: 3) {
            Text(MuscleMap.groupLabel(key))
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).opacity(0.7)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(main ? c : c.opacity(0.7))
        .background(main ? c.opacity(0.2) : Color.clear, in: Capsule())
        .overlay(Capsule().stroke(c.opacity(main ? 0 : 0.45), lineWidth: 1))
        .contentShape(Capsule())
    }
}
