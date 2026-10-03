import AppKit
import SwiftUI

// Rules that act with no click, and what the stops freed. Auto-stop (Settings): a
// leftover that stays one for 10 min or 1 h gets Stop. Quit When Idle (right-click on an
// open app): the app is asked to quit after hours in the background. Both run in each
// scan, also with the panel closed (60 s); the decisions are pure, see selfTest.
// UserDefaults keys: "autoStop" (Int, minutes; 0 = off), "autoStopSimulator" (Bool),
// "quitIdle" ([String: Int], group name → minutes), "freedBytes" (Int), "freedSince"
// (seconds since 1970, as Usage stores times), "recentActions" (JSON, newest first).

/// Seconds a group must stay a leftover before auto-stop; nil = off. Checked: `defaults
/// write` can store anything.
func autoStopAfter(_ stored: Int) -> TimeInterval? { [10, 60].contains(stored) ? TimeInterval(stored * 60) : nil }

let quitIdleChoices = [60, 120, 240]  // minutes, as the right-click menu offers them

/// The minutes of `name`'s Quit When Idle rule; nil for none or a value the menu does not offer.
func idleRule(_ name: String, _ rules: [String: Int] = UserDefaults.standard.quitIdle) -> Int? {
    rules[name].flatMap { quitIdleChoices.contains($0) ? $0 : nil }
}

/// "1 hour", "4 hours".
func hours(_ minutes: Int) -> String { "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" }

/// What Stop acts on: the simulator (simctl), or a group with a process of this user.
func stoppable(_ g: Group, uid: uid_t = getuid()) -> Bool { g.isSimulator || g.procs.contains { $0.uid == uid } }

/// The groups a Stop still acts on: not one whose processes all were in its last Stop (a
/// double-click or Stop All before the rescan, Alerts and auto-stop in one scan, a slow
/// exit), so the freed total and the log count it once. A respawn has new PIDs.
func notStopped(_ gs: [Group], _ stopped: [String: Set<pid_t>]) -> [Group] {
    gs.filter { !Set($0.procs.map(\.pid)).isSubset(of: stopped[$0.id] ?? []) }
}

/// When each leftover was first seen as one, by group id: AppMem's own clock, not process
/// age, kept only while auto-stop is on (Auto.check), so a fresh launch or auto-stop turned
/// on never stops at once. A group that is not a leftover in this scan (it exited, its app
/// opened, it is ignored) drops out, so its clock starts again. So does one with a paused
/// process: the user keeps it on purpose, and Resume gets a full wait.
func leftoverClock(_ groups: [Group], since: [String: Date], now: Date) -> [String: Date] {
    Dictionary(uniqueKeysWithValues: groups.filter { $0.leftover && !$0.procs.contains(where: \.stopped) }.map { ($0.id, since[$0.id] ?? now) })
}

/// The leftovers to auto-stop now. Not one that respawns: macOS starts it again, so it
/// would be stopped again and again (Stop by hand still can). `simulator`: also the iOS
/// Simulator and the Android emulator, as both can be in use with no Simulator or Android
/// Studio window (an agent's device, an emulator run from VS Code). Never an orphan, also
/// when Settings counts it as a leftover: no app tells it is waste, and a server kept on
/// purpose looks the same. Never a group that Recall keeps a command-line job in: a server
/// started in the app's terminal and kept after the app quit (nohup, pg_ctl, pm2) looks
/// the same too. Stop by hand still can.
/// ponytail: an AI app's MCP servers that outlive it wait for Stop too.
func autoStops(_ groups: [Group], since: [String: Date], after: TimeInterval?, simulator: Bool, now: Date,
               uid: uid_t = getuid()) -> [Group] {
    guard let after else { return [] }
    return groups.filter { g in
        g.leftover && !g.orphan && !g.recalled && g.respawns == nil && stoppable(g, uid: uid) && (simulator || !g.isSimulator && !g.isEmulator)
            && since[g.id].map { now.timeIntervalSince($0) >= after } == true
    }
}

/// The open apps to quit now by their rule: not frontmost for that long, counted from the
/// rule's start at the latest (`ruled`: name → the first scan that saw the rule), so a rule
/// set on an app idle for hours does not quit it at once. Never when Usage has no time for
/// it (unknown is not idle), never the frontmost app, never one with a paused process (it
/// cannot answer the quit). `tried`: name → the last-front time of a quit already asked:
/// one ask per idle stretch, so an app whose user cancelled the quit (a save dialog) is not
/// asked again each minute.
/// ponytail: frontmost is the only sign of use (see Usage), so a player with a rule quits
/// while it plays in the background; check CPU or audio if that bites.
func idleQuits(_ groups: [Group], rules: [String: Int], ruled: [String: Date], lastFront: (String) -> Date?,
               frontmost: String?, tried: [String: Date], now: Date) -> [Group] {
    groups.filter { g in
        guard let m = idleRule(g.name, rules), !g.leftover, !g.ignored, g.name != "macOS", g.name != frontmost,
              !g.procs.contains(where: \.stopped), let last = lastFront(g.name), tried[g.name] != last else { return false }
        return now.timeIntervalSince(max(last, ruled[g.name] ?? last)) >= TimeInterval(m * 60)
    }
}

/// `log` with `new` on top: newest first, at most 20.
func logged<T>(_ log: [T], _ new: [T]) -> [T] { Array((new + log).prefix(20)) }

/// A Recent Actions item: "Oct 3, 2:05 PM  Auto-stop: Cursor, 1.20 GB".
func logLine(_ e: Freed.Entry) -> String {
    "\(e.at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))  \(e.how): \(e.name), \(fmt(e.mem))"
}

extension UserDefaults {
    @objc dynamic var quitIdle: [String: Int] { dictionary(forKey: "quitIdle") as? [String: Int] ?? [:] }
}

/// The freed total and the last 20 actions.
enum Freed {
    struct Entry: Codable { let at: Date, name: String, mem: Int64, how: String }

    static var log: [Entry] {
        UserDefaults.standard.data(forKey: "recentActions").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// `how`: "Stop", "Stop All", "Auto-stop" or "Idle quit". The memory of the last scan:
    /// what the group held when it was stopped.
    static func record(_ gs: [Group], how: String) {
        guard !gs.isEmpty else { return }
        let d = UserDefaults.standard, now = Date()
        d.set(d.integer(forKey: "freedBytes") + gs.reduce(0) { $0 + Int($1.mem) }, forKey: "freedBytes")
        if d.double(forKey: "freedSince") == 0 { d.set(now.timeIntervalSince1970, forKey: "freedSince") }
        let new = gs.map { Entry(at: now, name: $0.name, mem: $0.mem, how: how) }
        d.set(try? JSONEncoder().encode(logged(log, new)), forKey: "recentActions")
    }
}

/// The rules' memory between scans. Main thread only, like Usage.
enum Auto {
    private static var since: [String: Date] = [:]  // leftover id → the first scan that saw it as one
    private static var ruled: [String: Date] = [:]  // app name → the first scan that saw its rule
    private static var tried: [String: Date] = [:]  // app name → its last-front time when asked to quit

    /// Each scan, from Model.refresh.
    static func check(_ groups: [Group], _ model: Model) {
        let d = UserDefaults.standard, now = Date(), after = autoStopAfter(d.integer(forKey: "autoStop"))
        since = after == nil ? [:] : leftoverClock(groups, since: since, now: now)
        let stops = autoStops(groups, since: since, after: after, simulator: d.bool(forKey: "autoStopSimulator"), now: now)
        if !stops.isEmpty {
            // Still a leftover after it (slow to exit): a full wait again, not a stop each scan.
            // ponytail: a respawn later than Recall's 60 s is not marked, so it is stopped once each wait.
            for g in stops { since[g.id] = nil }
            model.stopGroups(stops, how: "Auto-stop")
        }
        let rules = d.quitIdle
        ruled = Dictionary(uniqueKeysWithValues: rules.keys.map { ($0, ruled[$0] ?? now) })
        guard !rules.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.executableURL.map { appOf($0.path).name }
        for g in idleQuits(groups, rules: rules, ruled: ruled, lastFront: Usage.lastFront, frontmost: front, tried: tried, now: now) {
            tried[g.name] = Usage.lastFront(g.name)
            // Never forceTerminate: the app can ask to save, or cancel. So counted once it has quit.
            // ponytail: one that quits later than 10 s (a save dialog answered later) is not counted.
            if let app = Actions.runningApp(g), app.terminate() { Actions.whenQuit(app) { Freed.record([g], how: "Idle quit") } }
        }
    }
}

// MARK: - UI

/// Gear menu items. `recent`: the log, read when the menu opens (see SettingsMenu).
struct AutoMenus: View {
    let recent: [Freed.Entry]
    @AppStorage("autoStop") private var autoStop = 0
    @AppStorage("autoStopSimulator") private var simulator = false

    var body: some View {
        Menu("Auto-Stop Leftovers") {
            Picker("Auto-Stop Leftovers", selection: $autoStop) {
                Text("Off").tag(0)
                Text("After 10 Minutes").tag(10)
                Text("After 1 Hour").tag(60)
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
            // Off by default: see autoStops.
            Toggle("Include Simulator and Emulator", isOn: $simulator).disabled(autoStopAfter(autoStop) == nil)
        }
        Menu("Recent Actions") {
            if recent.isEmpty { Text("None") }
            ForEach(recent.indices, id: \.self) { Text(logLine(recent[$0])) }
        }
    }
}

/// Right-click on an open app's row. Read in body, as GroupMenu's ignore item: Model
/// rescans when the rules change, so the row and this menu are made again.
struct QuitIdleMenu: View {
    let g: Group

    var body: some View {
        let rule = idleRule(g.name) ?? 0
        Picker("Quit When Idle", selection: Binding(get: { rule }, set: { m in
            var r = UserDefaults.standard.quitIdle
            r[g.name] = m == 0 ? nil : m
            UserDefaults.standard.set(r, forKey: "quitIdle")
        })) {
            Text("Never").tag(0)
            ForEach(quitIdleChoices, id: \.self) { Text(hours($0).capitalized).tag($0) }
        }
    }
}

/// Panel footer "Freed 12.40 GB since Oct 3", once a stop freed anything.
struct FreedLine: View {
    @AppStorage("freedBytes") private var bytes = 0
    @AppStorage("freedSince") private var since = 0.0

    var body: some View {
        if bytes > 0 {
            let d = Date(timeIntervalSince1970: since), day = Date.FormatStyle.dateTime.month(.abbreviated).day()
            Divider()
            Text("Freed \(fmt(Int64(bytes))) since \(d.formatted(Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? day : day.year()))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().padding(.vertical, 4)
                .help("Memory of the groups that Stop, Stop All, Auto-Stop and Quit When Idle ended, as it was at each stop. Settings > Recent Actions lists them.")
        }
    }
}
