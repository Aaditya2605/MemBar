import AppKit
import SwiftUI

// Container VMs: Docker Desktop, OrbStack, Colima and Lima, Podman, UTM. One VM holds GBs, and
// its processes have names that say nothing: Apple's com.apple.Virtualization.VirtualMachine
// fell into "macOS" when its responsible process was gone; limactl or vfkit got a group of their
// own, and, left by a closed terminal, an orphan badge and a Stop. So a VM process goes to the app
// that owns it, else to "Linux VM" (vmOwner, from ownerPath); a group that runs a VM is never a
// leftover and never loses its orphans (isLeftover, orphaning), as its app's window is often
// closed on purpose and Stop would cut the VM off mid-write; and the expanded group shows the
// VM's memory with docker's containers under it. Read-only: nothing here starts or stops a
// container or a VM.

/// Not real files: appOf names their groups. "Linux VM" is an app, so Apple's VM process in it
/// gets the right-click Quit that it has in Docker's group (maySignal).
let linuxVM = "/Library/Application Support/Linux VM/vm"
/// ponytail: /opt/podman is the Podman installer's, which Podman Desktop runs; a Podman installed
/// alone there still reads as Podman Desktop, with a blank icon.
let podmanDesktop = "/Applications/Podman Desktop.app/Contents/MacOS/Podman Desktop"

/// The tools that start and serve VMs; Docker Desktop's VM drivers.
private let vmTools: Set<Substring> = ["limactl", "colima", "vfkit", "krunkit", "gvproxy", "com.docker.virtualization", "com.docker.krun"]

/// A process that runs a VM: Apple's Virtualization process (Docker, OrbStack, Lima, Podman and
/// UTM use it), QEMU (not the Android SDK's: the emulator is a group of its own), the tools.
func isVMPath(_ path: String) -> Bool {
    let exe = path[(path.lastIndex(of: "/").map(path.index(after:)) ?? path.startIndex)...]
    return exe == "com.apple.Virtualization.VirtualMachine" || vmTools.contains(exe) || exe.hasPrefix("qemu-system-") && !isEmulatorPath(path)
}

/// The path that names the group of VM process `path`, or of a process under VM process `top`
/// (lima's ssh), when today's owner `top` is not an app: its own app's folder, the Podman
/// installer's, else "Linux VM". nil when neither is a VM, or `top` is an app already: Docker,
/// OrbStack, UTM, or VS Code whose terminal started it (in use while it runs; once it quits, the
/// top is no app). Before Recall's memory: a VM is never a leftover of the app that started it.
func vmOwner(_ path: String, top: String) -> String? {
    guard isVMPath(path) || isVMPath(top), !appOf(top).isApp else { return nil }
    if appOf(path).isApp { return path }
    return path.hasPrefix("/opt/podman/") || top.hasPrefix("/opt/podman/") ? podmanDesktop : linuxVM
}

extension Group {
    var isVM: Bool { procs.contains { isVMPath($0.path) } }
}

struct Container: Equatable { let name: String, mem: Int64, cpu: Double }

/// docker's sizes: "12.5MiB", "7.66GiB", "0B"; Podman's are decimal: "512kB", "1.024MB".
/// nil for "--" (no number yet) and any other unit.
func dockerBytes<S: StringProtocol>(_ s: S) -> Int64? {
    let t = s.trimmingCharacters(in: .whitespaces), num = t.prefix { $0.isNumber || $0 == "." }
    let units: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
                                   "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
    guard let v = Double(num), let m = units[String(t.dropFirst(num.count))] else { return nil }
    return Int64((v * m).rounded())
}

/// The containers in `docker stats --no-stream --format '{{json .}}'` output, one JSON object a
/// line, by memory. MemUsage is "used / limit"; "--" (a container that starts or stops) reads as
/// 0. A line that does not decode is left out.
func containers(_ out: Data) -> [Container] {
    struct Line: Decodable {
        let name, mem, cpu: String
        enum CodingKeys: String, CodingKey { case name = "Name", mem = "MemUsage", cpu = "CPUPerc" }
    }
    let json = JSONDecoder()
    return out.split(separator: UInt8(ascii: "\n")).compactMap { l -> Container? in
        guard let s = try? json.decode(Line.self, from: l) else { return nil }
        return Container(name: s.name, mem: s.mem.split(separator: "/").first.flatMap { dockerBytes($0) } ?? 0,
                         cpu: Double(s.cpu.trimmingCharacters(in: .whitespaces).dropLast()) ?? 0)  // "0.12%"
    }.sorted { $0.mem > $1.mem }
}

// MARK: - System reads

/// The docker CLI: on PATH (a menu bar app gets launchd's short one), Homebrew's and Docker's
/// folders, OrbStack's.
func dockerCLI() -> String? {
    ((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.orbstack/bin"])
        .map { $0 + "/docker" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// `docker stats` once, ended after 3 s: a daemon that hangs must not hold the queue. [] when
/// docker is missing, fails or is ended.
/// ponytail: it samples twice for the CPU (about 2 s), so with many containers it can take
/// longer than 3 s and show nothing; a longer timeout if that happens.
func dockerStats() -> [Container] {
    guard let docker = dockerCLI() else { return [] }
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: docker)
    p.arguments = ["stats", "--no-stream", "--format", "{{json .}}"]
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let end = DispatchWorkItem { p.terminate() }  // our own child only
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: end)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()  // before wait: a full pipe would block docker
    p.waitUntilExit()
    end.cancel()
    return p.terminationReason == .exit && p.terminationStatus == 0 ? containers(data) : []
}

/// What the expanded VM row shows. Main thread only.
final class Containers: ObservableObject {
    static let shared = Containers()
    @Published private(set) var list: [Container] = []
    /// The VM group the list goes under: the largest.
    /// ponytail: the docker CLI talks to one engine (its current context), which is not read; with
    /// two VMs running the containers can show under the wrong one.
    @Published private(set) var vm: String?
    var watching: Set<String> = []  // the expanded VM rows on screen
    private var at = Date.distantPast, busy = false
    private let queue = DispatchQueue(label: "appmem.docker", qos: .utility)

    /// After each scan (`groups`) and when a VM row opens. docker stats is a process start and
    /// about 2 s: only with the panel open and the VM's row open, at most every 15 s.
    func poll(_ groups: [Group]? = nil, open: Bool) {
        if let groups {
            let id = groups.filter(\.isVM).max { $0.mem < $1.mem }?.id
            if id != vm { vm = id }
        }
        guard open, let vm, watching.contains(vm), !busy, -at.timeIntervalSinceNow >= 15 else { return }
        busy = true; at = Date()
        queue.async { let found = dockerStats(); DispatchQueue.main.async { self.list = found; self.busy = false } }
    }
}

// MARK: - UI

/// Above the processes of an expanded VM group: the VM's own processes as one line, and under it
/// docker's containers, when the list goes with this VM. Lines as in DeviceLines.
struct VMLines: View {
    let g: Group
    @ObservedObject private var c = Containers.shared

    var body: some View {
        let vm = g.procs.filter { isVMPath($0.path) }, list = g.id == c.vm ? c.list : []
        let names = Set(vm.map(\.name)).sorted().joined(separator: ", ")
        VStack(alignment: .leading, spacing: 2) {
            line(Text("Virtual machine"), vm)
                .help("The VM's own processes: \(names). Its memory holds the guest system and its containers.")
            ForEach(list.prefix(10), id: \.name) { k in
                line(Label(k.name, systemImage: "shippingbox"), cpu: k.cpu, mem: k.mem)
                    .foregroundStyle(.secondary).padding(.leading, 10)
                    .help("Container \(k.name): \(k.mem > 0 ? fmt(k.mem) : "no number yet") inside the VM, as docker stats reports it. It is part of the VM's memory, not more.")
            }
            if list.count > 10 {
                let rest = list.dropFirst(10)
                Text("\(rest.count) more containers, \(fmt(rest.reduce(0) { $0 + $1.mem }))").monospacedDigit()
                    .foregroundStyle(.secondary).padding(.leading, 10)
            }
        }
        .font(.caption).padding(.leading, 38)
        // Not on a closed panel's layout: docker runs only for a row that the user can see.
        .onAppear { c.watching.insert(g.id); c.poll(open: (NSApp.delegate as? Delegate)?.popover.isShown == true) }
        .onDisappear { c.watching.remove(g.id) }
    }

    func line(_ title: some View, _ procs: [Proc]) -> some View {
        line(title, cpu: procs.reduce(0) { $0 + $1.cpu }, mem: procs.reduce(0) { $0 + $1.mem })
    }

    func line(_ title: some View, cpu c: Double, mem: Int64) -> some View {
        HStack(spacing: 6) {  // 6 as in the rows: the CPU and memory columns line up
            title.lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(cpu(c)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            Text(mem > 0 ? fmt(mem) : "–").monospacedDigit().frame(minWidth: 62, alignment: .trailing)
        }
        .contentShape(Rectangle())  // the tooltip in the gaps too
        .accessibilityElement(children: .combine)
    }
}

/// Asserts for the rules above, run by selfTest.
func containersTest() {
    let xpc = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    let qemu = "/opt/homebrew/Cellar/qemu/9.1.0/bin/qemu-system-aarch64", android = "/Users/a/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"
    let colima = "/opt/homebrew/bin/colima", lima = "/opt/homebrew/bin/limactl", vfkit = "/opt/podman/bin/vfkit"
    let docker = "/Applications/Docker.app/Contents/MacOS/com.docker.backend", code = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
    precondition([xpc, qemu, colima, lima, vfkit, "/opt/homebrew/bin/krunkit", "com.apple.Virtualization.VirtualMachine"].allSatisfy(isVMPath))
    precondition(![android, "/opt/homebrew/bin/qemu-img", "/usr/bin/ssh", docker, "/opt/homebrew/bin/limactl-x", ""].contains(where: isVMPath))
    precondition(appOf(linuxVM) == ("Linux VM", true) && appOf(podmanDesktop) == ("Podman Desktop", true) && bundlePath(linuxVM) == nil)
    precondition(vmOwner(xpc, top: xpc) == linuxVM && vmOwner(qemu, top: "/bin/zsh") == linuxVM && vmOwner("/usr/bin/ssh", top: colima) == linuxVM)
    precondition(vmOwner(xpc, top: vfkit) == podmanDesktop && vmOwner(vfkit, top: vfkit) == podmanDesktop)
    precondition(vmOwner(xpc, top: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper") == nil)
    precondition(vmOwner(lima, top: code) == nil && vmOwner("/usr/bin/ssh", top: "/opt/homebrew/bin/node") == nil && vmOwner(android, top: android) == nil)
    let utm = "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/qemu-system-x86_64"
    precondition(vmOwner(utm, top: "/sbin/launchd") == utm)  // its own app's folder names it

    func p(_ pid: pid_t, _ ppid: pid_t, _ path: String, _ mb: Int64 = 1) -> (pid_t, Proc) {
        (pid, Proc(pid: pid, ppid: ppid, uid: 501, path: path, mem: mb << 20))
    }
    func byName(_ gs: [Group]) -> [String: Group] { Dictionary(uniqueKeysWithValues: gs.map { ($0.name, $0) }) }
    func pids(_ g: Group?) -> Set<pid_t> { Set(g?.procs.map(\.pid) ?? []) }
    // Colima left by a closed terminal (ppid 1), its VM process (responsible: limactl), a Podman
    // machine, a QEMU, a VM process with no known owner, Docker, the Android emulator.
    let procs = Dictionary(uniqueKeysWithValues: [
        p(1, 0, "/sbin/launchd"),
        p(20, 1, colima), p(21, 20, lima), p(22, 21, "/usr/bin/ssh"), p(23, 1, xpc, 2000),
        p(30, 1, vfkit), p(31, 1, "/opt/podman/bin/gvproxy"), p(32, 1, xpc, 1500),
        p(40, 1, qemu, 900), p(41, 1, xpc, 700),
        p(50, 1, docker), p(51, 1, "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"), p(52, 1, xpc, 3000),
        p(60, 1, android, 3000),
    ])
    let resp: [pid_t: pid_t] = [23: 21, 32: 30, 52: 51]
    let gs = byName(group(procs, responsible: { resp[$0] ?? $0 }))
    precondition(pids(gs["Linux VM"]) == [20, 21, 22, 23, 40, 41] && gs["Linux VM"]!.isVM && !gs["Linux VM"]!.leftover)
    precondition(pids(gs["Podman Desktop"]) == [30, 31, 32] && gs["Podman Desktop"]!.bundle == "/Applications/Podman Desktop.app" && !gs["Podman Desktop"]!.leftover)
    precondition(pids(gs["Docker"]) == [50, 51, 52] && pids(gs["macOS"]) == [1] && gs["Android Emulator"]!.leftover && !gs["Android Emulator"]!.isVM)
    // Its app is not open: never a leftover while it runs a VM; one without a VM still is.
    precondition(!isLeftover(Group(name: "Foo", isApp: true, procs: [procs[52]!]), open: []) && isLeftover(Group(name: "Foo", isApp: true, procs: [procs[50]!]), open: []))
    // Orphans (Settings counts them as leftovers): the VM's stay in its group, with no badge and no Stop.
    let o = byName(orphaning(Array(gs.values), [20, 21, 22, 30, 31, 40], procs: procs, ignored: [], asLeftover: true, uid: 501))
    precondition(pids(o["Linux VM"]) == [20, 21, 22, 23, 40, 41] && pids(o["Podman Desktop"]) == [30, 31, 32] && !o.values.contains { $0.isVM && ($0.orphan || $0.leftover) })

    // Started in VS Code's terminal: VS Code's while it runs; after it quits, Recall's memory does not make it a leftover.
    let open = Dictionary(uniqueKeysWithValues: [p(1, 0, "/sbin/launchd"), p(60, 1, code), p(61, 60, "/bin/zsh"), p(62, 61, lima), p(63, 1, xpc, 2000),
                                                 p(64, 61, "/opt/homebrew/bin/node")])
    let r1: (pid_t) -> pid_t = { [61: 60, 62: 60, 63: 62, 64: 60][$0] ?? $0 }
    let owners = remember(open, responsible: r1, owners: [:], uid: 501)
    let vs = byName(group(open, responsible: r1, owners: owners))["Visual Studio Code"]!
    precondition(pids(vs) == [60, 61, 62, 63, 64] && !vs.leftover && vs.isVM)
    var quit = open
    quit[60] = nil; quit[61] = nil
    quit[62] = p(62, 1, lima).1; quit[64] = p(64, 1, "/opt/homebrew/bin/node").1
    let after = byName(group(quit, responsible: { $0 == 63 ? 62 : $0 }, owners: remember(quit, responsible: { $0 == 63 ? 62 : $0 }, owners: owners, uid: 501)))
    precondition(pids(after["Linux VM"]) == [62, 63] && !after["Linux VM"]!.leftover && pids(after["Visual Studio Code"]) == [64] && after["Visual Studio Code"]!.leftover)

    // docker stats lines: binary and decimal units, "--", lines that do not decode.
    precondition(dockerBytes("12.5MiB") == 13_107_200 && dockerBytes(" 1.5GiB ") == 1_610_612_736 && dockerBytes("0B") == 0)
    precondition(dockerBytes("512kB") == 512_000 && dockerBytes("1.024MB") == 1_024_000 && dockerBytes("2KiB") == 2048)
    precondition(dockerBytes("--") == nil && dockerBytes("") == nil && dockerBytes("12parsecs") == nil && dockerBytes("MiB") == nil)
    let out = """
        {"BlockIO":"0B / 0B","CPUPerc":"0.12%","Container":"a1b2","ID":"a1b2c3","MemPerc":"0.16%","MemUsage":"12.5MiB / 7.66GiB","Name":"redis","NetIO":"1.2kB / 0B","PIDs":"5"}
        {"CPUPerc":"103.40%","MemUsage":"1.5GiB / 7.66GiB","Name":"postgres"}
        {"CPUPerc":"--","MemUsage":"-- / --","Name":"starting"}
        {"CPUPerc":"1.2%","MemUsage":"1.024MB / 8.299GB","Name":"podman-one"}
        not json
        {"Name":"no-numbers"}

        """
    let cs = containers(Data(out.utf8))
    precondition(cs == [Container(name: "postgres", mem: 1_610_612_736, cpu: 103.4), Container(name: "redis", mem: 13_107_200, cpu: 0.12),
                        Container(name: "podman-one", mem: 1_024_000, cpu: 1.2), Container(name: "starting", mem: 0, cpu: 0)])
    precondition(containers(Data()).isEmpty && containers(Data("Cannot connect to the Docker daemon".utf8)).isEmpty)
}

#if DEBUG
extension Containers {
    /// `CROWD=1 AppMem --snapshot out.png pid:900201`: a made-up "Linux VM" group, opened by the
    /// search, with containers. A snapshot has no popover, so it never runs docker.
    static func demo() -> Group {
        let mb: Int64 = 1 << 20
        func p(_ pid: pid_t, _ path: String, _ m: Int64, _ c: Double = 0) -> Proc {
            var p = Proc(pid: pid, ppid: 1, uid: getuid(), path: path, mem: m * mb)
            p.cpu = c
            return p
        }
        let g = Group(name: "Linux VM", isApp: true, procs: [
            p(900201, "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", 3100, 4.2),
            p(900202, "/opt/homebrew/bin/limactl", 48, 0.3), p(900203, "/usr/bin/ssh", 6)])
        let names = ["postgres", "a-container-with-a-very-long-compose-project-name-1"] + (2..<12).map { "svc-\($0)" }
        shared.list = names.enumerated().map { i, n in Container(name: n, mem: Int64(300 - i * 22) * mb, cpu: i == 0 ? 12.5 : 0.4) }
        shared.vm = g.id
        return g
    }
}
#endif
