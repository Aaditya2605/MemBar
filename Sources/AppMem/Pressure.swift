import AppKit
import SwiftUI

// Memory pressure and Activity Monitor's memory breakdown. "RAM used" alone says
// little: macOS fills free RAM with cache on purpose. Pressure is what macOS acts
// on: it compresses memory, then swaps, then asks you to quit apps.

/// kern.memorystatus_vm_pressure_level. The kernel gives dispatch levels: 1, 2, 4.
enum Pressure: Int32 {
    case normal = 1, warning = 2, critical = 4
    var label: String { switch self { case .normal: "Normal"; case .warning: "Warning"; case .critical: "Critical" } }
    var color: Color { switch self { case .normal: .green; case .warning: .yellow; case .critical: .red } }  // as Activity Monitor
}

struct SysMem {
    var app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0, cached: Int64 = 0, swap: Int64 = 0
    var pressure = Pressure.normal
    var free = 100  // kern.memorystatus_level: % of RAM that is available (free, or cache macOS can drop)
    var ram: Int64 { app + wired + compressed }  // "Memory Used" in Activity Monitor
    var usedPct: Int { min(100, max(0, 100 - free)) }  // the fill of Activity Monitor's pressure graph

    /// Activity Monitor's numbers from the VM page counts. Purgeable pages are
    /// cache, not app memory: macOS drops them first.
    init(_ vm: vm_statistics64 = .init(), page: Int64 = 0, swap: Int64 = 0, level: Int32? = nil, free: Int32? = nil) {
        func b(_ pages: natural_t) -> Int64 { Int64(pages) * page }
        app = max(0, b(vm.internal_page_count) - b(vm.purgeable_count))
        wired = b(vm.wire_count)
        compressed = b(vm.compressor_page_count)  // the RAM the compressor uses, not what it holds
        cached = b(vm.external_page_count) + b(vm.purgeable_count)
        self.swap = swap
        pressure = level.flatMap(Pressure.init) ?? .normal
        self.free = free.map(Int.init) ?? 100  // unknown: an empty bar, not a full one
    }
}

/// The menu bar dot and its words. Pressure wins over leftovers, critical over
/// warning: it needs action now.
func menuState(_ p: Pressure, waste: Int64) -> (dot: NSColor?, desc: String, tip: String) {
    let dot: NSColor? = p == .critical ? .systemRed : p == .warning ? .systemOrange : waste > 0 ? .systemYellow : nil
    let level = p == .normal ? nil : p.label
    let desc = ["AppMem", level.map { "memory pressure \($0.lowercased())" }, waste > 0 ? "leftovers found" : nil]
    let tip = [level.map { "Memory pressure: \($0)" }, waste > 0 ? "Leftovers use \(fmt(waste))" : nil].compactMap { $0 }
    return (dot, desc.compactMap { $0 }.joined(separator: ", "), tip.isEmpty ? "AppMem: no leftovers" : tip.joined(separator: "\n"))
}

/// Header row: a thin bar colored like Activity Monitor's pressure graph. A click
/// shows the breakdown.
struct PressureBar: View {
    let sys: SysMem
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                Text("Pressure")
                // Not ProgressView: it turns gray and ignores tint when the window is not key.
                Rectangle().fill(sys.pressure.color).scaleEffect(x: CGFloat(sys.usedPct) / 100, anchor: .leading)
                    .background(.quaternary).clipShape(Capsule()).frame(height: 5)
                Text("\(sys.usedPct)% \(sys.pressure.label)").monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Memory pressure: \(sys.pressure.label). \(sys.free)% of RAM is available. Click for the breakdown.")
        .accessibilityLabel("Memory pressure \(sys.pressure.label), \(sys.usedPct)%")
        .accessibilityHint("Shows the memory breakdown")
        .popover(isPresented: $shown, arrowEdge: .bottom) { Breakdown(sys: sys) }
    }
}

/// Activity Monitor's memory panel, in one column.
struct Breakdown: View {
    let sys: SysMem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Label { Text("Pressure \(sys.pressure.label)") } icon: { Circle().fill(sys.pressure.color).frame(width: 8, height: 8) }
                Text("\(sys.usedPct)%").gridColumnAlignment(.trailing)
            }
            .help("\(sys.free)% of RAM is available")
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Physical", Int64(ProcessInfo.processInfo.physicalMemory), "The RAM in this Mac")
            row("Used", sys.ram, "App + wired + compressed, as Activity Monitor counts it")
            row("App", sys.app, "Memory that apps and processes use", sub: true)
            row("Wired", sys.wired, "Memory the system keeps in RAM: it cannot be compressed or swapped", sub: true)
            row("Compressed", sys.compressed, "RAM that holds compressed memory", sub: true)
            row("Cached files", sys.cached, "Recently used files and purgeable memory. macOS frees it when apps need RAM")
            row("Swap", sys.swap, "Memory written to disk because RAM was full")
        }
        .font(.caption).monospacedDigit().padding(10)
    }

    func row(_ name: String, _ bytes: Int64, _ why: String, sub: Bool = false) -> some View {
        GridRow {
            Text(name).foregroundStyle(sub ? .secondary : .primary).padding(.leading, sub ? 12 : 0)
            Text(fmt(bytes))
        }
        .help(why)
    }
}
