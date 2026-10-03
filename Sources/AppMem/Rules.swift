import AppKit
import SwiftUI

// Two per-app rules from the right-click menu, both off until set. Restart When Above: an
// app that leaks (Electron) is restarted when it is above its limit and not in use. Pause
// When in Background (as App Tamer): SIGSTOP after 5 min in the background, SIGCONT when the
// user switches to it. The decisions are pure (restarts, PauseState), see rulesTest; Rules
// acts on them in each scan, also with the panel closed (60 s). UserDefaults keys:
// "restartAbove" ([String: Int], group name → MB), "pauseInBackground" ([String: Bool]).

let restartChoices = [2048, 4096, 8192]  // MB, as the right-click menu offers them

/// The limit of `name`'s Restart When Above rule; nil for none or a value the menu does not offer.
func restartRule(_ name: String, _ rules: [String: Int] = UserDefaults.standard.restartAbove) -> Int? {
    rules[name].flatMap { restartChoices.contains($0) ? $0 : nil }
}

/// Not an Apple app (Safari, Xcode, Mail): macOS keeps those, and they do not leak as Electron
/// apps do. nil: no app runs at the group's .app.
func restartable(_ bundleID: String?) -> Bool { bundleID.map { !$0.hasPrefix("com.apple.") } ?? false }

/// The open apps to restart now: above the rule's limit and not frontmost for 30 min, counted
/// from the rule's start at the latest (`ruled`: name → the first scan that saw it), so a rule set
/// on an app that is big and idle already waits too. A never-seen-frontmost app counts from the
/// rule: AppMem watched it since then. Never the frontmost app, never one with a paused process
/// (it cannot answer the quit), never an Apple app or a bare executable (`bundleID`: of the app at
/// the group's .app), at most once in 6 h for each app (`restarted`: name → the last try).
func restarts(_ groups: [Group], rules: [String: Int], ruled: [String: Date], lastFront: (String) -> Date?, frontmost: String?,
              restarted: [String: Date], bundleID: (Group) -> String?, now: Date) -> [Group] {
    groups.filter { g in
        guard let mb = restartRule(g.name, rules), !g.leftover, !g.ignored, g.isApp, g.name != frontmost, g.mem > Int64(mb) << 20,
              !g.procs.contains(where: \.stopped), restarted[g.name].map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true,
              now.timeIntervalSince(max(lastFront(g.name) ?? .distantPast, ruled[g.name] ?? now)) >= 30 * 60 else { return false }
        return restartable(bundleID(g))
    }
}

/// What a pause stops: the app's own processes that run and may get a signal (maySignal), in
/// its .app or an XPC service (WebKit's web pages). Not the command-line jobs it started (a
/// terminal's shells and builds, an editor's dev server, an agent): a paused build is lost time,
/// not saved CPU, and switching to the app would not show why it hangs.
func pauseTargets(_ g: Group, uid: uid_t = getuid(), me: pid_t = getpid()) -> [Proc] {
    guard let b = g.bundle else { return [] }
    return g.procs.filter { !$0.stopped && ($0.path.hasPrefix(b + "/") || $0.path.contains(".xpc/")) && maySignal($0, in: g, uid: uid, me: me) }
}

/// Pause When in Background between scans. Main thread only, in Rules.
struct PauseState {
    var clock: [String: Date] = [:]  // app name → when its wait last started: the first scan with the rule, or a resume
    var paused: [String: Group] = [:]  // app name → the processes AppMem stopped: only these are resumed, not a Pause by hand

    /// Each scan: the apps to pause now, and the pauses to undo as their rule is gone. Paused: an open
    /// app (not a leftover, not ignored) with the rule, a regular one (switching to it resumes it; a
    /// menu bar app has no Dock icon to click), not frontmost, in the background for 5 min since it
    /// was last frontmost or since its clock started, the later. A pause is forgotten only by a
    /// resume or when the app is gone: a scan from before the SIGSTOP still reads it as running.
    mutating func step(_ groups: [Group], rules: [String: Bool], lastFront: (String) -> Date?, frontmost: String?,
                       regular: (Group) -> Bool, now: Date, uid: uid_t = getuid(), me: pid_t = getpid()) -> (pause: [Group], resume: [Group]) {
        let on = Set(rules.filter(\.value).keys), names = Set(groups.map(\.name))
        let off = paused.filter { !on.contains($0.key) }.map(\.value)
        paused = paused.filter { on.contains($0.key) && names.contains($0.key) }  // gone: its processes quit
        clock = Dictionary(uniqueKeysWithValues: on.map { ($0, clock[$0] ?? now) })
        var pause: [Group] = []
        for g in groups where on.contains(g.name) && paused[g.name] == nil && !g.leftover && !g.ignored && g.name != frontmost {
            guard now.timeIntervalSince(max(lastFront(g.name) ?? .distantPast, clock[g.name] ?? now)) >= 5 * 60, regular(g) else { continue }
            var own = g
            own.procs = pauseTargets(g, uid: uid, me: me)
            if !own.procs.isEmpty { paused[g.name] = own; pause.append(own) }
        }
        return (pause, off)
    }

    /// `name` came to the front or its row's menu opened: what AppMem paused of it. Its wait starts again.
    mutating func resume(_ name: String, now: Date) -> Group? {
        guard let g = paused.removeValue(forKey: name) else { return nil }
        clock[name] = now
        return g
    }

    /// AppMem quits: all it paused.
    mutating func resumeAll() -> [Group] { defer { paused = [:] }; return Array(paused.values) }
}

/// `log` with `e` on top and no older entry of the same app and kind: an app paused each time it
/// goes to the background would push the stops out of the 20 lines.
func loggedOnce(_ log: [Freed.Entry], _ e: Freed.Entry) -> [Freed.Entry] { logged(log.filter { $0.name != e.name || $0.how != e.how }, [e]) }

let pauseWarning = "Paused apps cannot play audio, sync or receive messages"

/// The row's symbols and their help, for an open app with a rule. `paused`: AppMem paused it now.
func ruleNotes(restart mb: Int?, pause: Bool, paused: Bool) -> [(symbol: String, help: String)] {
    (mb.map { [("arrow.clockwise.circle", "Restarts above \(limitText($0)) when not used for 30 min, at most once in 6 hours")] } ?? [])
        + (!pause ? [] : paused ? [("pause.circle.fill", "Paused in the background: it resumes when you switch to it. \(pauseWarning)")]
            : [("pause.circle", "Pauses after 5 min in the background, resumes when you switch to it. \(pauseWarning)")])
}

extension UserDefaults {
    var restartAbove: [String: Int] { dictionary(forKey: "restartAbove") as? [String: Int] ?? [:] }
    var pauseInBackground: [String: Bool] { dictionary(forKey: "pauseInBackground") as? [String: Bool] ?? [:] }
}

/// The rules' memory and their actions. Main thread only, like Usage.
enum Rules {
    private static var pauses = PauseState()
    private static var ruled: [String: Date] = [:]  // app name → the first scan that saw its Restart When Above rule
    // ponytail: in RAM only, so an AppMem restart forgets the 6 h; the 30 min wait from launch still holds.
    private static var restarted: [String: Date] = [:]  // app name → the last restart that the rule tried
    private static var term: DispatchSourceSignal?

    /// At launch: resume at once when the user switches to a paused app, and before AppMem exits.
    static func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.executableURL?.path { resume(appOf(path).name) }
        }
        // queue nil: on the posting (main) thread, before the exit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in resumeAll() }
        // `kill` and `killall AppMem` skip willTerminate: resume, then exit as SIGTERM would.
        // ponytail: a crash or SIGKILL leaves them paused; the row's Resume or `kill -CONT` undoes it.
        signal(SIGTERM, SIG_IGN)
        term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term?.setEventHandler { resumeAll(); exit(0) }
        term?.resume()
    }

    /// Each scan, from Model.refresh.
    static func check(_ groups: [Group]) {
        let d = UserDefaults.standard, now = Date(), restart = d.restartAbove
        let front = NSWorkspace.shared.frontmostApplication?.executableURL.map { appOf($0.path).name }
        ruled = Dictionary(uniqueKeysWithValues: restart.keys.map { ($0, ruled[$0] ?? now) })
        for g in restarts(groups, rules: restart, ruled: ruled, lastFront: Usage.lastFront, frontmost: front, restarted: restarted,
                          bundleID: { Actions.runningApp($0)?.bundleIdentifier }, now: now) {
            guard let app = Actions.runningApp(g), let url = app.bundleURL, let mb = restartRule(g.name, restart) else { continue }
            restarted[g.name] = now
            // Never forceTerminate: the app can ask to save, or cancel; then it is not opened again.
            // Behind the front app: the user works there. Counted once it has quit.
            // ponytail: counts all it held; the new copy takes some of it back.
            Actions.quit(g, app)
            Actions.whenQuit(app, within: 60) {
                Freed.record([g], how: "Restart above \(limitText(mb))")
                let c = NSWorkspace.OpenConfiguration()
                c.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: c)
            }
        }
        let (pause, resume) = pauses.step(groups, rules: d.pauseInBackground, lastFront: Usage.lastFront, frontmost: front,
                                          regular: { Actions.runningApp($0)?.activationPolicy == .regular }, now: now)
        resume.forEach { Actions.send(SIGCONT, $0.procs, in: $0) }
        for g in pause {
            Actions.send(SIGSTOP, g.procs, in: g)
            let e = Freed.Entry(at: now, name: g.name, mem: g.mem, how: "Background pause")  // logged, not freed: it keeps its memory
            d.set(try? JSONEncoder().encode(loggedOnce(Freed.log, e)), forKey: "recentActions")
        }
    }

    static func resume(_ name: String) {
        if let g = pauses.resume(name, now: Date()) { Actions.send(SIGCONT, g.procs, in: g) }
    }

    static func resumeAll() { for g in pauses.resumeAll() { Actions.send(SIGCONT, g.procs, in: g) } }

    /// The row's symbols: only where the rules act, an open app.
    static func notes(_ g: Group) -> [(symbol: String, help: String)] {
        let mb = restartRule(g.name), pause = UserDefaults.standard.pauseInBackground[g.name] == true
        guard mb != nil || pause, !g.leftover, !g.ignored, Actions.runningApp(g) != nil else { return [] }
        return ruleNotes(restart: mb, pause: pause, paused: pauses.paused[g.name] != nil)
    }

    /// For VoiceOver on the row.
    static func help(_ g: Group) -> String? { let h = notes(g).map(\.help); return h.isEmpty ? nil : h.joined(separator: ". ") }

    /// A menu writes a rule: rescan, so the row's symbol shows at once.
    static func set(_ key: String, _ name: String, _ value: Any?) {
        var r = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        r[name] = value
        UserDefaults.standard.set(r, forKey: key)
        (NSApp.delegate as? Delegate)?.model.refresh()
    }
}

// MARK: - UI

/// Right-click on an open app's row (`app`: it runs at the group's .app). `signals`: Pause applies to some of its processes.
struct RuleMenus: View {
    let g: Group, app: NSRunningApplication, signals: Bool

    var body: some View {
        // SwiftUI builds a context menu's items when it opens (checked: not with the row), so each open
        // resumes the app if AppMem paused it: the user is about to act on it.
        let _ = Rules.resume(g.name)
        if restartable(app.bundleIdentifier) {
            Picker("Restart When Above", selection: Binding(get: { restartRule(g.name) ?? 0 },
                                                            set: { Rules.set("restartAbove", g.name, $0 > 0 ? $0 : nil) })) {
                Text("Off").tag(0)
                ForEach(restartChoices, id: \.self) { Text(limitText($0)).tag($0) }
            }
            .help("For an app that leaks: above the limit and not used for 30 min, it is asked to quit (it can save first) and opens again. At most once in 6 hours.")
        }
        if signals && app.activationPolicy == .regular {
            Toggle("Pause When in Background", isOn: Binding(get: { UserDefaults.standard.pauseInBackground[g.name] == true }, set: { on in
                Rules.set("pauseInBackground", g.name, on ? true : nil)
                if !on { Rules.resume(g.name) }
            }))
            .help("After 5 min in the background its processes are paused; switching to it resumes them. \(pauseWarning).")
        }
    }
}

/// After the name, as the limit bell: gone before the name truncates.
struct RuleBadges: View {
    let g: Group

    var body: some View {
        let notes = Rules.notes(g)
        if !notes.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(notes, id: \.symbol) { n in Image(systemName: n.symbol).flag().help(n.help + ". Right-click to change.").accessibilityLabel(n.help) }
                }
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1)
        }
    }
}

/// Asserts for the rules above, run by selfTest. Fake data only: these rules act.
func rulesTest() {
    let t0 = Date(timeIntervalSince1970: 1_000_000), m: TimeInterval = 60, h: TimeInterval = 3600, mb: Int64 = 1 << 20
    let slackApp = "/Applications/Slack.app"
    func proc(_ pid: pid_t, _ path: String, uid: uid_t = 501, stopped: Bool = false, _ size: Int64 = 1000) -> Proc {
        Proc(pid: pid, ppid: 1, uid: uid, path: path, mem: size * mb, stopped: stopped)
    }
    func app(_ name: String, _ size: Int64, isApp: Bool = true) -> Group {
        var g = Group(name: name, isApp: isApp, procs: [proc(10, "/Applications/\(name).app/Contents/MacOS/\(name)", size)])
        g.bundle = "/Applications/\(name).app"
        return g
    }

    // Restart When Above: Slack 5 GB, rule 4 GB, not frontmost for 2 h.
    precondition(restartRule("A", ["A": 4096]) == 4096 && restartRule("A", ["A": 1000]) == nil && restartRule("B", ["A": 4096]) == nil)
    precondition(restartable("com.tinyspeck.slackmacgap") && !restartable("com.apple.dt.Xcode") && !restartable(nil))
    let slack = app("Slack", 5000), rules = ["Slack": 4096]
    func restart(_ gs: [Group], rules: [String: Int] = rules, front: String? = nil, last: Date? = t0 - 2 * h, ruled: Date = t0 - 9 * h,
                 restarted: [String: Date] = [:], id: String? = "com.tinyspeck.slackmacgap", at: Date = t0) -> [String] {
        restarts(gs, rules: rules, ruled: ["Slack": ruled], lastFront: { _ in last }, frontmost: front,
                 restarted: restarted, bundleID: { _ in id }, now: at).map(\.name)
    }
    precondition(restart([slack]) == ["Slack"])
    precondition(restart([app("Slack", 4096)]).isEmpty && restart([slack], rules: ["Slack": 8192]).isEmpty)  // at the limit, under it
    precondition(restart([slack], last: t0 - 30 * m + 1).isEmpty && restart([slack], last: t0 - 30 * m) == ["Slack"])  // 29:59 in the background
    precondition(restart([slack], last: nil) == ["Slack"] && restart([slack], last: nil, ruled: t0 - 29 * m).isEmpty)  // never front: from the rule
    precondition(restart([slack], ruled: t0 - 30 * m + 1).isEmpty && restart([slack], ruled: t0 - 30 * m) == ["Slack"])  // a rule set on an idle app waits
    precondition(restart([slack], front: "Slack").isEmpty)
    precondition(restart([slack], restarted: ["Slack": t0 - 6 * h + 1]).isEmpty && restart([slack], restarted: ["Slack": t0 - 6 * h]) == ["Slack"])
    var pausedSlack = slack
    pausedSlack.procs.append(proc(11, slackApp + "/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", stopped: true, 1))
    precondition(restart([pausedSlack]).isEmpty)  // it cannot answer the quit
    precondition(restart([slack], id: "com.apple.Safari").isEmpty && restart([slack], id: nil).isEmpty && restart([app("Slack", 5000, isApp: false)]).isEmpty)
    var left = slack
    left.leftover = true
    precondition(restart([left]).isEmpty && restart(ignoring([left], ["Slack"])).isEmpty)

    // Pause When in Background: what it stops.
    let helper = slackApp + "/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
    let web = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
    var s = slack
    s.procs += [proc(11, helper), proc(12, web), proc(13, "/opt/homebrew/bin/node"), proc(14, "/bin/zsh"), proc(15, helper, uid: 502),
                proc(16, helper, stopped: true)]
    precondition(pauseTargets(s, uid: 501, me: 99).map(\.pid) == [10, 11, 12])  // not its jobs, other users', paused ones
    precondition(pauseTargets(s, uid: 501, me: 11).map(\.pid) == [10, 12] && pauseTargets(Group(name: "x", isApp: true, procs: s.procs), uid: 501, me: 99).isEmpty)

    // The clock starts when the rule is first seen; 5 min in the background, then a pause.
    var st = PauseState()
    let on = ["Slack": true]
    var last: Date? = t0 - h, front: String? = nil
    func step(_ gs: [Group] = [s], rules: [String: Bool] = on, regular: Bool = true, at: TimeInterval) -> (pause: [String], resume: [String]) {
        let r = st.step(gs, rules: rules, lastFront: { _ in last }, frontmost: front, regular: { _ in regular }, now: t0 + at, uid: 501, me: 99)
        return (r.pause.map(\.name), r.resume.map(\.name))
    }
    precondition(step(at: 0).pause.isEmpty && st.clock == ["Slack": t0] && step(at: 5 * m - 1).pause.isEmpty)
    precondition(step(regular: false, at: 5 * m).pause.isEmpty)  // a menu bar app: nothing would resume it
    front = "Slack"
    precondition(step(at: 5 * m).pause.isEmpty)  // frontmost
    front = nil; last = t0 + 4 * m  // it left the front at 4:00
    precondition(step(at: 9 * m - 1).pause.isEmpty && step(at: 9 * m).pause == ["Slack"] && st.paused["Slack"]!.procs.map(\.pid) == [10, 11, 12])
    precondition(step(at: 20 * m).pause.isEmpty)  // never twice: a scan from before the SIGSTOP still reads it as running
    // Switching to it resumes only what AppMem paused (not 16, paused by hand), and the wait starts again.
    precondition(st.resume("Other", now: t0 + 21 * m) == nil && st.resume("Slack", now: t0 + 21 * m)!.procs.map(\.pid) == [10, 11, 12])
    precondition(st.paused.isEmpty && st.clock["Slack"] == t0 + 21 * m && st.resume("Slack", now: t0 + 22 * m) == nil)
    precondition(step(at: 26 * m - 1).pause.isEmpty && step(at: 26 * m).pause == ["Slack"])  // 5 min after the resume (the menu's)
    // The rule turned off: resumed at once. A pause by hand only is not AppMem's to claim.
    precondition(step(rules: [:], at: 27 * m) == ([], ["Slack"]) && st.paused.isEmpty && st.clock.isEmpty)
    var byHand = s
    for i in byHand.procs.indices { byHand.procs[i].stopped = true }
    precondition(step([byHand], at: 30 * m).pause.isEmpty && step([byHand], at: 40 * m).pause.isEmpty && st.paused.isEmpty)
    precondition(step(rules: ["Slack": false], at: 50 * m).pause.isEmpty && st.clock.isEmpty)  // false is off
    // Quit while paused: forgotten. AppMem quits: everything it paused, once.
    _ = step(at: 60 * m)
    precondition(step(at: 65 * m).pause == ["Slack"] && step([], at: 66 * m) == ([], []) && st.paused.isEmpty)
    var zoom = app("Zoom", 300)
    zoom.procs[0] = proc(20, "/Applications/Zoom.app/Contents/MacOS/zoom")
    precondition(step([s, zoom], rules: ["Slack": true, "Zoom": true], at: 70 * m).pause == ["Slack"])  // its clock from 60:00
    precondition(step([s, zoom], rules: ["Slack": true, "Zoom": true], at: 75 * m).pause == ["Zoom"])
    precondition(Set(st.resumeAll().map(\.name)) == ["Slack", "Zoom"] && st.paused.isEmpty && st.resumeAll().isEmpty)
    var leftover = s
    leftover.leftover = true
    precondition(step([leftover], at: 90 * m).pause.isEmpty && step(ignoring([leftover], ["Slack"]), at: 90 * m).pause.isEmpty)

    // The log keeps one pause line per app; the symbols and their help.
    let e = { (name: String, how: String, at: TimeInterval) in Freed.Entry(at: t0 + at, name: name, mem: 1, how: how) }
    let log = [e("Slack", "Background pause", 2), e("Cursor", "Stop", 1), e("Slack", "Stop", 0)]
    precondition(loggedOnce(log, e("Slack", "Background pause", 3)).map { "\($0.name) \($0.how)" } == ["Slack Background pause", "Cursor Stop", "Slack Stop"])
    precondition(loggedOnce(log, e("Zoom", "Background pause", 3)).count == 4)
    precondition(ruleNotes(restart: nil, pause: false, paused: false).isEmpty)
    precondition(ruleNotes(restart: 4096, pause: true, paused: false).map(\.symbol) == ["arrow.clockwise.circle", "pause.circle"])
    precondition(ruleNotes(restart: 2048, pause: false, paused: false)[0].help == "Restarts above 2 GB when not used for 30 min, at most once in 6 hours")
    precondition(ruleNotes(restart: nil, pause: true, paused: true)[0].help.hasPrefix("Paused in the background: it resumes when you switch to it. Paused apps"))
}
