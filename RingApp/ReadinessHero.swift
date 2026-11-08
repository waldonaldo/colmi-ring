import SwiftUI
import UIKit

// MARK: - Readiness hero (Atlas #101)
//
// Oura-style: a full-width landscape photo behind the readiness score, with a
// short headline and one line that change with the score. Photos are
// copyright-free (Unsplash License, see HERO_PHOTO_CREDITS.md), picked by
// time of day (dawn / day / dusk / night) and score (good >= 70 / low).

enum HeroPhoto {
    enum TimeOfDay: String { case dawn, day, dusk, night }

    static func timeOfDay(_ date: Date = Date()) -> TimeOfDay {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<9: return .dawn
        case 9..<17: return .day
        case 17..<20: return .dusk
        default: return .night
        }
    }

    static func image(score: Int, at date: Date = Date()) -> UIImage? {
        let name = "hero_\(timeOfDay(date).rawValue)_\(score >= 70 ? "good" : "low")"
        if let path = Bundle.main.path(forResource: name, ofType: "jpg") {
            return UIImage(contentsOfFile: path)
        }
        return UIImage(named: name)
    }

    static func headline(_ score: Int) -> (title: String, line: String) {
        switch score {
        case 85...: return ("Peak day", "You're well recovered. A good day to push your workout.")
        case 70..<85: return ("Good to go", "Recovered enough for your usual plan.")
        case 55..<70: return ("Take it steady", "Your body is still recovering. Keep today's workout easy.")
        default: return ("Rest up", "Low recovery today. Put rest, water and an early night first.")
        }
    }
}

struct ReadinessHero: View {
    let readiness: Score

    var body: some View {
        let words = HeroPhoto.headline(readiness.value)
        ZStack(alignment: .bottomLeading) {
            backdrop
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(readiness.value)")
                        .font(.system(size: 64, weight: .light)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("READINESS").font(.caption2.weight(.semibold)).tracking(1.2)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(readiness.band.rawValue).font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.color(readiness.band))
                    }
                }
                Text(words.title)
                    .font(.system(size: 30, weight: .regular, design: .serif))
                Text(words.line)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if readiness.isProvisional {
                    Text("Still learning your baseline — scores settle after about two weeks.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                if let weakest = readiness.contributors.first {
                    HStack {
                        Text("Lowest contributor").font(.caption).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(weakest.name).font(.caption.weight(.medium))
                        Text("\(weakest.score)").font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.color(weakest.band))
                    }
                    .padding(.top, 4)
                }
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let img = HeroPhoto.image(score: readiness.value) {
            GeometryReader { geo in
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            Section2.readiness.gradient
        }
    }
}
