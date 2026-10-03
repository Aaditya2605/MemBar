import AppKit
import SwiftUI

// Menu bar item + popover. The popover refreshes every 2-5 s while it is open
// (Settings > Refresh Every); closed, a scan runs once a minute, only to update the icon.

final class Model: ObservableObject {
    @Published var groups: [Group] = []
    @Published var sys = SysMem()
    @Published var history = History()
    var onUpdate: () -> Void = {}
    var panelOpen = false { didSet { schedule(); refresh() } }
    var windowOpen = false { didSet { if windowOpen != oldValue { schedule(); refresh() } } }  // Details: scans as the panel does
    private var open: Bool { panelOpen || windowOpen }
    private var timer: Timer?
    private let queue = DispatchQueue(label: "appmem.scan", qos: .utility)
    private var top: [pid_t: Int64] = [:], topAt = Date.distantPast  // queue only
    private var prevCPU: [pid_t: UInt64] = [:], prevAt = Date.distantPast  // queue only
    private var ports: [pid_t: [UInt16]] = [:], portsAt = Date.distantPast  // queue only
    private var recall = Recall()  // queue only
    private var watches: [NSKeyValueObservation] = []

    init() {
        // Settings apply at once, also an ignore list that the right-click menu writes.
        // Main queue: KVO reports on the writer's thread, and the timer needs the main run loop.
        watches = [UserDefaults.standard.observe(\.ignored) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } },
                   UserDefaults.standard.observe(\.refreshEvery) { [weak self] _, _ in DispatchQueue.main.async { self?.schedule() } }]
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
            // ponytail: root-process memory from top at most every 30 s, and only
            // with the panel open. The icon needs only this user's processes.
            if open, force || -topAt.timeIntervalSinceNow > 30 { top = topMem(); topAt = Date() }
            var procs = scan(top: top)
            // Listening ports only with the panel open, at most every 10 s or on Refresh: a
            // pass reads each fd of each of this user's processes (about 2 ms for 420 here).
            if open, force || -portsAt.timeIntervalSinceNow > 10 { ports = listenPorts(procs); portsAt = Date() }
            // Not closed: the map gets old, and the panel shows these groups first when it opens.
            if open { addPorts(&procs, ports) }
            addCPU(&procs, prev: prevCPU, seconds: -prevAt.timeIntervalSinceNow)
            prevCPU = procs.mapValues(\.cpuTime); prevAt = Date()
            let g = ignoring(recall.groups(procs, responsible: responsible), UserDefaults.standard.ignored), s = systemMem()
            DispatchQueue.main.async { self.groups = g; self.sys = s; self.history.add(g, sys: s, allUsers: open); self.onUpdate() }
        }
    }

    /// Row's Stop and Stop All: stop, then watch the groups for a respawn (Recall).
    func stopGroups(_ gs: [Group]) {
        gs.forEach(stop)
        queue.async { [self] in gs.forEach { recall.didStop($0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { self.refresh() }  // a respawn shows within 60 s
    }
}

enum Sort: String { case name, procs, cpu, memory }

struct Panel: View {
    @ObservedObject var model: Model
    @AppStorage("sort") private var sort = Sort.memory
    @AppStorage("hideSmall") private var hideSmall = false
    @AppStorage("showMacOS") private var showMacOS = true
    @State var query = ""

    /// The Settings filters thin the plain list; a search looks at every group.
    var listed: (shown: [Group], small: [Group]) { visible(model.groups, hideSmall: hideSmall, showMacOS: showMacOS) }

    /// Leftovers first, then by the sort column. A query keeps the groups whose name,
    /// or one of whose process names or PIDs, matches.
    var shown: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let gs = q.isEmpty ? listed.shown : model.groups.filter { $0.name.lowercased().contains(q) || !matching($0, q).isEmpty }
        func key(_ g: Group) -> Double {
            switch sort { case .name: 0; case .procs: Double(g.procs.count); case .cpu: g.cpu; case .memory: Double(g.mem) }
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
                    if model.waste > 0 {
                        Text("Leftovers: \(fmt(model.waste))").foregroundStyle(.orange)
                        Button("Stop All") { model.stopAll() }
                            .controlSize(.small)
                            .help("Stop every leftover: \(model.groups.filter(\.leftover).map(\.name).joined(separator: ", "))")
                    }
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
                IdleLine(groups: model.groups)
                PressureBar(sys: model.sys).font(.caption).foregroundStyle(.secondary)
                RAMChart(samples: model.history.samples)
                TextField("Search apps, processes, PIDs or :ports", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(10)
            Divider()
            HStack(spacing: 6) {
                column("App", .name).padding(.leading, 38)
                Spacer(minLength: 4)
                column("Procs", .procs)
                column("CPU", .cpu).frame(width: 40, alignment: .trailing)
                column("Memory", .memory).frame(width: 62, alignment: .trailing)
            }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                    ForEach(shown) { g in
                        let hits = q.isEmpty || g.name.lowercased().contains(q) ? nil : matching(g, q)
                        Row(g: g, only: hits, points: model.history.points(g.id)) { model.stopGroups([g]) }
                    }
                }
                .padding(.vertical, 4)
            }
            let small = query.trimmingCharacters(in: .whitespaces).isEmpty ? listed.small : []
            if !small.isEmpty {
                Divider()
                Text("\(small.count) small group\(small.count == 1 ? "" : "s"), \(fmt(small.reduce(0) { $0 + $1.mem }))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().padding(.vertical, 4)
                    .help("Hidden by Settings > Hide Groups Under 10 MB")
            }
        }
        .frame(width: 400, height: 540)
    }

    func column(_ title: String, _ s: Sort) -> some View {
        Button { sort = s } label: {
            Text(title).fontWeight(sort == s ? .semibold : .regular).foregroundStyle(sort == s ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }
}

/// The processes of `g` whose name contains `q`, or whose PID or a port is `q`.
func matching(_ g: Group, _ q: String) -> [Proc] {
    g.procs.filter { $0.name.lowercased().contains(q) || String($0.pid) == q || portMatch($0.ports, q) }
}

/// App icons, cached: NSWorkspace reads them from disk.
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func of(_ g: Group) -> NSImage? {
        guard let path = g.bundle ?? (g.isApp ? installed(g.name) : nil) else { return nil }
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
    let stop: () -> Void
    @State private var expanded = false

    var body: some View {
        let growing = growthText(points), paused = isPaused(g), others = othersHelp(g)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // A double-click opens Details; its second toggle undoes the first.
                Button { expanded.toggle(); if isDoubleClick() { Details.show(g) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded || only != nil ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 10)
                        icon.frame(width: 16, height: 16)
                        Text(g.name).lineLimit(1).truncationMode(.middle)
                        if g.leftover {
                            Text("leftover").font(.caption2.bold()).foregroundStyle(.orange)
                                .help(g.isSimulator ? "A device is booted and Simulator is not open" : "\(g.name) is not open")
                        }
                        if let why = g.respawns {  // an icon: a second word would squeeze the name
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2.bold()).foregroundStyle(.orange)
                                .help(why).accessibilityLabel("Respawns")
                        }
                        if paused {
                            Text("paused").font(.caption2.bold()).foregroundStyle(.secondary)
                                .help("Paused: its processes do not run. Right-click to resume.")
                        }
                        UsageBadge(g: g)
                        if let growing {
                            Image(systemName: "arrow.up.right").font(.caption2.bold()).foregroundStyle(.red)
                                .help("Memory is growing: \(growing)")
                        }
                        // Next to a paused badge only the icon: the name keeps its room. None on a
                        // leftover: with the badge and Stop, even the icon cuts the name that Stop is for.
                        if !g.ports.isEmpty && !g.leftover { PortChip(ports: g.ports, network: true, limit: paused ? 0 : growing == nil ? 2 : 1) }
                        Spacer(minLength: 4)
                        // Here and on Stop, not on the whole row: an outer .help hides each .help inside it.
                        Text("\(g.procs.count)").font(.caption).foregroundStyle(.secondary).help(others)
                        Text(cpu(g.cpu)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Text(fmt(g.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(g.name), \(fmt(g.mem)), CPU \(cpu(g.cpu)), \(g.procs.count) processes\(g.leftover ? ", leftover" : "")\(growing.map { ", growing \($0)" } ?? "")\(portsLabel(g.ports))")
                .accessibilityValue([paused ? "Paused" : nil, g.respawns, Usage.note(g)?.help, others.isEmpty ? nil : others]
                    .compactMap { $0 }.joined(separator: ". "))
                .accessibilityAction(named: "Show Details") { Details.show(g) }
                if g.leftover {
                    Button("Stop", action: stop)
                        .controlSize(.small)
                        .disabled(!g.isSimulator && !g.procs.contains { $0.uid == getuid() })
                        .help(others)
                }
            }
            .contextMenu { GroupMenu(g: g) }
            if expanded || only != nil {
                if points.count >= 3 { Sparkline(points: points, growing: growing != nil).padding(.leading, 38) }
                ProcList(g: g, procs: only ?? g.procs)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }

    @ViewBuilder var icon: some View {
        if let i = Icons.of(g) {
            Image(nsImage: i).resizable()
        } else {
            Image(systemName: g.name == "macOS" ? "apple.logo" : g.isSimulator ? "iphone" : "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

/// "12%", or "–" below 0.1% so idle groups do not read as busy.
func cpu(_ v: Double) -> String { v < 0.1 ? "–" : v < 10 ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v) }

final class Delegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let model = Model()
    // The kernel calls when the pressure level changes: the dot need not wait for the 60 s scan.
    let pressureEvents = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let button = item.button else { return }
        button.image = Self.chip
        button.target = self
        button.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.onUpdate = { [weak self] in self?.updateIcon() }
        Usage.start()
        model.schedule()
        model.refresh()
        pressureEvents.setEventHandler { [weak self] in self?.model.refresh() }
        pressureEvents.resume()
    }

    // No size text in the menu bar: it read as the total RAM use. A yellow dot
    // means "leftovers found", orange or red memory pressure (see menuState); the
    // tooltip and the panel give the size.
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
    Thread.sleep(forTimeInterval: 1)
    procs = scan(top: top)
    addCPU(&procs, prev: prev, seconds: 1)
    addPorts(&procs, listenPorts(procs))
    model.groups = ignoring(group(procs, responsible: responsible), UserDefaults.standard.ignored)
    model.sys = systemMem()
    if ProcessInfo.processInfo.environment["HISTORY"] != nil { model.history = .demo(model.groups, sys: model.sys) }
    let view = NSHostingView(rootView: make(model))
    view.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    if ProcessInfo.processInfo.environment["DARK"] != nil { window.appearance = NSAppearance(named: .darkAqua) }
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // off screen, but ordered in:
    window.orderFrontRegardless()  // SwiftUI draws text only in a window that is ordered in
    RunLoop.main.run(until: Date() + 1)  // SwiftUI lays out on the run loop
    // cacheDisplay misses SwiftUI's text layers; render the layer tree instead.
    let w = Int(size.width) * 2, h = Int(size.height) * 2
    guard let layer = view.layer, let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ctx.cgContext.setFillColor(CGColor(gray: dark ? 0.15 : 0.96, alpha: 1))
    ctx.cgContext.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.cgContext.translateBy(x: 0, y: CGFloat(h))  // layers are top-down here
    ctx.cgContext.scaleBy(x: 2, y: -2)
    layer.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
#endif
