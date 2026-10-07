import AppKit
import SwiftUI

// Memory pressure and Activity Monitor's memory breakdown. "RAM used" alone says
// little: macOS fills free RAM with cache on purpose. Pressure is what macOS acts
// on: it compresses memory, then swaps, then asks you to quit apps.

/// kern.memorystatus_vm_pressure_level. The kernel gives dispatch levels: 1, 2, 4.
enum Pressure: Int32 {
    case normal = 1, warning = 2, critical = 4
    var label: String { switch self { case .normal: "Normal"; case .warning: "Warning"; case .critical: "Critical" } }
    var color: Color { switch self { case .normal: .green; case .warning: .orange; case .critical: .red } }
    // Orange, not Activity Monitor's yellow: as the menu bar dot and graph, where yellow means leftovers.
    // ponytail: leftovers are orange in the list and yellow in the menu bar; one color would hide Warning there.
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
    let desc = ["MemBar", level.map { "memory pressure \($0.lowercased())" }, waste > 0 ? "leftovers found" : nil]
    let tip = [level.map { "Memory pressure: \($0)" }, waste > 0 ? "Leftovers use \(fmt(waste))" : nil].compactMap { $0 }
    return (dot, desc.compactMap { $0 }.joined(separator: ", "), tip.isEmpty ? "MemBar: no leftovers" : tip.joined(separator: "\n"))
}

/// Header row: where the RAM goes (RAMBar.swift), then the pressure with a dot colored as the
/// menu bar's. One line for both: a second bar would weigh the header down. A dot, not
/// colored words: green and orange text is too faint on the light panel.
/// A click shows the breakdown.
struct PressureBar: View {
    let sys: SysMem
    let groups: [Group], slots: [String: Int]  // the bar's parts
    @State private var shown = false

    var body: some View {
        let parts = segments(groups: groups, sys: sys, physical: Int64(ProcessInfo.processInfo.physicalMemory), slots: slots)
        let note = scaleNote(groups, sys: sys)
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                RAMBar(parts: parts, note: note)
                // Here, not on the button: an outer .help hides the bar's own.
                HStack(spacing: 4) {
                    Circle().fill(sys.pressure.color).frame(width: 6, height: 6)
                    Text("Pressure \(sys.usedPct)% \(sys.pressure.label)").monospacedDigit()
                }
                .help("Memory pressure: \(sys.pressure.label). \(sys.free)% of RAM is available. Click for the breakdown.")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ramLabel(parts, note: note))
        .accessibilityValue("Memory pressure \(sys.pressure.label), \(sys.usedPct)%")
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
