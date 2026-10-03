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
    var name: String { String((path.split(separator: "/").last ?? "?").drop { $0 == "-" }) }
}

struct Group: Identifiable {
    let name: String
    let isApp: Bool  // a non-Apple app: only these can be leftovers
    var procs: [Proc] = []
    var leftover = false
    var bundle: String?  // the app's .app folder, for its icon
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

/// Groups sorted by memory, leftovers first.
func group(_ procs: [pid_t: Proc], responsible: (pid_t) -> pid_t) -> [Group] {
    let open = openApps(procs.values.lazy.map(\.path))
    var groups: [String: Group] = [:]
    var notExtension: Set<String> = []  // groups with a process that no app extension owns
    for p in procs.values {
        let top = owner(of: p.pid, responsible: responsible(p.pid), procs: procs)
        let topPath = procs[top]?.path ?? p.path
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

/// The executable path. proc_pidpath fails when the file was replaced (an app
/// update); then argv's exec path, then the short process name.
func path(of pid: pid_t, comm: String) -> String {
    var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 {
        var args = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &args, &size, nil, 0) == 0, size > 4 {
            let exe = args[4..<size].prefix { $0 != 0 }  // after int argc
            if !exe.isEmpty { return String(decoding: exe, as: UTF8.self) }
        }
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

/// RAM in use as Activity Monitor counts "Memory Used" (app + wired + compressed),
/// and swap in use.
func systemMem() -> (ram: Int64, swap: Int64) {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    } == KERN_SUCCESS
    let pages = Int64(vm.internal_page_count) - Int64(vm.purgeable_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
    var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 { swap = xsw_usage() }
    return (ok ? pages * Int64(vm_kernel_page_size) : 0, Int64(swap.xsu_used))
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
                          cpuTime: ok ? UInt64(Double(ri.ri_user_time + ri.ri_system_time) * nsPerTick) : 0)
    }
    return procs
}

// MARK: - Stop

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
    // Same PID and same executable as in the scan, so a reused PID is left alone.
    func same(_ p: Proc) -> Bool { shortInfo(p.pid).map { path(of: p.pid, comm: comm($0)) == p.path } ?? false }
    let targets = g.procs.filter { $0.uid == getuid() && $0.pid > 1 && $0.pid != getpid() && same($0) }
    for p in targets { kill(p.pid, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        for p in targets where same(p) { kill(p.pid, SIGKILL) }
    }
}

// MARK: - Command line

/// `AppMem --list`: the prototype's output, to compare the two.
func printGroups() {
    let groups = group(scan(top: topMem()), responsible: responsible).sorted { $0.mem > $1.mem }
    let sys = systemMem()
    print("apps \(fmt(groups.reduce(0) { $0 + $1.mem })), RAM \(fmt(sys.ram)), swap \(fmt(sys.swap))")
    for g in groups.prefix(20) {
        let flag = g.leftover ? (g.isSimulator ? "   <-- DEVICE RUNNING, SIMULATOR NOT OPEN" : "   <-- APP NOT OPEN") : ""
        print("\n" + g.name.padding(toLength: max(28, g.name.count), withPad: " ", startingAt: 0),
              fmt(g.mem).leftPad(9), String(g.procs.count).leftPad(4), "procs" + flag)
        for p in g.procs.prefix(5) { print("    " + fmt(p.mem).leftPad(9), String(p.pid).leftPad(6), p.name) }
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
    var cp = procs
    cp[10]!.cpuTime = 3_000_000_000; cp[11]!.cpuTime = 1_000_000_000
    addCPU(&cp, prev: [10: 1_000_000_000, 11: 2_000_000_000], seconds: 4)
    precondition(cp[10]!.cpu == 50 && cp[11]!.cpu == 0 && cp[20]!.cpu == 0)  // 2 s in 4 s; 11 = reused PID
    historySelfTest()
    print("ok")
}
