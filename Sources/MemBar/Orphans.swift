import Darwin
import Foundation

// Orphans: dev servers, watchers and MCP servers that a terminal tab or an agent session
// started and left running. When it ends they move to launchd (ppid 1), and their group is
// their own name ("node") or, by the responsibility call, the app that is still open (the
// terminal, the agent's app): never a leftover. Recall knows their app only if MemBar saw
// it alive. Not waste unless Settings > Count Orphans as Leftovers is on: a server kept on
// purpose looks the same.

let orphanHelp = "Started from a terminal or an agent that is gone, and still running"  // the badge's

/// Orphans of `uid` and every process under them. An orphan: a command-line process
/// (isCLI: not in an .app, not Apple's, not tmux and the like, whose sessions are kept
/// on purpose) that launchd adopted (ppid 1) but does not run as a job, and `detached`.
/// Not one with a process on a live `terminal` under it: a session keeper that the name
/// list misses (mosh-server), whose pty holds the user's shell and its vim.
/// Never MemBar or its children: they are not in the walk.
func orphans(_ procs: [pid_t: Proc], jobs: Set<pid_t>, detached: (pid_t) -> Bool, terminal: (pid_t) -> Bool,
             uid: uid_t = getuid(), me: pid_t = getpid()) -> Set<pid_t> {
    var kids: [pid_t: [pid_t]] = [:]
    for p in procs.values where p.uid == uid && p.pid != me { kids[p.ppid, default: []].append(p.pid) }
    let roots = procs.values.filter {
        $0.uid == uid && $0.ppid == 1 && $0.pid != me && !jobs.contains($0.pid) && isCLI($0.path) && detached($0.pid)
    }
    var out: Set<pid_t> = []
    for r in roots {
        var tree: Set<pid_t> = [], todo = [r.pid]
        while let pid = todo.popLast() {
            if tree.insert(pid).inserted { todo += kids[pid] ?? [] }  // inserted: a PID loop ends
        }
        if !tree.contains(where: terminal) { out.formUnion(tree) }
    }
    return out
}

/// Each orphan moves to a group named after its top orphan (the one launchd adopted), as
/// when its app is gone: the responsibility call and Recall keep it in the group of an app
/// that is still open (the agent's app, the terminal app). Not out of a leftover or an
/// ignored app's group, where its app is known and quit, not out of the simulator's or the
/// emulator's (their own groups: the simulator's also when an agent booted it), not under an ignored name,
/// and not a VM's own processes (Containers.swift): the dev server next to them in that group still moves.
/// Then the orphan badge and its Stop: a group named after its own executable, not
/// ignored, whose processes of `uid` are all orphans. `asLeftover` (Settings): it is a
/// leftover too, for the dot, the waste total and Stop All.
/// ponytail: groups go by name, so one "node" job of launchd keeps the badge off the
/// orphan "node" next to it.
func orphaning(_ groups: [Group], _ orphans: Set<pid_t>, procs: [pid_t: Proc], ignored: [String], asLeftover: Bool,
               uid: uid_t = getuid()) -> [Group] {
    /// The name of `p`'s top orphan; nil when `p` or an orphan above it runs a VM (lima's ssh under
    /// limactl): Stop on its tools would cut the VM off.
    func name(_ p: Proc) -> String? {
        var t = p, vm = isVMPath(p.path)
        for _ in 0..<64 { guard let pp = procs[t.ppid], orphans.contains(pp.pid) else { break }; t = pp; vm = vm || isVMPath(t.path) }  // 64: a PID loop
        return vm ? nil : appOf(t.path).name
    }
    var gs = groups
    for i in gs.indices where !gs[i].leftover && !gs[i].ignored && !gs[i].isSimulator && !gs[i].isEmulator {
        let away = gs[i].procs.filter { orphans.contains($0.pid) }.compactMap { p in name(p).map { (p, $0) } }
            .filter { !ignored.contains($0.1) && "\($0.1)|false" != gs[i].id }
        gs[i].procs.removeAll { p in away.contains { $0.0.pid == p.pid } }
        for (p, n) in away {
            if let j = gs.firstIndex(where: { $0.id == "\(n)|false" }) {
                gs[j].procs.append(p)
                gs[j].procs.sort { $0.mem > $1.mem }
            } else {
                gs.append(Group(name: n, isApp: false, procs: [p]))
            }
        }
    }
    return gs.filter { !$0.procs.isEmpty }.map { g in
        var g = g
        let mine = g.procs.filter { $0.uid == uid }
        g.orphan = !g.isApp && !g.leftover && !g.isSimulator && g.name != "macOS" && !ignored.contains(g.name)
            && !mine.isEmpty && mine.allSatisfy { orphans.contains($0.pid) }
        if g.orphan && asLeftover { g.leftover = true }
        return g
    }
}

/// No live controlling terminal, and started before `t`, the time of the job list: a newer
/// process may be a job it does not have.
func detached(_ pid: pid_t, before t: Date) -> Bool { started(pid).map { $0 < t } == true && !hasTerminal(pid) }

/// A controlling terminal whose device is still there: an open tab, or a session keeper's
/// pty. None, or its device is gone (the tab closed): false.
func hasTerminal(_ pid: pid_t) -> Bool {
    guard let tty = kinfo(pid)?.kp_eproc.e_tdev else { return false }
    return tty != -1 && devname(tty, S_IFCHR) != nil  // -1: NODEV, no terminal
}

/// The Model's job list (scan queue only). launchctl is a process start, so only with
/// the panel open and at most every 30 s.
/// ponytail: with the panel closed the list from its last open is used, so an orphan
/// that starts after that counts for the dot only once the panel opens again.
struct Orphans {
    private var jobs: Set<pid_t> = [], at = Date.distantPast  // distantPast: nothing is judged yet

    mutating func mark(_ groups: [Group], _ procs: [pid_t: Proc], open: Bool) -> [Group] {
        if open, -at.timeIntervalSinceNow > 30 {  // empty: launchctl failed or timed out; no jobs would make them all orphans
            let now = Date(), l = launchctlList(); if !l.isEmpty { jobs = Set(launchdJobs(l).keys); at = now }
        }
        let at = at, d = UserDefaults.standard
        return orphaning(groups, orphans(procs, jobs: jobs, detached: { detached($0, before: at) }, terminal: hasTerminal), procs: procs,
                         ignored: d.ignored, asLeftover: d.countOrphans)
    }
}

extension UserDefaults {
    @objc dynamic var countOrphans: Bool { bool(forKey: "countOrphans") }  // KVO: the key's name
}

/// Asserts for the rules above, run by selfTest.
func orphanTest() {
    func p(_ pid: pid_t, _ ppid: pid_t, _ path: String, uid: uid_t = 501) -> (pid_t, Proc) {
        (pid, Proc(pid: pid, ppid: ppid, uid: uid, path: path, mem: 1 << 20))
    }
    let node = "/opt/homebrew/bin/node"
    let procs = Dictionary(uniqueKeysWithValues: [
        p(1, 0, "/sbin/launchd"),
        p(10, 1, node), p(11, 10, "/opt/homebrew/bin/esbuild"), p(12, 11, "/bin/sh"),  // orphan, its child and grandchild
        p(20, 1, node),                                                // a launchd job
        p(30, 1, "/Applications/Foo.app/Contents/MacOS/Foo"),          // an app
        p(31, 1, "/usr/bin/x"),                                        // system path
        p(32, 1, "/Users/a/Library/Application Support/Foo/agent"),    // an app's (Recall, leftovers)
        p(33, 1, "/opt/homebrew/bin/tmux"), p(34, 33, "/bin/zsh"),     // a session kept on purpose
        p(35, 1, "/opt/homebrew/bin/mosh-server"), p(36, 35, "/bin/zsh"), p(37, 36, "/opt/homebrew/bin/nvim"),  // too: its pty is live
        p(40, 1, "/opt/homebrew/bin/python3"),                         // still has its terminal
        p(50, 1, node, uid: 502),                                      // another user's
        p(60, 1, "/Users/a/dev/MemBar"), p(61, 60, node),              // MemBar itself, its child
        p(70, 1, "/opt/homebrew/bin/deno"), p(71, 70, node, uid: 502), // a child of another user is not ours
        p(80, 1, "/Users/a/dev/srv"), p(81, 80, node),                 // an agent's, in its open app's group
        p(90, 1, "/opt/homebrew/bin/vite"),                            // in a leftover's group: Recall knows its app
    ])
    let tty: (pid_t) -> Bool = { [36, 37, 40].contains($0) }
    let o = orphans(procs, jobs: [20], detached: { $0 != 40 }, terminal: tty, uid: 501, me: 60)
    precondition(o == [10, 11, 12, 70, 80, 81, 90])
    precondition(orphans(procs, jobs: [20], detached: { $0 != 40 }, terminal: { _ in false }, uid: 501, me: 60).isSuperset(of: [35, 36, 37]))
    precondition(orphans(procs, jobs: [], detached: { _ in false }, terminal: tty, uid: 501, me: 60).isEmpty)  // before the first job list
    func g(_ name: String, _ isApp: Bool, _ pids: [pid_t], leftover: Bool = false) -> Group {
        Group(name: name, isApp: isApp, procs: pids.map { procs[$0]! }, leftover: leftover)
    }
    let gs = [g("node", false, [10, 11, 12]), g("Foo", true, [30, 32, 80, 81]), g("Bar", true, [90], leftover: true),
              g("deno", false, [70, 71]), g("tmux", false, [33, 34]), g("macOS", false, [1, 31, 40]), g("node", false, [50])]
    func run(_ gs: [Group], ignored: [String] = [], asLeftover: Bool = false) -> [String: Group] {
        let out = orphaning(gs, o, procs: procs, ignored: ignored, asLeftover: asLeftover, uid: 501)
        return Dictionary(out.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }
    func badges(_ gs: [String: Group]) -> Set<String> { Set(gs.values.filter(\.orphan).map(\.name)) }
    func pids(_ g: Group?) -> Set<pid_t> { Set(g?.procs.map(\.pid) ?? []) }
    let m = run(Array(gs.prefix(6)))
    precondition(badges(m) == ["node", "deno", "srv"] && !m.values.contains { $0.orphan && $0.leftover })
    precondition(pids(m["srv"]) == [80, 81] && pids(m["Foo"]) == [30, 32] && pids(m["Bar"]) == [90])  // out of the open app only
    precondition(badges(run([gs[6]])).isEmpty)  // none of ours
    let ig = run(Array(gs.prefix(6)), ignored: ["srv", "deno"])
    precondition(badges(ig) == ["node"] && pids(ig["Foo"]) == [30, 32, 80, 81])
    precondition(Set(run(Array(gs.prefix(6)), asLeftover: true).values.filter(\.leftover).map(\.name)) == ["Bar", "node", "deno", "srv"])
    // Into a group of the same name, with a job in it: no badge, and the app's group shrinks.
    let merged = run([g("Foo", true, [30, 10, 11, 12]), g("node", false, [20])])
    precondition(pids(merged["node"]) == [10, 11, 12, 20] && !merged["node"]!.orphan && pids(merged["Foo"]) == [30])
    precondition(run([g("Foo", true, [80, 81])])["Foo"] == nil)  // emptied: gone
    precondition(!detached(getpid(), before: .distantPast) && !detached(-5, before: .distantFuture) && !hasTerminal(-5))
}
