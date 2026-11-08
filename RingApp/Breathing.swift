import SwiftUI
import AudioToolbox

// MARK: - Guided breathing
//
// A paced breathing circle with the phase spelled out (Breathe in / Hold /
// Breathe out), optional haptic taps at each change, and the ring recording
// heart rate the whole time, saved like an unguided session (a mindful
// session in Apple Health, with lowest heart rate and HRV results).

struct BreathingPattern: Identifiable, Hashable {
    enum Phase: String { case inhale = "Breathe in", hold = "Hold", exhale = "Breathe out", rest = "Hold out" }

    let id: String
    let name: String
    let blurb: String
    let steps: [(Phase, Double)]

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var cycle: Double { steps.reduce(0) { $0 + $1.1 } }
    var rhythm: String { steps.map { String(format: "%g", $0.1) }.joined(separator: "-") }

    /// Where `t` seconds into the session falls: the step, and how far through it (0-1).
    func position(at t: Double) -> (index: Int, phase: Phase, progress: Double, remaining: Double) {
        var x = t.truncatingRemainder(dividingBy: cycle)
        for (i, step) in steps.enumerated() {
            if x < step.1 { return (i, step.0, x / step.1, step.1 - x) }
            x -= step.1
        }
        let last = steps[steps.count - 1]
        return (steps.count - 1, last.0, 1, 0)
    }

    static let all: [BreathingPattern] = [
        BreathingPattern(id: "box", name: "Box breathing",
                         blurb: "4 in, 4 hold, 4 out, 4 hold. Steadies you before something stressful.",
                         steps: [(.inhale, 4), (.hold, 4), (.exhale, 4), (.rest, 4)]),
        BreathingPattern(id: "478", name: "4-7-8 wind-down",
                         blurb: "4 in, 7 hold, 8 out. Long exhales slow the heart - good before bed.",
                         steps: [(.inhale, 4), (.hold, 7), (.exhale, 8)]),
        BreathingPattern(id: "calm", name: "Calm breathing",
                         blurb: "4 in, 6 out, no holds. Easy to keep up for longer sessions.",
                         steps: [(.inhale, 4), (.exhale, 6)]),
    ]
}

struct BreathingFlow: View {
    @EnvironmentObject private var ring: RingConnection
    @ObservedObject var capture: RingCapture
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case setup, running, feeling, results }

    @State private var stage = Stage.setup
    @State private var pattern = BreathingPattern.all[0]
    @AppStorage("breathingMinutes") private var minutes = 3
    @AppStorage("breathingHaptics") private var haptics = true
    @State private var started = Date()
    @State private var runTask: Task<Void, Never>?
    @State private var recording = false
    @State private var session: CaptureSession?
    @State private var finishedEarly = false

    private let accent = Section2.stress.accent
    private var total: TimeInterval { TimeInterval(minutes * 60) }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.32), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
            switch stage {
            case .setup:   setup
            case .running: running
            case .feeling: feeling
            case .results: results
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stage)
        .interactiveDismissDisabled(stage == .running)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: 16) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                Spacer()
            }
            Image(systemName: "wind").font(.system(size: 40, weight: .light)).foregroundStyle(accent)
            Text("Guided breathing")
                .font(.system(size: 34, weight: .regular, design: .serif))
            Text("Follow the circle. Your ring measures how your body settles.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(BreathingPattern.all) { p in
                        Button { pattern = p } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(p.name).font(.headline)
                                    Spacer()
                                    Text(p.rhythm).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(p.blurb).font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(pattern == p ? accent.opacity(0.2) : Palette.card,
                                        in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .stroke(pattern == p ? accent : Palette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Picker("Length", selection: $minutes) {
                Text("1 min").tag(1)
                Text("3 min").tag(3)
                Text("5 min").tag(5)
            }
            .pickerStyle(.segmented)

            Toggle("Haptic tap at each change", isOn: $haptics)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))

            Button { start() } label: {
                Text("Start").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            if !ring.isConnected {
                Text("Ring not connected: you can still breathe along, but no heart rate is recorded.")
                    .font(.caption).foregroundStyle(Palette.fair).multilineTextAlignment(.center)
            } else if capture.isCapturing {
                Text("Another recording is running, so this one won't record heart rate.")
                    .font(.caption).foregroundStyle(Palette.fair).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func start() {
        started = Date()
        finishedEarly = false
        session = nil
        recording = ring.isConnected && !capture.isCapturing
        stage = .running
        UIApplication.shared.isIdleTimerDisabled = true
        let name = pattern.name
        let length = total
        let record = recording
        runTask = Task {
            if record {
                session = await capture.record(.session, duration: length, activity: name)
            } else {
                try? await Task.sleep(for: .seconds(length))
            }
            finish()
        }
        if haptics { hapticLoop() }
    }

    /// A light tap whenever the phase changes, until the session ends.
    private func hapticLoop() {
        let p = pattern
        let begin = started
        Task {
            var last = -1
            let tap = UIImpactFeedbackGenerator(style: .soft)
            while stage == .running && !Task.isCancelled {
                let index = p.position(at: Date().timeIntervalSince(begin)).index
                if index != last {
                    if last >= 0 { tap.impactOccurred() }
                    last = index
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finish() {
        guard stage == .running else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        if !finishedEarly {
            AudioServicesPlaySystemSound(1013)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        stage = session == nil ? .results : .feeling
    }

    private func endEarly() {
        finishedEarly = true
        if recording {
            capture.finish()            // record() returns, runTask calls finish()
        } else {
            runTask?.cancel()           // the sleep ends early, runTask calls finish()
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 26) {
            Text(pattern.name).font(.subheadline.weight(.medium)).foregroundStyle(accent)
                .padding(.top, 20)
            Spacer()
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(started)
                let pos = pattern.position(at: t)
                VStack(spacing: 30) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.08), lineWidth: 2)
                        Circle()
                            .fill(RadialGradient(colors: [accent.opacity(0.55), accent.opacity(0.12)],
                                                 center: .center, startRadius: 10, endRadius: 140))
                            .scaleEffect(scale(pos.phase, pos.progress))
                        Circle()
                            .trim(from: 0, to: min(1, t / total))
                            .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 6) {
                            Text(pos.phase.rawValue)
                                .font(.system(size: 28, weight: .regular, design: .serif))
                            Text("\(Int(pos.remaining.rounded(.up)))")
                                .font(.system(size: 22, weight: .light, design: .rounded))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 280, height: 280)

                    HStack(spacing: 18) {
                        Text(Format.clock(max(0, total - t)))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if recording {
                            HStack(spacing: 5) {
                                Image(systemName: "heart.fill").font(.caption)
                                    .foregroundStyle(Section2.heart.accent)
                                Text(capture.liveHeartRate.map { "\($0) bpm" } ?? "Finding pulse…")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer()
            Button { endEarly() } label: {
                Text("End early").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 28).frame(height: 46)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    /// Small at the bottom of the out-breath, full at the top of the in-breath.
    private func scale(_ phase: BreathingPattern.Phase, _ progress: Double) -> CGFloat {
        let low = 0.55, high = 1.0
        let eased = 0.5 - cos(progress * .pi) / 2      // ease in-out
        switch phase {
        case .inhale: return CGFloat(low + (high - low) * eased)
        case .hold:   return CGFloat(high)
        case .exhale: return CGFloat(high - (high - low) * eased)
        case .rest:   return CGFloat(low)
        }
    }

    // MARK: Feeling + results

    private var feeling: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("How do you feel?")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Text("Compared with before you started.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, 14)
            ForEach(CaptureSession.Feeling.allCases.reversed(), id: \.self) { f in
                Button { answer(f) } label: {
                    Text(f.label).font(.body.weight(.medium))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Palette.card, in: Capsule())
                        .overlay(Capsule().stroke(Palette.hairline))
                }
                .buttonStyle(.plain)
            }
            Button("Skip") { stage = .results }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func answer(_ f: CaptureSession.Feeling) {
        if var s = session {
            s.feeling = f
            capture.update(s)
            session = s
        }
        stage = .results
    }

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text("Session complete")
                            .font(.system(size: 30, weight: .regular, design: .serif))
                        Text("\(pattern.name) · \(Format.clock(session?.duration ?? Date().timeIntervalSince(started)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 36).padding(.bottom, 8)

                    if let session {
                        SessionResults(session: session)
                    } else if recording {
                        Card {
                            Text(capture.status).font(.subheadline)
                            Text("No heart rate came through. Make sure the ring sits snugly and keep your hand still.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Card {
                            Text("Breathing done. Connect your ring next time to see how your heart rate settles.")
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button { dismiss() } label: {
                Text("Done").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
