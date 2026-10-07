import AppKit
import SwiftUI

// What the badges mean: one look for each row badge (Badge), the legend that shows the same
// views with their meaning (gear menu > What the Badges Mean), and the card on the panel's
// first open. UserDefaults key: "introSeen" (Bool).

/// Each row badge's look, in one place: the rows draw these views and the legend shows the
/// same ones, so the two always match.
enum Badge {
    static var leftover: some View { Text("leftover").flag(.leftover) }
    /// Orange only when Settings counts orphans as leftovers.
    static func orphan(leftover: Bool) -> some View { Text("orphan").flag(leftover ? .leftover : .secondary) }
    static var respawns: some View { Image(systemName: "arrow.triangle.2.circlepath").flag(.leftover).accessibilityLabel("Respawns") }
    static var paused: some View { Text("paused").flag() }
    static var growing: some View { Image(systemName: "arrow.up.right").flag(.red).accessibilityLabel("Growing") }
    static var quitIdle: some View { Image(systemName: "timer").flag().accessibilityLabel("Quits when idle") }
    /// Slashed when its alert cannot come.
    static func bell(on: Bool) -> some View { Image(systemName: on ? "bell" : "bell.slash").flag() }
    /// Restart When Above, Pause When in Background: ruleNotes' symbols.
    static func rule(_ symbol: String) -> some View { Image(systemName: symbol).flag() }
    /// "for 2 d", "idle 3 h": a note, quieter than a flag.
    static func usage(_ s: String) -> some View { Text(s).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
}

/// Gear menu > What the Badges Mean: a popover over the panel with each badge and its meaning,
/// in CONTEXT.md's words. The real views and labels: Badge, PortChip, changeLabel, the menu bar's glyph.
struct BadgeLegend: View {
    var body: some View {
        let g = Group(name: "", isApp: true, procs: [Proc(pid: 0, ppid: 0, uid: 0, path: "", mem: 1000 << 20)])
        let new = changeLabel(g, Mark.Delta(new: [g.id]))!, grew = changeLabel(g, Mark.Delta(change: [g.id: 320 << 20]))!
        let rules = ruleNotes(restart: restartChoices[0], pause: true, paused: false), pausedNow = ruleNotes(restart: nil, pause: true, paused: true)[0].symbol
        VStack(alignment: .leading, spacing: 6) {
            Text("What the Badges Mean").font(.headline).accessibilityAddTraits(.isHeader)
            header("In the list")
            line(Badge.leftover, "Its app is not open, or its program file is deleted, but it still runs.")
            line(Badge.orphan(leftover: false), orphanHelp + ".")
            line(Badge.respawns, "It came back within 60 s after Stop.")
            line(Badge.paused, "Its processes are paused: they do not run.")
            line(Badge.growing, "Memory rose by 25% and 300 MB or more, steadily.")
            line(Badge.usage("idle 3 h"), "Open, 500 MB or more, not frontmost for 2 h or more.")
            line(Badge.usage("for 2 d"), "How long a leftover or orphan has run.")
            line(change(new), new.help + ".")
            line(change(grew), "The change since the mark. Green: it shrank.")
            line(HStack(spacing: 4) { Badge.bell(on: true); Badge.bell(on: false) }.accessibilityElement(children: .ignore).accessibilityLabel("Bell"),
                 "Alerts above its limit. Slashed: the alert is off.")
            line(Badge.quitIdle, "Quit When Idle: MemBar asks it to quit when unused.")
            line(Badge.rule(rules[0].symbol).accessibilityLabel("Restart"), "Restart When Above: it restarts above its limit when unused.")
            line(HStack(spacing: 4) { Badge.rule(rules[1].symbol); Badge.rule(pausedNow) }.accessibilityElement(children: .ignore).accessibilityLabel("Pause"),
                 "Pause When in Background: paused after 5 min in the background. Filled: paused now, its jobs still run.")
            line(PortChip(ports: [3000]), "The TCP ports it listens on (a dev server).")
            line(Text(fmt(1 << 30)).font(.caption).monospacedDigit().slotDot(0).padding(.leading, 8), "Its color in the RAM bar: one of the \(ramSlots) largest.")
            header("In the menu bar")
            line(Image(nsImage: Delegate.glyphs[4]).accessibilityLabel("Blocks"), "RAM used. Each lit block is about a sixth of the RAM.", center: true)
            Text("Point to a badge in the list for its details.").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(12)
        .frame(width: 360)
    }

    func header(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4).accessibilityAddTraits(.isHeader)
    }

    /// A fixed badge column, so the meanings line up; one VoiceOver element per line. `center`: an
    /// image with no text baseline (the menu bar icon), else it sits above the line.
    func line(_ badge: some View, _ meaning: String, center: Bool = false) -> some View {
        HStack(alignment: center ? .center : .firstTextBaseline, spacing: 8) {
            badge.frame(width: 64, alignment: .leading)
            Text(meaning).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// As ChangeText draws it.
    func change(_ l: (text: String, color: Color, help: String)) -> some View {
        Text(l.text).font(.caption).monospacedDigit().foregroundStyle(l.color)
    }
}

/// The panel's first open: one sentence on leftovers and Stop at the top of the list. Gone for
/// good after "Got it" or when the panel closes. Snapshots show it only with FIRSTRUN=1.
struct IntroCard: View {
    @AppStorage("introSeen") private var seen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !seen {
            HStack(spacing: 8) {
                Text("**Leftovers** are processes that still run when their app is not open; **Stop** ends them.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Got it") { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { seen = true } }
                    .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.top, 6)
            .transition(.opacity)
            .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { n in
                if n.object as? NSPopover === (NSApp.delegate as? Delegate)?.popover { seen = true }
            }
        }
    }
}

#if DEBUG
/// `LEGEND=1 MemBar --snapshot out.png`: the badge legend instead of the panel.
func snapshotLegend(to path: String) {
    snapshot(to: path, size: NSSize(width: 360, height: 520)) { _ in BadgeLegend().frame(maxHeight: .infinity, alignment: .top) }
}
#endif
