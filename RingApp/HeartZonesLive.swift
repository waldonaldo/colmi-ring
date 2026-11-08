import SwiftUI

// MARK: - Live heart-rate zone
//
// Which of the five zones the live heart rate sits in, with that zone's bpm
// range, for any screen that streams heart rate during a workout. Zones come
// from HeartZones (max HR = 208 - 0.7 x age); without a birth year it says so.

struct LiveZoneBar: View {
    let bpm: Int?
    let zones: HeartZones?

    private var zone: Int? {
        guard let zones, let bpm else { return nil }
        return zones.zone(Double(bpm))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let zones {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { z in
                        Capsule()
                            .fill(HeartZones.color(z).opacity(z == zone ? 1 : 0.2))
                            .frame(height: z == zone ? 10 : 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: zone)
                Text(label(zones))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(zone.map { HeartZones.color($0) } ?? .secondary)
                    .contentTransition(.opacity)
            } else {
                Text("Add your birth year in Settings to see heart rate zones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ zones: HeartZones) -> String {
        guard let zone else { return "Waiting for heart rate" }
        if zone == 0 { return "Below zone 1 (under \(zones.range(1).lowerBound) bpm)" }
        let r = zones.range(zone)
        return "Zone \(zone) · \(HeartZones.names[zone - 1]) · \(r.lowerBound)–\(r.upperBound) bpm"
    }
}
