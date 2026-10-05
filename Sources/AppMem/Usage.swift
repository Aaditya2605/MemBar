import AppKit
import SwiftUI

// Idle apps and leftover age. An open app that holds a lot of memory but was not
// used for hours is worth a quit; how long a leftover has run tells how stale it is.

/// "45 min", "3 h", "2 d": whole units, rounded down.
func ago(_ t: TimeInterval) -> String {
    let m = max(1, Int(t / 60))
    return m < 60 ? "\(m) min" : m < 1440 ? "\(m / 60) h" : "\(m / 1440) d"
}

/// How long `g` was not frontmost, when it is an open app with 500 MB or more that
/// was not used for 2 h or more. nil for an app never seen frontmost: unknown is not idle.
func idleTime(_ g: Group, lastFront: Date?, now: Date) -> TimeInterval? {
    // "macOS": a frontmost app with no .app bundle (a script's window) maps to it.
    // An ignored leftover is not flagged, but its app is still not open.
    guard !g.leftover, !g.ignored, g.name != "macOS", g.mem >= 500 << 20, let last = lastFront else { return nil }
    let t = now.timeIntervalSince(last)
    return t >= 2 * 3600 ? t : nil
}

/// How long leftover or orphan `g` has run: its oldest process; for the simulator, its first booted
/// device, as its group also holds CoreSimulator daemons that run for weeks.
func leftoverAge(_ g: Group, started: (pid_t) -> Date?, now: Date) -> TimeInterval? {
    guard g.leftover || g.orphan else { return nil }
    let procs = g.isSimulator ? g.procs.filter { $0.name == "launchd_sim" } : g.procs
    return procs.compactMap { started($0.pid) }.min().map { now.timeIntervalSince($0) }
}

/// One process's kernel record. sysctl, not proc_pidinfo: it works for other users' processes too.
func kinfo(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 ? info : nil  // size 0: gone
}

/// When `pid` started.
func started(_ pid: pid_t) -> Date? {
    guard let t = kinfo(pid)?.kp_proc.p_un.__p_starttime else { return nil }
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
}

/// The browser of a Chromium PWA's app shim (bundle ID `<browser>.app.<id>`): the browser draws
/// the shim's windows, so it is in use while the shim is in front.
func shimBrowser(_ id: String?) -> String? { id.flatMap { id in id.range(of: ".app.").map { String(id[..<$0.lowerBound]) } } }

/// When each app was last frontmost, by group name. One workspace observer, no polling.
/// ponytail: frontmost is the only sign of use, so music that plays in the background
/// reads as idle; the badge only suggests a quit. Only a Quit When Idle rule, set by hand, acts.
enum Usage {
    private static let key = "lastFront"
    // ponytail: never pruned; one entry per app ever used, a few hundred at most.
    private static var seen: [String: Double] = [:]
    private static var front: Set<String> = []  // frontmost now (inUse): in use, whatever its stamp says
    private static var saving = false

    static func start() {
        // Saved stamps count as now: AppMem did not see the time it was not running, and an
        // app used then is not idle. The names carry over: an app open from launch on and
        // never brought to the front (Slack at login) reads as idle 2 h later.
        let now = Date().timeIntervalSince1970
        seen = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { _ in now }
        let ws = NSWorkspace.shared
        activated(ws.frontmostApplication)
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            activated(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    /// The names that app `app` in front puts in use: its own, and a PWA's browser (shimBrowser).
    static func inUse(_ app: NSRunningApplication?) -> [String] {
        guard let path = app?.executableURL?.path else { return [] }
        let browser = shimBrowser(app?.bundleIdentifier).flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.executableURL }
        return [appOf(path).name] + (browser.map { [appOf($0.path).name] } ?? [])
    }

    private static func activated(_ app: NSRunningApplication?) {
        let names = inUse(app), now = Date().timeIntervalSince1970
        guard !names.isEmpty else { return }
        for f in front { seen[f] = now }  // they were frontmost until now
        front = Set(names)
        for n in names { seen[n] = now }
        save()
    }

    /// At most one write a minute. ponytail: an app first frontmost in the last minute
    /// before a quit is not saved; after the next launch it is not idle until it is frontmost once.
    private static func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            saving = false
            for f in front { seen[f] = Date().timeIntervalSince1970 }
            UserDefaults.standard.set(seen, forKey: key)
        }
    }

    /// When app `name` was last frontmost: now while it is, nil when never seen.
    static func lastFront(_ name: String) -> Date? { front.contains(name) ? Date() : seen[name].map(Date.init(timeIntervalSince1970:)) }

    static func idle(_ g: Group) -> TimeInterval? { idleTime(g, lastFront: lastFront(g.name), now: Date()) }

    /// Only for leftovers and orphans: a sysctl each.
    static func age(_ g: Group) -> TimeInterval? { leftoverAge(g, started: started, now: Date()) }

    /// "for 2 d" after a leftover, "idle 3 h" after an idle app, and the help for it.
    static func note(_ g: Group) -> (word: String, age: String, help: String)? {
        if let t = age(g) {
            return ("for", ago(t), g.isSimulator ? "The first device was booted \(ago(t)) ago" : "Its oldest process started \(ago(t)) ago")
        }
        if let t = idle(g) { return ("idle", ago(t), "Not used for \(ago(t)). Quit it to free \(fmt(g.mem)).") }
        return nil
    }
}

/// After the name. A leftover row also has a Stop button, so where space is short
/// the badge drops to "2 d", then to nothing, and the name keeps its width.
struct UsageBadge: View {
    let g: Group
    var body: some View {
        if let n = Usage.note(g) {
            ViewThatFits(in: .horizontal) {
                Badge.usage("\(n.word) \(n.age)")  // Legend.swift
                Badge.usage(n.age)
                Color.clear.frame(width: 0, height: 0)
            }
            .help(n.help)
            .layoutPriority(-1)  // gets what is left after the name and the columns
        }
    }
}
