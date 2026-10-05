import Foundation
import SwiftUI

// iOS Simulator devices and the Android emulator. One booted simulator holds GBs, and
// the "iOS Simulator" group alone does not say which device: so the expanded group
// gets a line per booted device, each with its own Shut Down. The Android emulator is a
// group of its own while Android Studio runs it or once the app that started it quit
// (ownerPath), a leftover when Android Studio is not open (isLeftover).

struct SimDevice: Equatable {
    let udid: String, name: String, runtime: String
    var launchd: pid_t?  // its launchd_sim, the parent of the device's processes
}

extension Group {
    var isEmulator: Bool { name == "Android Emulator" }
}

// MARK: - Pure rules

/// The Android emulator (emulator, qemu-system-*, crashpad_handler) of the default SDK.
/// ponytail: an SDK in another folder (ANDROID_HOME elsewhere) is not matched.
func isEmulatorPath(_ path: String) -> Bool { path.contains("/Android/sdk/emulator/") }

/// "iOS 26.5" from the runtime key "com.apple.CoreSimulator.SimRuntime.iOS-26-5".
func runtimeName(_ key: String) -> String {
    let p = (key.split(separator: ".").last ?? "").split(separator: "-")
    return p.count > 1 ? String(p[0]) + " " + p.dropFirst().joined(separator: ".") : key
}

/// The booted devices in `xcrun simctl list devices booted -j` output, by name.
func bootedDevices(_ json: Data) -> [SimDevice] {
    struct List: Decodable {
        struct Device: Decodable { let udid: String, name: String, state: String }
        let devices: [String: [Device]]  // by runtime key
    }
    guard let list = try? JSONDecoder().decode(List.self, from: json) else { return [] }
    return list.devices.flatMap { key, ds in
        ds.filter { $0.state == "Booted" }.map { SimDevice(udid: $0.udid, name: $0.name, runtime: runtimeName(key)) }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// The device UDID in a path or a command line: .../CoreSimulator/Devices/<UDID>/...
func udid(in s: String) -> String? {
    guard let r = s.range(of: "/CoreSimulator/Devices/") else { return nil }
    let id = String(s[r.upperBound...].prefix { $0 != "/" })
    return UUID(uuidString: id) != nil ? id : nil
}

/// A launchd_sim's device set and UDID, from its argument <set>/<UDID>/data/var/run/
/// launchd_bootstrap.plist. Any set: the default one, Xcode Previews, XCTest clones;
/// `simctl` without --set acts only on the default one.
func simDevice(_ argv: [String]) -> (set: String, udid: String)? {
    let tail = "/data/var/run/launchd_bootstrap.plist"
    guard let a = argv.first(where: { $0.hasSuffix(tail) }) else { return nil }
    let dev = String(a.dropLast(tail.count)) as NSString
    return UUID(uuidString: dev.lastPathComponent) != nil ? (dev.deletingLastPathComponent, dev.lastPathComponent) : nil
}

/// The lines of the expanded simulator group: each device with its processes (by the
/// UDID in their path, else their launchd_sim parent chain), by memory, then "Shared"
/// (device nil) for the rest: CoreSimulatorService, simdiskimaged. A device with no
/// process (shut down since the last read) has no line; no device line, no lines.
/// ponytail: the render hosts (SimRenderServer, SimMetalHost) have no UDID and launchd
/// as parent, so they count as Shared, though each booted device starts its own.
func simLines(_ procs: [Proc], devices: [SimDevice]) -> [(device: SimDevice?, procs: [Proc])] {
    let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    let byLaunchd = Dictionary(devices.compactMap { d in d.launchd.map { ($0, d.udid) } }, uniquingKeysWith: { a, _ in a })
    let known = Set(devices.map(\.udid))
    func device(_ p: Proc) -> String? {
        if let id = udid(in: p.path) { return id }
        var q = p
        for _ in 0..<64 {  // a PID reused mid-scan could make a loop
            if let id = byLaunchd[q.pid] { return id }
            guard let parent = byPID[q.ppid], parent.pid != q.pid else { return nil }
            q = parent
        }
        return nil
    }
    var by: [String: [Proc]] = [:], shared: [Proc] = []
    for p in procs {
        if let id = device(p), known.contains(id) { by[id, default: []].append(p) } else { shared.append(p) }
    }
    func mem(_ ps: [Proc]) -> Int64 { ps.reduce(0) { $0 + $1.mem } }
    let lines = devices.compactMap { d in by[d.udid].map { (device: Optional(d), procs: $0) } }.sorted { mem($0.procs) > mem($1.procs) }
    return lines.isEmpty || shared.isEmpty ? lines : lines + [(nil, shared)]
}

// MARK: - System reads and Shut Down

enum Sims {
    private static var devices: [SimDevice] = [], at = Date.distantPast  // scan queue only
    /// Main thread: what the expanded simulator row shows.
    static var booted: [SimDevice] = []

    /// Scan queue, after each scan. simctl costs about 0.15 s of CPU: only with the panel
    /// open, only with a booted device (launchd_sim runs), at most every 30 s or on Refresh.
    /// ponytail: a device booted since the last read shows as Shared for up to 30 s.
    static func update(_ procs: [pid_t: Proc], open: Bool, force: Bool) {
        guard open else { return }
        let launchd = procs.values.filter { $0.name == "launchd_sim" }
        if launchd.isEmpty { devices = []; at = .distantPast }
        else if force || -at.timeIntervalSinceNow > 30 { devices = read(launchd); at = Date() }
        let d = devices
        DispatchQueue.main.async { booted = d }  // before the groups that the Model posts next
    }

    /// The booted devices, each with its launchd_sim: its argument is the device's
    /// .../Devices/<UDID>/data/var/run/launchd_bootstrap.plist.
    static func read(_ launchd: [Proc]) -> [SimDevice] {
        let data = output("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        let ids = Dictionary(launchd.compactMap { l in udid(in: argv(procArgs(l.pid) ?? []).joined(separator: " ")).map { ($0, l.pid) } },
                             uniquingKeysWith: { a, _ in a })
        return bootedDevices(data).map { d in var d = d; d.launchd = ids[d.udid]; return d }
    }

    /// `xcrun simctl shutdown <UDID>`: a clean shutdown, as for the group's Stop. `done`
    /// gets whether it worked, on the main thread.
    static func shutDown(_ d: SimDevice, done: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "shutdown", d.udid]
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { q in DispatchQueue.main.async { done(q.terminationStatus == 0) } }
        if (try? p.run()) == nil { done(false) }
    }
}

// MARK: - UI

/// Above the processes of the expanded simulator group. The panel's next scan (2-5 s)
/// drops the line of a device that was shut down.
struct DeviceLines: View {
    let g: Group

    var body: some View {
        let lines = simLines(g.procs, devices: Sims.booted)
        if !lines.isEmpty {  // no empty stack: the row's spacing would show as a gap
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.device?.udid) { DeviceLine(device: $0.device, procs: $0.procs) }
            }
            .font(.caption).padding(.leading, 38)
        }
    }
}

struct DeviceLine: View {
    let device: SimDevice?  // nil: Shared
    let procs: [Proc]
    @State private var busy = false  // Shut Down clicked: until the line goes, or it failed

    var body: some View {
        let title = device.map { "\($0.name) · \($0.runtime)" } ?? "Shared"
        HStack(spacing: 6) {  // 6 as in the rows: the CPU and memory columns line up
            ViewThatFits(in: .horizontal) {
                Text(title)
                Text(device?.name ?? title).truncationMode(.middle)  // the runtime goes first
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let device {
                Button("Shut Down") { busy = true; Sims.shutDown(device) { ok in if !ok { busy = false } } }
                    .controlSize(.mini).disabled(busy).fixedSize()
                    .accessibilityLabel("Shut Down \(device.name)")
            }
            Text(cpu(procs.reduce(0) { $0 + $1.cpu })).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            Text(fmt(procs.reduce(0) { $0 + $1.mem })).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
        }
        .contentShape(Rectangle())  // the tooltip in the gaps too
        .help(device.map { "\(title), \(procs.count) processes\n\($0.udid)" + (busy ? "\nShutting down…" : "") }
              ?? "Simulator services for all devices, such as CoreSimulatorService and the render hosts: \(procs.count) processes")
        .accessibilityElement(children: .contain)
    }
}
