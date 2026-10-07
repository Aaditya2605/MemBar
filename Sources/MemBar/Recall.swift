import Darwin
import Foundation

// What one scan cannot see, so the Model keeps it across scans:
// (1) The app that started a command-line process that outlives it: a node dev server
//     from VS Code's terminal, an MCP server of an AI app. When the app quits, the
//     responsibility call returns the process itself (macOS 26: never the dead PID, so a
//     memory by responsible PID never fires), its parent is launchd, and today's rule
//     names its group after its own executable ("node"): never a leftover.
// (2) A leftover that comes back after Stop.

/// A command-line process seen in an app's group: the app's top path (it gives the
/// group's name and icon), its own executable (a reused PID runs another one), its user.
struct AppOwner: Equatable { let app: String, exe: String, uid: uid_t }

/// An executable whose own group is not an app, not macOS (Apple's tools) and not the
/// simulator: "node", "python3". Only these are remembered, so only these move.
/// Not tmux and the like: they keep terminal sessions on purpose after the terminal app
/// quits, and Stop would end the user's shells.
/// ponytail: a `nohup` job kept on purpose looks like any other leftover.
func isCLI(_ path: String) -> Bool {
    let a = appOf(path)
    return !a.isApp && a.name != "iOS Simulator" && !systemPrefixes.contains(where: path.hasPrefix)
        && !["tmux", "screen", "zellij", "dtach", "abduco"].contains(a.name)
}

/// The path that names the group of `p`, whose owner by today's rule is `top`: the
/// remembered app when `top` is a command-line process that was seen in that app's
/// group, still runs the same executable, and `p` and `top` are of that user. Else
/// `top`'s own path, as today.
/// ponytail: the same executable at a reused PID (node after node) passes as the same
/// process; a start time would tell them apart.
func ownerPath(_ p: Proc, top: pid_t, procs: [pid_t: Proc], owners: [pid_t: AppOwner]) -> String {
    let t = procs[top] ?? p
    // Its own group also while Android Studio runs it, as the simulator is not Xcode's. An
    // app that started it (VS Code with Flutter, Terminal) keeps it: it is in use until that
    // app quits, and then its top is the emulator itself, its own group again.
    if isEmulatorPath(p.path) && appOf(t.path).name.lowercased().hasPrefix("android studio") { return p.path }
    if let vm = vmOwner(p.path, top: t.path) { return vm }  // Containers.swift: Docker's, Podman's or "Linux VM"
    guard let o = owners[top], t.path == o.exe, t.uid == o.uid, p.uid == o.uid else { return t.path }
    return o.app
}

/// The owner memory after a scan: each command-line process of `uid` whose group is an
/// app, by today's rule or by the old memory (a child that a remembered process starts
/// after its app quit is remembered too). The rest drop out: gone, reused, never an app's.
/// ponytail: memory is in RAM only: an app that quit before MemBar started, or that
/// started and quit between two scans (a minute with the panel closed), is not known.
/// A process under a shell that outlives its app stays macOS's: the top is /bin/zsh.
func remember(_ procs: [pid_t: Proc], responsible: (pid_t) -> pid_t, owners: [pid_t: AppOwner],
              uid: uid_t = getuid()) -> [pid_t: AppOwner] {
    var out: [pid_t: AppOwner] = [:]
    for p in procs.values where p.uid == uid && isCLI(p.path) {
        let top = owner(of: p.pid, responsible: responsible(p.pid), procs: procs)
        let app = ownerPath(p, top: top, procs: procs, owners: owners)
        if appOf(app).isApp { out[p.pid] = AppOwner(app: app, exe: p.path, uid: uid) }
    }
    return out
}

/// The processes of `g` that came back after Stop: `g` is a leftover again, and runs a
/// stopped executable under a new PID.
/// ponytail: one that the group started after the last scan, just before Stop, counts
/// too; start times would tell them apart.
func respawned(_ g: Group, pids: Set<pid_t>, paths: Set<String>) -> [Proc] {
    g.leftover ? g.procs.filter { paths.contains($0.path) && !pids.contains($0.pid) } : []
}

/// `launchctl list` lines "PID<tab>Status<tab>Label" → label by PID (PID "-" when the job does not
/// run: left out). Orphans uses its keys, Recall its labels.
func launchdJobs(_ list: String) -> [pid_t: String] {
    Dictionary(list.split(separator: "\n").compactMap { l -> (pid_t, String)? in
        let f = l.split(separator: "\t"); return f.count >= 3 ? pid_t(f[0]).map { ($0, String(f[2])) } : nil
    }, uniquingKeysWith: { a, _ in a })  // not uniqueKeysWithValues: a repeated PID must not trap
}

/// `launchctl list`: the launchd jobs of this user.
func launchctlList() -> String { String(decoding: output("/bin/launchctl", ["list"]), as: UTF8.self) }

/// The Model's memory across scans (scan queue only).
struct Recall {
    private var owners: [pid_t: AppOwner] = [:]
    private var stopped: [String: (at: Date, pids: Set<pid_t>, paths: Set<String>)] = [:]  // by group name
    private var respawns: [String: String] = [:]  // group name → why, the badge's help
    private var labels: [String: String] = [:]  // group name → its launchd job's label, for the menus (Agents.swift)

    /// group() with what earlier scans saw. `jobs` runs only to name the job of a new
    /// respawn, never each scan.
    mutating func groups(_ procs: [pid_t: Proc], responsible: (pid_t) -> pid_t, now: Date = Date(),
                         jobs: () -> String = launchctlList) -> [Group] {
        let resp = Dictionary(uniqueKeysWithValues: procs.keys.map { ($0, responsible($0)) })
        let r: (pid_t) -> pid_t = { resp[$0] ?? -1 }
        owners = remember(procs, responsible: r, owners: owners)
        var gs = group(procs, responsible: r, owners: owners)
        stopped = stopped.filter { now.timeIntervalSince($0.value.at) <= 60 }
        for i in gs.indices {
            let name = gs[i].name
            if let s = stopped[name] {
                let new = respawned(gs[i], pids: s.pids, paths: s.paths)
                if !new.isEmpty {
                    stopped[name] = nil
                    // A job of ours is a child of launchd that this user runs.
                    let j = new.contains { $0.ppid == 1 && $0.uid == getuid() } ? launchdJobs(jobs()) : [:]
                    let label = new.lazy.compactMap { j[$0.pid] }.first
                    respawns[name] = "It starts again after Stop: macOS or a launch agent restarts it"
                        + (label.map { ". launchd job: \($0)" } ?? "")
                    labels[name] = label
                }
            }
            if gs[i].leftover { gs[i].respawns = respawns[name]; gs[i].job = labels[name] }
        }
        return gs
    }

    /// After Stop: watch 60 s for the group to come back. Stop again clears the old mark.
    mutating func didStop(_ g: Group, at now: Date = Date()) {
        guard !g.isSimulator else { return }  // shut down, not signalled: whoever boots it again is no launch agent
        stopped[g.name] = (now, Set(g.procs.map(\.pid)), Set(g.procs.map(\.path)))
        respawns[g.name] = nil; labels[g.name] = nil
    }

    /// Disable Launch Agent ran: nothing restarts the groups of `label` now, so no badge, and
    /// auto-stop may stop them. Also a group that is not a leftover now: the mark waits for it.
    mutating func forget(job label: String) {
        for (name, l) in labels where l == label { respawns[name] = nil; labels[name] = nil }
    }
}

/// Asserts for the rules above, run by selfTest.
func recallTest() {
    func p(_ pid: pid_t, _ ppid: pid_t, _ path: String, uid: uid_t = 501) -> (pid_t, Proc) {
        (pid, Proc(pid: pid, ppid: ppid, uid: uid, path: path, mem: 1 << 20))
    }
    func byName(_ gs: [Group]) -> [String: Group] { Dictionary(uniqueKeysWithValues: gs.map { ($0.name, $0) }) }
    func pids(_ g: Group?) -> Set<pid_t> { Set(g?.procs.map(\.pid) ?? []) }
    let code = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", node = "/opt/homebrew/bin/node"
    precondition(isCLI(node) && isCLI("-/opt/homebrew/bin/bash") && !isCLI(code) && !isCLI("/usr/bin/python3"))
    precondition(!isCLI("/Users/a/Library/Application Support/Cursor/node") && !isCLI("launchd_sim"))
    precondition(!isCLI("/opt/homebrew/bin/tmux") && !isCLI("/opt/homebrew/Cellar/dtach/0.9/bin/dtach") && !isCLI("/opt/homebrew/bin/abduco"))

    // VS Code open: it started a dev server (61, detached: ppid 1) with a child (62).
    let open = Dictionary(uniqueKeysWithValues: [
        p(1, 0, "/sbin/launchd"),
        p(60, 1, code),
        p(61, 1, node),
        p(62, 61, "/opt/homebrew/bin/esbuild"),
        p(63, 1, node, uid: 502),     // another user's
        p(64, 60, "/usr/bin/python3"),  // an Apple tool: macOS's when orphaned
        p(65, 1, "/opt/homebrew/bin/tmux"), p(66, 65, "/bin/zsh"), p(67, 66, node),  // a tmux session from its terminal
        p(70, 1, "/opt/homebrew/bin/deno"),  // started by no app
    ])
    let r1: (pid_t) -> pid_t = { [61: 60, 62: 60, 63: 60, 64: 60, 65: 60, 66: 60, 67: 60][$0] ?? $0 }
    let owners1 = remember(open, responsible: r1, owners: [:], uid: 501)
    precondition(Set(owners1.keys) == [61, 62, 67] && owners1[61] == AppOwner(app: code, exe: node, uid: 501))
    let g1 = byName(group(open, responsible: r1, owners: owners1))
    precondition(!g1["Visual Studio Code"]!.leftover && pids(g1["Visual Studio Code"]).isSuperset(of: [60, 61, 62]))

    // VS Code quit: the responsibility call now returns each process itself, or a dead PID.
    var quit = open
    quit[60] = nil
    quit[64] = Proc(pid: 64, ppid: 1, uid: 501, path: "/usr/bin/python3", mem: 1 << 20)
    let r2: (pid_t) -> pid_t = { [62: 60, 70: 999][$0] ?? $0 }  // 999, 60: dead
    precondition(pids(byName(group(quit, responsible: r2))["node"]) == [61, 62, 63])  // no memory: today's rule
    let owners2 = remember(quit, responsible: r2, owners: owners1, uid: 501)
    precondition(Set(owners2.keys) == [61, 62])
    let g2 = byName(group(quit, responsible: r2, owners: owners2))
    let vs = g2["Visual Studio Code"]!
    precondition(vs.leftover && pids(vs) == [61, 62] && vs.bundle == "/Applications/Visual Studio Code.app")
    precondition(pids(g2["node"]) == [63] && !g2["node"]!.leftover)  // never another user's
    precondition(pids(g2["deno"]) == [70] && !g2["deno"]!.leftover)  // unknown dead responsible: today's
    precondition(pids(g2["macOS"]) == [1, 64])  // never out of macOS
    precondition(pids(g2["tmux"]) == [65, 66, 67] && !g2["tmux"]!.leftover)  // the session is the user's

    // VS Code open again (a new PID): its old dev server is no leftover.
    var again = quit
    again[80] = Proc(pid: 80, ppid: 1, uid: 501, path: code, mem: 1 << 20)
    precondition(!byName(group(again, responsible: r2, owners: owners2))["Visual Studio Code"]!.leftover)

    // PID 61 reused by another executable: not remapped, and forgotten.
    var reused = quit
    reused[61] = Proc(pid: 61, ppid: 1, uid: 501, path: "/opt/homebrew/bin/python3", mem: 1 << 20)
    reused[62] = nil
    let g3 = byName(group(reused, responsible: r2, owners: owners2))
    precondition(g3["Visual Studio Code"] == nil && pids(g3["python3"]) == [61] && !g3["python3"]!.leftover)
    precondition(remember(reused, responsible: r2, owners: owners2, uid: 501).isEmpty)

    // Respawns: a new PID of a stopped executable, in a group that is a leftover again.
    let agent = "/Users/a/Library/Application Support/Foo/agent"
    func foo(_ ps: [(pid_t, Proc)]) -> Group { Group(name: "Foo", isApp: true, procs: ps.map(\.1), leftover: true) }
    let back = foo([p(90, 1, agent), p(91, 1, agent), p(92, 1, node)])
    precondition(respawned(back, pids: [90], paths: [agent]).map(\.pid) == [91])  // 90 still exits; 92: other exe
    var openFoo = back
    openFoo.leftover = false
    precondition(respawned(openFoo, pids: [90], paths: [agent]).isEmpty)
    let list = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n91\t0\tcom.foo.agent\n"
    precondition(launchdJobs(list) == [91: "com.foo.agent"] && launchdJobs(list + "91\t0\tcom.foo.again\nbad\n") == [91: "com.foo.agent"])

    // Recall end to end, with this user's processes: stop, back within 60 s, marked.
    let me = getuid(), t0 = Date()
    let before = Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd"), p(90, 1, agent, uid: me)])
    let after = Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd"), p(91, 1, agent, uid: me)])
    var rc = Recall()
    let stopped = rc.groups(before, responsible: { $0 }, now: t0, jobs: { list }).first { $0.name == "Foo" }!
    precondition(stopped.leftover && stopped.respawns == nil)
    var late = rc
    rc.didStop(stopped, at: t0)
    late.didStop(stopped, at: t0)
    let marked = rc.groups(after, responsible: { $0 }, now: t0 + 20, jobs: { list }).first { $0.name == "Foo" }!
    precondition(marked.respawns == "It starts again after Stop: macOS or a launch agent restarts it. launchd job: com.foo.agent")
    precondition(marked.job == "com.foo.agent" && stopped.job == nil)
    precondition(late.groups(after, responsible: { $0 }, now: t0 + 61, jobs: { list }).first { $0.name == "Foo" }!.respawns == nil)

    // Its launch agent disabled: the mark goes, also from later scans; another label's does not.
    do {
        func foo(_ r: inout Recall) -> Group { r.groups(after, responsible: { $0 }, now: t0 + 30, jobs: { list }).first { $0.name == "Foo" }! }
        var off = rc
        off.forget(job: "com.bar")
        precondition(foo(&off).job == "com.foo.agent")
        off.forget(job: "com.foo.agent")
        let g = foo(&off)
        precondition(g.respawns == nil && g.job == nil && g.agentLabel == nil)
    }
}
