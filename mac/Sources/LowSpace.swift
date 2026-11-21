// Rumi — one low-space alert (v2.0). Off unless it's turned on in the menu-bar cartridge's menu.
// Every ten minutes Rumi looks at how much room the Mac has. When free space falls under the line it says so once, with
// a button that opens the map on what grew. Then it stays quiet until space has come back and fallen again, and it never
// speaks more than once a day.
import AppKit
import UserNotifications

enum LowSpace {
    private static let ON = "lowSpaceAlert", ARMED = "lowSpaceArmed", LAST = "lowSpaceLast"
    static var on: Bool { UserDefaults.standard.bool(forKey: ON) }

    /// The line: 10 GB, or a twentieth of the disk if that's less.
    static func line(total: Int64) -> Int64 { min(10_000_000_000, total / 20) }

    /// What a look at the disk leads to. `armed`: space has been comfortably above the line since Rumi last spoke
    /// (or it never has). Returns whether to speak, and whether it's armed afterwards.
    static func look(free: Int64, total: Int64, armed: Bool, last: Double, now: Double) -> (speak: Bool, armed: Bool) {
        guard total > 0 else { return (false, armed) }
        let l = line(total: total)
        if free >= l + l / 5 { return (false, true) }                        // room again: ready for the next time
        if free < l, armed, now - last >= 86400 { return (true, false) }     // (a second fall within the day waits for tomorrow)
        return (false, armed)
    }

    static func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// The Mac's own disk, whichever disk is on the map.
    private static var mac: Disk? { Disks.list().first { $0.mac } }

    static func check() {
        guard on, let d = mac else { return }
        let u = UserDefaults.standard, now = Date().timeIntervalSince1970
        let r = look(free: d.free, total: d.total, armed: u.object(forKey: ARMED) as? Bool ?? true, last: u.double(forKey: LAST), now: now)
        u.set(r.armed, forKey: ARMED)
        guard r.speak else { return }
        u.set(now, forKey: LAST)
        say("Your Mac is nearly full", "\(size(d.free)) free of \(size(d.total)).")
    }

    /// The switch in the cartridge's menu. Turning it on asks macOS for permission to notify and shows one notice, so
    /// what the alert looks like (and that it works) is seen now rather than on a bad day.
    static func set(_ want: Bool, failed: @escaping (String) -> Void) {
        guard want else { UserDefaults.standard.set(false, forKey: ON); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async {
                guard ok else { return failed("Allow notifications for Rumi in System Settings › Notifications, then turn this on again.") }
                UserDefaults.standard.set(true, forKey: ON)
                UserDefaults.standard.set(true, forKey: ARMED)
                let d = mac
                say("Rumi will tell you when space runs low", d.map { "\(size($0.free)) free now. The alert comes under \(size(line(total: $0.total)))." } ?? "")
            }
        }
    }

    private static func say(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default; c.categoryIdentifier = "low"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rumi.low-space", content: c, trigger: nil))
    }

    /// Call once at launch: the button on the notice, and what a click does.
    static func install(_ delegate: UNUserNotificationCenterDelegate) {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        let grew = UNNotificationAction(identifier: "grew", title: "Show What Grew", options: [.foreground])
        c.setNotificationCategories([UNNotificationCategory(identifier: "low", actions: [grew], intentIdentifiers: [])])
    }
}
