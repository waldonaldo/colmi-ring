import Foundation
import Combine
import Security
import UIKit
import SwiftUI

// MARK: - Fitness server link
//
// After every ring sync, the app sends what it read to a self-hosted Fitness
// server (POST /api/ring/ingest, the same payload the home Pi collector sends),
// so the server's dashboards, alerts and Atlas's workout check see the data
// wherever the phone is. The server can also ask for a fresh sync
// (GET /api/ring/sync-request) — the app checks that whenever it gets a chance
// to run and syncs straight away if a request is pending.
//
// Uploads are idempotent on the server (rows upsert by timestamp), so the app
// simply resends the last few days each time instead of tracking what landed.

@MainActor
final class FitnessLink: ObservableObject {
    static let shared = FitnessLink()

    @Published var baseURL: String = UserDefaults.standard.string(forKey: "fitness.url") ?? "" {
        didSet { UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespaces), forKey: "fitness.url") }
    }
    @Published var token: String = Keychain.read("fitness.token") ?? "" {
        didSet { Keychain.write("fitness.token", token.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    @Published private(set) var lastUpload: Date? = {
        let t = UserDefaults.standard.double(forKey: "fitness.lastUpload")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    @Published private(set) var status = "Not set up"

    private var lastPoll = Date.distantPast
    static let pollEvery: TimeInterval = 120

    var isConfigured: Bool { endpoint("/") != nil && !token.isEmpty }

    /// True when it's worth waking up to ask the server whether it wants a sync.
    var shouldPoll: Bool { isConfigured && Date().timeIntervalSince(lastPoll) > Self.pollEvery }

    private func endpoint(_ path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + path),
              let scheme = url.scheme, ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         timeout: TimeInterval = 10) -> URLRequest? {
        guard let url = endpoint(path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                   forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    // MARK: Upload

    /// Sends the last `days` days (plus today) of everything the ring logged.
    func upload(store: RingStore, battery: BatteryState?, days: Int) async {
        guard isConfigured else { return }
        let payload = Self.payload(store: store, battery: battery, days: days)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        await post(body)
    }

    /// The last upload that didn't get through (no home Wi-Fi, app suspended).
    /// Sent again the next time the app runs; a newer upload replaces it.
    private var pendingBody: Data?

    func retryPending() async {
        guard let body = pendingBody, !posting else { return }
        await post(body)
    }

    private var posting = false

    private func post(_ body: Data) async {
        guard let req = request("/api/ring/ingest", method: "POST", body: body, timeout: 20) else { return }
        posting = true
        defer { posting = false }
        // Ask iOS for time to finish if the app is backgrounded mid-upload.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "fitness-upload")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        do {
            // A separate task, so the caller being cancelled (the foreground
            // loop stops when the app goes to the background) can't cancel the
            // request halfway - that was the "(cancelled)" error.
            let (data, resp) = try await Task { try await URLSession.shared.data(for: req) }.value
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                status = code == 401 ? "Server rejected the token" : "Upload failed (HTTP \(code))"
                if code != 401 { pendingBody = body }
                return
            }
            pendingBody = nil
            let now = Date()
            lastUpload = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "fitness.lastUpload")
            lastPoll = now   // a fresh upload answers any pending sync request
            let counts = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["counts"]
                as? [String: Any]
            let hr = counts?["hr"] as? Int ?? 0
            status = "Sent \(Format.time(now)) · \(hr) heart-rate points"
        } catch {
            pendingBody = body
            status = "Not sent yet - will retry (\(error.localizedDescription))"
        }
    }

    /// Asks the server whether it wants a sync now (Atlas workout check).
    func syncRequested() async -> Bool {
        guard isConfigured, let req = request("/api/ring/sync-request", timeout: 8) else { return false }
        lastPoll = Date()
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return false }
        return json["pending"] as? Bool ?? false
    }

    /// Sends a workout recorded here to the Fitness server, which passes it to
    /// Atlas: its length and the ring's heart rate prove today's workout task.
    /// Returns Atlas's message (also remembered per workout).
    func sendWorkout(_ session: CaptureSession) async -> String {
        guard isConfigured else { return "Set up the Fitness server in Settings to send workouts to Atlas." }
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [
            "activity": session.activity ?? "Workout",
            "start": iso.string(from: session.started),
            "end": iso.string(from: session.ended),
            "readings": session.validHeartRates.count,
        ]
        if let avg = session.meanHR { body["avg_hr"] = (avg * 10).rounded() / 10 }
        if let peak = session.maxHR { body["max_hr"] = peak }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let req = request("/api/ring/workout", method: "POST", body: data, timeout: 30) else {
            return "Couldn't build the request."
        }
        do {
            let (out, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
            let message = (json?["message"] as? String) ?? "Fitness server answered HTTP \(code)"
            if code == 200 { Self.rememberSent(session, message, ok: json?["ok"] as? Bool ?? false) }
            return message
        } catch {
            return "Can't reach the Fitness server (\(error.localizedDescription)) - try again on home Wi-Fi or Tailscale."
        }
    }

    static func sentResult(_ session: CaptureSession) -> (message: String, ok: Bool)? {
        guard let d = UserDefaults.standard.dictionary(forKey: "atlas.sent." + session.id),
              let m = d["message"] as? String else { return nil }
        return (m, d["ok"] as? Bool ?? false)
    }

    private static func rememberSent(_ session: CaptureSession, _ message: String, ok: Bool) {
        UserDefaults.standard.set(["message": message, "ok": ok], forKey: "atlas.sent." + session.id)
    }

    /// Checks the URL and token without sending any data.
    func test() async {
        guard isConfigured, let req = request("/api/ring/sync-request", timeout: 8) else {
            status = "Enter the server address (http:// or https://) and the token"
            return
        }
        status = "Testing…"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: status = "Connected"
            case 401: status = "Server rejected the token"
            case let code: status = "Server answered HTTP \(code)"
            }
        } catch {
            status = "Can't reach the server (\(error.localizedDescription))"
        }
    }

    // MARK: Payload (matches the Pi collector's)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current            // the server stores local wall time
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func payload(store: RingStore, battery: BatteryState?, days: Int) -> [String: Any] {
        let since = DayKey.midnight(daysAgo: days) ?? Date().addingTimeInterval(-Double(days) * 86400)
        let ts = { (d: Date) in stamp.string(from: d) }

        let hr = store.heartRates.filter { $0.time >= since }.map { [ts($0.time), $0.bpm] as [Any] }
        let steps = store.steps.filter { $0.time >= since }
            .map { [ts($0.time), $0.steps, NSNull(), $0.metres] as [Any] }
        let series = { (kind: String) in
            store.samples.filter { $0.kind == kind && $0.time >= since }
                .map { [ts($0.time), Int($0.value.rounded())] as [Any] }
        }
        let temperature = store.temperatures.filter { $0.time >= since }
            .map { [ts($0.time), ($0.celsius * 10).rounded() / 10] as [Any] }
        let sleepSince = since.addingTimeInterval(-86400)
        let sleep = store.nights.filter { $0.end >= sleepSince }.map { night -> [String: Any] in
            ["start": ts(night.start), "end": ts(night.end),
             "stages": night.segments.map { [Int($0.stage.rawValue), $0.minutes] }]
        }

        var device: [String: Any] = ["source": "iphone"]
        if let battery {
            device["battery"] = battery.level
            device["charging"] = battery.isCharging
        }
        return ["hr": hr, "steps": steps, "stress": series("stress"), "hrv": series("hrv"),
                "temperature": temperature, "sleep": sleep, "device": device,
                "scores": scores(store: store, days: days)]
    }

    /// The scores this app shows, so the server and the emailed reports use
    /// the same numbers instead of working out their own.
    static func scores(store: RingStore, days: Int) -> [[String: Any]] {
        let encode = { (score: Score?) -> Any in
            guard let score else { return NSNull() }
            return ["score": score.value, "provisional": score.isProvisional,
                    "contributors": score.inOrder.map {
                        ["name": $0.name, "score": $0.score, "detail": $0.detail] as [String: Any]
                    }] as [String: Any]
        }
        return dayKeys(endingOn: DayKey.of(Date()), count: max(1, days)).compactMap { key in
            let readiness = store.readiness(on: key)
            let sleep = store.sleepScore(on: key)
            let activity = store.activityScore(on: key)
            guard readiness != nil || sleep != nil || activity != nil else { return nil }
            return ["date": key, "readiness": encode(readiness), "sleep": encode(sleep),
                    "activity": encode(activity)]
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "RingApp",
         kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        // Readable in the background once the phone has been unlocked since boot.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Settings

struct FitnessLinkSection: View {
    @ObservedObject var link: FitnessLink

    var body: some View {
        Section {
            TextField("Server address", text: $link.baseURL, prompt: Text("https://fitness.example.com"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Ring token", text: $link.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Test connection") { Task { await link.test() } }
            LabeledContent("Status", value: link.status)
                .font(.footnote)
            if let last = link.lastUpload {
                LabeledContent("Last sent", value: last.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
            }
        } header: {
            Text("Fitness server")
        } footer: {
            Text("After every sync the last few days of ring data are sent to your Fitness server, and the app syncs early when the server asks (the Atlas workout check). The token is the server's RING_INGEST_TOKEN and is kept in the iPhone Keychain.")
        }
    }
}
