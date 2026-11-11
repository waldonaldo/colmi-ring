import SwiftUI

// How to take an accurate home blood pressure reading (American Heart
// Association home-monitoring steps). Same list as the Fitness website.

struct BPHowToStep: Identifiable {
    let id: Int
    let title: String
    let items: [String]
}

enum BPHowToText {
    static let steps: [BPHowToStep] = [
        BPHowToStep(id: 1, title: "30 minutes before", items: [
            "No coffee or energy drinks, no smoking or vaping, no exercise.",
            "Use the bathroom first: a full bladder raises the reading.",
        ]),
        BPHowToStep(id: 2, title: "Sit right", items: [
            "Sit in a chair with your back supported, feet flat on the floor, legs uncrossed.",
            "Rest your arm on a table so the cuff is at heart level, palm up, arm relaxed.",
            "Sit quietly for 5 minutes before the first reading. No phone, no TV.",
        ]),
        BPHowToStep(id: 3, title: "Put the cuff on", items: [
            "On bare skin, not over a sleeve (and don't roll a tight sleeve up).",
            "Bottom edge about 1 inch above the bend of your elbow, tube down the middle of the inside of the arm.",
            "Snug: you can just slide two fingertips under it. The right cuff size matters.",
            "Use the same arm every time.",
        ]),
        BPHowToStep(id: 4, title: "Take it", items: [
            "Stay still and don't talk while it measures.",
            "Take 2 readings, 1 minute apart (3 if the first two differ a lot). Log each one.",
        ]),
        BPHowToStep(id: 5, title: "When", items: [
            "Same times every day: morning before breakfast, coffee and any medicine, and evening before dinner or bed.",
            "Before your doctor visit, aim for a week of morning and evening checks.",
        ]),
    ]

    static let urgent = "If a reading is above 180/120, rest 5 minutes and measure again. Still that high with chest pain, back pain, shortness of breath, numbness or weakness, vision changes or trouble speaking: call 911. Still that high without symptoms: call your doctor right away."
}

/// Tap to open: the full steps, then the "very high" warning.
struct BPHowToCard: View {
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack {
                    Image(systemName: "list.number")
                    Text("How to take an accurate reading").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(BPHowToText.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(step.id). \(step.title)").font(.subheadline.weight(.medium))
                        ForEach(step.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text(BPHowToText.urgent)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}
