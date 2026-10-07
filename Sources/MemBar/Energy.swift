import Darwin
import Foundation

// Power and disk I/O per process, from the rusage call that scan() already makes: no new
// syscall. Like CPU %, a rate since the previous scan. Power is ri_energy_nj (flavor V6):
// the energy that macOS estimates the process's CPU work used. Not ri_billed_energy (V4):
// that is the work other processes did for it (XPC), so a busy process that asks no one
// reads 0. On this Mac `yes` at 98% CPU read 0 mW there and 4.2 W here.
// ponytail: CPU energy only, not the GPU or the screen; an Intel Mac may read 0 (then "–").

/// Lifetime counters: the start (mach time: a reused PID has another), energy in nJ, disk
/// bytes read and written. Then the rates since the previous scan (addIO). All 0 when
/// rusage is not readable (other users' processes).
struct IO {
    var start: UInt64 = 0, energy: UInt64 = 0, read: UInt64 = 0, write: UInt64 = 0
    var power = 0.0, readRate = 0.0, writeRate = 0.0  // mW, bytes per second
    var disk: Double { readRate + writeRate }
}

extension IO {
    init(_ ri: rusage_info_v6) {
        self.init(start: ri.ri_proc_start_abstime, energy: ri.ri_energy_nj, read: ri.ri_diskio_bytesread, write: ri.ri_diskio_byteswritten)
    }
}

extension Group {
    var power: Double { procs.reduce(0) { $0 + $1.io.power } }
    var disk: Double { procs.reduce(0) { $0 + $1.io.disk } }
}

/// `now - then` per second; 0 when the counter went back or no time passed.
func perSecond(_ now: UInt64, _ then: UInt64, _ seconds: Double) -> Double {
    now >= then && seconds > 0 ? Double(now - then) / seconds : 0
}

/// Power and disk rates since the previous scan, as addCPU. A new process, or a reused PID
/// (another start time, whatever its counters), gets 0.
func addIO(_ procs: inout [pid_t: Proc], prev: [pid_t: IO], seconds: Double) {
    for (pid, p) in procs {
        guard let o = prev[pid], o.start == p.io.start else { continue }
        procs[pid]!.io.power = perSecond(p.io.energy, o.energy, seconds) / 1e6  // nJ/s → mW
        procs[pid]!.io.readRate = perSecond(p.io.read, o.read, seconds)
        procs[pid]!.io.writeRate = perSecond(p.io.write, o.write, seconds)
    }
}

/// "350 mW", "4.2 W"; "–" under 1 mW (idle, or not readable).
func watts(_ mW: Double) -> String {
    mW < 1 ? "–" : mW < 999.5 ? String(format: "%.0f mW", mW) : String(format: "%.1f W", mW / 1000)
}

/// "120 KB/s", "3 MB/s", "1.5 GB/s"; `none` under 1 KB/s.
func diskText(_ bytesPerSecond: Double, none: String = "–") -> String {
    bytesPerSecond < 1024 ? none : bytesPerSecond < 999.5 * 1024 ? String(format: "%.0f KB/s", bytesPerSecond / 1024)
        : short(Int64(bytesPerSecond)) + "/s"
}

/// "Power about 1.2 W · Disk 3 MB/s": the parts that are not trivial (0.1 W, 1 MB/s), nil
/// when none is. "About": the energy is macOS's estimate.
func ioNote(_ g: Group) -> String? {
    let parts = [g.power >= 100 ? "Power about \(watts(g.power))" : nil, g.disk >= 1_048_576 ? "Disk \(diskText(g.disk))" : nil].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// The row's CPU tooltip: what the number is, then ioNote. The panel has no room for more columns.
func cpuHelp(_ g: Group) -> String { "% of one core since the last scan" + (ioNote(g).map { "\n" + $0 } ?? "") }

/// The Details Disk cell's tooltip.
func diskHelp(_ io: IO) -> String {
    io.start == 0 ? "Not readable: it runs as another user" : "Read \(diskText(io.readRate, none: "0")), write \(diskText(io.writeRate, none: "0")) since the last scan"
}
