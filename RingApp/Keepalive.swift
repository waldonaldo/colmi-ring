import SwiftUI
import UIKit
import UserNotifications

// MARK: - Keepalive (fork addition)
//
// Two reminders that iOS delivers even when the app isn't running:
//
// 1. "App closed" alarm. Swiping the app away in the app switcher stops iOS
//    from waking it for the ring, and an app can't tell that happened. So every
//    time the app runs (opened, ring connects, background refresh, ring data)
//    it pushes one pending notification `closedAfter` into the future. While
//    the app keeps getting woken, it never fires; once it stops, it does.
//    It's a heuristic: a long quiet stretch without a swipe can trigger it too,
//    and opening the app is the fix either way. Never fires 11 PM - 8 AM.
//
// 2. Re-sign reminder. A free Apple ID signs the app for 7 days (Sideloadly).
//    The signing profile inside the app says when it expires, so the reminders
//    move by themselves after every re-sign: the day before, and a few hours
//    before.

@MainActor
enum Keepalive {
    static let closedID = "keepalive.closed"
    static let expiryIDs = ["keepalive.expiry.day", "keepalive.expiry.hours"]
    static let closedAfter: TimeInterval = 6 * 3600
    static let quietStart = 23, quietEnd = 8

    private static var lastTouch = Date.distantPast

    static var closedAlertOn: Bool {
        get { UserDefaults.standard.object(forKey: "keepalive.closedAlert") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepalive.closedAlert")
            lastTouch = .distantPast
            touch()
        }
    }

    /// Call whenever the app gets to run. Cheap; does real work at most every 5 minutes.
    static func touch(now: Date = Date()) {
        guard now.timeIntervalSince(lastTouch) > 300 else { return }
        lastTouch = now
        let center = UNUserNotificationCenter.current()

        if closedAlertOn {
            let fire = outsideQuietHours(now.addingTimeInterval(closedAfter))
            let c = UNMutableNotificationContent()
            c.title = "Naldo Fitness isn't running"
            c.body = "It hasn't run since \(Format.time(now)). If you swiped it away, open it so the ring keeps syncing."
            c.sound = .default
            add(center, closedID, c, at: fire, now: now)
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [closedID])
        }

        scheduleExpiry(center, now: now)
        // Anything that couldn't be sent last time (no Wi-Fi, app suspended).
        Task { await FitnessLink.shared.retryPending() }
    }

    // MARK: Re-sign reminder

    /// When the sideloaded signature runs out, from the app's embedded profile.
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    private static func scheduleExpiry(_ center: UNUserNotificationCenter, now: Date) {
        center.removePendingNotificationRequests(withIdentifiers: expiryIDs)
        guard let expiry, expiry > now else { return }
        let when = expiry.formatted(.dateTime.weekday(.wide).hour().minute())
        let plan: [(String, Date, String)] = [
            (expiryIDs[0], beforeQuietHours(expiry.addingTimeInterval(-24 * 3600)),
             "Naldo Fitness stops opening \(when). Plug the iPhone into the PC and click Start in Sideloadly - your data stays."),
            (expiryIDs[1], beforeQuietHours(expiry.addingTimeInterval(-3 * 3600)),
             "Last call: Naldo Fitness expires \(when). Re-sign it in Sideloadly (USB, click Start)."),
        ]
        for (id, fire, body) in plan where fire > now {
            let c = UNMutableNotificationContent()
            c.title = "Re-sign Naldo Fitness"
            c.body = body
            c.sound = .default
            add(center, id, c, at: fire, now: now)
        }
    }

    // MARK: Helpers

    private static func add(_ center: UNUserNotificationCenter, _ id: String,
                            _ content: UNMutableNotificationContent, at fire: Date, now: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSince(now)), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Pushes a time that lands overnight to 8 AM.
    static func outsideQuietHours(_ date: Date) -> Date {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        guard h >= quietStart || h < quietEnd else { return date }
        let day = h >= quietStart ? cal.date(byAdding: .day, value: 1, to: date)! : date
        return cal.date(bySettingHour: quietEnd, minute: 0, second: 0, of: day)!
    }

    /// Pulls a time that lands overnight back to 10 PM (a deadline can't wait for morning).
    static func beforeQuietHours(_ date: Date) -> Date {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        guard h >= quietStart || h < quietEnd else { return date }
        let day = h < quietEnd ? cal.date(byAdding: .day, value: -1, to: date)! : date
        return cal.date(bySettingHour: quietStart - 1, minute: 0, second: 0, of: day)!
    }
}

// MARK: - Settings

struct KeepaliveSection: View {
    @State private var closedAlert = Keepalive.closedAlertOn

    var body: some View {
        Section {
            Toggle("Alert if the app stops running", isOn: $closedAlert)
                .onChange(of: closedAlert) { _, on in Keepalive.closedAlertOn = on }
            LabeledContent("Re-sign by") {
                if let e = Keepalive.expiry {
                    Text(e.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Staying connected")
        } footer: {
            Text("Don't swipe this app away in the app switcher - iOS then stops waking it for the ring. If it hasn't run for 6 hours you get a reminder to open it (never 11 PM - 8 AM). Sideloaded apps expire after 7 days: you get a reminder the day before and a few hours before. Re-sign by plugging into the PC and clicking Start in Sideloadly.")
        }
    }
}
