import Darwin
import SwiftUI

// TCP ports that this user's processes listen on, to see which app owns a dev
// server (`node` on :3000). Read-only, and read only while the panel is open.

// MARK: - Pure rules

/// Sorted host-order ports from `insi_lport` values (network byte order in an
/// int). A port open for IPv4 and IPv6 is two sockets but one port.
func ports(fromLPorts lports: [Int32]) -> [UInt16] {
    Set(lports.map { UInt16(bigEndian: UInt16(truncatingIfNeeded: $0)) }).sorted()
}

/// ":3000 :9229", and "+N" for the ports after the first `limit`.
func portsText(_ ports: [UInt16], limit: Int = .max) -> String {
    (ports.prefix(limit).map { ":\($0)" } + (ports.count > limit ? ["+\(ports.count - limit)"] : [])).joined(separator: " ")
}

/// A search query ("3000" or ":3000", lower-cased and trimmed) is one of the ports.
func portMatch(_ ports: [UInt16], _ q: String) -> Bool {
    guard let n = UInt16(q.hasPrefix(":") ? String(q.dropFirst()) : q) else { return false }
    return ports.contains(n)
}

/// The tooltip: "Listens on TCP ports :3000 :9229".
func portsHelp(_ ports: [UInt16]) -> String { "Listens on TCP port\(ports.count > 1 ? "s" : "") \(portsText(ports))" }

/// For the row's accessibility label: ", listens on ports 3000, 9229", or "".
func portsLabel(_ ports: [UInt16]) -> String {
    ports.isEmpty ? "" : ", listens on port\(ports.count > 1 ? "s" : "") " + ports.map(String.init).joined(separator: ", ")
}

extension Group {
    var ports: [UInt16] { Set(procs.flatMap(\.ports)).sorted() }
}

// MARK: - System reads

/// The TCP ports that `pid` listens on.
func listenPorts(_ pid: pid_t) -> [UInt16] {
    let fdSize = MemoryLayout<proc_fdinfo>.stride
    let need = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))  // bytes, with some spare room
    // ponytail: a process with more than 4096 fds is skipped (the most on this Mac was
    // about 400); each socket costs one more syscall. Read only its first fds if one matters.
    guard need > 0, need / fdSize <= 4096 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: need / fdSize)
    let n = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))) / fdSize
    var lports: [Int32] = []
    for fd in fds.prefix(max(n, 0)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var si = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
              si.psi.soi_kind == SOCKINFO_TCP, si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        lports.append(si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
    }
    return ports(fromLPorts: lports)
}

/// Listening ports of this user's processes; other users' fds are not readable.
func listenPorts(_ procs: [pid_t: Proc]) -> [pid_t: [UInt16]] {
    var out: [pid_t: [UInt16]] = [:]
    for p in procs.values where p.uid == getuid() {
        let ps = listenPorts(p.pid)
        if !ps.isEmpty { out[p.pid] = ps }
    }
    return out
}

/// ponytail: ports are matched by PID only, so for up to 10 s (the read interval) a
/// reused PID can show the old process's ports.
func addPorts(_ procs: inout [pid_t: Proc], _ ports: [pid_t: [UInt16]]) {
    for (pid, ps) in ports where procs[pid] != nil { procs[pid]!.ports = ps }
}

// MARK: - UI

/// Small tag ":3000 :9229 +1"; `network` adds the icon (a group row, a paused process). Two ports at
/// most, so the name keeps its room; the tooltip has all of them. `limit` 0 = the
/// icon only, next to a paused badge. One port next to the growing arrow, else a
/// short name like "macOS" truncates.
struct PortChip: View {
    let ports: [UInt16]
    var network = false
    var limit = 2

    var body: some View {
        HStack(spacing: 2) {
            if network { Image(systemName: "network") }
            if limit > 0 { Text(portsText(ports, limit: limit)) }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .help(portsHelp(ports))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(portsLabel(ports).dropFirst(2)))
    }
}
