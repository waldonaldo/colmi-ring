import SwiftUI
import UIKit

/// Find my ring: while open, the ring is told to flash every few seconds and
/// its heart-rate sensor runs (the green light), and the phone reads the
/// Bluetooth signal strength once a second as a warmer/colder meter.
struct FindRingSheet: View {
    @EnvironmentObject private var ring: RingConnection
    @Environment(\.dismiss) private var dismiss
    let capture: RingCapture?

    /// Stop on its own after this long so the ring battery isn't drained.
    static let maxSeconds = 180

    @State private var task: Task<Void, Never>?
    @State private var seconds = 0
    @State private var readings: [Int] = []
    @State private var trend: Trend = .steady

    enum Trend { case warmer, colder, steady }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                pulse
                signal
                tips
                Spacer()
                Button(isRunning ? "Stop" : "Start again") {
                    if isRunning { stop() } else { start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .navigationTitle("Find my ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var isRunning: Bool { task != nil }

    // MARK: Pieces

    private var pulse: some View {
        ZStack {
            Circle().fill(Color.green.opacity(isRunning ? 0.15 : 0.05))
                .frame(width: 150, height: 150)
            Image(systemName: "circle.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(isRunning ? Color.green : .secondary)
                .symbolEffect(.pulse, isActive: isRunning)
        }
    }

    private var signal: some View {
        VStack(spacing: 8) {
            if !ring.isConnected {
                Text("Ring out of range")
                    .font(.title3.weight(.semibold))
                Text("Walk back toward where it last connected. It reconnects by itself.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let r = ring.rssi {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<5) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i < bars(r) ? Color.green : Color.secondary.opacity(0.25))
                            .frame(width: 14, height: CGFloat(14 + i * 10))
                    }
                }
                Text(distance(r)).font(.title3.weight(.semibold))
                Text(trendText + " · \(r) dBm")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("Reading signal…").font(.title3)
            }
        }
        .frame(minHeight: 120)
    }

    private var tips: some View {
        VStack(spacing: 4) {
            Text(isRunning
                 ? "The ring is flashing and its green light is on. Turn the lights off to spot it. Stops after 3 minutes."
                 : "Stopped.")
            Text("More bars = closer. Walk slowly and pause a second between steps.")
        }
        .font(.footnote).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private var trendText: String {
        switch trend {
        case .warmer: return "Getting closer"
        case .colder: return "Getting farther"
        case .steady: return "Hold still a moment"
        }
    }

    private func bars(_ r: Int) -> Int {
        switch r {
        case (-55)...: return 5
        case (-63)...: return 4
        case (-71)...: return 3
        case (-80)...: return 2
        default: return 1
        }
    }

    private func distance(_ r: Int) -> String {
        switch r {
        case (-55)...: return "Very close: within arm's reach"
        case (-65)...: return "Close: a few steps away"
        case (-78)...: return "Nearby: same room or next door"
        default: return "Far: keep looking"
        }
    }

    // MARK: Loop

    private func start() {
        guard task == nil else { return }
        // A running capture holds the sensor; finding the ring wins.
        if let capture, capture.isCapturing { capture.stop() }
        ring.connectIfNeeded()
        seconds = 0
        readings = []
        trend = .steady
        task = Task { @MainActor in
            var sensorOn = false
            while !Task.isCancelled && seconds < Self.maxSeconds {
                if ring.isConnected {
                    ring.readRSSI()
                    if seconds % 3 == 0 { ring.findDevice() }
                    // (Re)start the green light every 30 s: off a finger the
                    // ring may give up on its own.
                    if !sensorOn || seconds % 30 == 0 {
                        ring.startRealtime(.heartRate); sensorOn = true
                    } else if seconds % 10 == 0 {
                        ring.keepRealtimeAlive(.heartRate)
                    }
                } else {
                    sensorOn = false
                    if seconds % 5 == 0 { ring.connectIfNeeded() }
                }
                try? await Task.sleep(for: .seconds(1))
                seconds += 1
                record()
            }
            if !Task.isCancelled { finish() }   // timed out (Stop already cleaned up)
        }
    }

    private func record() {
        guard ring.isConnected, let r = ring.rssi, let at = ring.rssiAt,
              Date().timeIntervalSince(at) < 2 else { return }
        readings.append(r)
        readings = Array(readings.suffix(8))
        guard readings.count >= 6 else { return }
        let recent = Double(readings.suffix(3).reduce(0, +)) / 3
        let before = Double(readings.dropLast(3).suffix(3).reduce(0, +)) / 3
        let next: Trend = recent - before >= 3 ? .warmer : (before - recent >= 3 ? .colder : .steady)
        if next == .warmer && trend != .warmer {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        trend = next
    }

    private func stop() {
        task?.cancel()
        finish()
    }

    private func finish() {
        task = nil
        if ring.isConnected { ring.stopRealtime(.heartRate) }
    }
}
