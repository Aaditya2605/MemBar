import Darwin
import Foundation

// The core, ported from ~/projects/scripts/appmem.py. Pure rules first (testable
// without the UI, see selfTest), then the system reads, then Stop.

struct Proc {
    let pid: pid_t, ppid: pid_t, uid: uid_t
    let path: String
    let mem: Int64  // physical footprint in bytes ("Memory" in Activity Monitor)
    var cpuTime: UInt64 = 0  // user + system CPU time since start, in ns
    var cpu: Double = 0  // % of one core since the previous scan
    var ports: [UInt16] = []  // TCP ports it listens on, read only while the panel is open
    var stopped = false  // SIGSTOP: paused by AppMem, a debugger or ctrl-Z in a shell
    var name: String { String((path.split(separator: "/").last ?? "?").drop { $0 == "-" }) }
}

struct Group: Identifiable {
    let name: String
    let isApp: Bool  // a non-Apple app: only these can be leftovers
    var procs: [Proc] = []
    var leftover = false
    var bundle: String?  // the app's .app folder, for its icon
    var ignored = false  // a leftover that ignoring() unflagged: its app is still not open
    var respawns: String?  // it came back after Stop: why (see Recall)
    var id: String { "\(name)|\(isApp)" }
    var mem: Int64 { procs.reduce(0) { $0 + $1.mem } }
    var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
    var isSimulator: Bool { name == "iOS Simulator" }
}

// MARK: - Pure rules

let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

/// Group name for the executable path of a group's top process.
func appOf(_ path: String) -> (name: String, isApp: Bool) {
    if path.contains("CoreSimulator") || path == "launchd_sim" { return ("iOS Simulator", false) }
    // Deviation from the prototype: Apple's own apps (/System/Applications/Weather.app
    // widgets and the like) keep their name but are never leftovers. macOS starts them.
    let isApp = !systemPrefixes.contains { path.hasPrefix($0) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    // .../Library/Application Support/<X>/... → X
    for i in parts.indices.dropFirst().dropLast(3)
    where parts[i] == "Library" && parts[i + 1] == "Application Support" && !parts[i + 2].isEmpty {
        return (String(parts[i + 2]), isApp)
    }
    // the outermost <X>.app/ → X
    for p in parts.dropFirst().dropLast() where p.count > 4 && p.hasSuffix(".app") {
        return (String(p.dropLast(4)), isApp)
    }
    if !isApp { return ("macOS", false) }
    return (String((parts.last ?? "?").drop { $0 == "-" }), false)
}

/// The outermost `<X>.app` folder in `path`.
func bundlePath(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
    return String(path[..<r.lowerBound]) + ".app"
}

/// Lower-case names of apps whose `<X>.app/Contents/MacOS/<exe>` runs.
func openApps<S: Sequence>(_ paths: S) -> Set<String> where S.Element == String {
    Set(paths.compactMap { path in
        let p = path.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count >= 5, !p[p.count - 1].isEmpty, p[p.count - 2] == "MacOS", p[p.count - 3] == "Contents",
              p[p.count - 4].count > 4, p[p.count - 4].hasSuffix(".app") else { return nil }
        return p[p.count - 4].dropLast(4).lowercased()
    })
}

/// ponytail: loose name match, as in the prototype, but by whole words: "claude" ~
/// "claude helper", "opencode" ~ "ai.opencode.desktop". The prototype's plain
/// substring match let "xcode" hide "Code", and "appmem" hide "AppMemTestApp".
/// A helper .app that still runs counts as its app being open.
func isOpen(_ name: String, _ open: Set<String>) -> Bool {
    let n = name.lowercased()
    func words(_ s: String) -> [Substring] { s.split { !$0.isLetter && !$0.isNumber } }
    return open.contains { o in o == n || words(o).contains(Substring(n)) || words(n).contains(Substring(o)) }
}

func isLeftover(_ g: Group, open: Set<String>) -> Bool {
    if g.isSimulator {  // launchd_sim = a booted device; agents boot them with no window
        return !open.contains("simulator") && g.procs.contains { $0.name == "launchd_sim" }
    }
    return g.isApp && !isOpen(g.name, open)
}

/// The top process of `pid`'s owner: the responsible process if it is alive, else
/// `pid` itself, then up the parent chain until launchd.
func owner(of pid: pid_t, responsible: pid_t, procs: [pid_t: Proc]) -> pid_t {
    var top = procs[responsible] == nil ? pid : responsible
    for _ in 0..<64 {  // a PID reused mid-scan could make a loop
        guard let pp = procs[top]?.ppid, pp > 1, procs[pp] != nil else { break }
        top = pp
    }
    return top
}

/// Groups sorted by memory, leftovers first. `owners`: remembered app owners (Recall).
func group(_ procs: [pid_t: Proc], responsible: (pid_t) -> pid_t, owners: [pid_t: AppOwner] = [:]) -> [Group] {
    let open = openApps(procs.values.lazy.map(\.path))
    var groups: [String: Group] = [:]
    var notExtension: Set<String> = []  // groups with a process that no app extension owns
    for p in procs.values {
        let top = owner(of: p.pid, responsible: responsible(p.pid), procs: procs)
        let topPath = ownerPath(p, top: top, procs: procs, owners: owners)
        let (name, isApp) = appOf(topPath), key = "\(name)|\(isApp)"
        groups[key, default: Group(name: name, isApp: isApp)].procs.append(p)
        if groups[key]!.bundle == nil { groups[key]!.bundle = bundlePath(topPath) }
        if !topPath.contains(".appex/") { notExtension.insert(key) }
    }
    return groups.values.map { g in
        var g = g
        g.procs.sort { $0.mem > $1.mem }
        // App extensions are not leftovers: macOS starts them with the app quit (a
        // notification extension decrypts each push), and starts them again after Stop.
        g.leftover = notExtension.contains(g.id) && isLeftover(g, open: open)
        return g
    }.sorted { ($0.leftover ? 1 : 0, $0.mem) > ($1.leftover ? 1 : 0, $1.mem) }
}

/// CPU % of one core for each process: its CPU time since the previous scan over
/// the wall time. A PID that is new or reused (less CPU time than before) gets 0.
func addCPU(_ procs: inout [pid_t: Proc], prev: [pid_t: UInt64], seconds: Double) {
    guard seconds > 0 else { return }
    for (pid, p) in procs {
        if let t = prev[pid], p.cpuTime >= t { procs[pid]!.cpu = Double(p.cpuTime - t) / 1e9 / seconds * 100 }
    }
}

/// top's MEM column: "1241M", "1.5G+", "512K".
func parseMem<S: StringProtocol>(_ s: S) -> Int64 {
    let num = s.prefix { $0.isNumber || $0 == "." }
    guard let v = Double(num), let unit = s.dropFirst(num.count).first,
          let mult = ["B": 1.0, "K": 1024.0, "M": 1048576.0, "G": 1073741824.0][unit] else { return 0 }
    return Int64(v * mult)
}

func fmt(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1048576
    return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - System reads

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
// Private libsystem call that Activity Monitor uses to put XPC and WebKit helpers
// under their app. RTLD_DEFAULT is (void *)-2 on macOS.
private let responsibleFn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFn.self) }

func responsible(_ pid: pid_t) -> pid_t { responsibleFn?(pid) ?? -1 }

/// KERN_PROCARGS2: argc, exec path, argv, environment (see argv(_:)). nil for
/// other users' processes.
func procArgs(_ pid: pid_t) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var args = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &args, &size, nil, 0) == 0, size > 4 else { return nil }
    return Array(args.prefix(size))
}

/// The executable path. proc_pidpath fails when the file was replaced (an app
/// update); then argv's exec path, then the short process name.
func path(of pid: pid_t, comm: String) -> String {
    var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
    if let args = procArgs(pid) {
        let exe = args[4...].prefix { $0 != 0 }  // after int argc
        if !exe.isEmpty { return String(decoding: exe, as: UTF8.self) }
    }
    return comm
}

private func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
    var s = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &s, size) == size ? s : nil
}

private func comm(_ s: proc_bsdshortinfo) -> String {
    withUnsafeBytes(of: s.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// Footprint via top, for processes that proc_pid_rusage refuses (root and other
/// users). top costs about 0.35 s of CPU, so callers cache it.
func topMem() -> [pid_t: Int64] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    p.arguments = ["-l", "1", "-stats", "pid,mem"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var out: [pid_t: Int64] = [:], started = false
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ")
        if f.first == "PID" { started = true } else if started, f.count >= 2, let pid = pid_t(f[0]) { out[pid] = parseMem(f[1]) }
    }
    return out
}

// rusage CPU times are in mach ticks (on Apple Silicon 1 tick = 125/3 ns).
private let nsPerTick: Double = { var i = mach_timebase_info(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) }()

private let host = mach_host_self()  // once: each call adds a port reference

/// Activity Monitor's memory numbers (see SysMem), swap in use, and the memory pressure.
func systemMem() -> SysMem {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    } == KERN_SUCCESS
    var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 { swap = xsw_usage() }
    func int(_ name: String) -> Int32? {
        var v: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
    return SysMem(ok ? vm : vm_statistics64(), page: Int64(vm_kernel_page_size), swap: Int64(swap.xsu_used),
                  level: int("kern.memorystatus_vm_pressure_level"), free: int("kern.memorystatus_level"))
}

/// Every process. PROC_PIDT_SHORTBSDINFO works for all users (PROC_PIDTBSDINFO
/// does not for root processes when this app is not root).
func scan(top: [pid_t: Int64]) -> [pid_t: Proc] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var procs: [pid_t: Proc] = [:]
    for pid in pids.prefix(max(n, 0)) {
        guard let s = shortInfo(pid) else { continue }  // gone
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        procs[pid] = Proc(pid: pid, ppid: pid_t(s.pbsi_ppid), uid: s.pbsi_uid, path: path(of: pid, comm: comm(s)),
                          mem: ok ? Int64(ri.ri_phys_footprint) : top[pid] ?? 0,
                          cpuTime: ok ? UInt64(Double(ri.ri_user_time + ri.ri_system_time) * nsPerTick) : 0,
                          stopped: s.pbsi_status == SSTOP)
    }
    return procs
}

// MARK: - Stop

// Same PID and same executable as in the scan, so a reused PID is left alone.
func same(_ p: Proc) -> Bool { shortInfo(p.pid).map { path(of: p.pid, comm: comm($0)) == p.path } ?? false }

/// App leftover: SIGTERM, then SIGKILL after 3 s for the ones that still run.
/// Simulator: shut down the booted devices. Never the macOS group, never other users.
func stop(_ g: Group) {
    guard g.leftover, g.name != "macOS" else { return }
    if g.isSimulator {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "shutdown", "all"]  // = each booted device
        try? p.run()
        return
    }
    let targets = g.procs.filter { $0.uid == getuid() && $0.pid > 1 && $0.pid != getpid() && same($0) }
    for p in targets {
        kill(p.pid, SIGTERM)
        kill(p.pid, SIGCONT)  // paused (maybe since the scan): it acts on SIGTERM only once it runs
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        for p in targets where same(p) { kill(p.pid, SIGKILL) }
    }
}

// MARK: - Command line

/// `AppMem --list`: the prototype's output, to compare the two.
func printGroups() {
    var procs = scan(top: topMem())
    addPorts(&procs, listenPorts(procs))
    let groups = group(procs, responsible: responsible).sorted { $0.mem > $1.mem }
    let sys = systemMem()
    print("apps \(fmt(groups.reduce(0) { $0 + $1.mem })), RAM \(fmt(sys.ram)), swap \(fmt(sys.swap))")
    print("pressure \(sys.pressure.label.lowercased()) \(sys.usedPct)%; RAM = app \(fmt(sys.app)) + wired \(fmt(sys.wired))",
          "+ compressed \(fmt(sys.compressed)); cached files \(fmt(sys.cached))")
    for g in groups.prefix(20) {
        let flag = g.leftover ? (g.isSimulator ? "   <-- DEVICE RUNNING, SIMULATOR NOT OPEN" : "   <-- APP NOT OPEN") : ""
        print("\n" + g.name.padding(toLength: max(28, g.name.count), withPad: " ", startingAt: 0),
              fmt(g.mem).leftPad(9), String(g.procs.count).leftPad(4), "procs" + flag)
        for p in g.procs.prefix(5) {
            print("    " + fmt(p.mem).leftPad(9), String(p.pid).leftPad(6), p.name + (p.ports.isEmpty ? "" : "  " + portsText(p.ports)))
        }
    }
    for g in groups where g.leftover { print("leftover: \(g.name) \(fmt(g.mem)) pids \(g.procs.map(\.pid))") }
}

private extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

/// `AppMem --test`: asserts for the pure rules.
func selfTest() {
    precondition(parseMem("1241M") == 1241 << 20 && parseMem("1.5G+") == 1536 << 20 && parseMem("512K") == 512 << 10)
    precondition(appOf("/Users/a/Library/Application Support/Cursor/User/x/bin/cursor-agent") == ("Cursor", true))
    precondition(appOf("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") == ("Claude", true))
    precondition(appOf("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer") == ("macOS", false))
    precondition(appOf("/System/Applications/Weather.app/Contents/PlugIns/W.appex/Contents/MacOS/W") == ("Weather", false))
    precondition(appOf("-/opt/homebrew/bin/bash") == ("bash", false))
    precondition(appOf("launchd_sim") == ("iOS Simulator", false))
    precondition(appOf("kernel_task") == ("kernel_task", false))
    precondition(appOf("/Library/Application Support/X") == ("X", false))  // X must be a folder
    precondition(bundlePath("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/C") == "/Applications/Claude.app")
    precondition(bundlePath("/opt/homebrew/bin/node") == nil && bundlePath("/Applications/X.app") == "/Applications/X.app")

    let open = openApps(["/Applications/Claude.app/Contents/MacOS/Claude", "/usr/bin/top",
                         "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"])
    precondition(open == ["claude", "claude helper"])
    precondition(isOpen("Claude", open) && !isOpen("Cursor", open))
    precondition(isOpen("ai.opencode.desktop", ["opencode"]) && isOpen("Code", ["visual studio code"]))
    precondition(!isOpen("Code", ["xcode"]) && !isOpen("AppMemTestApp", ["appmem"]))

    func p(_ pid: pid_t, _ ppid: pid_t, _ path: String, _ mb: Int64) -> (pid_t, Proc) {
        (pid, Proc(pid: pid, ppid: ppid, uid: 501, path: path, mem: mb << 20))
    }
    let procs = Dictionary(uniqueKeysWithValues: [
        p(1, 0, "/sbin/launchd", 10),
        p(10, 1, "/Users/a/Library/Application Support/Cursor/node", 500),  // its app quit
        p(11, 10, "/opt/homebrew/bin/node", 300),                          // child of a leftover
        p(20, 1, "/Applications/Claude.app/Contents/MacOS/Claude", 400),
        p(21, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent", 900),
        p(30, 1, "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/launchd_sim", 50),
        p(40, 1, "/System/Applications/Weather.app/Contents/PlugIns/W.appex/Contents/MacOS/W", 30),
        p(50, 1, "/Applications/WhatsApp.app/Contents/PlugIns/S.appex/Contents/MacOS/S", 40),  // app quit
        p(51, 1, "/System/Library/Frameworks/Intents.framework/XPCServices/intents_helper.xpc/Contents/MacOS/intents_helper", 2),
    ])
    let resp: [pid_t: pid_t] = [10: 999, 11: 999, 21: 20, 51: 50]  // 999 = dead; others: -1 (unknown)
    precondition(owner(of: 11, responsible: 999, procs: procs) == 10)
    precondition(owner(of: 21, responsible: 20, procs: procs) == 20)
    let groups = group(procs, responsible: { resp[$0] ?? -1 })
    let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
    precondition(byName["Cursor"]!.leftover && byName["Cursor"]!.procs.map(\.pid) == [10, 11])
    precondition(!byName["Claude"]!.leftover && byName["Claude"]!.mem == 1300 << 20)
    precondition(byName["iOS Simulator"]!.leftover && !byName["Weather"]!.leftover && !byName["macOS"]!.leftover)
    precondition(!byName["WhatsApp"]!.leftover && byName["WhatsApp"]!.procs.map(\.pid) == [50, 51])
    precondition(groups.map(\.name) == ["Cursor", "iOS Simulator", "Claude", "WhatsApp", "Weather", "macOS"])
    // CLI.swift: a stray or misspelt flag must never turn into a stop.
    precondition(parseArgs([]) == nil && parseArgs(["-h"]) == .help)
    precondition(parseArgs(["--json", "--cpu"]) == .json(cpu: true) && parseArgs(["--stop", "--json"]) == .json(cpu: false))
    precondition(parseArgs(["Cursor", "--dry-run", "--stop", "iOS Simulator"], uid: 501) == .stop(names: ["Cursor", "iOS Simulator"], dryRun: true))
    precondition(parseArgs(["--stop", "--dryrun"]) == .bad("unknown flag: --dryrun") && parseArgs(["--stop", "--cpu"], uid: 501) == .bad("unknown flag for --stop: --cpu"))
    precondition(parseArgs(["--dry-run"]) == .bad("--dry-run works only with --stop"))
    // A typo must not start the menu bar app (it never exits); Cocoa's own args must.
    precondition(parseArgs(["--leftover"]) == .bad("unknown flag: --leftover") && parseArgs(["--json", "--cpuu"]) == .bad("unknown flag: --cpuu"))
    precondition(parseArgs(["-NSDocumentRevisionsDebugMode", "YES", "-psn_0_1"]) == nil)
    #if DEBUG
    precondition(parseArgs(["--snapshot", "x.png"]) == nil && parseArgs(["--snapshot"]) == .bad("--snapshot needs OUT.png"))
    #else
    precondition(parseArgs(["--snapshot", "x.png"]) == .bad("--snapshot works only in debug builds"))
    #endif
    // As root (sudo) every root daemon would count as this user's: no --stop, even dry.
    precondition(parseArgs(["--stop", "--dry-run"], uid: 0) == .bad("--stop does not run as root: run it without sudo"))
    precondition(parseArgs(["--json"], uid: 0) == .json(cpu: false))
    precondition(stopTargets(groups, []).targets.map(\.name) == ["Cursor", "iOS Simulator"])
    let named = stopTargets(groups, ["cursor", "Claude", "nope"])  // Claude is open: not a leftover
    precondition(named.targets.map(\.name) == ["Cursor"] && named.missing == ["Claude", "nope"])
    let json = try! JSONSerialization.jsonObject(with: jsonReport(groups, sys: SysMem(swap: 2, level: 2), cpu: false)) as! [String: Any]
    let cursor = (json["groups"] as! [[String: Any]])[0]
    precondition(json["swap"] as? Int64 == 2 && json["pressure"] as? String == "warning")
    precondition(cursor["name"] as? String == "Cursor" && cursor["leftover"] as? Bool == true)
    precondition(cursor["memory"] as? Int64 == 800 << 20 && cursor["processCount"] as? Int == 2 && cursor["cpu"] == nil)
    var cp = procs
    cp[10]!.cpuTime = 3_000_000_000; cp[11]!.cpuTime = 1_000_000_000
    addCPU(&cp, prev: [10: 1_000_000_000, 11: 2_000_000_000], seconds: 4)
    precondition(cp[10]!.cpu == 50 && cp[11]!.cpu == 0 && cp[20]!.cpu == 0)  // 2 s in 4 s; 11 = reused PID

    // Ports: network byte order in, IPv4 + IPv6 of one port = one port.
    precondition(ports(fromLPorts: [Int32(UInt16(3000).bigEndian), Int32(UInt16(9229).bigEndian), Int32(UInt16(3000).bigEndian)]) == [3000, 9229])
    precondition(portsText([3000, 9229]) == ":3000 :9229" && portsText([1, 2, 3, 4], limit: 2) == ":1 :2 +2" && portsText([]) == "")
    precondition(portMatch([3000, 9229], "3000") && portMatch([3000], ":3000") && !portMatch([3000], "300") && !portMatch([3000], ":"))
    precondition(portsHelp([80]) == "Listens on TCP port :80" && portsHelp([3000, 9229]) == "Listens on TCP ports :3000 :9229")
    precondition(portsLabel([]) == "" && portsLabel([80]) == ", listens on port 80" && portsLabel([80, 443]) == ", listens on ports 80, 443")
    var pp = procs
    addPorts(&pp, [11: [3000], 20: [9229, 3000], 777: [1]])  // 777: gone since the read
    let pg = Dictionary(uniqueKeysWithValues: group(pp, responsible: { resp[$0] ?? -1 }).map { ($0.name, $0) })
    precondition(pg["Cursor"]!.ports == [3000] && pg["Claude"]!.ports == [3000, 9229] && pg["macOS"]!.ports.isEmpty)
    precondition(matching(pg["Cursor"]!, ":3000").map(\.pid) == [11] && matching(pg["Claude"]!, "9229").map(\.pid) == [20])
    historySelfTest()

    var vm = vm_statistics64()  // in pages of 16 KB
    vm.internal_page_count = 100; vm.purgeable_count = 10; vm.wire_count = 20; vm.compressor_page_count = 5; vm.external_page_count = 30
    let sm = SysMem(vm, page: 16384, swap: 7, level: 4, free: 30)
    precondition(sm.app == 90 * 16384 && sm.ram == 115 * 16384 && sm.cached == 40 * 16384 && sm.swap == 7)
    precondition(sm.pressure == .critical && sm.usedPct == 70 && SysMem().usedPct == 0 && SysMem(level: 3).pressure == .normal)
    precondition(Pressure(rawValue: 2)?.label == "Warning" && Pressure.warning.color == .yellow && Pressure.critical.color == .red)
    precondition(menuState(.critical, waste: 1).dot == .systemRed && menuState(.warning, waste: 1).dot == .systemOrange)
    precondition(menuState(.normal, waste: 1).dot == .systemYellow && menuState(.normal, waste: 0).dot == nil)
    precondition(menuState(.normal, waste: 0).desc == "AppMem" && menuState(.normal, waste: 0).tip == "AppMem: no leftovers")
    precondition(menuState(.warning, waste: 1 << 30).desc == "AppMem, memory pressure warning, leftovers found")
    precondition(menuState(.warning, waste: 1 << 30).tip == "Memory pressure: Warning\nLeftovers use 1.00 GB")

    // Usage: idle apps and leftover age.
    precondition(ago(20) == "1 min" && ago(45 * 60) == "45 min" && ago(3 * 3600 + 3599) == "3 h" && ago(49 * 3600) == "2 d")
    let now = Date(), h: TimeInterval = 3600, claude = byName["Claude"]!  // open, 1300 MB
    precondition(idleTime(claude, lastFront: now - 2 * h, now: now) == 2 * h)
    precondition(idleTime(claude, lastFront: now - h, now: now) == nil && idleTime(claude, lastFront: nil, now: now) == nil)
    precondition(idleTime(byName["Cursor"]!, lastFront: now - 3 * h, now: now) == nil)  // leftover
    precondition(idleTime(byName["Weather"]!, lastFront: now - 3 * h, now: now) == nil)  // 30 MB
    precondition(idleTime(Group(name: "macOS", isApp: false, procs: claude.procs), lastFront: now - 3 * h, now: now) == nil)
    precondition(started(getpid())!.timeIntervalSinceNow < 0 && started(-5) == nil)
    var sim = byName["iOS Simulator"]!  // booted 1 h ago (30); a CoreSimulator daemon from last week must not date it
    sim.procs.append(p(31, 1, "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged", 5).1)
    let since: [pid_t: Date] = [30: now - h, 31: now - 168 * h, 10: now - 3 * h, 11: now - h]
    precondition(leftoverAge(sim, started: { since[$0] }, now: now) == h && leftoverAge(byName["Cursor"]!, started: { since[$0] }, now: now) == 3 * h)
    precondition(leftoverAge(claude, started: { since[$0] }, now: now) == nil)  // open: no age

    do {  // right-click actions: who may get a signal, which items apply
        let cursor = byName["Cursor"]!, weather = byName["Weather"]!
        precondition(allowed(cursor, app: false, uid: 501, me: 99) == Allowed(quit: true, pause: true))
        precondition(allowed(cursor, app: false, uid: 502, me: 99) == Allowed())  // other users
        precondition(!maySignal(procs[10]!, in: cursor, uid: 501, me: 10) && !maySignal(procs[11]!, in: cursor, uid: 501, me: 10))  // AppMem, its child
        precondition(allowed(byName["macOS"]!, app: true, uid: 501, me: 99) == Allowed())  // even with an app
        precondition(!maySignal(procs[1]!, in: cursor, uid: 501, me: 99))  // launchd, in any group
        precondition(allowed(byName["iOS Simulator"]!, app: false, uid: 501, me: 99) == Allowed())
        // Apple's own: no signals, but its app can be asked to quit; in a third-party app's group, signals
        precondition(allowed(weather, app: false, uid: 501, me: 99) == Allowed() && allowed(weather, app: true, uid: 501, me: 99) == Allowed(quit: true, restart: true))
        precondition(maySignal(procs[51]!, in: byName["WhatsApp"]!, uid: 501, me: 99))
        var paused = cursor
        paused.procs[0].stopped = true
        precondition(!isPaused(paused, uid: 501) && allowed(paused, app: false, uid: 501, me: 99) == Allowed(quit: true, pause: true, resume: true))
        paused.procs[1].stopped = true
        precondition(isPaused(paused, uid: 501) && !isPaused(paused, uid: 502) && allowed(paused, app: false, uid: 501, me: 99) == Allowed(quit: true, resume: true))
        precondition(allowed(paused.procs[0], in: paused, uid: 501, me: 99) == Allowed(quit: true, resume: true))
        precondition(allowed(procs[11]!, in: cursor, uid: 501, me: 99) == Allowed(quit: true, pause: true))
        precondition(summaryText(cursor) == "Cursor: 800 MB, CPU –, 2 processes\n  500 MB  CPU –  PID 10  node\n  300 MB  CPU –  PID 11  node")
        precondition(summaryText(pg["Cursor"]!).hasSuffix("PID 10  node\n  300 MB  CPU –  PID 11  node  :3000"))
    }

    // Process tree: nesting, memory order among siblings, orphans are roots, loops end.
    func t(_ ps: [(pid_t, Proc)]) -> [String] { tree(ps.map(\.1)).map { "\($0.proc.pid):\($0.depth)" } }
    precondition(t([p(5, 1, "/r", 50), p(9, 99, "/orphan", 45), p(7, 5, "/big", 40), p(8, 7, "/grand", 30), p(6, 5, "/small", 10)])
                 == ["5:0", "7:1", "8:2", "6:1", "9:0"])
    precondition(t([p(3, 4, "/a", 2), p(4, 3, "/b", 1), p(0, 0, "kernel_task", 9)]) == ["0:0", "3:0", "4:1"])
    let args = withUnsafeBytes(of: Int32(3)) { Array($0) } + Array("/bin/node\0\0\0node\0\0--port=1\0PATH=/x\0".utf8)
    precondition(argv(args) == ["node", "", "--port=1"] && argv([1, 0]) == [] && argv(procArgs(getpid()) ?? []).contains("--test"))
    precondition(commandLine("/bin/node", ["node", "a.js"]) == "/bin/node a.js" && commandLine("/x", []) == "/x")
    precondition(commandLine("/x", ["x", String(repeating: "a", count: 500)]).count == 300)
    // node's process.title over argv: the title, not the path and blanks
    precondition(commandLine("/bin/node", ["next-server (v15.0.0)", "", "", ""]) == "next-server (v15.0.0)")
    let mixed = Group(name: "X", isApp: true, procs: [procs[10]!, Proc(pid: 2, ppid: 1, uid: 0, path: "/usr/sbin/d", mem: 1)])
    precondition(othersHelp(mixed, uid: 501).hasPrefix("1 of 2 ") && othersHelp(mixed, uid: 7).hasPrefix("All ")
                 && othersHelp(byName["Cursor"]!, uid: 501) == "")

    // Settings: refresh choices, the ignore list, the list filters
    precondition(refreshSeconds(2) == 2 && refreshSeconds(5) == 5 && refreshSeconds(0) == 3 && refreshSeconds(-1) == 3)
    let ig = ignoring(groups, ["Cursor"])
    precondition(ig.filter(\.leftover).map(\.name) == ["iOS Simulator"] && ig.map(\.name) == groups.map(\.name))
    precondition(ignoring(groups, ["cursor"]).first { $0.name == "Cursor" }!.leftover)  // exact names only
    let mix = [byName["Claude"]!, byName["macOS"]!, Group(name: "Tiny", isApp: true, procs: [p(60, 1, "/t", 9).1]),
               Group(name: "TinyLeft", isApp: true, procs: [p(61, 1, "/u", 1).1], leftover: true)]  // macOS: 10 MB, not under
    precondition(visible(mix, hideSmall: true, showMacOS: true).shown.map(\.name) == ["Claude", "macOS", "TinyLeft"])
    precondition(visible(mix, hideSmall: true, showMacOS: false).small.map(\.name) == ["Tiny"])
    precondition(visible(mix, hideSmall: false, showMacOS: false).shown.count == 3)
    var tinyPaused = mix[2]
    tinyPaused.procs[0].stopped = true  // paused from the right-click menu: it must stay findable
    precondition(visible([tinyPaused], hideSmall: true, showMacOS: true).shown.count == 1)
    // An ignored leftover's app is not open: not idle. An ignored app that is open can be.
    precondition(ig[0].ignored && !ig[1].ignored && idleTime(ig[0], lastFront: now - 3 * h, now: now) == nil)
    precondition(idleTime(ignoring([claude], ["Claude"])[0], lastFront: now - 2 * h, now: now) == 2 * h)
    precondition(ignoring(groups, ["Claude"]).allSatisfy { !$0.ignored })  // open: nothing to unflag
    var back = groups
    back[0].respawns = "x"  // Cursor came back after Stop: the respawn icon is a badge too
    precondition(ignoring(back, ["Cursor"])[0].respawns == nil && ignoring(back, [])[0].respawns == "x")
    recallTest()
    print("ok")
}
