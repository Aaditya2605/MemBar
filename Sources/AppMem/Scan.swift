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
    var peak: Int64 = 0  // the most memory since it started; 0 when not readable (other users)
    var io = IO()  // energy and disk counters, and their rates since the previous scan (Energy.swift)
    var name: String { String((path.split(separator: "/").last ?? "?").drop { $0 == "-" }) }
}

struct Group: Identifiable {
    let name: String
    let isApp: Bool  // a non-Apple app, not a bare executable; isLeftover() also flags the simulator, orphaning() orphans
    var procs: [Proc] = []
    var leftover = false
    var bundle: String?  // the app's .app folder, for its icon
    var ignored = false  // a leftover that ignoring() unflagged: its app is still not open
    var respawns: String?  // it came back after Stop: why (see Recall)
    var orphan = false  // its processes were left by a terminal or agent that is gone (see Orphans)
    var recalled = false  // holds a command-line process that only Recall's memory puts in this app's group
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
    if isEmulatorPath(path) { return ("Android Emulator", true) }  // Google's app, not a plain executable: it can be a leftover
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
        // An iPhone/iPad app on a Mac runs from `Wrapper/<X>.app/<exe>`: no Contents/MacOS. Only
        // under Wrapper: the simulator's own Maps.app/Maps must not hide a "Google Maps" leftover.
        if p.count >= 4, !p[p.count - 1].isEmpty, p[p.count - 3] == "Wrapper", p[p.count - 2].count > 4, p[p.count - 2].hasSuffix(".app") {
            return p[p.count - 2].dropLast(4).lowercased()
        }
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
    if g.isVM { return false }  // Containers.swift: its app's window is often closed on purpose
    if g.isSimulator {  // launchd_sim = a booted device; agents boot them with no window
        return !open.contains("simulator") && g.procs.contains { $0.name == "launchd_sim" }
    }
    // ponytail: Stop's SIGKILL after 3 s can cut the emulator's quickboot snapshot save
    // short; its next boot is then cold.
    if g.isEmulator { return !open.contains { $0.hasPrefix("android studio") } }  // Android Studio Preview.app too
    // An app of its own that runs inside this group's folder (Instruments or FileMerge in
    // Xcode.app, an IDE in Application Support/JetBrains) shares no word with the group
    // name: it is open, not a leftover. Not a headless Chrome that an agent started: its
    // own folder is not the group's.
    return g.isApp && !isOpen(g.name, open) && !g.procs.contains { appOf($0.path).name == g.name && !openApps([$0.path]).isEmpty }
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
        if owners[top]?.app == topPath { groups[key]!.recalled = true }
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

/// A tool's stdout; empty if it cannot run. Read before wait: a full pipe would block the tool.
func output(_ exe: String, _ args: [String]) -> Data {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return Data() }
    defer { p.waitUntilExit() }
    return pipe.fileHandleForReading.readDataToEndOfFile()
}

/// Footprint via top, for processes that proc_pid_rusage refuses (root and other
/// users). top costs about 0.35 s of CPU, so callers cache it.
func topMem() -> [pid_t: Int64] {
    let data = output("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"])
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
        var ri = rusage_info_v6()  // V6, not V4: its ri_energy_nj is the process's own energy (Energy.swift)
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        } == 0
        procs[pid] = Proc(pid: pid, ppid: pid_t(s.pbsi_ppid), uid: s.pbsi_uid, path: path(of: pid, comm: comm(s)),
                          mem: ok ? Int64(ri.ri_phys_footprint) : top[pid] ?? 0,
                          cpuTime: ok ? UInt64(Double(ri.ri_user_time + ri.ri_system_time) * nsPerTick) : 0,
                          stopped: s.pbsi_status == SSTOP, peak: ok ? Int64(ri.ri_lifetime_max_phys_footprint) : 0)
        if ok { procs[pid]!.io = IO(ri) }
    }
    return procs
}

// MARK: - Stop

// Same PID and same executable as in the scan, so a reused PID is left alone.
func same(_ p: Proc) -> Bool { shortInfo(p.pid).map { path(of: p.pid, comm: comm($0)) == p.path } ?? false }

/// App leftover or orphan: SIGTERM, then SIGKILL after 3 s for the ones that still run.
/// Simulator: shut down each booted device, in its own set. Never the macOS group, never other users.
func stop(_ g: Group) {
    guard g.leftover || g.orphan, g.name != "macOS" else { return }
    if g.isSimulator {
        for l in g.procs where l.name == "launchd_sim" && l.uid == getuid() {
            guard let d = simDevice(argv(procArgs(l.pid) ?? [])) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "--set", d.set, "shutdown", d.udid]
            try? p.run()
        }
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
    let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_23A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot"
    precondition(openApps(["/Applications/Foo.app/Wrapper/Foo.app/Foo"]) == ["foo"] && openApps([runtime + "/Applications/Maps.app/Maps"]).isEmpty)
    let xcode = "/Applications/Xcode.app/Contents/", agent = "/Users/a/Library/Application Support/Cursor/node"
    for tool in ["Applications/Instruments.app/Contents/MacOS/Instruments", "Developer/Applications/Simulator.app/Contents/MacOS/Simulator"] {
        let g = Group(name: "Xcode", isApp: true, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: xcode + tool, mem: 0)])
        precondition(!isLeftover(g, open: openApps(g.procs.map(\.path))))  // Xcode quit, its tool is still in use
    }
    let headless = Group(name: "Cursor", isApp: true, procs: [Proc(pid: 3, ppid: 1, uid: 501, path: agent, mem: 0),
        Proc(pid: 4, ppid: 3, uid: 501, path: "/Users/a/.cache/puppeteer/chrome/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", mem: 0)])
    precondition(isLeftover(headless, open: openApps(headless.procs.map(\.path))))

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
    do {  // Energy.swift: power and disk rates between scans, their text
        func io(_ start: UInt64, _ nJ: UInt64, _ read: UInt64, _ write: UInt64) -> IO { IO(start: start, energy: nJ, read: read, write: write) }
        let prev: [pid_t: IO] = [10: io(7, 3_000_000_000, 1 << 20, 0), 11: io(5, 1, 0, 0), 20: io(9, 5000, 0, 0)]
        var ps = procs
        ps[10]!.io = io(7, 9_000_000_000, 3 << 20, 1 << 20)  // +6 J, +2 MB read, +1 MB written
        ps[11]!.io = io(8, 9_000_000_000, 4 << 20, 0)  // a reused PID: another start, higher counters
        ps[20]!.io = io(9, 1000, 0, 0)  // a counter that went back
        ps[21]!.io = io(3, 9_000_000_000, 1 << 30, 0)  // new since the last scan
        var still = ps
        addIO(&ps, prev: prev, seconds: 2)
        precondition(ps[10]!.io.power == 3000 && ps[10]!.io.readRate == 1_048_576 && ps[10]!.io.writeRate == 524_288 && ps[10]!.io.disk == 1_572_864)
        precondition([11, 20, 21].allSatisfy { ps[$0]!.io.power == 0 && ps[$0]!.io.disk == 0 })
        addIO(&still, prev: prev, seconds: 0)  // no time: no rate, never a division by 0
        precondition(still.values.allSatisfy { $0.io.power == 0 && $0.io.disk == 0 })
        precondition(perSecond(10, 4, 2) == 3 && perSecond(4, 10, 2) == 0 && perSecond(10, 4, 0) == 0 && perSecond(10, 4, -1) == 0)
        let g = Group(name: "Cursor", isApp: true, procs: [ps[10]!, ps[11]!])
        precondition(g.power == 3000 && g.disk == 1_572_864)
        precondition(watts(0.4) == "–" && watts(350) == "350 mW" && watts(999.6) == "1.0 W" && watts(12_340) == "12.3 W")
        precondition(diskText(1000) == "–" && diskText(1000, none: "0") == "0" && diskText(120 * 1024) == "120 KB/s")
        precondition(diskText(999 * 1024) == "999 KB/s" && diskText(3 * 1_048_576) == "3 MB/s" && diskText(1536 * 1_048_576) == "1.5 GB/s")
        precondition(cpuHelp(g) == "% of one core since the last scan\nPower about 3.0 W · Disk 2 MB/s")
        precondition(ioNote(Group(name: "A", isApp: true, procs: [ps[11]!])) == nil && cpuHelp(Group(name: "A", isApp: true)) == "% of one core since the last scan")
        var busy = ps[11]!
        busy.io.power = 120; busy.io.readRate = 921_600  // 0.12 W, but under 1 MB/s (900 KB/s)
        precondition(ioNote(Group(name: "A", isApp: true, procs: [busy])) == "Power about 120 mW")
        precondition(diskHelp(ps[10]!.io) == "Read 1 MB/s, write 512 KB/s since the last scan" && diskHelp(busy.io) == "Read 900 KB/s, write 0 since the last scan")
        precondition(diskHelp(IO()) == "Not readable: it runs as another user")
        precondition(scan(top: [:])[getpid()]!.io.start > 0)  // the V6 call works here
    }

    // Ports: network byte order in, IPv4 + IPv6 of one port = one port.
    precondition(ports(fromLPorts: [Int32(UInt16(3000).bigEndian), Int32(UInt16(9229).bigEndian), Int32(UInt16(3000).bigEndian)]) == [3000, 9229])
    precondition(portsText([3000, 9229]) == ":3000 :9229" && portsText([1, 2, 3, 4], limit: 2) == ":1 :2 +2" && portsText([]) == "")
    do {  // the row's port chip: only where a port tells what the group is
        var cli = Group(name: "node", isApp: false, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: "/opt/node", mem: 1)])
        cli.procs[0].ports = [3000]
        var app = cli; app.bundle = "/Applications/Spotify.app"
        var left = app; left.leftover = true
        let mac = Group(name: "macOS", isApp: false, procs: cli.procs)
        precondition(showsPorts(cli) && !showsPorts(app) && !showsPorts(mac) && showsPorts(left))
        cli.procs[0].ports = []
        precondition(!showsPorts(cli))
    }
    precondition(portMatch([3000, 9229], "3000") && portMatch([3000], ":3000") && !portMatch([3000], "300") && !portMatch([3000], ":"))
    precondition(portsHelp([80]) == "Listens on TCP port :80" && portsHelp([3000, 9229]) == "Listens on TCP ports :3000 :9229")
    precondition(portsLabel([]) == "" && portsLabel([80]) == ", listens on port 80" && portsLabel([80, 443]) == ", listens on ports 80, 443")
    var pp = procs
    addPorts(&pp, [11: [3000], 20: [9229, 3000], 777: [1]])  // 777: gone since the read
    let pg = Dictionary(uniqueKeysWithValues: group(pp, responsible: { resp[$0] ?? -1 }).map { ($0.name, $0) })
    precondition(pg["Cursor"]!.ports == [3000] && pg["Claude"]!.ports == [3000, 9229] && pg["macOS"]!.ports.isEmpty)
    precondition(matching(pg["Cursor"]!, ":3000").map(\.pid) == [11] && matching(pg["Claude"]!, "9229").map(\.pid) == [20])
    historySelfTest()
    dayTest()  // Day.swift

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
        precondition(allowed([paused.procs[0]], in: paused, uid: 501, me: 99) == Allowed(quit: true, resume: true))
        precondition(allowed([procs[11]!], in: cursor, uid: 501, me: 99) == Allowed(quit: true, pause: true))
        precondition(summaryText(cursor) == "Cursor: 800 MB, CPU –, 2 processes\n  500 MB  CPU –  PID 10  node\n  300 MB  CPU –  PID 11  node")
        precondition(summaryText(pg["Cursor"]!).hasSuffix("PID 10  node\n  300 MB  CPU –  PID 11  node  :3000"))
    }

    do {  // MenuBar.swift: the text next to the icon, the quick menu's info line, Copy Report, appmem:// URLs
        let gb: Int64 = 1 << 30, fs = "\u{2007}"  // figure space: as wide as a digit
        precondition(short(850 << 20) == "850 MB" && short(999 << 20) == "999 MB" && short(1000 << 20) == "1.0 GB" && short(16 * gb) == "16.0 GB")
        precondition(padDigits("3.2 GB", 3) == fs + "3.2 GB" && padDigits("50 MB", 3) == fs + "50 MB" && padDigits("100%", 2) == "100%")
        var s = SysMem(level: 2, free: 47)
        s.app = 11 * gb + (100 << 20)
        precondition(menuBarText(.icon, sys: s, waste: gb) == "" && menuBarText(.leftovers, sys: s, waste: 0) == "")
        precondition(menuBarText(.leftovers, sys: s, waste: 850 << 20) == "850 MB" && menuBarText(.ram, sys: s, waste: 0) == "11.1 GB")
        precondition(menuBarText(.pressure, sys: s, waste: 0) == "53%" && menuBarText(.pressure, sys: SysMem(free: 95), waste: 0) == fs + "5%")
        // Same width from scan to scan: as many characters for 9.8 GB as for 19.8 GB.
        precondition(menuBarText(.leftovers, sys: s, waste: gb * 98 / 10).count == menuBarText(.leftovers, sys: s, waste: gb * 198 / 10).count)
        precondition(infoLine(s, physical: 16 * gb) == "RAM 11.1 GB of 16 GB · Pressure 53%")
        var rg = groups
        rg[0].respawns = "x"  // Cursor
        rg.append(Group(name: "A|B", isApp: false, procs: [Proc(pid: 70, ppid: 1, uid: getuid(), path: "/t", mem: 5 << 20, stopped: true)]))
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 5))!
        precondition(report(groups: rg, sys: s, date: date, physical: 16 * gb, flags: { $0.name == "Claude" ? ["idle"] : [] }) == """
            ## AppMem report, 2026-10-03 14:05

            - RAM used: 11.10 GB of 16 GB
            - Swap: 0 MB
            - Memory pressure: Warning, 53%
            - Leftovers: 850 MB (Cursor 800 MB, iOS Simulator 50 MB)

            | App | Memory | CPU | Processes | Flags |
            |:--|--:|--:|--:|:--|
            | Claude | 1.27 GB | – | 2 | idle |
            | Cursor | 800 MB | – | 2 | leftover, respawns |
            | iOS Simulator | 50 MB | – | 1 | leftover |
            | WhatsApp | 42 MB | – | 2 |  |
            | Weather | 30 MB | – | 1 |  |
            | macOS | 10 MB | – | 1 |  |
            | A\\|B | 5 MB | – | 1 | paused |
            """)
        let many = (0..<20).map { Group(name: "G\($0)", isApp: false, procs: [Proc(pid: pid_t(100 + $0), ppid: 1, uid: 501, path: "/g", mem: 1 << 20)]) }
        let r = report(groups: many, sys: s, date: date)
        precondition(r.split(separator: "\n").filter { $0.hasPrefix("| G") }.count == 15 && r.hasSuffix("\n\n_5 more groups: 5 MB_"))
        precondition(report(groups: [], sys: s, date: date).contains("\n- Leftovers: none\n"))
        // No URL stops anything: any web page can open one.
        precondition(urlCommand("appmem://open") == .open && urlCommand("appmem://open/") == .open && urlCommand("appmem:open") == .open)
        precondition(urlCommand("AppMem://Report") == .report && urlCommand("appmem://refresh?x=1") == .refresh)
        precondition(urlCommand("appmem://stop") == nil && urlCommand("appmem://open/stop") == nil && urlCommand("https://open") == nil && urlCommand("appmem://") == nil)
        // In an extension: AppKit calls it only if Objective-C sees it, else no URL works.
        precondition(Delegate.instancesRespond(to: NSSelectorFromString("applicationWillFinishLaunching:")))
    }

    do {  // MenuGraph.swift: the RAM Graph's samples, line and tooltip
        let t0 = Date(timeIntervalSince1970: 1_000_000), gb: Int64 = 1 << 30, size = CGSize(width: 28, height: 14)
        func s(_ sec: Double, _ ram: Int64 = 8 << 30) -> Sample { Sample(at: t0 + sec, ram: ram, swap: 0, groups: [:]) }
        // One a minute: the open panel's (each 15 s) thinned, the closed ones (60 to 70 s apart) all kept; the newest 29.
        precondition(graphSamples((0...40).map { s(Double($0) * 15) }).map(\.at) == (0...10).map { t0 + Double($0) * 60 })
        let hour = (0..<60).map { s(Double($0) * 65) }, kept = graphSamples(hour)
        precondition(kept.count == 29 && kept.first!.at == hour[31].at && kept.last!.at == hour[59].at)
        precondition(graphSamples([]).isEmpty && graphSamples([s(0)]).count == 1)
        // 0 to all the RAM on the height, 0.5 pt in for the line, on 0.5 pt steps; over the full width.
        let pts = graphPoints([0, 8 * gb, 16 * gb, 20 * gb], top: 16 * gb, size: size)
        precondition(pts.map(\.y) == [0.5, 7, 13.5, 13.5] && pts.map(\.x) == [0, 28.0 / 3, 56.0 / 3, 28])
        precondition(graphPoints([gb], top: 16 * gb, size: size) == [CGPoint(x: 0, y: 1.5), CGPoint(x: 28, y: 1.5)])  // one: flat, full width
        precondition(graphPoints(Array(repeating: 8 * gb, count: 29), top: 16 * gb, size: size).allSatisfy { $0.y == 7 })  // flat
        precondition(graphPoints([], top: 16 * gb, size: size).isEmpty && graphPoints([gb], top: 0, size: size).isEmpty)
        precondition(graphTip([s(0, 11 * gb), s(1680, 11 * gb + (307 << 20))], physical: 16 * gb) == "RAM used in the last 28 min: 11.0 GB to 11.3 GB of 16 GB")
        precondition(graphTip([s(0, 11 * gb)], physical: 16 * gb) == "RAM used in the last 1 min: 11.0 GB of 16 GB")
        precondition(menuBarText(.graph, sys: SysMem(level: 4), waste: gb) == "")  // the graph is the image, no text
        // updateIcon keeps an image whose description is the state's: the graph must have the plain icon's.
        let icon = Delegate.graphIcon(menuState(.warning, waste: gb), ram: [], top: 16 * gb, pressure: .warning)
        precondition(icon.accessibilityDescription == menuState(.warning, waste: gb).desc && icon.size == NSSize(width: 48, height: 14))
    }

    do {  // Export.swift: Save Report's CSV, one row per process; a name with a comma, a quote or a line break stays one field
        precondition(csvField("node") == "node" && csvField("") == "" && csvField("a,b") == "\"a,b\"" && csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        precondition(csvField("a\nb") == "\"a\nb\"" && csvField("a\r\nb") == "\"a\r\nb\"" && csvField("a\rb") == "\"a\rb\"")
        var odd = Group(name: "Foo, \"Bar\"", isApp: true, procs: [Proc(pid: 7, ppid: 1, uid: 0, path: "/x/two\nlines", mem: 5 << 20, stopped: true),
                                                                Proc(pid: 8, ppid: 7, uid: 501, path: "/x/b", mem: 1 << 20)], leftover: true)
        odd.procs[0].cpu = 12.34; odd.procs[0].ports = [3000, 9229]; odd.respawns = "x"
        precondition(csvReport([odd], flags: { _ in ["idle"] }, user: { $0 == 0 ? "root" : "ann" }) == #"""
            group,pid,name,user,memory_bytes,cpu_percent,ports,flags
            "Foo, ""Bar""",7,"two
            lines",root,5242880,12.3,3000 9229,leftover respawns idle paused
            "Foo, ""Bar""",8,b,ann,1048576,0.0,,leftover respawns idle

            """#)
        precondition(csvReport(groups).split(separator: "\n").count == 1 + procs.count && csvReport([]) == "group,pid,name,user,memory_bytes,cpu_percent,ports,flags\n")
        var orphan = odd
        orphan.orphan = true; orphan.respawns = nil
        precondition(flagWords(orphan) == ["orphan"] && flagWords(byName["Claude"]!).isEmpty)  // as the row: orphan, not leftover too
    }

    do {  // simulator devices, the Android emulator group
        let a = "193A1049-1F4C-44E8-83CB-BFD1ED9F19CA", b = "0D9C2F1E-7B3A-4C8D-9E6F-112233445566", devs = "/Users/a/Library/Developer/CoreSimulator/Devices/"
        precondition(udid(in: devs + a + "/data/Containers/Bundle/Application/X/My.app/My") == a)
        precondition(udid(in: "launchd_sim " + devs + a + "/data/var/run/launchd_bootstrap.plist") == a)
        let prev = "/Users/a/Library/Developer/Xcode/UserData/Previews/Simulator Devices"
        precondition(simDevice(["launchd_sim", devs + a + "/data/var/run/launchd_bootstrap.plist"])! == (String(devs.dropLast()), a))
        precondition(simDevice(["launchd_sim", prev + "/" + b + "/data/var/run/launchd_bootstrap.plist"])! == (prev, b))
        precondition(simDevice(["launchd_sim"]) == nil && simDevice([prev + "/x/data/var/run/launchd_bootstrap.plist"]) == nil)
        precondition(udid(in: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/x") == nil && udid(in: devs + "x/data") == nil)
        precondition(runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-5") == "iOS 26.5" && runtimeName("watchOS-11-0-1") == "watchOS 11.0.1")
        let json = """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {"udid": "\(a)", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true},
              {"udid": "C0FFEE00-0000-0000-0000-000000000000", "name": "iPhone SE", "state": "Shutdown"}],
             "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [{"udid": "\(b)", "name": "iPad Air", "state": "Booted"}],
             "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": []}}
            """
        precondition(bootedDevices(Data(json.utf8)) == [SimDevice(udid: b, name: "iPad Air", runtime: "iOS 18.2"),
                                                       SimDevice(udid: a, name: "iPhone 17 Pro", runtime: "iOS 26.5")])
        precondition(bootedDevices(Data("xcrun: error".utf8)).isEmpty)
        // A: its launchd_sim (100) and the tree under it; B: only by the UDID in a path; C: no process left.
        let sims = [p(100, 1, "launchd_sim", 10), p(101, 100, "/RuntimeRoot/SpringBoard.app/SpringBoard", 90), p(102, 101, "/RuntimeRoot/usr/libexec/x", 5),
                    p(103, 1, "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulatorService", 30),
                    p(104, 1, devs + b + "/data/Containers/Bundle/Application/Y/Y.app/Y", 200),
                    p(105, 1, devs + "AAAAAAAA-0000-0000-0000-000000000000/data/z", 1)].map(\.1)  // a device simctl does not list
        let da = SimDevice(udid: a, name: "A", runtime: "iOS 26.5", launchd: 100), db = SimDevice(udid: b, name: "B", runtime: "iOS 18.2")
        let lines = simLines(sims, devices: [da, db, SimDevice(udid: "C", name: "C", runtime: "iOS 26.5", launchd: 999)])
        precondition(lines.map { $0.device?.name ?? "Shared" } == ["B", "A", "Shared"])  // by memory, Shared last
        precondition(lines.map { $0.procs.map(\.pid) } == [[104], [100, 101, 102], [103, 105]])
        precondition(simLines(sims, devices: []).isEmpty && simLines([sims[3]], devices: [da]).isEmpty)  // no device line: no Shared alone

        let studio = "/Applications/Android Studio.app/Contents/MacOS/studio", sdk = "/Users/a/Library/Android/sdk/emulator/"
        precondition(appOf(sdk + "qemu/darwin-aarch64/qemu-system-aarch64") == ("Android Emulator", true) && !isCLI(sdk + "emulator"))
        let emu = Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd", 10), p(70, 1, studio, 900), p(71, 70, sdk + "emulator", 20),
                                                    p(72, 71, sdk + "qemu/darwin-aarch64/qemu-system-aarch64", 3000), p(73, 72, sdk + "crashpad_handler", 5)])
        let withStudio = group(emu, responsible: { [71: 70, 72: 70, 73: 70][$0] ?? $0 }).first { $0.isEmulator }!
        precondition(!withStudio.leftover && withStudio.procs.map(\.pid) == [72, 71, 73])  // its own group, not Android Studio's
        var quit = emu
        quit[70] = nil
        let alone = group(quit, responsible: { $0 }).first { $0.isEmulator }!
        precondition(alone.leftover && alone.isApp && alone.mem == 3025 << 20)
        precondition(!isLeftover(alone, open: ["android studio preview"]) && isLeftover(alone, open: ["xcode", "studio"]))
    }

    do {  // an emulator that an open app started stays in that app's group: no leftover, no Stop All
        let code = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", sdk = "/Users/a/Library/Android/sdk/emulator/"
        let term = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        let ps = Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd", 10), p(60, 1, code, 500), p(61, 60, "/bin/zsh", 5),
                                                   p(62, 61, sdk + "emulator", 20), p(63, 62, sdk + "qemu/darwin-aarch64/qemu-system-aarch64", 3000),
                                                   p(64, 63, sdk + "crashpad_handler", 5)])
        let byCode = group(ps, responsible: { [61: 60, 62: 60, 63: 60, 64: 60][$0] ?? $0 })
        let vs = byCode.first { $0.name == "Visual Studio Code" }!
        precondition(!byCode.contains { $0.isEmulator || $0.leftover } && Set(vs.procs.map(\.pid)) == [60, 61, 62, 63, 64])
        var fromTerm = ps
        fromTerm[60] = p(60, 1, term, 80).1  // `emulator -avd X` in Terminal
        precondition(!group(fromTerm, responsible: { [61: 60, 62: 60, 63: 60, 64: 60][$0] ?? $0 }).contains { $0.isEmulator || $0.leftover })
        var quit = ps  // VS Code quit, the shell with it: the emulator alone is its own group, a leftover
        quit[60] = nil; quit[61] = nil
        quit[62] = p(62, 1, sdk + "emulator", 20).1
        let alone = group(quit, responsible: { $0 }).first { $0.isEmulator }!
        precondition(alone.leftover && Set(alone.procs.map(\.pid)) == [62, 63, 64])
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

    do {  // keyboard: the next selection, the selection after a refresh, keys that type, Stop
        let a = RowID(group: "A"), a1 = RowID(group: "A", pid: 1), b = RowID(group: "B"), ids = [a, a1, b]
        precondition(move(nil, in: ids, by: 1) == a && move(nil, in: ids, by: -1) == b && move(nil, in: [], by: 1) == nil)
        precondition(move(a, in: ids, by: 1) == a1 && move(a1, in: ids, by: 1) == b && move(b, in: ids, by: 1) == b)  // stops at the end
        precondition(move(a, in: ids, by: -1) == a && move(b, in: ids, by: -1) == a1 && move(RowID(group: "gone"), in: ids, by: 1) == a)
        precondition(kept(a1, in: ids) == a1 && kept(b, in: [b, a]) == b)  // by id: a reorder keeps it
        precondition(kept(a1, in: [a, b]) == a && kept(RowID(group: "B", pid: 9), in: [a]) == nil && kept(nil, in: ids) == nil)
        precondition(types("a") && types("C") && types(":") && types("3") && types("é"))
        precondition(!types("") && !types(" ") && !types("\r") && !types("\t") && !types("\u{1b}") && !types("\u{7f}") && !types("\u{F701}"))
        let cursor = byName["Cursor"]!, sim = byName["iOS Simulator"]!
        precondition(canStop(cursor, uid: 501) && !canStop(cursor, uid: 502) && canStop(sim, uid: 502) && !canStop(byName["Claude"]!, uid: 501))
        var orphan = Group(name: "node", isApp: false, procs: [Proc(pid: 80, ppid: 1, uid: 501, path: "/opt/homebrew/bin/node", mem: 1)])
        orphan.orphan = true  // not counted as a leftover (Settings): the row still has Stop
        precondition(canStop(orphan, uid: 501) && !canStop(orphan, uid: 502))
        let many = (1...12).map { Proc(pid: pid_t($0), ppid: 1, uid: 501, path: "/x", mem: 1) }
        precondition(procLines(many, all: false).count == 10 && procLines(many, all: true).count == 12)
    }

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
    let hid = visible(mix, hideSmall: true, showMacOS: false)  // the header's Apps total sums both: no macOS in it
    precondition((hid.shown + hid.small).map(\.name).sorted() == ["Claude", "Tiny", "TinyLeft"])
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

    do {  // Auto.swift: auto-stop, Quit When Idle, the log. Fake data only: these rules act.
        let t0 = Date(timeIntervalSince1970: 1_000_000), m: TimeInterval = 60
        precondition(autoStopAfter(10) == 600 && autoStopAfter(60) == 3600 && autoStopAfter(0) == nil && autoStopAfter(5) == nil)
        // The clock starts at first sight, not at process start: a fresh AppMem stops nothing at once.
        let c0 = leftoverClock(groups, since: [:], now: t0)
        precondition(c0 == ["Cursor|true": t0, "iOS Simulator|false": t0])
        precondition(autoStops(groups, since: c0, after: 600, simulator: true, now: t0, uid: 501).isEmpty)
        let c1 = leftoverClock(groups, since: c0, now: t0 + 10 * m)
        precondition(c1 == c0)  // carried over
        func stops(_ gs: [Group], _ c: [String: Date], after: TimeInterval? = 600, sim: Bool = false, at: TimeInterval, uid: uid_t = 501) -> [String] {
            autoStops(gs, since: c, after: after, simulator: sim, now: t0 + at, uid: uid).map(\.name)
        }
        precondition(stops(groups, c1, at: 10 * m - 1).isEmpty && stops(groups, c1, at: 10 * m) == ["Cursor"])
        precondition(stops(groups, c1, sim: true, at: 10 * m) == ["Cursor", "iOS Simulator"])  // the simulator toggle
        let emu = Group(name: "Android Emulator", isApp: true, procs: [p(74, 1, "/Users/a/Library/Android/sdk/emulator/emulator", 20).1], leftover: true)
        precondition(stops([emu], [emu.id: t0], at: 10 * m).isEmpty)  // the same toggle: VS Code runs it with no Android Studio
        precondition(stops([emu], [emu.id: t0], sim: true, at: 10 * m) == ["Android Emulator"])
        precondition(stops(groups, c1, after: nil, sim: true, at: 9 * h).isEmpty)  // off
        precondition(stops(groups, c1, at: h, uid: 502) == [])  // only other users' processes: Stop cannot act
        precondition(stops(ignoring(groups, ["Cursor"]), c1, at: h).isEmpty)  // ignored: never
        precondition(leftoverClock(ignoring(groups, ["Cursor"]), since: c1, now: t0 + h)["Cursor|true"] == nil)
        var held = groups
        held[0].procs[0].stopped = true  // paused to resume later: never auto-stopped, and Resume gets a full wait
        let ch = leftoverClock(held, since: c1, now: t0 + h)
        precondition(ch["Cursor|true"] == nil && stops(held, ch, at: h).isEmpty && leftoverClock(groups, since: ch, now: t0 + h)["Cursor|true"] == t0 + h)
        var again = groups
        again[0].respawns = "x"  // macOS starts it again: no stop each wait
        precondition(stops(again, c1, at: h).isEmpty)
        again[0].respawns = nil
        again[0].leftover = false  // its app opened for one scan: the clock starts again
        let c2 = leftoverClock(again, since: c1, now: t0 + 20 * m)
        precondition(c2["Cursor|true"] == nil && leftoverClock(groups, since: c2, now: t0 + 21 * m)["Cursor|true"] == t0 + 21 * m)
        precondition(stoppable(byName["iOS Simulator"]!, uid: 7) && stoppable(byName["Cursor"]!, uid: 501) && !stoppable(byName["Cursor"]!, uid: 502))
        // Stop again before the rescan (double-click, Stop All, Alerts + auto-stop): acted on and counted once.
        let cur = byName["Cursor"]!, done = [cur.id: Set<pid_t>([10, 11])]
        var exiting = cur, back2 = cur
        exiting.procs.removeFirst()  // PID 10 is gone, 11 still exits: the same Stop
        back2.procs.append(p(12, 1, "/x", 1).1)  // a new PID (a respawn): a new Stop
        precondition(notStopped([cur], [:]).count == 1 && notStopped([cur, exiting], done).isEmpty && notStopped([back2], done).count == 1)
        // A server from VS Code's terminal (nohup), kept in its group by Recall after VS Code quit: by hand only.
        let code = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", node = "/opt/homebrew/bin/node"
        let kept = group(Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd", 10), p(61, 1, node, 300), p(62, 61, "/opt/homebrew/bin/esbuild", 20)]),
                         responsible: { $0 }, owners: [61: AppOwner(app: code, exe: node, uid: 501)]).first { $0.name == "Visual Studio Code" }!
        precondition(kept.leftover && kept.recalled && kept.procs.count == 2 && stops([kept], [kept.id: t0], at: h).isEmpty)
        precondition(!byName["Cursor"]!.recalled)  // its own Application Support folder: no memory needed

        // Quit When Idle: Claude is open (1300 MB); Cursor is a leftover; 5 min is no menu choice.
        let rules = ["Claude": 60, "Cursor": 60, "WhatsApp": 5, "macOS": 60]
        let last: [String: Date] = ["Claude": t0 - 2 * h, "Cursor": t0 - 2 * h, "WhatsApp": t0 - 9 * h, "macOS": t0 - 9 * h]
        func quits(_ gs: [Group], front: String? = nil, tried: [String: Date] = [:], ruled: [String: Date] = [:], at: Date = t0) -> [String] {
            idleQuits(gs, rules: rules, ruled: ruled, lastFront: { last[$0] }, frontmost: front, tried: tried, now: at).map(\.name)
        }
        precondition(quits(groups) == ["Claude"] && quits(groups, at: t0 - h - 1).isEmpty)  // idle 2 h; 59:59
        precondition(quits(groups, front: "Claude").isEmpty)  // frontmost
        precondition(idleQuits(groups, rules: rules, ruled: [:], lastFront: { _ in nil }, frontmost: nil, tried: [:], now: t0).isEmpty)  // unknown
        precondition(quits(groups, tried: ["Claude": t0 - 2 * h]).isEmpty && quits(groups, tried: ["Claude": t0 - 5 * h]) == ["Claude"])  // one ask per idle stretch
        var pausedClaude = claude
        pausedClaude.procs[0].stopped = true  // it cannot answer the quit
        precondition(quits([pausedClaude]).isEmpty && quits(ignoring([claude], ["Claude"])) == ["Claude"])
        // A rule set on an app idle for 2 h counts from when it was set: never a quit at once.
        precondition(quits(groups, ruled: ["Claude": t0 - h + 1]).isEmpty && quits(groups, ruled: ["Claude": t0 - h]) == ["Claude"])
        precondition(quits(groups, tried: ["Claude": t0 - 2 * h], ruled: ["Claude": t0 - h]).isEmpty)  // still one ask per stretch
        precondition(idleRule("Claude", rules) == 60 && idleRule("WhatsApp", rules) == nil && idleRule("Nope", rules) == nil)
        precondition(hours(60) == "1 hour" && hours(240) == "4 hours" && hours(120).capitalized == "2 Hours")

        // The log: newest first, the last 20; a Stop All of several keeps the list order.
        let es = (1...25).map { Freed.Entry(at: t0 + Double($0), name: "G\($0)", mem: 1, how: "Stop") }
        let log = es.reduce([Freed.Entry]()) { logged($0, [$1]) }
        precondition(log.count == 20 && log.first?.name == "G25" && log.last?.name == "G6")
        precondition(logged([es[0]], [es[1], es[2]]).map(\.name) == ["G2", "G3", "G1"])
        precondition(logLine(Freed.Entry(at: t0, name: "Cursor", mem: 800 << 20, how: "Auto-stop")).hasSuffix("  Auto-stop: Cursor, 800 MB"))
    }
    do { rulesTest() }  // Rules.swift: Restart When Above, Pause When in Background

    do {  // orphans with auto-stop, alerts, the report, and the emulator's own group
        let t0 = Date(timeIntervalSince1970: 1_000_000), node = "/opt/homebrew/bin/node"
        var o = Group(name: "node", isApp: false, procs: [Proc(pid: 80, ppid: 1, uid: 501, path: node, mem: 900 << 20)], leftover: true)
        o.orphan = true  // Settings > Count Orphans as Leftovers
        precondition(autoStops([o], since: [o.id: t0], after: 600, simulator: true, now: t0 + 3600, uid: 501).isEmpty)  // by hand only
        let on = AlertSettings(leftovers: true)
        let st = alertsToSend(prev: AlertState(), groups: [o], sys: SysMem(), growth: [:], now: t0, settings: on, uid: 501).0
        let a = alertsToSend(prev: st, groups: [o], sys: SysMem(), growth: [:], now: t0 + 30, settings: on, uid: 501).1
        precondition(a.count == 1 && a[0].stop && a[0].body == orphanHelp + ". Its processes use 900 MB.")
        precondition(report(groups: [o], sys: SysMem(), date: t0).hasSuffix("\n| node | 900 MB | – | 1 | orphan |"))
        // An agent's detached node (10) started the emulator (11), Android Studio runs it: it stays in its group.
        let n = Proc(pid: 10, ppid: 1, uid: 501, path: node, mem: 1 << 20)
        let e = Proc(pid: 11, ppid: 10, uid: 501, path: "/Users/a/Library/Android/sdk/emulator/emulator", mem: 1 << 20)
        let og = orphaning([Group(name: "Android Emulator", isApp: true, procs: [e]), Group(name: "node", isApp: false, procs: [n])],
                           [10, 11], procs: [10: n, 11: e], ignored: [], asLeftover: false, uid: 501)
        precondition(og.map { $0.procs.map(\.pid) } == [[11], [10]] && og.map(\.orphan) == [false, true])
    }

    do {  // Mark: memory change since a point in time
        let mb: Int64 = 1 << 20
        func g(_ name: String, _ m: Int64) -> Group { Group(name: name, isApp: true, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: "/x", mem: m * mb)]) }
        let m = Mark([g("A", 1000), g("B", 2000), g("C", 300), g("D", 9), g("E", 500), g("H", 100)], ram: 8000 * mb, at: now - 720)
        precondition(m.groups == ["A|true": 1000 * mb, "B|true": 2000 * mb, "C|true": 300 * mb, "E|true": 500 * mb, "H|true": 100 * mb])  // not D: 9 MB
        let later = [g("A", 1320), g("B", 900), g("C", 349), g("D", 30), g("F", 200), g("G", 5), g("H", 50)]
        let d = delta(mark: m, groups: later)
        precondition(d.change == ["A|true": 320 * mb, "B|true": -1100 * mb, "C|true": 49 * mb, "H|true": -50 * mb])
        precondition(d.new == ["D|true", "F|true"] && d.gone == ["E|true": 500 * mb])  // D grew past 10 MB: reads as new; G: small
        precondition(later.map(d.key) == [320 * mb, -1100 * mb, 49 * mb, 30 * mb, 200 * mb, 0, -50 * mb])
        let label = later.map { changeLabel($0, d) }
        precondition(label[0]! == ("+320 MB", .red, "+320 MB since the mark: 1000 MB then") && label[1]!.text == "−1.1 GB" && label[1]!.color == .green)
        precondition(label[2] == nil && label[6]!.text == "−50 MB" && label[3]!.text == "new" && label[4]!.text == "new" && label[5] == nil)  // 49 MB: noise
        precondition(fmtChange(0) == "0 MB" && fmtChange(-(1 << 19) + 1) == "0 MB" && fmtChange(1536 * mb) == "+1.5 GB" && fmtChange(-50 * mb) == "−50 MB" && fmtChange(1023 * mb + mb * 6 / 10) == "+1.0 GB")
        precondition(markSummary(m, ram: 9229 * mb, d, now: now) == "Since mark (12 min): RAM +1.2 GB · 2 new · 1 gone")
        precondition(markSummary(m, ram: 7900 * mb, Mark.Delta(), now: now + 3 * h) == "Since mark (3 h): RAM −100 MB")
        precondition(markHelp(m, d).hasSuffix(", RAM 7.81 GB\nGone since the mark: E 500 MB") && !markHelp(m, Mark.Delta()).contains("Gone"))
        let saved = try! JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(m))  // UserDefaults keeps it as JSON
        precondition(saved.groups == m.groups && saved.ram == m.ram && abs(saved.at.timeIntervalSince(m.at)) < 0.001)
    }

    do {  // RAMBar.swift: the RAM bar's parts, the largest groups' colors, the tooltips
        let gb: Int64 = 1 << 30
        func g(_ name: String, _ m: Int64) -> Group { Group(name: name, isApp: true, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: "/x", mem: m)]) }
        var s = SysMem()
        s.app = 8 * gb; s.wired = 2 * gb; s.compressed = gb
        // Footprints add up to 16 GB, App memory is 8: the app part is halved, and the parts add up to the RAM.
        let gs = [g("A", 6 * gb), g("B", 4 * gb), g("C", 3 * gb), g("D", 2 * gb), g("E", gb)]
        let p = segments(groups: gs, sys: s, physical: 16 * gb)
        precondition(p.map(\.name) == ["A", "B", "C", "D", "Other apps", "Wired", "Compressed", "Cached and free"] && p.map(\.colorIndex) == Array(0..<8))
        precondition(p.map(\.bytes) == [3 * gb, 2 * gb, 3 * gb / 2, gb, gb / 2, 2 * gb, gb, 5 * gb] && p.reduce(0) { $0 + $1.bytes } == 16 * gb)
        // Under App memory (other users' processes at 0 before top runs): not scaled up, Other apps takes the rest.
        let few = segments(groups: [g("A", 2 * gb), g("B", gb)], sys: s, physical: 16 * gb)  // fewer groups than slots
        precondition(few.map(\.colorIndex) == [0, 1, 4, 5, 6, 7] && few[0].bytes == 2 * gb && few[2].bytes == 5 * gb)
        precondition(segments(groups: [], sys: SysMem(), physical: 0).isEmpty && segments(groups: [g("A", 0)], sys: SysMem(), physical: 0).isEmpty)
        precondition(segments(groups: gs, sys: SysMem(), physical: 16 * gb).map(\.name) == ["Cached and free"])  // no VM numbers yet
        // A color stays with its group: B outgrows A and nothing moves; E takes the slot that D leaves.
        let k = keepSlots(gs, kept: [:])
        precondition(k == ["A|true": 0, "B|true": 1, "C|true": 2, "D|true": 3])
        let later = [g("A", 4 * gb), g("B", 7 * gb), g("C", 3 * gb), g("D", gb / 2), g("E", gb)]
        precondition(keepSlots(later, kept: k) == ["A|true": 0, "B|true": 1, "C|true": 2, "E|true": 3])
        precondition(segments(groups: later, sys: s, physical: 16 * gb, slots: keepSlots(later, kept: k)).prefix(4).map(\.name) == ["A", "B", "C", "E"])
        precondition(keepSlots([g("A", gb)], kept: k) == ["A|true": 0] && keepSlots([], kept: k).isEmpty)
        // The tooltips say when the app parts are scaled; VoiceOver hears every part.
        let note = scaleNote(gs, sys: s)!
        precondition(note.hasSuffix(" add up to 16.00 GB.") && scaleNote([g("A", 2 * gb)], sys: s) == nil)
        precondition(partHelp(p[0], note: note) == "A 3.00 GB\n" + note && partHelp(p[4], note: note).hasPrefix("Other apps 512 MB: the other groups\n"))
        precondition(partHelp(p[5], note: note) == "Wired 2.00 GB: memory the system keeps in RAM; it cannot be compressed or swapped")
        precondition(ramLabel(Array(p.suffix(2))) == "RAM: Compressed 1.00 GB, Cached and free 5.00 GB")
        precondition(ramLabel(Array(p.suffix(1)), note: note) == "RAM: Cached and free 5.00 GB. " + note)  // VoiceOver cannot reach the .help
    }
    recallTest()
    alertsTest()
    orphanTest()
    do { containersTest() }  // Containers.swift: VM owners, docker stats lines

    do {  // Details window: the extra columns, search, summary, sort keys, the multi-selection menu
        precondition(userName(0) == "root" && userName(getuid()) == NSUserName() && userName(4_000_000) == "4000000")
        precondition(threadCount(getpid())! >= 1 && threadCount(-5) == nil)
        let me = scan(top: [:])[getpid()]!
        precondition(me.mem > 0 && me.peak >= me.mem)
        let a = DetailRow(p: procs[10]!, user: "ann", command: "/x/node server.js")  // no port, threads not readable
        let b = DetailRow(p: pp[11]!, user: "root", threads: 4)  // :3000
        precondition(detailMatch(a, "server") && detailMatch(a, "ann") && detailMatch(a, "") && detailMatch(b, "11") && detailMatch(b, ":3000"))
        precondition(!detailMatch(b, "1") && !detailMatch(a, "3000"))
        precondition([a, b].sorted(using: KeyPathComparator(\DetailRow.portKey)).map(\.id) == [11, 10])  // no port last
        precondition([a, b].sorted(using: KeyPathComparator(\DetailRow.threads, order: .reverse)).map(\.id) == [11, 10])  // unknown last
        let cursor = byName["Cursor"]!
        precondition(detailsSummary(cursor.procs, total: 2) == "2 processes, 800 MB, CPU –")
        precondition(detailsSummary([procs[11]!], total: 2) == "1 of 2 processes, 300 MB, CPU –" && detailsSummary([procs[11]!], total: 1) == "1 process, 300 MB, CPU –")
        precondition(startedText(.distantPast) == "–" && startedText(now, now: now) == now.formatted(date: .omitted, time: .shortened))
        var paused = cursor
        paused.procs[0].stopped = true
        precondition(allowed(paused.procs, in: paused, uid: 501, me: 99) == Allowed(quit: true, pause: true, resume: true))
        precondition(allowed(paused.procs, in: paused, uid: 502, me: 99) == Allowed() && allowed([], in: cursor, uid: 501, me: 99) == Allowed())
        precondition(allowed(byName["macOS"]!.procs, in: byName["macOS"]!, uid: 501, me: 99) == Allowed())
        // The header badge's tooltip is the row's: orphans and the emulator too.
        var orphan = Group(name: "node", isApp: false)
        orphan.orphan = true
        precondition(flagHelp(cursor) == "Cursor is not open" && flagHelp(orphan) == orphanHelp
                     && flagHelp(Group(name: "Android Emulator", isApp: true)) == "An emulator runs and Android Studio is not open")
        #if DEBUG
        precondition(parseArgs(["--snapshot-details", "x.png", "Claude"]) == nil)
        precondition(parseArgs(["--snapshot-details", "x.png"]) == .bad("--snapshot-details needs OUT.png GROUP"))
        #else
        precondition(parseArgs(["--snapshot-details", "x.png", "Claude"]) == .bad("--snapshot-details works only in debug builds"))
        #endif
    }

    do {  // Search.swift: tokens and text, each token's match, hits, the empty result
        let s = Search("Leftover  >1GB node")
        precondition(s.tokens == [.leftover, .memOver(1 << 30)] && s.text == "node" && Search(" \t").isEmpty)
        precondition(Search(">1.5gb >0.5GB <100mb cpu>2.5 CPU>5% :3000 port:80 User:Root pid:42").tokens
                     == [.memOver(1536 << 20), .memOver(512 << 20), .memUnder(100 << 20), .cpuOver(2.5), .cpuOver(5), .port(3000), .port(80), .user("root"), .pid(42)])
        precondition(Search("orphan paused growing idle new ignored").tokens == [.orphan, .paused, .growing, .idle, .new, .ignored])
        // Look like tokens, are text: no unit, another unit, inf and nan (Int64() traps), no number, too big a port.
        let odd = Search(">1000 >1tb >gb >infgb >nangb cpu>x cpu>inf pid:abc port:99999 :x user: foo:bar leftovers")
        precondition(odd.tokens.isEmpty && odd.text == ">1000 >1tb >gb >infgb >nangb cpu>x cpu>inf pid:abc port:99999 :x user: foo:bar leftovers")
        precondition(Search("google   chrome >1gb").text == "google chrome")  // words joined by one space, as a name has them
        let cursor = pg["Cursor"]!, claude = pg["Claude"]!  // leftover 800 MB, PIDs 10 11, :3000 on 11; open 1300 MB, :3000 :9229 on 20
        precondition(matches(.leftover, cursor) && !matches(.leftover, claude) && !matches(.orphan, cursor))
        precondition(matches(.memOver(1 << 30), claude) && !matches(.memOver(1 << 30), cursor) && matches(.memUnder(900 << 20), cursor) && !matches(.memUnder(800 << 20), cursor))
        precondition(matches(.port(9229), claude) && !matches(.port(9229), cursor) && matches(.pid(11), cursor) && !matches(.pid(20), cursor))
        precondition(matches(.growing, claude, .init(growing: true)) && !matches(.growing, claude) && matches(.idle, claude, .init(idle: true)))
        precondition(matches(.new, claude, .init(new: true)) && !matches(.new, claude) && matches(.ignored, claude, .init(ignored: true)))
        precondition(matches(.ignored, ig[0]) && !matches(.ignored, cursor))  // Cursor unflagged by the list
        var busy = claude, held = cursor, root = cursor, left = cursor
        busy.procs[0].cpu = 4; busy.procs[1].cpu = 2; left.orphan = true
        precondition(matches(.cpuOver(5), busy) && !matches(.cpuOver(6), busy) && !matches(.cpuOver(5), claude))
        held.procs = held.procs.map { var p = Proc(pid: $0.pid, ppid: $0.ppid, uid: getuid(), path: $0.path, mem: $0.mem); p.stopped = true; return p }
        precondition(matches(.paused, held) && !matches(.paused, cursor) && matches(.orphan, left))
        root.procs[1] = Proc(pid: 11, ppid: 10, uid: 0, path: "/usr/sbin/d", mem: 1)
        precondition(matches(.user("root"), root) && matches(.user("0"), root) && !matches(.user("root"), cursor))
        // Hits: process tokens pick lines (on one process together), group tokens do not, text keeps its meaning.
        precondition(hits(cursor, Search("")) == nil && hits(cursor, Search("leftover >500mb")) == nil && hits(cursor, Search("cursor")) == nil)
        precondition(hits(cursor, Search(":3000"))!.map(\.pid) == [11] && hits(cursor, Search("cursor port:3000 leftover"))!.map(\.pid) == [11])
        precondition(hits(claude, Search(":3000 pid:20"))!.map(\.pid) == [20] && hits(claude, Search(":3000 pid:21"))!.isEmpty)
        precondition(hits(cursor, Search("3000"))!.map(\.pid) == [11] && hits(cursor, Search("10"))!.map(\.pid) == [10])  // text: a port, a PID
        precondition(hits(root, Search("user:root"))!.map(\.pid) == [11] && hits(cursor, Search("node pid:10"))!.map(\.pid) == [10])
        precondition(found(cursor, Search("leftover >500mb node")) && !found(cursor, Search("leftover >1gb")) && !found(claude, Search("leftover")))
        precondition(found(claude, Search("claude :9229")) && !found(claude, Search("claude :1")) && !found(claude, Search("nothing-here")))
        precondition(found(cursor, Search("cpu>x")) == false && found(cursor, Search(">1tb")) == false)  // text that no name has
        precondition(noResultsText(Search("leftover >1gb cpu>5 node")) == "Filters: leftover, over 1 GB, CPU over 5%\nText: “node”")
        precondition(Search(">1.5gb >0.5gb").tokens.map(\.label) == ["over 1.5 GB", "over 512 MB"])
        precondition(noResultsText(Search("new"), marked: false) == "Filters: new since the mark\nNo mark yet: the flag button sets one."
                     && noResultsText(Search("leftover"), marked: false) == "Filters: leftover")
        precondition(noResultsText(Search("new :3000 user:root pid:7 <500mb")) == "Filters: new since the mark, port 3000, user root, PID 7, under 500 MB")
    }

    do {  // --drive (Drive.swift): the flag, and the notification that each alert builds
        #if DEBUG
        precondition(parseArgs(["--drive", "/tmp/d"]) == nil && parseArgs(["--drive"]) == .bad("--drive needs OUTDIR"))
        #else
        precondition(parseArgs(["--drive", "/tmp/d"]) == .bad("--drive works only in debug builds"))
        #endif
        let left = Alerts.request(Alert(kind: .leftover, group: "Cursor", stop: true, title: "Leftover: Cursor", body: "b"))
        precondition(left.identifier == "leftover|Cursor" && left.content.title == "Leftover: Cursor" && left.content.body == "b")
        precondition(left.content.categoryIdentifier == "leftover" && left.content.userInfo["group"] as? String == "Cursor")
        let hot = Alerts.request(Alert(kind: .pressure, title: "t", body: "b"))  // no group, no Stop
        precondition(hot.identifier == "pressure|" && hot.content.categoryIdentifier.isEmpty && hot.content.userInfo.isEmpty)
    }
    print("ok")
}
