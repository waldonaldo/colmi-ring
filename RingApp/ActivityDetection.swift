import SwiftUI

// MARK: - Automatic activity detection
//
// Finds sustained walks and runs in the ring's own logs (15-minute step
// buckets + the 5-minute heart-rate log) that weren't recorded as a workout,
// and ASKS before logging anything: "Looks like a 25-min walk at 3:10 PM - log
// it?". A confirmed one is saved as a workout session marked `detected`; it is
// never sent to Atlas and never completes an Atlas workout. "Not a workout" is
// remembered so the same stretch doesn't ask again.
//
// Thresholds:
// - A 15-minute slot counts as moving at 900+ steps (60 steps/min on average).
//   Brisk walking is ~100-120 steps/min, so 900 means at least ~8-9 minutes of
//   continuous walking inside the slot; pottering around the house rarely
//   averages more than ~30-40 steps/min over 15 minutes.
// - Back-to-back moving slots join into one activity. Its moving time is
//   estimated from the steps (walking ~100 steps/min, running ~160) and must be
//   10+ minutes with 1,000+ steps.
// - Running: a slot averaging 130+ steps/min, or strides over a metre (the same
//   rule the calorie maths uses).
// - Heart rate: when the log has 2+ readings in the window, the average must be
//   15+ bpm over resting (or 90+ bpm when resting isn't known). With fewer
//   readings the steps decide - you confirm it anyway.

struct DetectedActivity: Identifiable {
    let id: String              // start time, ISO
    let start: Date
    let end: Date
    let steps: Int
    let metres: Int
    let activity: WorkoutActivity
    let heartRates: [Int]

    var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    var meanHR: Int? {
        heartRates.isEmpty ? nil : Int((Double(heartRates.reduce(0, +)) / Double(heartRates.count)).rounded())
    }
    var noun: String { activity == .running ? "run" : "walk" }
}

enum ActivityDetector {
    static let movingStepsPerSlot = 900
    static let minMinutes = 10.0
    static let minSteps = 1_000
    static let lookback: TimeInterval = 48 * 3600
    static let slot: TimeInterval = 15 * 60

    private static let dismissedKey = "activityDetection.dismissed"

    static var dismissed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    static func dismiss(_ id: String) {
        var ids = Array(dismissed)
        ids.append(id)
        UserDefaults.standard.set(Array(ids.suffix(200)), forKey: dismissedKey)
    }

    @MainActor
    static func candidates(in store: RingStore, now: Date = Date()) -> [DetectedActivity] {
        let since = now.addingTimeInterval(-lookback)
        let buckets = store.steps
            .filter { $0.time >= since && $0.time.addingTimeInterval(slot) <= now }
            .sorted { $0.time < $1.time }
        let skip = dismissed
        let workouts = store.sessions.filter { $0.resolvedKind == .workout }

        // Join back-to-back moving slots.
        var runs: [[StepBucket]] = []
        for b in buckets where b.steps >= movingStepsPerSlot {
            if let last = runs.last?.last, b.time.timeIntervalSince(last.time) <= slot + 60 {
                runs[runs.count - 1].append(b)
            } else {
                runs.append([b])
            }
        }

        return runs.compactMap { run -> DetectedActivity? in
            guard let first = run.first, let last = run.last else { return nil }
            let steps = run.reduce(0) { $0 + $1.steps }
            let metres = run.reduce(0) { $0 + $1.metres }
            let running = run.contains { b in
                let stride = b.metres > 0 ? Double(b.metres) / Double(b.steps) : 0
                return Double(b.steps) / 15 >= 130 || stride >= 1.0
            }
            let cadence = running ? 160.0 : 100.0
            // Moving time inside the first and last slots, from their steps.
            let firstMin = min(15, Double(first.steps) / cadence)
            let lastMin = min(15, Double(last.steps) / cadence)
            let start = first.time.addingTimeInterval((15 - firstMin) * 60)
            let end = run.count == 1
                ? start.addingTimeInterval(min(15, Double(steps) / cadence) * 60)
                : last.time.addingTimeInterval(lastMin * 60)
            let minutes = end.timeIntervalSince(start) / 60
            guard minutes >= minMinutes, steps >= minSteps else { return nil }

            let id = DayKey.iso(start)
            guard !skip.contains(id) else { return nil }
            // Already recorded (or logged) as a workout? Any overlap counts.
            let windowStart = first.time, windowEnd = last.time.addingTimeInterval(slot)
            guard !workouts.contains(where: { $0.started < windowEnd && $0.ended > windowStart }) else { return nil }

            let hrs = store.heartRates
                .filter { $0.time >= windowStart && $0.time <= windowEnd && $0.bpm > 30 && $0.bpm < 220 }
                .map(\.bpm)
            if hrs.count >= 2 {
                let mean = Double(hrs.reduce(0, +)) / Double(hrs.count)
                let resting = restingHR(store, around: start)
                let needed = resting.map { $0 + 15 } ?? 90
                guard mean >= needed else { return nil }
            }
            return DetectedActivity(id: id, start: start, end: end, steps: steps, metres: metres,
                                    activity: running ? .running : .walking, heartRates: hrs)
        }
        .sorted { $0.start > $1.start }
    }

    @MainActor
    private static func restingHR(_ store: RingStore, around date: Date) -> Double? {
        let key = DayKey.of(date)
        if let r = store.metrics(on: key)?.restingHR { return r }
        return store.daily.filter { $0.dayKey <= key }.compactMap(\.restingHR).last
    }

    /// Saves a confirmed one as a workout session (marked detected).
    @MainActor
    static func log(_ d: DetectedActivity, in store: RingStore) {
        var session = CaptureSession(started: d.start, ended: d.end,
                                     subtype: RealtimeSubtype.heartRate.rawValue,
                                     rrIntervals: [], heartRates: d.heartRates)
        session.kind = .workout
        session.activity = d.activity.rawValue
        session.detected = true
        store.add(session: session)
    }
}

/// Today's prompt. Shows the newest unconfirmed activity, one at a time.
struct ActivityDetectionCard: View {
    @EnvironmentObject private var store: RingStore
    @State private var refresh = 0
    @State private var justLogged: String?

    var body: some View {
        let _ = refresh
        if let d = ActivityDetector.candidates(in: store).first {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: d.activity.symbol)
                        .font(.title3)
                        .foregroundStyle(Section2.activity.accent)
                        .frame(width: 40, height: 40)
                        .background(Section2.activity.accent.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Looks like a \(d.minutes)-min \(d.noun) at \(Format.time(d.start)) - log it?")
                            .font(.system(size: 17, weight: .regular, design: .serif))
                        Text(detail(d)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        ActivityDetector.log(d, in: store)
                        justLogged = "Logged your \(d.noun). It isn't sent to Atlas."
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        refresh += 1
                    } label: {
                        Text("Log it").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Button {
                        ActivityDetector.dismiss(d.id)
                        refresh += 1
                    } label: {
                        Text("Not a workout").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
        } else if let justLogged {
            Card {
                Label(justLogged, systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(Palette.optimal)
            }
        }
    }

    private func detail(_ d: DetectedActivity) -> String {
        var parts = ["\(d.steps.formatted()) steps"]
        if d.metres > 0 {
            parts.append(Measurement(value: Double(d.metres), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        if let hr = d.meanHR { parts.append("avg \(hr) bpm") }
        parts.append("from your ring")
        return parts.joined(separator: " · ")
    }
}
