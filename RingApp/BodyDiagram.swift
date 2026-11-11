import SwiftUI

// MARK: - Body diagram (Fitness 2026-11-11)
//
// Front and back outlines from the Fitness server's /api/app/muscles/body-map
// (fetched once per app session), with worked muscles shaded in their group's
// color. Either a workout's or exercise's muscles by group (main muscles full
// color, "also" muscles faded, with a legend) or one group's muscles.

struct BodyMap: Decodable {
    let source: String?
    let viewBox: [Double]?
    let anterior: [BodyMapMuscle]?
    let posterior: [BodyMapMuscle]?
}

struct BodyMapMuscle: Decodable {
    let muscle: String?
    let polygons: [[Double]]?     // flat x1, y1, x2, y2, ...
}

/// One muscle's outline, ready to draw (in body-map units).
struct BodyPart: Identifiable {
    let id: Int
    let muscle: String
    let path: Path
}

/// The body map, loaded once and kept for the app session.
@MainActor
final class BodyMapCache: ObservableObject {
    static let shared = BodyMapCache()

    @Published private(set) var front: [BodyPart] = []
    @Published private(set) var back: [BodyPart] = []
    @Published private(set) var size = CGSize(width: 100, height: 200)
    @Published private(set) var loaded = false
    @Published private(set) var failed = false
    private var loading = false
    private var failedAt: Date?

    func load() async {
        if loaded || loading { return }
        // After a failure, try again only now and then.
        if let f = failedAt, Date().timeIntervalSince(f) < 60 { return }
        loading = true
        defer { loading = false }
        do {
            let map: BodyMap = try await FitnessLink.shared.api("/api/app/muscles/body-map")
            let f: [BodyPart] = Self.parts(map.anterior ?? [], firstID: 0)
            let b: [BodyPart] = Self.parts(map.posterior ?? [], firstID: 1000)
            guard !f.isEmpty || !b.isEmpty else { throw FitnessAPIError.http(200, "Empty body map") }
            // The box is the stated viewBox, grown to fit every outline (the
            // back view runs a little taller than 200).
            var w: CGFloat = CGFloat(map.viewBox?.first ?? 100)
            var h: CGFloat = CGFloat((map.viewBox?.count ?? 0) > 1 ? (map.viewBox?[1] ?? 200) : 200)
            for part in f + b {
                let r: CGRect = part.path.boundingRect
                w = max(w, r.maxX)
                h = max(h, r.maxY)
            }
            size = CGSize(width: max(w, 1), height: max(h, 1))
            front = f
            back = b
            loaded = true
            failed = false
            failedAt = nil
        } catch {
            failed = true
            failedAt = Date()
        }
    }

    private static func parts(_ list: [BodyMapMuscle], firstID: Int) -> [BodyPart] {
        var out: [BodyPart] = []
        for m in list {
            guard let name = m.muscle else { continue }
            var path = Path()
            for poly in m.polygons ?? [] {
                var pts: [CGPoint] = []
                var i = 0
                while i + 1 < poly.count {
                    pts.append(CGPoint(x: poly[i], y: poly[i + 1]))
                    i += 2
                }
                if pts.count >= 3 {
                    path.addLines(pts)
                    path.closeSubpath()
                }
            }
            if !path.isEmpty {
                out.append(BodyPart(id: firstID + out.count, muscle: muscleKey(name), path: path))
            }
        }
        return out
    }

    /// Body-map name -> MuscleMap key. The soleus outlines count as calves;
    /// head and knees stay as they are (never shaded).
    static func muscleKey(_ name: String) -> String {
        if name == "left-soleus" || name == "right-soleus" { return "calves" }
        return name
    }
}

/// One row of the legend: a group and the muscles shaded for it.
struct BodyLegendItem: Identifiable {
    let id: String          // group key
    let title: String       // "Core" or "Core (also)"
    let names: String       // "Abs, Obliques"
    let color: Color
    let main: Bool
}

struct BodyDiagram: View {
    let fills: [String: Color]      // muscle key -> shade
    let legend: [BodyLegendItem]
    let height: CGFloat             // figure height
    let tap: MusclePillTap          // what tapping a legend row does
    @ObservedObject private var cache: BodyMapCache = BodyMapCache.shared
    @State private var open: MuscleGroupRef?

    static let base: Color = Color.white.opacity(0.2)
    static let outline: Color = Color.white.opacity(0.32)

    /// By group: main muscles in their group's color, "also" muscles faded.
    init(primary: [String], secondary: [String], height: CGFloat = 220,
         showLegend: Bool = true, tap: MusclePillTap = .sheet) {
        let p: [String] = MuscleMap.unique(primary)
        let s: [String] = MuscleMap.unique(secondary).filter { !p.contains($0) }
        var f: [String: Color] = [:]
        for m in s {
            if let g = MuscleMap.groupFor(muscle: m) { f[m] = g.color.opacity(0.4) }
        }
        for m in p {
            if let g = MuscleMap.groupFor(muscle: m) { f[m] = g.color }
        }
        self.fills = f
        self.legend = showLegend ? Self.legendItems(primary: p, secondary: s) : []
        self.height = height
        self.tap = tap
    }

    /// By group, from the server's summary (a workout's muscles). Groups
    /// without muscle names shade the whole group.
    init(summary: MuscleSummary, height: CGFloat = 220, showLegend: Bool = true,
         tap: MusclePillTap = .sheet) {
        var p: [String] = summary.primary ?? []
        var s: [String] = summary.secondary ?? []
        if p.isEmpty {
            p = (summary.groups ?? []).flatMap { MuscleMap.group($0)?.muscles ?? [] }
        }
        if s.isEmpty {
            s = (summary.secondaryGroups ?? []).flatMap { MuscleMap.group($0)?.muscles ?? [] }
        }
        self.init(primary: p, secondary: s, height: height, showLegend: showLegend, tap: tap)
    }

    /// One group: its muscles in its color, no legend.
    init(group key: String, height: CGFloat = 200) {
        var f: [String: Color] = [:]
        if let g = MuscleMap.group(key) {
            for m in g.muscles { f[m] = g.color }
        }
        self.fills = f
        self.legend = []
        self.height = height
        self.tap = .off
    }

    /// Main groups first, then the "also" ones, each in the usual group order.
    static func legendItems(primary p: [String], secondary s: [String]) -> [BodyLegendItem] {
        var mains: [BodyLegendItem] = []
        var alsos: [BodyLegendItem] = []
        for g in MuscleMap.groups {
            let gp: [String] = p.filter { g.muscles.contains($0) }
            let gs: [String] = s.filter { g.muscles.contains($0) }
            if !gp.isEmpty {
                mains.append(BodyLegendItem(id: g.id, title: g.label,
                                            names: MuscleMap.namesLine(primary: gp, secondary: gs),
                                            color: g.color, main: true))
            } else if !gs.isEmpty {
                alsos.append(BodyLegendItem(id: g.id, title: g.label + " (also)",
                                            names: gs.map(MuscleMap.label).joined(separator: ", "),
                                            color: g.color, main: false))
            }
        }
        return mains + alsos
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            figures
            if !legend.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(legend) { item in legendRow(item) }
                }
            }
        }
        .task { await cache.load() }
        .sheet(item: $open) { ref in MuscleGroupSheet(groupKey: ref.id) }
    }

    // MARK: Figures

    @ViewBuilder
    private var figures: some View {
        if cache.loaded {
            HStack(alignment: .top, spacing: 22) {
                figure(cache.front, "Front")
                figure(cache.back, "Back")
            }
            .frame(maxWidth: .infinity)
        } else if !cache.failed {
            ProgressView().frame(maxWidth: .infinity).frame(height: height)
        }
    }

    private func figure(_ parts: [BodyPart], _ caption: String) -> some View {
        let box: CGSize = cache.size
        let width: CGFloat = height * box.width / box.height
        return VStack(spacing: 6) {
            BodyFigure(parts: parts, fills: fills, box: box)
                .frame(width: width, height: height)
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption + " of the body")
    }

    // MARK: Legend

    @ViewBuilder
    private func legendRow(_ item: BodyLegendItem) -> some View {
        switch tap {
        case .sheet:
            Button { open = MuscleGroupRef(id: item.id) } label: { legendLabel(item, chevron: true) }
                .buttonStyle(.plain)
        case .push:
            NavigationLink { MuscleGroupScreen(groupKey: item.id) } label: { legendLabel(item, chevron: true) }
                .buttonStyle(.plain)
        case .off:
            legendLabel(item, chevron: false)
        }
    }

    private func legendLabel(_ item: BodyLegendItem, chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(item.main ? item.color : item.color.opacity(0.4))
                .frame(width: 12, height: 12)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.main ? Color.primary : Color.secondary)
                .fixedSize()
            Text(item.names)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One view of the body (front or back), scaled to fit and centered.
private struct BodyFigure: View {
    let parts: [BodyPart]
    let fills: [String: Color]
    let box: CGSize

    var body: some View {
        GeometryReader { geo in
            let s: CGFloat = min(geo.size.width / box.width, geo.size.height / box.height)
            let dx: CGFloat = (geo.size.width - box.width * s) / 2
            let t: CGAffineTransform = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: 0)
            ZStack(alignment: .topLeading) {
                ForEach(parts) { part in
                    let p: Path = part.path.applying(t)
                    p.fill(BodyDiagram.base)
                    if let c = fills[part.muscle] {
                        p.fill(c)
                    }
                    p.stroke(BodyDiagram.outline, lineWidth: 0.6)
                }
            }
        }
    }
}
