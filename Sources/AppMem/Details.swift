import AppKit
import SwiftUI

// The Details window: one group's processes as a full table, with the columns the
// 400 pt panel has no room for. One window, reused. While it is open and visible the Model
// scans as if the panel were open; covered, it scans as closed; closed, its view goes too.

/// One table line: the scan's Proc, plus what the scan does not read. -1 threads and
/// distantPast: not readable (another user's process, or it is gone).
struct DetailRow: Identifiable {
    let p: Proc
    var user = "", threads = -1, start = Date.distantPast, command = ""
    var id: pid_t { p.pid }
    var portKey: Int { p.ports.first.map(Int.init) ?? Int.max }  // the Ports sort: no port after all ports
}

/// Reads the extra columns. Only for the group shown, only while the window is open
/// (the table is built only then); threads only for this user's processes.
func detailRow(_ p: Proc, me: uid_t = getuid()) -> DetailRow {
    DetailRow(p: p, user: userName(p.uid), threads: p.uid == me ? threadCount(p.pid) ?? -1 : -1,
              start: started(p.pid) ?? .distantPast, command: Args.of(p))
}

/// PROC_PIDTASKINFO's thread count. nil for other users' processes: not readable without root.
func threadCount(_ pid: pid_t) -> Int? {
    var ti = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size ? Int(ti.pti_threadnum) : nil
}

private var users: [uid_t: String] = [:]  // main thread only

/// The login name, cached: getpwuid asks the directory service. The number if it has none.
func userName(_ uid: uid_t) -> String {
    if let n = users[uid] { return n }
    let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
    users[uid] = n
    return n
}

/// The Started column: the time if it started today, else the day. The tooltip has both.
func startedText(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> String {
    d == .distantPast ? "–" : cal.isDate(d, inSameDayAs: now) ? d.formatted(date: .omitted, time: .shortened)
        : d.formatted(.dateTime.month(.abbreviated).day())
}

/// The window's search (`q` lower-cased and trimmed): the name, user or command line
/// contains it, or the PID or a port is it.
func detailMatch(_ r: DetailRow, _ q: String) -> Bool {
    q.isEmpty || [r.p.name, r.user, r.command].contains { $0.lowercased().contains(q) }
        || String(r.p.pid) == q || portMatch(r.p.ports, q)
}

/// "3 of 12 processes, 1.24 GB, CPU 3.2%": the lines shown, out of the group's `total`.
func detailsSummary(_ procs: [Proc], total: Int) -> String {
    let n = procs.count == total ? "\(total)" : "\(procs.count) of \(total)"
    return "\(n) process\(total == 1 ? "" : "es"), \(fmt(procs.reduce(0) { $0 + $1.mem })), CPU \(cpu(procs.reduce(0) { $0 + $1.cpu }))"
}

/// The second click of a double-click, read in a Button's action. Mouse-ups only:
/// clickCount raises on a key event (Space on a focused button).
func isDoubleClick() -> Bool { NSApp.currentEvent.map { $0.type == .leftMouseUp && $0.clickCount == 2 } ?? false }

/// Right-click menu of a multi-selection: ProcMenu's items that act on many, with its checks.
struct SelectionMenu: View {
    let ps: [Proc], g: Group

    var body: some View {
        let a = allowed(ps, in: g), n = "\(ps.count) Processes"
        Button("Quit \(n)") { Actions.send(SIGTERM, ps, in: g) }.disabled(!a.quit)
        Button("Force Quit \(n)…") { if Actions.confirmForceQuit(n.lowercased()) { Actions.send(SIGKILL, ps, in: g) } }
            .disabled(!a.quit)
        Button("Pause") { Actions.send(SIGSTOP, ps.filter { !$0.stopped }, in: g) }.disabled(!a.pause)
        Button("Resume") { Actions.send(SIGCONT, ps.filter(\.stopped), in: g) }.disabled(!a.resume)
        Divider()
        Button("Copy PIDs") { Actions.copy(ps.map { String($0.pid) }.joined(separator: " ")) }
    }
}

struct DetailsView: View {
    @ObservedObject var model: Model
    let id: String, name: String  // the group's; it may be gone by the next scan
    @State private var sort = [KeyPathComparator(\DetailRow.p.mem, order: .reverse)]
    @State var query = ""  // not private: the snapshot sets it
    @State private var selection = Set<pid_t>()

    var body: some View {
        let g = model.groups.first { $0.id == id }, q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = (g?.procs ?? []).map { detailRow($0) }.filter { detailMatch($0, q) }.sorted(using: sort)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(detailsSummary(rows.map(\.p), total: g?.procs.count ?? 0)).monospacedDigit()
                if let g, g.leftover || g.orphan {  // as the row's badge
                    Text(g.orphan ? "orphan" : "leftover").font(.caption.bold()).foregroundStyle(g.leftover ? .orange : .secondary)
                        .help(flagHelp(g))
                }
                Spacer()
                TextField("Search name, PID, user, command or :port", text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
            .padding(10)
            Divider()
            if let g {
                table(g, rows)
            } else {
                ContentUnavailableView("\(name) has no processes", systemImage: "memorychip")
            }
        }
        .frame(minWidth: 560, minHeight: 240)
        // No menu bar in an accessory app, so no File > Close: ⌘W from a hidden button.
        .background { Button("Close") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w").hidden() }
    }

    func table(_ g: Group, _ rows: [DetailRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Name", value: \.p.name) { r in
                HStack(spacing: 4) {
                    Text(r.p.name).lineLimit(1).truncationMode(.middle)
                    if r.p.stopped { Text("paused").font(.caption.bold()).foregroundStyle(.secondary) }
                }
                .help(r.p.path)
            }
            .width(min: 90, ideal: 150)
            TableColumn("PID", value: \.p.pid) { num(String($0.p.pid)) }.width(46)
            TableColumn("User", value: \.user) { Text($0.user).lineLimit(1).help($0.user) }.width(min: 44, ideal: 80, max: 80)
            TableColumn("CPU", value: \.p.cpu) { num(cpu($0.p.cpu)).help("% of one core since the last scan") }
                .width(46)
            TableColumn("Memory", value: \.p.mem) { num(fmt($0.p.mem)) }.width(66)
            TableColumn("Peak", value: \.p.peak) { r in
                num(r.p.peak > 0 ? fmt(r.p.peak) : "–")
                    .help(r.p.peak > 0 ? "The most memory it used since it started" : "Not readable: it runs as another user")
            }
            .width(66)
            TableColumn("Threads", value: \.threads) { r in
                num(r.threads < 0 ? "–" : String(r.threads)).help(r.threads < 0 ? "Not readable: it runs as another user" : "")
            }
            .width(56)
            TableColumn("Ports", value: \.portKey) { r in
                Text(portsText(r.p.ports)).monospacedDigit().lineLimit(1).help(r.p.ports.isEmpty ? "" : portsHelp(r.p.ports))
            }
            .width(min: 44, ideal: 64, max: 64)
            TableColumn("Started", value: \.start) { r in
                Text(startedText(r.start)).monospacedDigit().lineLimit(1).help(r.start == .distantPast ? ""
                    : "\(r.start.formatted(date: .abbreviated, time: .shortened)), \(ago(-r.start.timeIntervalSinceNow)) ago")
            }
            .width(66)  // "12:59 PM" is 58 pt, "오후 12:59" 63, "12:59 p.m." 65
            TableColumn("Command Line", value: \.command) { r in
                Text(r.command).lineLimit(1).foregroundStyle(.secondary).help(r.command)
            }
            .width(min: 100, ideal: 260)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        // The process line's menu for one; for many, the items that make sense for many.
        .contextMenu(forSelectionType: pid_t.self) { pids in
            let ps = g.procs.filter { pids.contains($0.pid) }
            if ps.count == 1 { ProcMenu(p: ps[0], g: g) } else if !ps.isEmpty { SelectionMenu(ps: ps, g: g) }
        }
    }

    /// A number cell: right-aligned and digits of one width, so the column lines up.
    func num(_ s: String) -> some View { Text(s).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
}

/// The window. One, reused: another group switches its content.
enum Details {
    private static var window: NSWindow?

    static func show(_ g: Group) {
        guard let d = NSApp.delegate as? Delegate else { return }
        let w = window ?? make()
        w.title = "\(g.name) — AppMem"
        // A new view: sort, search and selection start fresh for the new group.
        let v = NSHostingView(rootView: DetailsView(model: d.model, id: g.id, name: g.name))
        v.sizingOptions = .minSize  // not the ideal size too: that would keep the user from making it smaller
        w.contentView = v
        d.model.windowOpen = true
        d.popover.performClose(nil)  // the user works in the window now
        NSApp.activate(ignoringOtherApps: true)  // to the front; the app stays .accessory, no Dock icon
        w.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        // 900 wide: ten columns with 17 pt between each; at 760 the command line had no room.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("Details")  // takes the saved frame, if there is one
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            w.contentView = nil  // the table stops observing the model and reading threads
            (NSApp.delegate as? Delegate)?.model.windowOpen = false
        }
        // Covered, on another Space, screen locked: no Dock icon to find it again, so it can stay
        // behind for hours; scan as closed until it is visible again (then one refresh at once).
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { _ in
            (NSApp.delegate as? Delegate)?.model.windowOpen = w.occlusionState.contains(.visible)
        }
        window = w
        return w
    }
}

#if DEBUG
/// `AppMem --snapshot-details out.png GROUP [query]` (debug builds): the Details window's
/// content with live data as a PNG. GROUP: a group name, any case.
func snapshotDetails(to path: String, group: String, query: String) {
    snapshot(to: path, size: NSSize(width: 900, height: 480)) { m in
        let g = m.groups.first { $0.name.lowercased() == group.lowercased() }
        return DetailsView(model: m, id: g?.id ?? "", name: g?.name ?? group, query: query)
    }
}
#endif
