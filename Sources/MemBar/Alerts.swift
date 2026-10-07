import AppKit
import SwiftUI
import UserNotifications

// Notifications: a new leftover, critical memory pressure, a growing app, an app above its
// own limit. All off by default. The rules are one pure function that compares each scan
// with the last one (alertsToSend), so the check costs nothing next to the scan, also with
// the panel closed. UserDefaults keys: "alertLeftovers", "alertPressure", "alertGrowth",
// "alertLimits" (Bool), and "limits" ([String: Int], group name → MB; the right-click menu
// on a row writes it).

/// What earlier scans saw, so that each event alerts once. By group name.
struct AlertState: Equatable {
    var leftovers: [String: Date] = [:]  // leftover now: since when, in this appearance
    var told: Set<String> = []  // leftovers that had their alert, until they are gone
    var critical = false, pressureAt = Date.distantPast  // the level in the last scan; the last alert
    var growing: Set<String> = [], grewAt: [String: Date] = [:]  // badge on in the last scan; alerts in the last hour
    var over: Set<String> = []  // above its limit, until it is 10% under it
}

struct AlertSettings {
    var leftovers = false, pressure = false, growth = false, limits = false
    var limitMB: [String: Int] = [:]
}

struct Alert: Equatable {
    enum Kind: String { case leftover, pressure, growth, limit }
    let kind: Kind
    var group: String? = nil
    var stop = false  // a Stop button: a leftover that MemBar can stop, as the row's Stop
    let title: String, body: String
}

/// "2 GB", or "1500 MB" for a limit that `defaults write` set.
func limitText(_ mb: Int) -> String { mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB" }

/// The alerts for this scan, and the state for the next one. The state follows each event
/// also when its toggle is off, so a toggle turned on alerts for new events, not old ones.
/// Growth is the exception: `growth` (group name → History's growth text) is measured only
/// with its toggle on, so the apps that grow at that moment alert once.
func alertsToSend(prev: AlertState, groups: [Group], sys: SysMem, growth: [String: String], now: Date,
                  settings s: AlertSettings, uid: uid_t = getuid()) -> (AlertState, [Alert]) {
    var next = AlertState(), out: [Alert] = []
    let gs = groups.filter { !$0.ignored }  // the user said this app runs without its window on purpose
    for g in gs where g.leftover {
        let since = prev.leftovers[g.name] ?? now
        next.leftovers[g.name] = since
        if prev.told.contains(g.name) { next.told.insert(g.name); continue }
        // Not at once: an app that quits leaves its helpers for a few seconds, and a scan can see them.
        guard g.mem >= 500 << 20, now.timeIntervalSince(since) >= 30 else { continue }
        next.told.insert(g.name)
        if s.leftovers {
            out.append(Alert(kind: .leftover, group: g.name, stop: stoppable(g, uid: uid),
                             title: "Leftover: \(g.name)", body: "\(flagHelp(g)). Its processes use \(fmt(g.mem))."))
        }
    }

    next.critical = sys.pressure == .critical
    next.pressureAt = prev.pressureAt
    if s.pressure, next.critical, !prev.critical, now.timeIntervalSince(prev.pressureAt) >= 30 * 60 {
        next.pressureAt = now
        // Not macOS: it has nothing to quit.
        let big = groups.filter { $0.name != "macOS" }.sorted { $0.mem > $1.mem }.prefix(3)
        out.append(Alert(kind: .pressure, title: "Memory pressure is critical",
                         body: "Largest: " + big.map { "\($0.name) \(fmt($0.mem))" }.joined(separator: ", ")))
    }

    next.grewAt = prev.grewAt.filter { now.timeIntervalSince($0.value) < 3600 }
    for g in gs {
        guard let text = growth[g.name] else { continue }
        next.growing.insert(g.name)
        if s.growth, !prev.growing.contains(g.name), next.grewAt[g.name] == nil {
            next.grewAt[g.name] = now
            out.append(Alert(kind: .growth, group: g.name, title: "\(g.name) keeps growing", body: "Memory \(text), now \(fmt(g.mem))."))
        }
    }

    for g in gs {
        guard let mb = s.limitMB[g.name], mb > 0 else { continue }
        let limit = Int64(mb) << 20
        if g.mem > limit {
            next.over.insert(g.name)
            if s.limits, !prev.over.contains(g.name) {
                out.append(Alert(kind: .limit, group: g.name, title: "\(g.name) is above \(limitText(mb))", body: "It uses \(fmt(g.mem))."))
            }
        } else if prev.over.contains(g.name), g.mem * 10 >= limit * 9 {  // an app that hovers at its limit alerts once
            next.over.insert(g.name)
        }
    }
    return (next, out)
}

/// The bell's tooltip, also read by VoiceOver on the row. nil without a limit.
func limitHelp(_ g: Group, limits: [String: Int] = UserDefaults.standard.limits,
               on: Bool = UserDefaults.standard.bool(forKey: "alertLimits")) -> String? {
    guard let mb = limits[g.name] else { return nil }
    let off = g.ignored ? "ignored apps never alert" : on ? nil : "Settings > Notifications > App Over Limit"
    return "Alert above \(limitText(mb))" + (off.map { " (off: \($0))" } ?? "")
}

extension UserDefaults {
    // Same name as the key, so Alerts can observe(\.limits). Only 1 MB...16 TB: `defaults
    // write` can store anything, and a larger value overflows `<< 20` and `* 9`.
    @objc dynamic var limits: [String: Int] {
        (dictionary(forKey: "limits") ?? [:]).compactMapValues { ($0 as? Int).flatMap { (1...1 << 24).contains($0) ? $0 : nil } }
    }
}

/// Sends the notifications and answers clicks on them. Main thread only.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    private var state = AlertState()
    private weak var model: Model?
    private var open: () -> Void = {}
    private var stopAfterScan: String?  // the group of a Stop clicked in a notification
    private var watch: NSKeyValueObservation?
    // Toggles turned on that wait for macOS's answer. Main thread only. macOS drops an alert
    // sent before the first answer, so check() keeps the old state until then: the events of
    // that wait are still new and alert after Allow. ponytail: only a prompt of this launch;
    // a toggle left on with the prompt not answered at quit sends alerts that macOS drops.
    private static var asking = 0

    /// nil outside an .app (the bare debug binary): there the center raises an exception.
    static var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    /// At launch, before it ends: a click that launches MemBar comes here too.
    func start(_ model: Model, open: @escaping () -> Void) {
        self.model = model
        self.open = open
        Self.center?.delegate = self
        Self.center?.setNotificationCategories([UNNotificationCategory(
            identifier: "leftover", actions: [UNNotificationAction(identifier: "stop", title: "Stop")], intentIdentifiers: [])])
        // A new limit applies at once: rescan, so the bell shows and an app already above it alerts now.
        watch = UserDefaults.standard.observe(\.limits) { [weak model] _, _ in DispatchQueue.main.async { model?.refresh() } }
    }

    /// After each scan (Model.onUpdate).
    func check() {
        guard let model, Self.asking == 0 else { return }
        let d = UserDefaults.standard
        let s = AlertSettings(leftovers: d.bool(forKey: "alertLeftovers"), pressure: d.bool(forKey: "alertPressure"),
                              growth: d.bool(forKey: "alertGrowth"), limits: d.bool(forKey: "alertLimits"), limitMB: d.limits)
        var growth: [String: String] = [:]
        if s.growth {  // a line fit for each group: only when it is on
            for g in model.groups { if let t = growthText(model.history.points(g.id)) { growth[g.name] = t } }
        }
        let (next, out) = alertsToSend(prev: state, groups: model.groups, sys: model.sys, growth: growth, now: Date(), settings: s)
        state = next
        out.forEach(send)
        if let name = stopAfterScan {
            stopAfterScan = nil
            // A scan after the click: the app can be open again since the notification came.
            // Not a leftover now: show the panel, so it is clear why nothing stopped.
            if let g = model.groups.first(where: { $0.name == name && $0.leftover }) { model.stopGroups([g]) } else { open() }
        }
    }

    private func send(_ a: Alert) { Self.center?.add(Self.request(a)) }

    /// The notification of `a`. Apart from sending it: --drive builds it with no permission asked.
    static func request(_ a: Alert) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = a.title
        c.body = a.body
        if a.stop, let g = a.group { c.categoryIdentifier = "leftover"; c.userInfo = ["group": g] }
        // One per kind and group: a new one takes the place of the old one in Notification Center.
        return UNNotificationRequest(identifier: "\(a.kind)|\(a.group ?? "")", content: c, trigger: nil)
    }

    /// A toggle turned on: ask macOS now. The first time it shows its prompt, after that it
    /// answers at once. Denied: the toggle goes off again, and an alert says where to allow it.
    static func allow(_ key: String) {
        guard let center else { return UserDefaults.standard.set(false, forKey: key) }
        asking += 1
        center.requestAuthorization(options: [.alert]) { ok, _ in
            DispatchQueue.main.async {
                asking -= 1
                // Rescan: what came while macOS asked alerts now, not with a scan up to 60 s later.
                if ok { (NSApp.delegate as? Delegate)?.model.refresh(); return }
                UserDefaults.standard.set(false, forKey: key)
                // perform, not inline: a modal loop inside a main-queue block holds back every other
                // main-queue job (scan results, SIGTERM, the reopen after a quit) until it closes.
                RunLoop.main.perform {
                    let a = NSAlert()
                    a.messageText = "Notifications are off for MemBar"
                    a.informativeText = "To allow them, open System Settings > Notifications > MemBar and turn on Allow Notifications."
                    a.addButton(withTitle: "Open System Settings")
                    a.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn, let id = Bundle.main.bundleIdentifier,
                       let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // macOS asks only while MemBar is the active app. With the panel open, it shows the same:
    // no banner, only Notification Center. Main queue: panelOpen is main-thread state.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { done(self.model?.panelOpen == true ? [.list] : [.banner, .list]) }
    }

    /// Stop: rescan, then stop the group if it is still a leftover (see check). Any other click opens the panel.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let stop = response.actionIdentifier == "stop" ? response.notification.request.content.userInfo["group"] as? String : nil
        DispatchQueue.main.async {
            if let stop { self.stopAfterScan = stop; self.model?.refresh() } else { self.open() }
            done()
        }
    }
}

/// Settings > Notifications.
struct AlertsMenu: View {
    @AppStorage("alertLeftovers") private var leftovers = false
    @AppStorage("alertPressure") private var pressure = false
    @AppStorage("alertGrowth") private var growth = false
    @AppStorage("alertLimits") private var limits = false

    var body: some View {
        Menu("Notifications") {
            Toggle("New Leftovers", isOn: asking($leftovers, "alertLeftovers"))
                .help("A leftover of 500 MB or more appears. Once, until it is gone.")
            Toggle("Memory Pressure", isOn: asking($pressure, "alertPressure"))
                .help("Memory pressure becomes critical. At most once in 30 min.")
            Toggle("Growing Apps", isOn: asking($growth, "alertGrowth"))
                .help("An app's memory keeps growing (the red arrow). At most once an hour for each app.")
            Toggle("App Over Limit", isOn: asking($limits, "alertLimits"))
                .help("An app goes above its limit. Right-click an app > Alert Above to set one.")
        }
    }

    /// Turned on: ask macOS for permission.
    func asking(_ b: Binding<Bool>, _ key: String) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; if $0 { Alerts.allow(key) } })
    }
}

/// Right-click > Alert Above. A limit turns App Over Limit on too: else it does nothing.
struct LimitMenu: View {
    let g: Group

    var body: some View {
        Picker("Alert Above", selection: Binding(get: { UserDefaults.standard.limits[g.name] ?? 0 }, set: set)) {
            Text("Off").tag(0)
            ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) GB").tag($0 << 10) }
        }
    }

    func set(_ mb: Int) {
        let d = UserDefaults.standard
        var l = d.limits
        l[g.name] = mb > 0 ? mb : nil
        d.set(l, forKey: "limits")
        if mb > 0 && !d.bool(forKey: "alertLimits") { d.set(true, forKey: "alertLimits"); Alerts.allow("alertLimits") }
    }
}

/// After the name of a group with a limit. Slashed when its alert cannot come.
struct LimitBell: View {
    let g: Group
    @AppStorage("alertLimits") private var on = false  // so it changes at once with the toggle

    var body: some View {
        if let help = limitHelp(g, on: on) {
            ViewThatFits(in: .horizontal) {  // as UsageBadge: gone before the name truncates, as next to Stop
                Badge.bell(on: on && !g.ignored).help(help).accessibilityLabel(help)  // Legend.swift
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1.5)  // after the age badge (-1): a tie would let the bell take the age's room
        }
    }
}

/// Asserts for alertsToSend, run by selfTest.
func alertsTest() {
    let mb: Int64 = 1 << 20, me: uid_t = 501, all = AlertSettings(leftovers: true, pressure: true, growth: true, limits: true, limitMB: ["Slack": 2048])
    func g(_ name: String, _ m: Int64, leftover: Bool = false, uid: uid_t = 501) -> Group {
        Group(name: name, isApp: true, procs: [Proc(pid: 9, ppid: 1, uid: uid, path: "/x", mem: m * mb)], leftover: leftover)
    }
    var st = AlertState(), last: [Alert] = []
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func run(_ gs: [Group], _ at: TimeInterval, _ p: Pressure = .normal, growth: [String: String] = [:], with s: AlertSettings = all) -> [String] {
        var sys = SysMem()
        sys.pressure = p
        (st, last) = alertsToSend(prev: st, groups: gs, sys: sys, growth: growth, now: t0 + at, settings: s, uid: me)
        return last.map { "\($0.kind.rawValue) \($0.group ?? "")" }
    }

    // Leftovers: once per appearance, after 30 s (a quitting app's helpers), 500 MB or more.
    let cursor = [g("Cursor", 800, leftover: true)]
    precondition(run(cursor, 0) == [] && run(cursor, 29) == [])  // may be an app that quits
    precondition(run(cursor, 30) == ["leftover Cursor"])  // first appearance
    precondition(last[0].stop && last[0].title == "Leftover: Cursor" && last[0].body == "Cursor is not open. Its processes use 800 MB.")
    precondition(run(cursor, 90) == [] && run(cursor, 150) == [])  // still there
    precondition(run([], 210) == [] && st.leftovers.isEmpty && st.told.isEmpty)  // gone
    precondition(run(cursor, 270) == [] && run(cursor, 330) == ["leftover Cursor"])  // back: again
    precondition(run([], 400) == [] && run([g("Small", 300, leftover: true)], 400) == [] && run([g("Small", 300, leftover: true)], 500) == [])
    precondition(run([g("Small", 600, leftover: true)], 560) == ["leftover Small"])  // grew to 500 MB in the same appearance
    precondition(run([g("Root", 900, leftover: true, uid: 0)], 600) == [] && run([g("Root", 900, leftover: true, uid: 0)], 660) == ["leftover Root"])
    precondition(!last[0].stop)  // other users' processes: no Stop, as the row
    let sim = Group(name: "iOS Simulator", isApp: false, procs: [Proc(pid: 9, ppid: 1, uid: 0, path: "launchd_sim", mem: 900 * mb)], leftover: true)
    _ = run([sim], 700)
    precondition(run([sim], 760) == ["leftover iOS Simulator"] && last[0].stop && last[0].body.hasPrefix("A device is booted"))
    _ = run([], 800)
    var off = all
    off.leftovers = false; off.pressure = false; off.limits = false
    precondition(run(cursor, 800, with: off) == [] && run(cursor, 860, with: off) == [] && run(cursor, 920) == [])  // turned on: old ones stay quiet

    // Pressure: when it becomes critical, at most once in 30 min; names the 3 largest, not macOS.
    st = AlertState()
    let big = [g("A", 3000), g("macOS", 5000), g("B", 2000), g("C", 1000), g("D", 500)]
    precondition(run(big, 0, .critical) == ["pressure "] && last[0].body == "Largest: A 2.93 GB, B 1.95 GB, C 1000 MB")
    precondition(run(big, 60, .critical) == [] && run(big, 120, .warning) == [] && run(big, 180, .critical) == [])  // within 30 min
    precondition(run(big, 1000) == [] && run(big, 1800, .critical) == ["pressure "])
    precondition(run(big, 1900, .warning) == [] && run(big, 4000, .critical, with: off) == [] && run(big, 4100, .warning) == [])
    precondition(run(big, 4200, .critical) == ["pressure "])  // off: no alert, so no 30 min wait after it

    // Growth: when the badge turns on, at most once an hour for each group.
    st = AlertState()
    let slack = [g("Slack", 1500)], up = ["Slack": "+600 MB in 30 min"]
    precondition(run(slack, 0, growth: up) == ["growth Slack"] && last[0].body == "Memory +600 MB in 30 min, now 1.46 GB.")
    precondition(run(slack, 60, growth: up) == [] && run(slack, 120) == [] && run(slack, 180, growth: up) == [])  // badge flaps
    precondition(run(slack, 3500) == [] && run(slack, 3600, growth: up) == ["growth Slack"])

    // Limits: once per crossing, again only after 10% under; a group that is gone is under.
    st = AlertState()
    precondition(run([g("Slack", 2100)], 0) == ["limit Slack"] && last[0].title == "Slack is above 2 GB" && last[0].body == "It uses 2.05 GB.")
    precondition(run([g("Slack", 2200)], 60) == [] && run([g("Slack", 1900)], 120) == [] && run([g("Slack", 2100)], 180) == [])  // 1900 >= 90%
    precondition(run([g("Slack", 1800)], 240) == [] && run([g("Slack", 2100)], 300) == ["limit Slack"])  // 1800 < 1843
    precondition(run([], 360) == [] && run([g("Slack", 2100)], 420) == ["limit Slack"])
    precondition(run([], 480) == [] && run([g("Slack", 2100), g("Other", 9000)], 540, with: off) == [] && st.over == ["Slack"])
    precondition(run([g("Slack", 2100)], 600) == [])  // crossed while off: turned on, it stays quiet
    let d = UserDefaults(suiteName: "MemBar.selfTest")!  // registered only: in memory, no file
    d.register(defaults: ["limits": ["A": 2048, "B": 1 << 24, "C": 0, "D": 1 << 40, "E": "x"]])
    precondition(d.limits == ["A": 2048, "B": 1 << 24])  // 1 << 40 MB: limit * 9 traps

    // Ignored groups never alert: not as a leftover (ignoring() unflags it), not growing, not over a limit.
    st = AlertState()
    var ig = g("Slack", 9000)
    ig.ignored = true
    precondition(run([ig], 0, growth: up) == [] && run([ig], 60, growth: up) == [] && st == AlertState())
    precondition(limitText(2048) == "2 GB" && limitText(1500) == "1500 MB")
    precondition(limitHelp(g("Slack", 1), limits: ["Slack": 2048], on: true) == "Alert above 2 GB" && limitHelp(g("X", 1), limits: [:], on: true) == nil)
    precondition(limitHelp(g("Slack", 1), limits: ["Slack": 1024], on: false) == "Alert above 1 GB (off: Settings > Notifications > App Over Limit)")
    precondition(limitHelp(ig, limits: ["Slack": 1024], on: true) == "Alert above 1 GB (off: ignored apps never alert)")
}
