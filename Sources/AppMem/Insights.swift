import SwiftUI

// One quiet line at the top of the list: the one most useful thing to do now, with a button
// that does it or shows it, and an ✕ that hides it for 24 h. From what the Model already has
// (groups, SysMem, History, Usage's times): no scan, no read of its own. UserDefaults key:
// "insightsHidden" (JSON, insight id → when its ✕ was clicked).

struct Insight: Equatable {
    enum Action: Equatable { case search(String), select(String) }  // select: a group id
    let id: String  // what ✕ hides: the kind, plus the group for one about a group
    let symbol: String, text: String, short: String  // short: where text does not fit in 400 pt
    let help: String, button: String, action: Action
}

/// The insight to show now: the first of these that holds and was not hidden in the last 24 h.
/// Not leftovers: the header shows their total and Stop All whenever there are any.
/// 1. Idle apps (Usage's rule: open, 500 MB or more, not frontmost for 2 h) of 1 GB or more together:
///    the "idle" filter.
/// 2. Swap of 25% of the RAM or more, at Warning or Critical pressure: the largest group that has a
///    process of this user and is not macOS (kernel_task and root daemons cannot be quit).
/// 3. A growing group (History's rule), not an ignored one, not macOS (nothing to quit, and Settings can
///    hide its row) and with a process of this user (as 2): the one that rose the most. By group: a hidden
///    one does not hide another app's growth.
/// 4. Booted simulators (launchd_sim runs) and emulators that are not leftovers, as their app is
///    open, of 1 GB or more together: the largest one, open, so its devices show with Shut Down.
/// nil: nothing is worth a line.
/// ponytail: no hysteresis, so a total at a threshold (or growth that flaps) can make the line come
/// and go between scans; keep the last insight for a few minutes if that shows.
func insight(groups: [Group], sys: SysMem, history: History, now: Date, hidden: [String: Date],
             lastFront: (String) -> Date? = Usage.lastFront, physical: Int64 = Int64(ProcessInfo.processInfo.physicalMemory),
             uid: uid_t = getuid()) -> Insight? {
    func shows(_ id: String) -> Bool { hidden[id].map { now.timeIntervalSince($0) >= 86400 } ?? true }
    func sum(_ gs: [Group]) -> Int64 { gs.reduce(0) { $0 + $1.mem } }
    func list(_ gs: [Group]) -> String { gs.sorted { $0.mem > $1.mem }.map { "\($0.name) \(fmt($0.mem))" }.joined(separator: ", ") }

    let idle = groups.filter { idleTime($0, lastFront: lastFront($0.name), now: now) != nil }
    if shows("idle"), sum(idle) >= 1 << 30 {
        let t = "\(idle.count) idle app\(idle.count == 1 ? " uses" : "s use") \(short(sum(idle)))"
        return Insight(id: "idle", symbol: "moon.zzz", text: t, short: t,
                       help: "Open, 500 MB or more, not used for 2 hours or more: \(list(idle))", button: "Show", action: .search("idle"))
    }
    if shows("swap"), sys.swap * 4 >= physical, sys.pressure != .normal,
       let big = groups.filter({ g in g.name != "macOS" && g.procs.contains { $0.uid == uid } }).max(by: { $0.mem < $1.mem }) {
        return Insight(id: "swap", symbol: "internaldrive",
                       text: "Swap is \(short(sys.swap)). The largest app is \(big.name) (\(short(big.mem)))",
                       short: "Swap \(short(sys.swap)). Largest: \(big.name) (\(short(big.mem)))",
                       help: "Memory pressure is \(sys.pressure.label) and swap is \(sys.swap * 100 / max(physical, 1))% of the RAM: macOS writes memory to disk, and apps slow down. Quitting the largest app frees the most.",
                       button: "Show", action: .select(big.id))
    }
    let grow = groups.filter { g in !g.ignored && g.name != "macOS" && g.procs.contains { $0.uid == uid } && shows("growing|\(g.id)") }
        .compactMap { g in isGrowing(history.points(g.id)).map { (g, $0) } }.max { $0.1 < $1.1 }?.0
    if let g = grow, let t = growthText(history.points(g.id)) {
        return Insight(id: "growing|\(g.id)", symbol: "arrow.up.right", text: "\(g.name) keeps growing: \(t)", short: "\(g.name): \(t)",
                       help: "Its memory rose steadily, now \(fmt(g.mem)): a leak, or work that piles up. A restart frees it.",
                       button: "Show", action: .select(g.id))
    }
    let sims = groups.filter { g in !g.leftover && !g.ignored && (g.isEmulator || g.isSimulator && g.procs.contains { $0.name == "launchd_sim" }) }
    if shows("sims"), sum(sims) >= 1 << 30, let big = sims.max(by: { $0.mem < $1.mem }) {
        let t = sims.allSatisfy(\.isEmulator) ? "The Android emulator uses \(short(sum(sims)))" : "Booted simulators use \(short(sum(sims)))"
        return Insight(id: "sims", symbol: "iphone", text: t, short: t,
                       help: "Running while Simulator or Android Studio is open: \(list(sims)). Shut down the devices you do not use.",
                       button: "Show", action: .select(big.id))
    }
    return nil
}

/// `hidden` with `id` hidden from `now`, and without what is 24 h old: the list stays small.
func hiding(_ id: String, in hidden: [String: Date], now: Date) -> [String: Date] {
    hidden.filter { now.timeIntervalSince($0.value) < 86400 }.merging([id: now]) { $1 }
}

/// Below the first-run card, above the rows. No motion but a short fade as it comes, goes or
/// changes (none with Reduce Motion); a new number for the same insight just shows.
struct InsightLine: View {
    @ObservedObject var model: Model
    let act: (Insight) -> Void
    @AppStorage("insightsHidden") private var hiddenJSON = Data()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hidden = (try? JSONDecoder().decode([String: Date].self, from: hiddenJSON)) ?? [:]
        let i = insight(groups: model.groups, sys: model.sys, history: model.history, now: Date(), hidden: hidden)
        ZStack {  // a ZStack: an old and a new insight fade over each other, the list does not jump twice
            if let i {
                let hint = switch i.action {
                case .search: "Shows only these in the list"
                case .select: "Selects it in the list"
                }
                // Text in the name column, the symbol in the icon column, the ✕ at the memory column's edge.
                HStack(spacing: 6) {
                    Image(systemName: i.symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        Text(i.text)
                        Text(i.short).truncationMode(.middle)
                    }
                    .lineLimit(1).foregroundStyle(.secondary).help(i.help)
                    Spacer(minLength: 4)
                    Button { act(i) } label: { Text(i.button).padding(.vertical, 3).contentShape(Rectangle()) }
                        .buttonStyle(.link).foregroundStyle(.tint).fixedSize()  // as ProcList's "Show all": the line's one action
                        .help(hint).accessibilityHint(hint)
                    Button {
                        hiddenJSON = (try? JSONEncoder().encode(hiding(i.id, in: hidden, now: Date()))) ?? Data()
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).padding(.horizontal, 3).padding(.vertical, 3).contentShape(Rectangle()) }
                        .buttonStyle(.borderless)
                        .help("Hide this for 24 hours")
                        .accessibilityLabel("Hide for 24 hours")
                }
                .font(.caption).monospacedDigit()
                .padding(.leading, 26).padding(.trailing, 7).padding(.top, 4)
                .id(i.id)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: i?.id)
    }
}

extension Panel {
    /// The insight's button. Show clears a search first: it could hide the group.
    func act(_ i: Insight) {
        switch i.action {
        case .search(let token): query = token + " "; focus = .list  // as the filter menu: a key typed next is text, not more of the word
        case .select(let id):
            query = ""
            nav.expanded.insert(id)  // its sparkline, process list or device lines tell the rest
            nav.click(RowID(group: id))  // selects it
            nav.shows += 1  // the list scrolls to it (scrolls(to:)), also when it was selected already
        }
    }
}

/// Asserts for insight(), run by selfTest. Made-up groups only.
func insightTest() {
    let mb: Int64 = 1 << 20, gb: Int64 = 1 << 30, h: TimeInterval = 3600, t0 = Date(timeIntervalSince1970: 1_000_000)
    func g(_ name: String, _ m: Int64, isApp: Bool = true, leftover: Bool = false, uid: uid_t = 501, path: String = "/x") -> Group {
        Group(name: name, isApp: isApp, procs: [Proc(pid: 9, ppid: 1, uid: uid, path: path, mem: m * mb)], leftover: leftover)
    }
    func rise(_ by: [String: (from: Int64, step: Int64)]) -> History {  // 30 min, one sample each 15 s, `step` MB more each
        History(samples: (0...120).map { i in Sample(at: t0 - 1800 + Double(i) * 15, ram: 0, groups: by.mapValues { ($0.from + Int64(i) * $0.step) * mb }) })
    }
    let sim = g("iOS Simulator", 1100, isApp: false, path: "launchd_sim")
    // Each candidate holds: two idle apps (1.2 GB), swap at 25% of 16 GB at Warning, Claude, Slack and macOS growing, a booted simulator.
    let all = [g("Cursor", 600, leftover: true), g("Slack", 700), g("Notion", 500), g("Claude", 5000), sim,
               g("macOS", 6000, isApp: false), g("kernel_task", 7000, isApp: false, uid: 0)]  // larger, but nothing to quit
    let warn = SysMem(swap: 4 * gb, level: 2), grows = rise(["Claude|true": (1000, 5), "Slack|true": (700, 3), "macOS|false": (3000, 10)])  // +600, +360, +1200 MB
    let last: [String: Date] = ["Slack": t0 - 3 * h, "Notion": t0 - 3 * h, "Claude": t0]
    func run(_ gs: [Group] = all, _ sys: SysMem = warn, _ history: History = grows, hidden: [String] = [], ago: TimeInterval = 60) -> Insight? {  // `hidden`: ✕ clicked `ago` seconds before
        insight(groups: gs, sys: sys, history: history, now: t0, hidden: Dictionary(uniqueKeysWithValues: hidden.map { ($0, t0 - ago) }),
                lastFront: { last[$0] }, physical: 16 * gb, uid: 501)
    }

    // Priority order, each one hidden in turn; then none.
    let i = run()!  // not the 600 MB leftover: the header has its total and Stop All
    precondition(i.id == "idle" && i.text == "2 idle apps use 1.2 GB" && i.action == .search("idle") && i.help.hasSuffix(": Slack 700 MB, Notion 500 MB"))
    let s = run(hidden: ["idle"])!
    precondition(s.id == "swap" && s.text == "Swap is 4.0 GB. The largest app is Claude (4.9 GB)" && s.action == .select("Claude|true"))
    precondition(s.short == "Swap 4.0 GB. Largest: Claude (4.9 GB)" && s.help.hasPrefix("Memory pressure is Warning and swap is 25% of the RAM"))
    let c = run(hidden: ["idle", "swap"])!
    precondition(c.id == "growing|Claude|true" && c.text == "Claude keeps growing: +600 MB in 30 min" && c.short == "Claude: +600 MB in 30 min" && c.action == .select("Claude|true"))  // not macOS, which grew more
    let sl = run(hidden: ["idle", "swap", "growing|Claude|true"])!  // by group: Slack's growth still shows
    precondition(sl.id == "growing|Slack|true" && sl.text == "Slack keeps growing: +360 MB in 30 min")
    let b = run(hidden: ["idle", "swap", "growing|Claude|true", "growing|Slack|true"])!
    precondition(b.id == "sims" && b.text == "Booted simulators use 1.1 GB" && b.action == .select("iOS Simulator|false"))
    precondition(run(hidden: ["idle", "swap", "growing|Claude|true", "growing|Slack|true", "sims"]) == nil)
    precondition(run([], SysMem(), History()) == nil && run([g("A", 9000)], SysMem(), History()) == nil)  // a big app alone: nothing to say

    // Thresholds, one candidate at a time.
    let none = SysMem(), flat = History()
    precondition(run([g("C", 5000, leftover: true)], none, flat) == nil)  // a leftover alone: no line, the header has it
    precondition(run([g("Slack", 512), g("Notion", 511)], none, flat) == nil && run([g("Slack", 512), g("Notion", 512)], none, flat)?.text == "2 idle apps use 1.0 GB")
    precondition(run([g("Slack", 1024)], none, flat)?.text == "1 idle app uses 1.0 GB" && run([g("Slack", 2000), g("Notion", 499)], none, flat)?.text == "1 idle app uses 2.0 GB")
    let claude = [g("Claude", 5000)]
    precondition(run(claude, SysMem(swap: 4 * gb - 1, level: 4), flat) == nil && run(claude, SysMem(swap: 8 * gb), flat) == nil)  // under 25%; Normal
    precondition(run(claude, SysMem(swap: 4 * gb, level: 4), flat)?.id == "swap" && run([g("macOS", 6000, isApp: false)], warn, flat) == nil)
    precondition(run(claude, none, rise(["Claude|true": (4000, 2)])) == nil)  // +240 MB: not growing
    var ignored = g("Claude", 5000)
    ignored.ignored = true
    precondition(run([ignored], none, grows) == nil)  // never flagged: it does not grow out loud either
    precondition(run([g("kernel_task", 7000, isApp: false, uid: 0)], none, rise(["kernel_task|false": (3000, 10)])) == nil)  // no Restart for root
    precondition(run([g("iOS Simulator", 1023, isApp: false, path: "launchd_sim")], none, flat) == nil)
    precondition(run([g("iOS Simulator", 4000, isApp: false, path: "/CoreSimulatorService")], none, flat) == nil)  // no device booted
    precondition(run([g("iOS Simulator", 4000, isApp: false, leftover: true, path: "launchd_sim")], none, flat) == nil)  // a leftover: Stop is on its row
    precondition(run([g("Android Emulator", 2048, path: "/Users/a/Library/Android/sdk/emulator/emulator")], none, flat)?.text == "The Android emulator uses 2.0 GB")

    // Hidden for 24 h, by id; hiding() keeps only the last 24 h.
    precondition(run(hidden: ["idle"], ago: 86399)?.id == "swap" && run(hidden: ["idle"], ago: 86400)?.id == "idle")
    let kept = hiding("idle", in: ["swap": t0 - 86400, "sims": t0 - 86399, "idle": t0 - 5], now: t0)
    precondition(kept == ["sims": t0 - 86399, "idle": t0])
}
