import AppKit
import SwiftUI

// Menu bar item + popover. The popover refreshes every 2-5 s while it is open
// (Settings > Refresh Every); closed, a light scan runs once a minute and on a pressure
// change, for the icon, notifications, History and the auto rules.

final class Model: ObservableObject {
    @Published var groups: [Group] = []
    @Published var sys = SysMem()
    @Published var history = HistoryFile.load()  // Day.swift: the last 24 h from disk, saved as it grows
    @Published var mark = Mark.saved()  // Mark.swift; set it with setMark, which saves it
    var slots: [String: Int] = [:]  // RAMBar.swift: the largest groups' colors, kept from scan to scan
    var markAsked = false  // markNow: the next scan with the panel open takes the mark
    var onUpdate: () -> Void = {}
    // A new timer and a scan only when `open` changes. Details opened from the panel ran two scans at once
    // for nothing, during its table's first layout, with AppKit's "reentrant NSTableView" warning (--drive).
    var panelOpen = false { didSet { if panelOpen != oldValue, !windowOpen { schedule(); refresh() } } }
    var windowOpen = false { didSet { if windowOpen != oldValue, !panelOpen { schedule(); refresh() } } }  // Details: scans as the panel does
    private var open: Bool { panelOpen || windowOpen }
    private var timer: Timer?
    private let queue = DispatchQueue(label: "appmem.scan", qos: .utility)
    private var top: [pid_t: Int64] = [:], topAt = Date.distantPast  // queue only
    private var prevCPU: [pid_t: UInt64] = [:], prevAt = Date.distantPast  // queue only
    private var prevIO: [pid_t: IO] = [:]  // queue only
    private var ports: [pid_t: [UInt16]] = [:], portsAt = Date.distantPast  // queue only
    private var recall = Recall()  // queue only
    private var orphans = Orphans()  // queue only
    private var watches: [NSKeyValueObservation] = []
    private var stopped: [String: Set<pid_t>] = [:]  // main only: Group.id → the PIDs of its last Stop (notStopped)

    init() {
        // Settings apply at once, also an ignore list that the right-click menu writes.
        // Main queue: KVO reports on the writer's thread, and the timer needs the main run loop.
        watches = [UserDefaults.standard.observe(\.ignored) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } },
                   UserDefaults.standard.observe(\.refreshEvery) { [weak self] _, _ in DispatchQueue.main.async { self?.schedule() } },
                   UserDefaults.standard.observe(\.quitIdle) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } },
                   UserDefaults.standard.observe(\.countOrphans) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }]
    }

    var waste: Int64 { groups.filter(\.leftover).reduce(0) { $0 + $1.mem } }

    func schedule() {
        timer?.invalidate()
        let every = open ? refreshSeconds(UserDefaults.standard.refreshEvery) : 60
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = open ? 0.5 : 10
    }

    /// `force`: the Refresh button, also reads root-process memory from top again.
    func refresh(force: Bool = false) {
        let open = self.open
        queue.async { [self] in
            // A held ⌘R (one action per key repeat) or fast clicks: at most one forced
            // top/ports/simctl pass in 2 s; the queued rest do only the cheap scan.
            let force = force && -topAt.timeIntervalSinceNow > 2
            // ponytail: root-process memory from top at most every 30 s, and only
            // with the panel open. The icon needs only this user's processes.
            if open, force || -topAt.timeIntervalSinceNow > 30 { top = topMem(); topAt = Date() }
            var procs = scan(top: top)
            // Listening ports only with the panel open, at most every 10 s or on Refresh: a
            // pass reads each fd of each of this user's processes (about 2 ms for 420 here).
            if open, force || -portsAt.timeIntervalSinceNow > 10 { ports = listenPorts(procs); portsAt = Date() }
            // Not closed: the map gets old, and the panel shows these groups first when it opens.
            if open { addPorts(&procs, ports) }
            Sims.update(procs, open: open, force: force)
            addCPU(&procs, prev: prevCPU, seconds: -prevAt.timeIntervalSinceNow)
            addIO(&procs, prev: prevIO, seconds: -prevAt.timeIntervalSinceNow); prevIO = procs.mapValues(\.io)
            prevCPU = procs.mapValues(\.cpuTime); prevAt = Date()
            let g = orphans.mark(ignoring(recall.groups(procs, responsible: responsible), UserDefaults.standard.ignored), procs, open: open)
            let s = systemMem()
            DispatchQueue.main.async {
                // A group that is gone drops out: its old PIDs never match reused ones later.
                self.stopped = self.stopped.filter { id, _ in g.contains { $0.id == id } }
                self.slots = keepSlots(g, kept: self.slots)
                self.groups = g; self.sys = s; self.history.add(g, sys: s, allUsers: open); self.onUpdate()
                HistoryFile.save(self.history)  // at most every 5 min, off the main thread
                if open, self.markAsked { self.markAsked = false; self.setMark(Mark(g, ram: s.ram)) }
                Auto.check(g, self)  // auto-stop and Quit When Idle, also with the panel closed
                Rules.check(g)  // Restart When Above, Pause When in Background
                Containers.shared.poll(g, open: self.panelOpen)  // docker stats for an open VM row
            }
        }
    }

    /// Row's Stop, Stop All and auto-stop: stop, then watch the groups for a respawn (Recall).
    func stopGroups(_ gs: [Group], how: String = "Stop") {
        let gs = notStopped(gs, stopped)
        guard !gs.isEmpty else { return }
        gs.forEach { stopped[$0.id] = Set($0.procs.map(\.pid)) }
        gs.forEach(stop)
        Freed.record(gs.filter { stoppable($0) }, how: how)
        queue.async { [self] in gs.forEach { recall.didStop($0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { self.refresh() }  // a respawn shows within 60 s
    }
}

enum Sort: String { case name, procs, cpu, memory, change }

struct Panel: View {
    @ObservedObject var model: Model
    @AppStorage("sort") private var sort = Sort.memory
    @AppStorage("hideSmall") private var hideSmall = false
    @AppStorage("showMacOS") private var showMacOS = true
    @State var query = ""
    @StateObject var nav = Nav()  // selection and open groups (Keys.swift)
    @FocusState var focus: Field?

    /// The Settings filters thin the plain list; a search looks at every group.
    var listed: (shown: [Group], small: [Group]) { visible(model.groups, hideSmall: hideSmall, showMacOS: showMacOS) }

    /// The search as tokens and text (Search.swift). One place: shown and rowIDs must agree.
    var q: Search { Search(query) }
    var markDelta: Mark.Delta? { model.mark.map { delta(mark: $0, groups: model.groups) } }

    /// Leftovers first, then by the sort column. A search keeps the groups it finds, from all groups.
    var shown: [Group] {
        let q = q
        let gs = q.isEmpty ? listed.shown : searched(q)
        let d = markDelta
        func key(_ g: Group) -> Double {
            switch sort { case .name: 0; case .procs: Double(g.procs.count); case .cpu: g.cpu; case .memory: Double(g.mem); case .change: Double(d?.key(g) ?? g.mem) }
        }
        return gs.sorted {
            if $0.leftover != $1.leftover { return $0.leftover }
            return sort == .name ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : key($0) > key($1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AppMem").font(.headline)
                    Spacer()
                    if model.waste > 0 {  // the total and its action as one unit, a little apart from the tools
                        HStack(spacing: 6) {
                            Text("Leftovers \(fmt(model.waste))").foregroundStyle(Color.leftover).monospacedDigit()
                            Button("Stop All") { model.stopAll() }
                                .controlSize(.small)
                                .help("Stop every leftover: \(model.groups.filter(\.leftover).map(\.name).joined(separator: ", "))")
                        }
                        .padding(.trailing, 4)
                    }
                    MarkButton(model: model)
                    Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("r")
                        .help("Refresh (⌘R)")
                        .accessibilityLabel("Refresh")
                    SettingsMenu()
                }
                HStack(spacing: 12) {
                    Text("RAM \(fmt(model.sys.ram)) of \(fmt(Int64(ProcessInfo.processInfo.physicalMemory)))")
                        .help("Memory Used in Activity Monitor: app, wired and compressed memory")
                    Text("Swap \(fmt(model.sys.swap))").help("Swap in use on disk")
                    // The rows and the small-groups footer: a hidden macOS group has no line, so not in it.
                    Text("Apps \(fmt((listed.shown + listed.small).reduce(0) { $0 + $1.mem }))")
                        .help("Sum of the memory of all processes below")
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                MarkLine(model: model)
                IdleLine(groups: model.groups)
                PressureBar(sys: model.sys, groups: model.groups, slots: model.slots).font(.caption).foregroundStyle(.secondary)
                HistoryChart(history: model.history)  // Day.swift: RAMChart over 1 h or 24 h
                TextField("Search or filter: leftover, >1gb, :3000", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focus, equals: .search)
                    .onKeyPress(keys: [.upArrow, .downArrow]) { step($0.key == .downArrow ? 1 : -1) }
                    .help("Keys: ↑ ↓ select a row, → ← open and close it, ⌘C copy, ⌘⌫ Stop a leftover or orphan, ⌘F search, Esc clear")
                    .searchMenu(marked: model.mark != nil, insert: insert)
            }
            .padding(10)
            Divider()
            HStack(spacing: 6) {
                column("App", .name).padding(.leading, 38)
                Spacer(minLength: 4)
                if model.mark != nil { column("Change", .change) }
                column("Procs", .procs)
                column("CPU", .cpu, width: 40)
                column("Memory", .memory, width: 62)
            }
            .font(.caption).padding(.horizontal, 10)
            Divider()
            let s = shown, typed = query.trimmingCharacters(in: .whitespaces)  // shown sorts: once per render
            IntroCard()  // Legend.swift. Not in the lazy list: scrolled away, it would drop its close watch
            ScrollView {
                LazyVStack(spacing: 0) {
                    let q = q, d = markDelta
                    ForEach(s) { g in
                        Row(g: g, only: hits(g, q), points: model.history.points(g.id), change: d.flatMap { changeLabel(g, $0) }, slot: model.slots[g.id], nav: nav) {
                            model.stopGroups([g])
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable().focusEffectDisabled().focused($focus, equals: .list)
            .onKeyPress(action: listKey)
            .onCopyCommand(perform: copied.map { s in { [NSItemProvider(object: s as NSString)] } })  // nil: Copy is off
            .scrolls(to: nav.sel)
            .overlay { if s.isEmpty && !typed.isEmpty { NoResults(typed: typed, q: q, marked: model.mark != nil) } }  // else no match looks like loading
            let small = q.isEmpty ? listed.small : []
            if !small.isEmpty {
                Divider()
                Text("\(small.count) small group\(small.count == 1 ? "" : "s"), \(fmt(small.reduce(0) { $0 + $1.mem }))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().padding(.vertical, 4)
                    .help("Hidden by Settings > Hide Groups Under 10 MB")
            }
            FreedLine()
        }
        .frame(width: 400, height: 540)
        .onKeyPress(.escape, phases: [.down, .repeat], action: escape)
        .onChange(of: rowIDs) { _, ids in nav.sel = kept(nav.sel, in: ids) }
        .onAppear { focus = .list; nav.focusList = { focus = .list } }
        // Each time the popover opens (onAppear runs only the first time), else AppKit gives the
        // focus to a button: arrows work at once, and typing still searches. Only the panel's
        // popover: the pressure breakdown is an NSPopover too.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { n in
            if n.object as? NSPopover === (NSApp.delegate as? Delegate)?.popover { focus = .list }
        }
        // Each open starts unfiltered: else a notification opens a list that hides its leftover, and typing
        // adds to the old text. On close, not on show: didShow comes after the animation shows the old list.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { n in
            if n.object as? NSPopover === (NSApp.delegate as? Delegate)?.popover { query = "" }
        }
    }

    /// The header's height and the column's width are the target, not only the word.
    func column(_ title: String, _ s: Sort, width: CGFloat? = nil) -> some View {
        Button { sort = s } label: {
            Text(title).fontWeight(sort == s ? .semibold : .regular).foregroundStyle(sort == s ? .primary : .secondary)
                .frame(width: width, alignment: .trailing).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
        .accessibilityAddTraits(sort == s ? .isSelected : [])
    }
}

/// The processes of `g` whose name or site/role (Names.swift) contains `q`, or whose PID or a port is `q`: the search's text.
func matching(_ g: Group, _ q: String) -> [Proc] {
    g.procs.filter { $0.name.lowercased().contains(q) || String($0.pid) == q || portMatch($0.ports, q) || Names.of($0, in: g.name).lowercased().contains(q) }
}

/// App icons, cached: NSWorkspace reads them from disk.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func of(_ g: Group) -> NSImage? {
        guard let path = g.bundle ?? (g.isApp ? installed(g.isEmulator ? "Android Studio" : g.name) : nil) else { return nil }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }

    /// An app in /Applications with this name, for groups found by their
    /// Application Support folder (Cursor's node processes).
    private static func installed(_ name: String) -> String? {
        ["/Applications", NSHomeDirectory() + "/Applications"].map { "\($0)/\(name).app" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}

struct Row: View {
    let g: Group
    let only: [Proc]?  // search hits inside the group: show these, expanded
    var points: [(at: Date, mem: Int64)] = []  // memory history: growing badge, sparkline
    var change: (text: String, color: Color, help: String)?  // since the mark (Mark.swift)
    var slot: Int?  // its color in the RAM bar (RAMBar.swift), for the 4 largest
    @ObservedObject var nav: Nav  // open or not, selected or not (Keys.swift)
    let stop: () -> Void
    var expanded: Bool { nav.expanded.contains(g.id) }

    var body: some View {
        let growing = growthText(points), paused = isPaused(g), others = othersHelp(g), picked = nav.sel == RowID(group: g.id)
        // Only where the right-click menu shows the rule and idleQuits acts: an open app at the group's .app.
        let quitIdle = idleRule(g.name).flatMap { m in
            g.leftover || g.ignored || Actions.runningApp(g) == nil ? nil : "Quits when not used for \(hours(m))"
        }
        // A double-click opens Details; its second toggle undoes the first.
        let open = { nav.click(RowID(group: g.id)); nav.toggle(g.id); if isDoubleClick() { Details.show(g) } }
        let isOpen = expanded || only != nil
        VStack(alignment: .leading, spacing: 2) {
            // The row's margins are inside its buttons: a click anywhere on the row opens it, not
            // only on the text. Open, no margin below: the process lines are its targets there.
            HStack(spacing: 0) {
                Button(action: open) {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 10)
                        icon.frame(width: 16, height: 16)
                        Text(g.name).lineLimit(1).truncationMode(.middle)
                        if g.orphan {  // orange only when counted as a leftover (Settings)
                            Badge.orphan(leftover: g.leftover).help(flagHelp(g))
                        } else if g.leftover {
                            Badge.leftover.help(flagHelp(g))
                        }
                        if let why = g.respawns {  // an icon: a second word would squeeze the name
                            Badge.respawns.help(why)
                        }
                        if let quitIdle {
                            Badge.quitIdle.help(quitIdle + ". Right-click to change.")
                        }
                        if paused { Badge.paused.help("Paused: its processes do not run. Right-click to resume.") }
                        UsageBadge(g: g)
                        if let growing { Badge.growing.help("Memory is growing: \(growing)") }
                        LimitBell(g: g)
                        RuleBadges(g: g)  // Rules.swift
                        // Only where a port tells what the group is (a dev server, a leftover's or orphan's
                        // socket); an app's own ports are noise here, and stay in its lines, the search and VoiceOver.
                        // Gone before the name truncates: all ports, one, the icon, then nothing. After the
                        // age badge (-1): how stale a leftover is matters more to Stop than its socket.
                        if showsPorts(g) {
                            ViewThatFits(in: .horizontal) {
                                PortChip(ports: g.ports, network: true)
                                PortChip(ports: g.ports, network: true, limit: 1)
                                PortChip(ports: g.ports, network: true, limit: 0)
                                Color.clear.frame(width: 0, height: 0)
                            }
                            .layoutPriority(-2)
                        }
                        // ponytail: on a leftover or orphan row Stop sits between the change and "Procs", so the
                        // change is a Stop width left of its header; a fixed Stop slot would take it from every name.
                        Spacer(minLength: 4).overlay(alignment: .trailing) { ChangeText(label: change, procs: g.procs.count) }
                    }
                    .padding(.leading, 10).padding(.trailing, 6).padding(.top, 3).padding(.bottom, isOpen ? 0 : 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(g.name), \(fmt(g.mem)), CPU \(cpu(g.cpu)), \(g.procs.count) processes\(g.orphan ? ", orphan" : g.leftover ? ", leftover" : "")\(growing.map { ", growing \($0)" } ?? "")\(portsLabel(g.ports))")
                .accessibilityValue([paused ? "Paused" : nil, g.orphan ? orphanHelp : nil, g.respawns, Usage.note(g)?.help, quitIdle, Rules.help(g), limitHelp(g), change?.help, ioNote(g), others.isEmpty ? nil : others]
                    .compactMap { $0 }.joined(separator: ". "))
                .accessibilityAction(named: "Show Details") { Details.show(g) }
                .accessibilityAddTraits(picked ? .isSelected : [])
                if g.leftover || g.orphan {
                    Button("Stop", action: stop)
                        .controlSize(.small)
                        .disabled(!canStop(g))
                        .help(others)
                        .accessibilityLabel("Stop \(g.name)")
                        // The labels' margins, so it stays centered on the name; not a target: a near miss does nothing.
                        .padding(.trailing, 6).padding(.top, 3).padding(.bottom, isOpen ? 0 : 3)
                }
                // After Stop, as in DeviceLine: the numbers line up with the header and the process lines.
                // The row's label already reads them to VoiceOver.
                Button(action: open) {
                    HStack(spacing: 6) {
                        // Here and on Stop, not on the whole row: an outer .help hides each .help inside it.
                        // Fixed: a count squeezed by Stop wrapped to two lines ("1" over "9").
                        Text("\(g.procs.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize().help(others)
                        Text(cpu(g.cpu)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                            .help(cpuHelp(g))  // power and disk too (Energy.swift)
                        Text(fmt(g.mem)).monospacedDigit().slotDot(slot).frame(minWidth: 62, alignment: .trailing)
                    }
                    .padding(.trailing, 10).padding(.top, 3).padding(.bottom, isOpen ? 0 : 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .contextMenu { GroupMenu(g: g) }
            .highlight(picked, lead: -4, trail: -4, top: -2, bottom: isOpen ? 1 : -2)  // where it was with the margins outside
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    if points.count >= 3 { Sparkline(points: points, growing: growing != nil).padding(.leading, 38) }
                    if g.isSimulator { DeviceLines(g: g) }
                    if g.isVM { VMLines(g: g) }  // Containers.swift
                    ProcList(g: g, procs: only ?? g.procs, nav: nav)
                }
                .padding(.horizontal, 10).padding(.bottom, 3)
            }
        }
    }

    @ViewBuilder var icon: some View {
        if let i = Icons.of(g) {
            Image(nsImage: i).resizable()
        } else {
            Image(systemName: g.name == "macOS" ? "apple.logo" : g.isSimulator ? "iphone" : g.isEmulator ? "smartphone" : g.isVM ? "server.rack" : "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

/// The row's port chip: on a leftover, an orphan, or a command-line group (no .app, not
/// macOS), where a port tells what it is (`node` on :3000). An app's own ports would be noise.
func showsPorts(_ g: Group) -> Bool { !g.ports.isEmpty && (g.leftover || g.orphan || g.bundle == nil && g.name != "macOS") }

extension View {
    /// One style for a row's flags, words and icons alike (leftover, orphan, paused, respawns,
    /// growing, quit timer, limit bell); the color says how much it matters.
    func flag(_ color: Color = .secondary) -> some View { font(.caption2.weight(.semibold)).foregroundStyle(color) }
}

extension Color {
    /// Leftover orange. systemOrange text is about 2:1 on the light panel, too faint for a
    /// 10 pt word; a darker orange there is about 3.7:1. Dark mode keeps systemOrange (about 7:1).
    static let leftover = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemOrange : NSColor(srgbRed: 0.78, green: 0.38, blue: 0, alpha: 1)
    })
}

/// Why a group has its orphan or leftover badge: the badge's tooltip (row and Details),
/// and the first sentence of the leftover notification.
func flagHelp(_ g: Group) -> String {
    g.orphan ? orphanHelp : g.isSimulator ? "A device is booted and Simulator is not open"
        : g.isEmulator ? "An emulator runs and Android Studio is not open" : "\(g.name) is not open"
}

/// "12%", or "–" below 0.1% so idle groups do not read as busy.
func cpu(_ v: Double) -> String { v < 0.1 ? "–" : v < 10 ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v) }

final class Delegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let model = Model()
    let alerts = Alerts()
    // The kernel calls when the pressure level changes: the dot need not wait for the 60 s scan.
    let pressureEvents = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let button = item.button else { return }
        button.image = Self.chip
        button.target = self
        button.action = #selector(clicked)  // MenuBar.swift: a right click opens the quick menu
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.onUpdate = { [weak self] in self?.updateIcon(); self?.alerts.check() }
        alerts.start(model) { [weak self] in self?.openPanel() }  // a notification click; MenuBar.swift
        Usage.start()
        Rules.start()  // resumes the apps it paused on a switch to them and at quit
        model.schedule()
        model.refresh()
        pressureEvents.setEventHandler { [weak self] in self?.model.refresh() }
        pressureEvents.resume()
    }

    // No size text in the menu bar by default (Settings > Menu Bar Shows): it read as the
    // total RAM use. A yellow dot means "leftovers found", orange or red memory pressure
    // (see menuState); the tooltip and the panel give the size.
    static let chip: NSImage = {
        let i = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "AppMem")!
        i.isTemplate = true
        return i
    }()

    // Not a template (it has a color), so it draws the chip in the menu bar text
    // color itself. cacheMode .never: draw again when the menu bar goes dark/light.
    static func dotIcon(_ color: NSColor, _ description: String) -> NSImage {
        let i = NSImage(size: chip.size, flipped: false) { r in
            chip.draw(in: r)
            NSColor.labelColor.set()
            r.fill(using: .sourceAtop)
            let dot = NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear  // gap around the dot
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        i.cacheMode = .never
        i.accessibilityDescription = description
        return i
    }

    func updateIcon() {
        let s = menuState(model.sys.pressure, waste: model.waste)
        // The description names the state, so a new image only when the state changes.
        if item.button?.image?.accessibilityDescription != s.desc {
            item.button?.image = s.dot.map { Self.dotIcon($0, s.desc) } ?? Self.chip
        }
        item.button?.toolTip = s.tip
        updateTitle()  // MenuBar.swift
        updateGraph(s)  // MenuGraph.swift: Menu Bar Shows > RAM Graph
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverWillShow(_ note: Notification) { model.panelOpen = true }
    func popoverDidClose(_ note: Notification) { model.panelOpen = false }
}

#if DEBUG
/// `AppMem --snapshot out.png [query]` (debug builds): the panel with live data as
/// a PNG, to check the layout without a click on the menu bar. `make`: the view to
/// draw, from the filled model (Details draws its window this way too).
func snapshot<V: View>(to path: String, size: NSSize = NSSize(width: 400, height: 540), _ make: (Model) -> V) {
    _ = NSApplication.shared
    let model = Model()
    let top = topMem()
    var procs = scan(top: top)
    let prev = procs.mapValues(\.cpuTime)
    let prevIO = procs.mapValues(\.io)
    Thread.sleep(forTimeInterval: 1)
    procs = scan(top: top)
    addCPU(&procs, prev: prev, seconds: 1)
    addIO(&procs, prev: prevIO, seconds: 1)
    addPorts(&procs, listenPorts(procs))
    Sims.booted = Sims.read(procs.values.filter { $0.name == "launchd_sim" })  // not update(): it posts to main, too late for the layout
    model.groups = ignoring(group(procs, responsible: responsible), UserDefaults.standard.ignored)
    var orphans = Orphans()
    model.groups = orphans.mark(model.groups, procs, open: true)
    if ProcessInfo.processInfo.environment["CROWD"] != nil { model.groups = Group.crowd + model.groups }
    if ProcessInfo.processInfo.environment["CROWD"] != nil { model.groups.append(Containers.demo()) }  // Containers.swift
    model.sys = systemMem()
    model.slots = keepSlots(model.groups, kept: [:])
    if ProcessInfo.processInfo.environment["HISTORY"] != nil { model.history = .demo(model.groups, sys: model.sys) }
    model.mark = ProcessInfo.processInfo.environment["MARK"] != nil ? .demo(model.groups, sys: model.sys) : nil  // never the saved one
    // FIRSTRUN=1: the first-run card. In the argument domain: in memory, never the saved flag.
    let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    UserDefaults.standard.setVolatileDomain(args.merging(["introSeen": ProcessInfo.processInfo.environment["FIRSTRUN"] == nil]) { $1 },
                                            forName: UserDefaults.argumentDomain)
    let view = NSHostingView(rootView: make(model))
    view.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    if let d = ProcessInfo.processInfo.environment["DARK"] { window.appearance = NSAppearance(named: d == "0" ? .aqua : .darkAqua) }  // DARK=0: light
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // off screen, but ordered in:
    window.orderFrontRegardless()  // SwiftUI draws text only in a window that is ordered in
    RunLoop.main.run(until: Date() + 1)  // SwiftUI lays out on the run loop
    writePNG(view, to: path)
}

/// `view` at 2x as a PNG: the snapshots, and --drive's windows (Drive.swift).
func writePNG(_ view: NSView, to path: String) {
    // cacheDisplay misses SwiftUI's text layers; render the layer tree instead.
    let w = Int(view.bounds.width) * 2, h = Int(view.bounds.height) * 2
    guard let layer = view.layer, let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ctx.cgContext.setFillColor(CGColor(gray: dark ? 0.15 : 0.96, alpha: 1))
    ctx.cgContext.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.cgContext.translateBy(x: 0, y: CGFloat(h))  // layers are top-down here
    ctx.cgContext.scaleBy(x: 2, y: -2)
    layer.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

extension Group {
    /// `CROWD=1 AppMem --snapshot ...`: made-up groups with each badge (leftover, respawns,
    /// orphan, paused, ports), to check a crowded panel. Never stopped: a snapshot only draws.
    /// The first process has AppMem's own PID, for a real age; the rest PIDs that cannot exist.
    static var crowd: [Group] {
        let mb: Int64 = 1 << 20
        func ps(_ path: String, _ mem: Int64, _ n: Int = 1, ports: [UInt16] = [], stopped: Bool = false) -> [Proc] {
            (0..<n).map { i in
                var p = Proc(pid: i == 0 ? getpid() : 900_000 + pid_t(i), ppid: 1, uid: getuid(), path: path, mem: mem * mb)
                p.ports = i == 0 ? ports : []; p.stopped = stopped
                return p
            }
        }
        var cursor = Group(name: "Cursor", isApp: true, procs: ps(NSHomeDirectory() + "/Library/Application Support/Cursor/node", 110, 19, ports: [3000, 9229]), leftover: true)
        cursor.respawns = "Came back after Stop: launchd starts it again"
        cursor.job = "com.todesktop.230313mzl4w4u92.ShipIt"  // a launch agent: the Details header names it
        var node = Group(name: "node", isApp: false, procs: ps("/opt/homebrew/bin/node", 420, ports: [5173]))
        node.orphan = true
        var docker = Group(name: "Docker", isApp: true, procs: ps("/Applications/Docker.app/Contents/MacOS/com.docker.backend", 900, 2, ports: [2375], stopped: true))
        docker.bundle = "/Applications/Docker.app"
        return [cursor, node, docker]
    }
}
#endif
