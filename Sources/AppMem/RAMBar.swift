import AppKit
import SwiftUI

// The header's RAM bar: where physical memory goes now. The largest groups each get a color
// (a dot on their rows too), then the other groups, wired, compressed, cached and free. It is
// the pressure bar too (PressureBar): one calm line, not a second bar under it.

/// Groups with a color of their own. More reads as noise in a 400 pt bar, and 4 is as many as
/// stay apart for color-blind eyes too, each pair: a row's dot is matched to any part of the bar.
let ramSlots = 4

/// Each slot's color, light and dark: every pair stays apart under protanopia, deuteranopia and
/// normal vision, in both modes (dataviz validator, all pairs). Not green, yellow, orange or red:
/// here they mean pressure, leftovers and growth.
private let slotColors = [(0x355fa4, 0x5991ed), (0x34c0aa, 0x00aa95), (0x8f7ce3, 0x6647c0), (0x88296f, 0xa85c90)].map { light, dark in
    func rgb(_ v: Int) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) })
}

/// A part's color: the slots, then grays.
func ramColor(_ i: Int) -> Color {
    switch i - ramSlots {
    case ..<0: slotColors[i]
    case 0: .primary.opacity(0.25)  // other apps
    case 1: .primary.opacity(0.5)  // wired
    case 2: .primary.opacity(0.35)  // compressed
    default: Color(nsColor: .quaternaryLabelColor)  // cached and free: the empty bar's gray
    }
}

/// The largest groups' slots, by group id. A group keeps its slot while it stays among the 4
/// largest, so its color and place in the bar do not swap when two sizes cross; a slot that a
/// group leaves goes to the largest newcomer. `kept`: the last scan's (Model.slots).
func keepSlots(_ groups: [Group], kept: [String: Int]) -> [String: Int] {
    let top = groups.filter { $0.mem > 0 }.sorted { $0.mem > $1.mem }.prefix(ramSlots).map(\.id)
    var slots = kept.filter { top.contains($0.key) }
    for id in top where slots[id] == nil {
        if let free = (0..<ramSlots).first(where: { !slots.values.contains($0) }) { slots[id] = free }
    }
    return slots
}

/// The bar's parts, as bytes of physical RAM: the slotted groups in slot order, then "Other
/// apps", wired, compressed, and the rest (cached and free). Footprints count compressed memory
/// too, so they can add up to more than App memory, even more than the RAM: then the app part
/// is scaled down to App memory. Under it (other users' processes count 0 until top runs),
/// "Other apps" takes the rest. Zero parts are left out.
func segments(groups: [Group], sys: SysMem, physical: Int64, slots: [String: Int]? = nil) -> [(name: String, bytes: Int64, colorIndex: Int)] {
    let slots = slots ?? keepSlots(groups, kept: [:])
    let total = groups.reduce(0) { $0 + $1.mem }, scale = total > sys.app ? Double(sys.app) / Double(total) : 1
    let top = groups.compactMap { g in slots[g.id].map { (name: g.name, bytes: Int64(Double(g.mem) * scale), colorIndex: $0) } }
        .sorted { $0.colorIndex < $1.colorIndex }
    let rest = [("Other apps", sys.app - top.reduce(0) { $0 + $1.bytes }), ("Wired", sys.wired), ("Compressed", sys.compressed),
                ("Cached and free", physical - sys.ram)].enumerated().map { (name: $1.0, bytes: $1.1, colorIndex: ramSlots + $0) }
    return (top + rest).filter { $0.bytes > 0 }
}

/// The app parts' tooltip line when they are scaled; nil when not.
func scaleNote(_ groups: [Group], sys: SysMem) -> String? {
    let total = groups.reduce(0) { $0 + $1.mem }
    return total > sys.app ? "Apps are scaled to fit App memory, \(fmt(sys.app)): their footprints, as on the rows, count compressed memory too and add up to \(fmt(total))." : nil
}

/// A part's tooltip: its name and size, what it is, and for the app parts the scale note.
func partHelp(_ p: (name: String, bytes: Int64, colorIndex: Int), note: String?) -> String {
    let what = switch p.colorIndex - ramSlots {
    case ..<0: ""
    case 0: ": the other groups"
    case 1: ": memory the system keeps in RAM; it cannot be compressed or swapped"
    case 2: ": RAM that holds compressed memory"
    default: ": cached files and free RAM; macOS gives the cache to apps when they need it"
    }
    return "\(p.name) \(fmt(p.bytes))\(what)" + (p.colorIndex <= ramSlots ? note.map { "\n" + $0 } ?? "" : "")
}

/// VoiceOver: "RAM: Claude 3.10 GB, macOS 3.00 GB, …, Cached and free 4.20 GB".
func ramLabel(_ parts: [(name: String, bytes: Int64, colorIndex: Int)]) -> String {
    "RAM: " + parts.map { "\($0.name) \(fmt($0.bytes))" }.joined(separator: ", ")
}

/// The thin stacked bar. No animation: it changes a little at each scan, and a jump is calmer
/// than parts that slide every 3 s.
struct RAMBar: View {
    let parts: [(name: String, bytes: Int64, colorIndex: Int)]
    let note: String?

    var body: some View {
        let total = CGFloat(max(1, parts.reduce(0) { $0 + $1.bytes }))
        GeometryReader { geo in
            let room = geo.size.width - CGFloat(max(0, parts.count - 1))  // 1 pt gaps: grays side by side stay apart
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    ramColor(parts[i].colorIndex)
                        .frame(width: max(0, room * CGFloat(parts[i].bytes) / total), height: 6)
                        .frame(maxHeight: .infinity)  // the tooltip's area is the line's height, not only the 6 pt bar
                        .contentShape(Rectangle())
                        .help(partHelp(parts[i], note: note))
                }
            }
            .mask { Capsule().frame(height: 6) }
        }
        .background { Capsule().fill(ramColor(ramSlots + 3)).frame(height: 6) }  // no parts yet: the empty bar
        .frame(height: 12)
    }
}

extension View {
    /// A row's memory: a dot in the color of its part of the bar, just before the number. Drawn
    /// outside the text, so the column does not move; at 12.34 GB it sits in the gap before it.
    func slotDot(_ slot: Int?) -> some View {
        overlay(alignment: .leading) { if let slot { Circle().fill(ramColor(slot)).frame(width: 5, height: 5).offset(x: -8) } }
    }
}
