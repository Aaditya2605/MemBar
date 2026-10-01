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
            let g = group(scan(top: top), responsible: responsible), s = systemMem()
            DispatchQueue.main.async { self.groups = g; self.sys = s; self.onUpdate() }
        }
    }

    func stopGroup(_ g: Group) {
        stop(g)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.refresh() }
    }
}

struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
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
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.groups) { g in Row(g: g) { model.stopGroup(g) } }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 400, height: 540)
    }
}

struct Row: View {
    let g: Group
    let stop: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).frame(width: 10)
                        Text(g.name).lineLimit(1).truncationMode(.middle)
                        if g.leftover {
                            Text("leftover").font(.caption2.bold()).foregroundStyle(.orange)
                                .help(g.isSimulator ? "A device is booted and Simulator is not open" : "\(g.name) is not open")
                        }
                        Spacer(minLength: 4)
                        Text("\(g.procs.count)").font(.caption).foregroundStyle(.secondary)
                        Text(fmt(g.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(g.name), \(fmt(g.mem)), \(g.procs.count) processes\(g.leftover ? ", leftover" : "")")
                if g.leftover {
                    Button("Stop", action: stop)
                        .controlSize(.small)
                        .disabled(!g.isSimulator && !g.procs.contains { $0.uid == getuid() })
                }
            }
            if expanded {
                ForEach(g.procs.prefix(10), id: \.pid) { p in
                    HStack {
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(p.pid)).monospacedDigit()
                        Text(fmt(p.mem)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}

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
