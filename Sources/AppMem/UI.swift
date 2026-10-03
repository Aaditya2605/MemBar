import AppKit
import SwiftUI

// Menu bar item + popover. The popover refreshes every 3 s while it is open;
// closed, a scan runs once a minute, only to update the icon.

final class Model: ObservableObject {
    @Published var groups: [Group] = []
    @Published var sys: (ram: Int64, swap: Int64) = (0, 0)
    var onUpdate: () -> Void = {}
    var panelOpen = false { didSet { schedule(); refresh() } }
    private var timer: Timer?
    private let queue = DispatchQueue(label: "appmem.scan", qos: .utility)
    private var top: [pid_t: Int64] = [:], topAt = Date.distantPast  // queue only
    private var prevCPU: [pid_t: UInt64] = [:], prevAt = Date.distantPast  // queue only

    var waste: Int64 { groups.filter(\.leftover).reduce(0) { $0 + $1.mem } }
    var total: Int64 { groups.reduce(0) { $0 + $1.mem } }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: panelOpen ? 3 : 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = panelOpen ? 0.5 : 10
    }

    /// `force`: the Refresh button, also reads root-process memory from top again.
    func refresh(force: Bool = false) {
        let open = panelOpen
        queue.async { [self] in
            // ponytail: root-process memory from top at most every 30 s, and only
            // with the panel open. The icon needs only this user's processes.
            if open, force || -topAt.timeIntervalSinceNow > 30 { top = topMem(); topAt = Date() }
            var procs = scan(top: top)
            addCPU(&procs, prev: prevCPU, seconds: -prevAt.timeIntervalSinceNow)
            prevCPU = procs.mapValues(\.cpuTime); prevAt = Date()
            let g = group(procs, responsible: responsible), s = systemMem()
            DispatchQueue.main.async { self.groups = g; self.sys = s; self.onUpdate() }
        }
    }

    func stopGroup(_ g: Group) {
        stop(g)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.refresh() }
    }
}

enum Sort: String { case name, procs, cpu, memory }

struct Panel: View {
    @ObservedObject var model: Model
    @AppStorage("sort") private var sort = Sort.memory
    @State var query = ""

    /// Leftovers first, then by the sort column. A query keeps the groups whose name,
    /// or one of whose process names or PIDs, matches.
    var shown: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let gs = q.isEmpty ? model.groups : model.groups.filter { $0.name.lowercased().contains(q) || !matching($0, q).isEmpty }
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
                    }
                    Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("r")
                        .help("Refresh (⌘R)")
                        .accessibilityLabel("Refresh")
                    Button("Quit") { NSApp.terminate(nil) }
                }
                HStack(spacing: 12) {
                    Text("RAM \(fmt(model.sys.ram)) of \(fmt(Int64(ProcessInfo.processInfo.physicalMemory)))")
                        .help("Memory Used in Activity Monitor: app, wired and compressed memory")
                    Text("Swap \(fmt(model.sys.swap))").help("Swap in use on disk")
                    Text("Apps \(fmt(model.total))").help("Sum of the memory of all processes below")
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                TextField("Search apps, processes or PIDs", text: $query)
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
                        Row(g: g, only: hits) { model.stopGroup(g) }
                    }
                }
                .padding(.vertical, 4)
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

/// The processes of `g` whose name contains `q`, or whose PID is `q`.
func matching(_ g: Group, _ q: String) -> [Proc] {
    g.procs.filter { $0.name.lowercased().contains(q) || String($0.pid) == q }
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
    let stop: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded || only != nil ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 10)
                        icon.frame(width: 16, height: 16)
                        Text(g.name).lineLimit(1).truncationMode(.middle)
                        if g.leftover {
                            Text("leftover").font(.caption2.bold()).foregroundStyle(.orange)
                                .help(g.isSimulator ? "A device is booted and Simulator is not open" : "\(g.name) is not open")
                        }
                        Spacer(minLength: 4)
                        Text("\(g.procs.count)").font(.caption).foregroundStyle(.secondary)
                        Text(cpu(g.cpu)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Text(fmt(g.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(g.name), \(fmt(g.mem)), CPU \(cpu(g.cpu)), \(g.procs.count) processes\(g.leftover ? ", leftover" : "")")
                if g.leftover {
                    Button("Stop", action: stop)
                        .controlSize(.small)
                        .disabled(!g.isSimulator && !g.procs.contains { $0.uid == getuid() })
                }
            }
            if expanded || only != nil {
                ForEach((only ?? g.procs).prefix(10), id: \.pid) { p in
                    HStack {
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(p.pid)).monospacedDigit()
                        Text(cpu(p.cpu)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        Text(fmt(p.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
                }
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

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let button = item.button else { return }
        button.image = Self.chip
        button.target = self
        button.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.onUpdate = { [weak self] in self?.updateIcon() }
        model.schedule()
        model.refresh()
    }

    // No size text in the menu bar: it read as the total RAM use. A yellow dot
    // means "leftovers found"; the tooltip and the panel give the size.
    static let chip: NSImage = {
        let i = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "AppMem")!
        i.isTemplate = true
        return i
    }()

    // Not a template (it has a color), so it draws the chip in the menu bar text
    // color itself. cacheMode .never: draw again when the menu bar goes dark/light.
    static let junkIcon: NSImage = {
        let i = NSImage(size: chip.size, flipped: false) { r in
            chip.draw(in: r)
            NSColor.labelColor.set()
            r.fill(using: .sourceAtop)
            let dot = NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear  // gap around the dot
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        i.cacheMode = .never
        i.accessibilityDescription = "AppMem, leftovers found"
        return i
    }()

    func updateIcon() {
        let waste = model.waste
        item.button?.image = waste > 0 ? Self.junkIcon : Self.chip
        item.button?.toolTip = waste > 0 ? "Leftovers use \(fmt(waste))" : "AppMem: no leftovers"
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
/// a PNG, to check the layout without a click on the menu bar.
func snapshot(to path: String, query: String) {
    _ = NSApplication.shared
    let model = Model()
    let top = topMem()
    var procs = scan(top: top)
    let prev = procs.mapValues(\.cpuTime)
    Thread.sleep(forTimeInterval: 1)
    procs = scan(top: top)
    addCPU(&procs, prev: prev, seconds: 1)
    model.groups = group(procs, responsible: responsible)
    model.sys = systemMem()
    let view = NSHostingView(rootView: Panel(model: model, query: query))
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 540)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    if ProcessInfo.processInfo.environment["DARK"] != nil { window.appearance = NSAppearance(named: .darkAqua) }
    window.contentView = view
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // off screen, but ordered in:
    window.orderFrontRegardless()  // SwiftUI draws text only in a window that is ordered in
    RunLoop.main.run(until: Date() + 1)  // SwiftUI lays out on the run loop
    // cacheDisplay misses SwiftUI's text layers; render the layer tree instead.
    guard let layer = view.layer, let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1080, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ctx.cgContext.setFillColor(CGColor(gray: dark ? 0.15 : 0.96, alpha: 1))
    ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 800, height: 1080))
    ctx.cgContext.translateBy(x: 0, y: 1080)  // layers are top-down here
    ctx.cgContext.scaleBy(x: 2, y: -2)
    layer.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
#endif
