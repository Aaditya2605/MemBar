import AppKit
import SwiftUI

// Mark: the memory of each group at one moment, to see what changed since then (what a
// build, a browser tab or an agent run took). One mark at a time; UserDefaults "mark"
// keeps it across restarts.

struct Mark: Codable {
    let at: Date
    let ram: Int64
    let groups: [String: Int64]  // group id → memory, only groups of 10 MB or more: small to store

    /// `change`: groups in the mark that run now, memory now minus then. `new`: groups of
    /// 10 MB or more that are not in it. `gone`: groups in it that do not run now, memory then.
    struct Delta {
        var change: [String: Int64] = [:], new: Set<String> = [], gone: [String: Int64] = [:]

        /// Sort by change: a new group counts with all its memory; a small one not in the mark
        /// with 0, as it most likely ran then too, under 10 MB.
        func key(_ g: Group) -> Int64 { change[g.id] ?? (new.contains(g.id) ? g.mem : 0) }
    }
}

extension Mark {
    init(_ groups: [Group], ram: Int64, at: Date = Date()) {
        self.init(at: at, ram: ram, groups: Dictionary(uniqueKeysWithValues: groups.filter { $0.mem >= 10 << 20 }.map { ($0.id, $0.mem) }))
    }

    static func saved() -> Mark? { UserDefaults.standard.data(forKey: "mark").flatMap { try? JSONDecoder().decode(Mark.self, from: $0) } }
}

/// ponytail: a group under 10 MB at the mark is not in it, so one that grew past 10 MB
/// since then reads as new; store every group if that misleads.
func delta(mark: Mark, groups: [Group]) -> Mark.Delta {
    var d = Mark.Delta(gone: mark.groups)
    for g in groups {
        d.gone[g.id] = nil
        if let then = mark.groups[g.id] { d.change[g.id] = g.mem - then } else if g.mem >= 10 << 20 { d.new.insert(g.id) }
    }
    return d
}

/// "+320 MB", "−1.1 GB" (a true minus sign), "0 MB". One decimal in GB: a change is a rough number.
func fmtChange(_ bytes: Int64) -> String {
    let mb = Double(bytes.magnitude) / 1048576
    let s = mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    return (s == "0 MB" ? "" : bytes > 0 ? "+" : "−") + s
}

/// A row's change: "new", "+320 MB" in red (it grew 50 MB or more), "−1.1 GB" in green
/// (it shrank 50 MB or more), nil for less: a few MB up and down is noise.
func changeLabel(_ g: Group, _ d: Mark.Delta) -> (text: String, color: Color, help: String)? {
    if d.new.contains(g.id) { return ("new", .secondary, "New since the mark (or under 10 MB then)") }
    guard let c = d.change[g.id], abs(c) >= 50 << 20 else { return nil }
    return (fmtChange(c), c > 0 ? .red : .green, "\(fmtChange(c)) since the mark: \(fmt(g.mem - c)) then")
}

/// The header line: "Since mark (12 min): RAM +1.2 GB · 3 new · 2 gone".
func markSummary(_ m: Mark, ram: Int64, _ d: Mark.Delta, now: Date = Date()) -> String {
    (["Since mark (\(ago(now.timeIntervalSince(m.at)))): RAM \(fmtChange(ram - m.ram))"]
        + (d.new.isEmpty ? [] : ["\(d.new.count) new"]) + (d.gone.isEmpty ? [] : ["\(d.gone.count) gone"])).joined(separator: " · ")
}

/// The header line's help: when, and the groups that are gone with their memory then, largest first.
func markHelp(_ m: Mark, _ d: Mark.Delta) -> String {
    let when = m.at.formatted(date: Calendar.current.isDateInToday(m.at) ? .omitted : .abbreviated, time: .shortened)
    let gone = d.gone.sorted { $0.value > $1.value }.map { id, mem in
        "\(id[..<(id.lastIndex(of: "|") ?? id.endIndex)]) \(fmt(mem))"  // id = "name|isApp"
    }
    return "Marked at \(when), RAM \(fmt(m.ram))"
        + (gone.isEmpty ? "" : "\nGone since the mark: " + gone.prefix(10).joined(separator: ", ") + (gone.count > 10 ? " and \(gone.count - 10) more" : ""))
}

extension Model {
    /// The header's flag and Settings > Mark Memory Now. Again: the old mark is replaced.
    func markNow() { if !groups.isEmpty { setMark(Mark(groups, ram: sys.ram)) } }

    func setMark(_ m: Mark?) {
        mark = m
        UserDefaults.standard.set(m.flatMap { try? JSONEncoder().encode($0) }, forKey: "mark")
    }
}

/// Header button; filled while a mark exists.
struct MarkButton: View {
    @ObservedObject var model: Model

    var body: some View {
        Button { model.markNow() } label: { Image(systemName: model.mark == nil ? "flag" : "flag.fill") }
            .buttonStyle(.borderless)
            .help(model.mark == nil ? "Mark memory now, to see what changes" : "Mark memory again: changes count from now")
            .accessibilityLabel("Mark memory")
    }
}

/// Header line while a mark exists; ✕ clears it.
struct MarkLine: View {
    @ObservedObject var model: Model
    @AppStorage("sort") private var sort = Sort.memory

    var body: some View {
        if let m = model.mark {
            let d = delta(mark: m, groups: model.groups)
            HStack(spacing: 4) {
                Text(markSummary(m, ram: model.sys.ram, d)).lineLimit(1).help(markHelp(m, d))
                Button {
                    model.setMark(nil)
                    if sort == .change { sort = .memory }  // its column goes with the mark
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).padding(.horizontal, 3).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .help("Clear the mark")
                    .accessibilityLabel("Clear mark")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A row's change, drawn over the free space before the process count: it never squeezes
/// the name or moves a column, and where it does not fit it is not shown.
struct ChangeText: View {
    let label: (text: String, color: Color, help: String)?
    let procs: Int

    var body: some View {
        if let label {
            // The header's "Change" ends where "Procs" starts; here the count is narrower than "Procs".
            let pad = max(0, captionWidth("Procs") - captionWidth(String(procs)))
            ViewThatFits(in: .horizontal) {
                Text(label.text).foregroundStyle(label.color).help(label.help).padding(.trailing, pad)
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.caption).monospacedDigit()
        }
    }
}

/// Width in SwiftUI's .caption (the caption1 text style), to line up with text in another view.
private func captionWidth(_ s: String) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
}

#if DEBUG
extension Mark {
    /// `MARK=1 AppMem --snapshot ...`: a mark 12 min old around the live numbers. The
    /// largest group grew 400 MB, the second shrank 1.2 GB, the third is new, two are gone.
    static func demo(_ groups: [Group], sys: SysMem) -> Mark {
        let big = groups.filter { $0.mem >= 10 << 20 }.sorted { $0.mem > $1.mem }
        var m = Dictionary(uniqueKeysWithValues: big.map { ($0.id, $0.mem) })
        if big.count > 2 { m[big[0].id]! -= 400 << 20; m[big[1].id]! += 1200 << 20; m[big[2].id] = nil }
        m["Cursor|true"] = 2100 << 20
        m["node|false"] = 300 << 20
        return Mark(at: Date() - 12 * 60, ram: sys.ram - (1200 << 20), groups: m)
    }
}
#endif
