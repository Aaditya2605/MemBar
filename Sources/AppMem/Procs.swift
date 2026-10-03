import Darwin
import SwiftUI

// The processes of an expanded group: a tree (which helper started which), and
// the command line on hover, which tells one `node` from the next.

/// Each parent before its children, siblings in input (memory) order. A process
/// whose parent is not in `procs` is a root, so a top-10 list stays a tree.
func tree(_ procs: [Proc]) -> [(proc: Proc, depth: Int)] {
    let pids = Set(procs.map(\.pid))
    func isRoot(_ p: Proc) -> Bool { p.ppid == p.pid || !pids.contains(p.ppid) }  // kernel_task is its own parent
    var kids: [pid_t: [Proc]] = [:]
    for p in procs where !isRoot(p) { kids[p.ppid, default: []].append(p) }
    var out: [(proc: Proc, depth: Int)] = [], seen: Set<pid_t> = []
    func walk(_ p: Proc, _ depth: Int) {
        guard seen.insert(p.pid).inserted else { return }
        out.append((p, depth))
        for k in kids[p.pid] ?? [] { walk(k, depth + 1) }
    }
    for p in procs where isRoot(p) { walk(p, 0) }
    for p in procs { walk(p, 0) }  // a parent loop (PIDs reused mid-scan) has no root
    return out
}

/// The arguments in KERN_PROCARGS2 data: int argc, the exec path, NUL padding,
/// then argc NUL-terminated arguments, then the environment (not read).
func argv(_ buf: [UInt8]) -> [String] {
    guard buf.count > 4 else { return [] }
    let argc = max(0, Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
    var i = buf[4...].firstIndex(of: 0) ?? buf.endIndex
    while i < buf.endIndex, buf[i] == 0 { i += 1 }
    return buf[i...].split(separator: 0, maxSplits: argc, omittingEmptySubsequences: false)
        .prefix(argc).map { String(decoding: $0, as: UTF8.self) }
}

/// Tooltip text: the full path (argv[0] is often only a name), then the arguments.
func commandLine(_ path: String, _ argv: [String]) -> String {
    let s = ([path] + argv.dropFirst()).joined(separator: " ")
    return s.count > 300 ? s.prefix(299) + "…" : s
}

/// Group row tooltip: the processes that Stop must leave alone.
func othersHelp(_ g: Group, uid: uid_t = getuid()) -> String {
    let n = g.procs.filter { $0.uid != uid }.count
    if n == 0 { return "" }
    return "\(n == g.procs.count ? "All" : "\(n) of \(g.procs.count)") processes run as another user (such as root). AppMem cannot stop them."
}

/// Command lines, read only when a row is expanded, then cached: the same PID
/// with the same path runs the same command. Main thread only.
enum Args {
    private static var cache: [String: String] = [:]

    static func of(_ p: Proc) -> String {
        let key = "\(p.pid) \(p.path)"
        if let s = cache[key] { return s }
        // ponytail: dropped whole past 2000 entries (PIDs that came and went); LRU if refills ever cost.
        if cache.count > 2000 { cache.removeAll() }
        let s = commandLine(p.path, argv(procArgs(p.pid) ?? []))  // other users': the path only
        cache[key] = s
        return s
    }
}

struct ProcList: View {
    let g: Group  // for the right-click menu's rules
    let procs: [Proc]  // memory order: all of g's, or the search hits
    @State private var all = false

    var body: some View {
        // Lazy: "Show all" on the macOS group is hundreds of lines and argv reads.
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(tree(all ? procs : Array(procs.prefix(10))), id: \.proc.pid) { r in
                HStack {
                    Text(r.proc.name).lineLimit(1).truncationMode(.middle)
                    if r.proc.stopped { Text("paused").font(.caption2.bold()) }  // the group badge needs all of them paused
                    if !r.proc.ports.isEmpty { PortChip(ports: r.proc.ports) }
                    Spacer()
                    Text(String(r.proc.pid)).monospacedDigit()
                    Text(cpu(r.proc.cpu)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text(fmt(r.proc.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                }
                .padding(.leading, CGFloat(min(r.depth, 4)) * 10)  // capped: deep chains keep room for the name
                .contentShape(Rectangle())  // tooltip and right-click in the gaps too
                .help(Args.of(r.proc))
                .contextMenu { ProcMenu(p: r.proc, g: g) }
                .accessibilityElement(children: .combine)
            }
            if procs.count > 10 {
                Button(all ? "Show fewer" : "Show all \(procs.count)") { all.toggle() }
                    .buttonStyle(.link).foregroundStyle(.tint)  // not .secondary like the lines
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
    }
}
