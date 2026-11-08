import SwiftUI
import Combine

// MARK: - Readiness-adjusted activity goal
//
// On a low-readiness day the day's step and calorie targets come down, as
// Oura does, so the Activity score doesn't push you to train through poor
// recovery. The base goals (ActivityScore.stepGoal / calorieGoal) never change;
// only the day's target does. On by default, switchable on the Activity screen.

struct ActivityGoal {
    let steps: Double
    let calories: Double
    let factor: Double
    let readiness: Int?

    var isLowered: Bool { factor < 1 }

    static let adjustKey = "activityGoal.adjustToReadiness"

    /// Default ON: a missing key counts as on.
    static var adjustsToReadiness: Bool {
        get { UserDefaults.standard.object(forKey: adjustKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: adjustKey) }
    }

    /// Readiness under 55 -> 70% of the goal, under 70 -> 85%, otherwise the full goal.
    static func factor(readiness: Int?) -> Double {
        guard let readiness else { return 1 }
        switch readiness {
        case ..<55: return 0.70
        case ..<70: return 0.85
        default:    return 1
        }
    }

    static let base = ActivityGoal(steps: ActivityScore.stepGoal, calories: ActivityScore.calorieGoal,
                                   factor: 1, readiness: nil)
}

extension RingStore {
    /// The day's goal: lowered when that day's readiness is low (and the
    /// setting is on). Readiness is built from sleep and history, not from the
    /// Activity score, so there's no loop.
    func activityGoal(on dayKey: String) -> ActivityGoal {
        guard ActivityGoal.adjustsToReadiness else { return .base }
        let score = self.readiness(on: dayKey)?.value
        let f = ActivityGoal.factor(readiness: score)
        return ActivityGoal(steps: (ActivityScore.stepGoal * f).rounded(),
                            calories: (ActivityScore.calorieGoal * f).rounded(),
                            factor: f, readiness: score)
    }
}

/// On the Activity screen: today's goal, why it's lower, and the switch.
struct ActivityGoalCard: View {
    @EnvironmentObject private var store: RingStore
    let day: String
    @AppStorage(ActivityGoal.adjustKey) private var adjust = true

    var body: some View {
        let goal = store.activityGoal(on: day)
        Card(title: "Today's goal") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Int(goal.steps).formatted())
                    .font(.system(size: 26, weight: .light, design: .rounded)).monospacedDigit()
                Text("steps · \(Int(goal.calories)) active kcal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if goal.isLowered, let r = goal.readiness {
                Label("Goal lowered to \(Int((goal.factor * 100).rounded()))% today - readiness \(r). Recovery comes first; light movement still counts.",
                      systemImage: "arrow.down.heart")
                    .font(.footnote)
                    .foregroundStyle(Section2.readiness.accent)
            } else if adjust {
                Text("Full goal - readiness is fine (or not in yet).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Lower the goal on low-readiness days", isOn: $adjust)
                .font(.subheadline)
                .tint(Section2.activity.accent)
                .onChange(of: adjust) { _, _ in store.objectWillChange.send() }
        }
    }
}
