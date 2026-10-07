import AppKit
import SwiftUI

// Right-click actions on groups and processes, and Stop All. The rules (who may get a
// signal, which items apply) are pure, see selfTest. Each signal re-checks its process
// right before it goes out, with Stop's `same`.

/// Which menu items apply. Force Quit applies when Quit does.
struct Allowed: Equatable { var quit = false, restart = false, pause = false, resume = false }

/// May the menu signal `p`? Only this user's processes; never launchd, MemBar or its
/// children (a paused top would hang the scan); never the macOS group; Apple's own
/// programs only in a third-party app's group (SIGTERM to loginwindow logs out); the iOS
/// Simulator only by Stop, as simctl shuts devices down cleanly.
func maySignal(_ p: Proc, in g: Group, uid: uid_t = getuid(), me: pid_t = getpid()) -> Bool {
    p.uid == uid && p.pid > 1 && p.pid != me && p.ppid != me && g.name != "macOS" && !g.isSimulator
        && (g.isApp || !systemPrefixes.contains { p.path.hasPrefix($0) })
}

/// Which items apply to processes `ps` of `g`: an item applies when it applies to one of them.
func allowed(_ ps: [Proc], in g: Group, uid: uid_t = getuid(), me: pid_t = getpid()) -> Allowed {
    let mine = ps.filter { maySignal($0, in: g, uid: uid, me: me) }
    return Allowed(quit: !mine.isEmpty, pause: mine.contains { !$0.stopped }, resume: mine.contains(where: \.stopped))
}

/// `app`: an app runs at the group's .app, so Quit asks it to quit. Without one, Quit
/// signals quitProcs.
func allowed(_ g: Group, app: Bool, uid: uid_t = getuid(), me: pid_t = getpid()) -> Allowed {
    var a = allowed(g.procs, in: g, uid: uid, me: me)
    a.restart = app && g.name != "macOS"; a.quit = a.restart || allowed(quitProcs(g), in: g, uid: uid, me: me).quit
    return a
}

/// What the group's Quit signals with no app to ask: not Apple's VM process (Containers.swift).
/// Its tool (limactl, vfkit, Docker's) powers the guest off cleanly on SIGTERM, and the VM ends
/// with it; a signal to the VM at the same moment cuts the guest off mid-write. Its own line still
/// can, as for a VM whose tool is gone.
func quitProcs(_ g: Group) -> [Proc] { g.procs.filter { !isVMPath($0.path) || !systemPrefixes.contains(where: $0.path.hasPrefix) } }

/// The "paused" badge: all of this user's processes in `g` are stopped.
func isPaused(_ g: Group, uid: uid_t = getuid()) -> Bool {
    let mine = g.procs.filter { $0.uid == uid }
    return !mine.isEmpty && mine.allSatisfy(\.stopped)
}

/// "Copy Summary": the group as plain text, to paste in a chat or a bug report.
func summaryText(_ g: Group) -> String {
    let top = g.procs.prefix(10).map {
        "  \(fmt($0.mem))  CPU \(cpu($0.cpu))  PID \($0.pid)  \($0.name)" + ($0.ports.isEmpty ? "" : "  " + portsText($0.ports))
    }
    return (["\(g.name): \(fmt(g.mem)), CPU \(cpu(g.cpu)), \(g.procs.count) processes"] + top).joined(separator: "\n")
}

/// The part that acts: signals, apps, the pasteboard, Finder.
enum Actions {
    /// `sig` to each of `procs` that maySignal allows and that is still the process from
    /// the scan (same PID, same executable), checked right before its signal.
    static func send(_ sig: Int32, _ procs: [Proc], in g: Group) {
        for p in procs where maySignal(p, in: g) && same(p) {
            kill(p.pid, sig)
            // A paused process acts on SIGTERM only once it runs. Always: p.stopped is from
            // the last scan, so a Pause since then is not in it; SIGCONT does nothing to a running one.
            if sig == SIGTERM { kill(p.pid, SIGCONT) }
        }
    }

    /// The app that runs at the group's .app. Of Apple's own, only apps with a Dock icon:
    /// loginwindow, Dock or ControlCenter are not for quitting.
    static func runningApp(_ g: Group) -> NSRunningApplication? {
        guard let b = g.bundle else { return nil }
        let apple = systemPrefixes.contains { b.hasPrefix($0) }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == b && $0.processIdentifier != getpid() && (!apple || $0.activationPolicy == .regular)
        }
    }

    /// With an app: ask it to quit (it can save first, or cancel), or force it. Without:
    /// SIGTERM or SIGKILL to the group's processes, but Apple's VM process (quitProcs).
    static func quit(_ g: Group, _ app: NSRunningApplication?, force: Bool = false) {
        guard let app else { return send(force ? SIGKILL : SIGTERM, quitProcs(g), in: g) }
        send(SIGCONT, g.procs, in: g)  // a paused app cannot answer; all, as stopped can be old
        _ = force ? app.forceTerminate() : app.terminate()
    }

    /// Quit, then open it again once it has exited.
    static func restart(_ g: Group, _ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        quit(g, app)
        whenQuit(app) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    /// `then` on the main thread once `app` has exited, waited for off the main thread. Never
    /// if it still runs after `within` s, or 60 s after it came to the front: the user may have
    /// cancelled the quit (to answer a save dialog, they bring the app to the front).
    static func whenQuit(_ app: NSRunningApplication, within: TimeInterval = 10, then: @escaping () -> Void) {
        DispatchQueue.global().async {
            var end = Date() + within
            while !app.isTerminated, Date() < end {
                if app.isActive { end = min(end, Date() + 60) }
                Thread.sleep(forTimeInterval: within > 60 ? 1 : 0.2)  // a wait of hours: once a second is enough
            }
            if app.isTerminated { DispatchQueue.main.async(execute: then) }
        }
    }

    /// Force Quit asks first: the process gets no chance to save.
    static func confirmForceQuit(_ what: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Force quit \(what)?"
        a.informativeText = "It stops at once. Changes that are not saved are lost."
        a.addButton(withTitle: "Force Quit").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Right-click menu of a group row. Items that cannot apply are disabled or hidden.
/// ponytail: it acts on the processes of the last scan (at most 5 s old with the panel
/// open), so a process started since then is not paused or quit. Rescan first if needed.
struct GroupMenu: View {
    let g: Group

    var body: some View {
        let app = Actions.runningApp(g), a = allowed(g, app: app != nil)
        let file = g.bundle ?? g.procs.first { $0.path.hasPrefix("/") }?.path
        Button("Show Details…") { Details.show(g) }  // Details.swift
        Divider()
        Button("Quit \(g.name)") { Actions.quit(g, app) }.disabled(!a.quit)
        Button("Force Quit \(g.name)…") { if Actions.confirmForceQuit(g.name) { Actions.quit(g, app, force: true) } }
            .disabled(!a.quit)
        if let app, a.restart { Button("Restart \(g.name)") { Actions.restart(g, app) } }
        if a.restart && !g.leftover { Divider(); QuitIdleMenu(g: g) }  // restart: an app runs at the group's .app; divider: rules apart from act-now items
        if let app, a.restart && !g.leftover { RuleMenus(g: g, app: app, signals: a.pause || a.resume) }  // Rules.swift
        Divider()
        if a.resume { Button("Resume") { Actions.send(SIGCONT, g.procs.filter(\.stopped), in: g) } }
        if a.pause || !a.resume {
            Button("Pause") { Actions.send(SIGSTOP, g.procs.filter { !$0.stopped }, in: g) }.disabled(!a.pause)
        }
        if let job = g.agentLabel { Divider(); AgentItems(label: job) }  // Agents.swift: what starts it again after Stop
        Divider()
        Button("Reveal in Finder") { file.map(Actions.reveal) }.disabled(file == nil)
        Button("Copy Summary") { Actions.copy(summaryText(g)) }
        Divider()  // what MemBar tells about this app
        LimitMenu(g: g)  // Alerts.swift
        // Settings > Never Flagged lists the same names; Model rescans when the list changes.
        let ignored = UserDefaults.standard.ignored.contains(g.name)
        // The groups that can be leftovers, and an ignored one: an orphan's badge goes with the ignore, its undo stays.
        if g.isApp || g.isSimulator || g.orphan || ignored {
            // An ignored group has no flag left to name, so the undo says neither.
            Button(ignored ? "Flag Again" : g.orphan ? "Never Flag as Orphan" : "Never Flag as Leftover") {
                let rest = UserDefaults.standard.ignored.filter { $0 != g.name }
                UserDefaults.standard.set(rest + (ignored ? [] : [g.name]), forKey: "ignored")
            }
        }
    }
}

/// Right-click menu of a process line in an expanded group.
struct ProcMenu: View {
    let p: Proc, g: Group

    var body: some View {
        let a = allowed([p], in: g)
        Button("Quit") { Actions.send(SIGTERM, [p], in: g) }.disabled(!a.quit)
        Button("Force Quit…") { if Actions.confirmForceQuit("\(p.name) (PID \(p.pid))") { Actions.send(SIGKILL, [p], in: g) } }
            .disabled(!a.quit)
        if p.stopped {
            Button("Resume") { Actions.send(SIGCONT, [p], in: g) }.disabled(!a.resume)
        } else {
            Button("Pause") { Actions.send(SIGSTOP, [p], in: g) }.disabled(!a.pause)
        }
        Divider()
        Button("Reveal in Finder") { Actions.reveal(p.path) }.disabled(!p.path.hasPrefix("/"))
        Button("Copy Path") { Actions.copy(p.path) }
        Button("Copy PID") { Actions.copy(String(p.pid)) }
        InspectMenu(p: p)  // Inspect.swift: Sample, Open Files and Ports, Environment
    }
}

extension Model {
    /// The header's Stop All: Stop for each leftover, with Stop's own checks. `only`: the quick
    /// menu's, the ids of the leftovers it named; the ones that are still leftovers now.
    func stopAll(only ids: Set<String>? = nil) { stopGroups(groups.filter { $0.leftover && ids?.contains($0.id) ?? true }, how: "Stop All") }
}
