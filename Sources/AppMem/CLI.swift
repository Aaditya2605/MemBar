import Foundation

// Flags for scripts and agent hooks: the same scan, rules and stop() as the menu
// bar. --list and --test are in Scan.swift, --snapshot in UI.swift.

private let usage = """
    usage: AppMem [flag]          no flag: run the menu bar app

      --list                      groups as text
      --json [--cpu]              groups, RAM, swap and pressure as JSON (bytes);
                                  --cpu: two scans 1 s apart, adds CPU % of one core
      --leftovers                 leftover groups, one per line: name, memory, PIDs
                                  (tab-separated); exit status 1 if any, 0 if none
      --stop [NAME ...] [--dry-run]
                                  stop all leftover groups, or only the named ones
                                  (any case), as the Stop button does; --dry-run:
                                  print what it would stop, stop nothing; not as root
      --test                      self-check of the pure rules
      --snapshot OUT.png [QUERY]  debug builds: the panel as a PNG
      --snapshot-details OUT.png GROUP [QUERY]
                                  debug builds: the Details window of GROUP as a PNG
      --help, -h                  this text

    """

enum CLICommand: Equatable { case help, json(cpu: Bool), leftovers, stop(names: [String], dryRun: Bool), bad(String) }

/// Every flag, also the ones main.swift reads (--list, --test, --snapshot).
private let flags: Set = ["--help", "--json", "--cpu", "--leftovers", "--stop", "--dry-run", "--list", "--test", "--snapshot", "--snapshot-details"]

/// The command in `args` (argv without the program); nil when there is none, so
/// main.swift runs --snapshot or starts the menu bar app. Any other "--" flag is an
/// error: the app's run loop never returns, so a hook with a typo would hang. Cocoa's
/// own args (-NSFoo YES, -psn_) start with one dash and pass. --stop is checked last
/// and takes no other flag than --dry-run: a stray flag never becomes a stop.
func parseArgs(_ args: [String], uid: uid_t = getuid()) -> CLICommand? {
    let has = Set(args)
    if let f = args.first(where: { $0.hasPrefix("--") && !flags.contains($0) }) { return .bad("unknown flag: \(f)") }
    #if DEBUG
    if args.last == "--snapshot" { return .bad("--snapshot needs OUT.png") }
    if let i = args.firstIndex(of: "--snapshot-details"), i + 2 >= args.count { return .bad("--snapshot-details needs OUT.png GROUP") }
    #else
    if has.contains("--snapshot") { return .bad("--snapshot works only in debug builds") }
    if has.contains("--snapshot-details") { return .bad("--snapshot-details works only in debug builds") }
    #endif
    if has.contains("--help") || has.contains("-h") { return .help }
    if has.contains("--json") { return .json(cpu: has.contains("--cpu")) }
    if has.contains("--leftovers") { return .leftovers }
    if has.contains("--stop") {
        if let f = args.first(where: { $0.hasPrefix("-") && $0 != "--stop" && $0 != "--dry-run" }) {
            return .bad("unknown flag for --stop: \(f)")
        }
        // getuid() is 0 under sudo, so root's daemons would pass stop()'s "this user only" rule.
        if uid == 0 { return .bad("--stop does not run as root: run it without sudo") }
        return .stop(names: args.filter { !$0.hasPrefix("-") }, dryRun: has.contains("--dry-run"))
    }
    if has.contains("--cpu") { return .bad("--cpu works only with --json") }
    if has.contains("--dry-run") { return .bad("--dry-run works only with --stop") }
    return nil
}

/// The leftover groups to stop: all, or the ones in `names` (any case). `missing`:
/// names with no leftover group (a typo, or the app is open), to report them.
func stopTargets(_ groups: [Group], _ names: [String]) -> (targets: [Group], missing: [String]) {
    let left = groups.filter(\.leftover), want = Set(names.map { $0.lowercased() })
    let found = Set(left.map { $0.name.lowercased() })
    return (names.isEmpty ? left : left.filter { want.contains($0.name.lowercased()) },
            names.filter { !found.contains($0.lowercased()) })
}

private struct ProcJSON: Encodable { let pid: pid_t, name: String, path: String, memory: Int64, cpu: Double? }
private struct GroupJSON: Encodable {
    let name: String, isApp: Bool, leftover: Bool, memory: Int64, processCount: Int, cpu: Double?, processes: [ProcJSON]
}
private struct ReportJSON: Encodable { let ram: Int64, ramTotal: Int64, swap: Int64, pressure: String, groups: [GroupJSON] }

/// `--json`: memory in bytes; `cpu` (% of one core, in 0.1 steps) only when measured;
/// `pressure` as in --list: "normal", "warning" or "critical".
func jsonReport(_ groups: [Group], sys: SysMem, cpu: Bool) -> Data {
    func pct(_ v: Double) -> Double? { cpu ? (v * 10).rounded() / 10 : nil }
    let report = ReportJSON(ram: sys.ram, ramTotal: Int64(ProcessInfo.processInfo.physicalMemory), swap: sys.swap,
                            pressure: sys.pressure.label.lowercased(), groups: groups.map { g in
        GroupJSON(name: g.name, isApp: g.isApp, leftover: g.leftover, memory: g.mem, processCount: g.procs.count, cpu: pct(g.cpu),
                  processes: g.procs.map { ProcJSON(pid: $0.pid, name: $0.name, path: $0.path, memory: $0.mem, cpu: pct($0.cpu)) })
    })
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]  // sorted: else the key order changes each run
    return try! enc.encode(report)  // only NaN or infinity throws; CPU % is finite
}

/// ponytail: no top by default (like the menu bar icon): it costs 0.35 s of CPU,
/// and without it only root processes in a leftover group show 0 memory.
/// With `cpu`, two scans 1 s apart: CPU % needs two CPU times.
/// Ignored apps (Settings) are not leftovers here either: --stop must not stop what
/// the menu has no Stop for. Only --list keeps them, to compare with the prototype.
private func scanGroups(top: [pid_t: Int64] = [:], cpu: Bool = false) -> [Group] {
    let start = Date()
    var procs = scan(top: top)
    if cpu {
        Thread.sleep(forTimeInterval: 1)
        let prev = procs.mapValues(\.cpuTime), seconds = -start.timeIntervalSinceNow  // scan start to scan start
        procs = scan(top: top)
        addCPU(&procs, prev: prev, seconds: seconds)
    }
    return ignoring(group(procs, responsible: responsible), UserDefaults.standard.ignored)
}

/// Runs the command in `args` and returns the exit status; nil when `args` has
/// none of these flags.
func runCLI(_ args: [String]) -> Int32? {
    guard let cmd = parseArgs(args) else { return nil }
    switch cmd {
    case .bad(let why):
        fputs("AppMem: \(why)\n\n\(usage)", stderr)
        return 2
    case .help:
        print(usage, terminator: "")
        return 0
    case .json(let cpu):
        print(String(decoding: jsonReport(scanGroups(top: topMem(), cpu: cpu), sys: systemMem(), cpu: cpu), as: UTF8.self))
        return 0
    case .leftovers:
        let left = scanGroups().filter(\.leftover)
        for g in left { print(g.name, fmt(g.mem), g.procs.map { String($0.pid) }.joined(separator: " "), separator: "\t") }
        if left.isEmpty { fputs("no leftovers\n", stderr) }
        return left.isEmpty ? 0 : 1
    case .stop(let names, let dryRun):
        let (targets, missing) = stopTargets(scanGroups(), names)
        for n in missing { fputs("no leftover named \"\(n)\"\n", stderr) }
        if names.isEmpty && targets.isEmpty { fputs("no leftovers\n", stderr) }
        var stopped = false
        for g in targets {
            // A hook that runs in a leftover group would stop its own agent and shell.
            if g.procs.contains(where: { $0.pid == getpid() }) {
                fputs("skip \(g.name): this command runs in it\n", stderr); continue
            }
            let mine = g.procs.filter { $0.uid == getuid() }.map { String($0.pid) }  // stop() signals only these
            if !g.isSimulator && mine.isEmpty {
                fputs("skip \(g.name): its processes belong to other users\n", stderr); continue
            }
            print(dryRun ? "would stop" : "stop", g.name, fmt(g.mem),
                  g.isSimulator ? "xcrun simctl shutdown all" : mine.joined(separator: " "), separator: "\t")
            if !dryRun { stop(g); stopped = true }
        }
        // ponytail: a fixed wait, not a handle on the follow-up. stop() sends SIGKILL
        // from a global queue after 3 s (+ up to 10% timer leeway); exit would drop it.
        if stopped { fflush(stdout); Thread.sleep(forTimeInterval: 4) }
        return missing.isEmpty ? 0 : 1
    }
}
