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

/// When `pid` started. sysctl, not proc_pidinfo: it works for other users' processes too.
func started(_ pid: pid_t) -> Date? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }  // size 0: gone
    let t = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
}

/// When each app was last frontmost, by group name. One workspace observer, no polling.
/// ponytail: frontmost is the only sign of use, so music that plays in the background
/// reads as idle; the badge only suggests a quit, it never acts.
enum Usage {
    private static let key = "lastFront"
    // ponytail: never pruned; one entry per app ever used, a few hundred at most.
    private static var seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    private static var front: String?  // frontmost now: in use, whatever its stamp says
    private static var saving = false

    static func start() {
        let ws = NSWorkspace.shared
        activated(ws.frontmostApplication)
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            activated(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private static func activated(_ app: NSRunningApplication?) {
        guard let path = app?.executableURL?.path else { return }
        let now = Date().timeIntervalSince1970, name = appOf(path).name
        if let f = front { seen[f] = now }  // it was frontmost until now
        front = name
        seen[name] = now
        save()
    }

    /// At most one write a minute. ponytail: switches in the last minute before a
    /// quit are lost; the next launch takes the frontmost app again.
    private static func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            saving = false
            if let f = front { seen[f] = Date().timeIntervalSince1970 }
            UserDefaults.standard.set(seen, forKey: key)
        }
    }

    static func idle(_ g: Group) -> TimeInterval? {
        let last = g.name == front ? Date() : seen[g.name].map(Date.init(timeIntervalSince1970:))
        return idleTime(g, lastFront: last, now: Date())
    }

    /// How long the oldest process of a leftover runs. Only for leftovers: a sysctl each.
    static func age(_ g: Group) -> TimeInterval? {
        guard g.leftover, let first = g.procs.compactMap({ started($0.pid) }).min() else { return nil }
        return -first.timeIntervalSinceNow
    }

    /// "for 2 d" after a leftover, "idle 3 h" after an idle app, and the help for it.
    static func note(_ g: Group) -> (word: String, age: String, help: String)? {
        if let t = age(g) { return ("for", ago(t), "Its oldest process started \(ago(t)) ago") }
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
                Text("\(n.word) \(n.age)")
                Text(n.age)
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.caption2).foregroundStyle(.secondary).help(n.help)
            .layoutPriority(-1)  // gets what is left after the name and the columns
        }
    }
}

/// Header line "Idle apps use 3.20 GB", when there are idle apps.
struct IdleLine: View {
    let groups: [Group]
    var body: some View {
        let mem = groups.filter { Usage.idle($0) != nil }.reduce(0) { $0 + $1.mem }
        if mem > 0 {
            Text("Idle apps use \(fmt(mem))").font(.caption).foregroundStyle(.secondary)
                .help("Open apps with 500 MB or more, not used for 2 hours or more")
        }
    }
}
