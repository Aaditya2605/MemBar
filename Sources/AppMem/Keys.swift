import AppKit
import SwiftUI

// Keyboard navigation in the panel: arrows move a selection over the group rows and
// the process lines of open groups. No animation on any key: keys are pressed hundreds
// of times, and each press must show its result at once.

/// One line of the list: a group row (pid nil), or a process line of an open group.
/// By id, not by index: a refresh reorders the rows.
struct RowID: Hashable { var group: String, pid: pid_t? = nil }

/// Up/Down: `by` lines on, stopped at the ends. No selection, or one that is gone:
/// Down starts at the top, Up at the bottom.
func move(_ sel: RowID?, in ids: [RowID], by: Int) -> RowID? {
    guard let sel, let i = ids.firstIndex(of: sel) else { return by > 0 ? ids.first : ids.last }
    return ids[min(max(i + by, 0), ids.count - 1)]
}

/// The selection after a refresh: the same line while it shows; a process line that is
/// gone gives way to its group; a group that is gone clears it.
func kept(_ sel: RowID?, in ids: [RowID]) -> RowID? {
    guard let sel else { return nil }
    return ids.contains(sel) ? sel : ids.contains(RowID(group: sel.group)) ? RowID(group: sel.group) : nil
}

/// A key that types text (a letter, a digit, ":" of a port), not an arrow (Apple's
/// function keys are U+F700 to U+F8FF), Return, Tab or Esc: the list hands it to the search.
func types(_ chars: String) -> Bool {
    !chars.isEmpty && chars.unicodeScalars.allSatisfy { s in
        !s.properties.isWhitespace && !CharacterSet.controlCharacters.contains(s) && !(0xF700...0xF8FF).contains(s.value)
    }
}

/// The row's Stop applies: a leftover or an orphan (stop() acts on both) that Stop can act on.
func canStop(_ g: Group, uid: uid_t = getuid()) -> Bool { (g.leftover || g.orphan) && stoppable(g, uid: uid) }

/// The selection and the open groups, out of the rows so that keys reach them.
final class Nav: ObservableObject {
    @Published var sel: RowID?
    @Published var expanded: Set<String> = []  // group ids
    @Published var all: Set<String> = []  // groups that show all their processes, not the top 10
    var focusList = {}  // the Panel sets it: after a click, keys act on the clicked line

    func click(_ id: RowID) { sel = id; focusList() }
    func toggle(_ group: String) { if expanded.remove(group) == nil { expanded.insert(group) } }
}

extension Panel {
    enum Field { case search, list }

    /// The lines on screen, in order: what Up and Down walk.
    var rowIDs: [RowID] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return shown.flatMap { g in
            let only = hits(g, q), open = only != nil || nav.expanded.contains(g.id)
            let procs = open ? procLines(only ?? g.procs, all: nav.all.contains(g.id)) : []
            return [RowID(group: g.id)] + procs.map { RowID(group: g.id, pid: $0.proc.pid) }
        }
    }

    /// Up/Down, from the list or the search field (as in Spotlight). The list takes the
    /// keys, so ⌘⌫ and ⌘C act on the selection, not on the search text.
    func step(_ by: Int) -> KeyPress.Result {
        nav.sel = move(nav.sel, in: rowIDs, by: by)
        focus = .list
        return .handled
    }

    /// ⌘C on the list: a process line's path; a group's Copy Summary. Through the main menu's
    /// Copy (main.swift), not listKey: the menu takes ⌘C first, also while its Copy is off.
    var copied: String? {
        guard let s = nav.sel, let g = model.groups.first(where: { $0.id == s.group }) else { return nil }
        return s.pid.flatMap { pid in g.procs.first { $0.pid == pid } }?.path ?? summaryText(g)
    }

    /// Keys while the list has focus. A key that types text starts a search with it.
    func listKey(_ k: KeyPress) -> KeyPress.Result {
        let cmd = k.modifiers.contains(.command), s = nav.sel
        let g = s.flatMap { s in model.groups.first { $0.id == s.group } }
        switch k.key {
        case .downArrow, .upArrow: return step(k.key == .downArrow ? 1 : -1)
        case .rightArrow: if let s, s.pid == nil { nav.expanded.insert(s.group) }
        case .leftArrow:  // a process line: to its group; a group: close it
            guard let s else { return .ignored }
            if s.pid != nil { nav.sel = RowID(group: s.group) } else { nav.expanded.remove(s.group) }
        case .return: if let s { nav.sel = RowID(group: s.group); nav.toggle(s.group) }
        // The row's Stop, on the group row only: on a process line it reads as "quit this one".
        // Backspace comes as U+007F, not as .delete (U+0008).
        case "\u{7f}" where cmd, .delete where cmd:
            guard let g, s?.pid == nil, canStop(g) else { return .ignored }
            model.stopGroups([g])
        case "f" where cmd: focus = .search
        default:
            guard k.modifiers.isDisjoint(with: [.command, .option, .control]), types(k.characters) else { return .ignored }
            query += k.characters
            focus = .search
            // Focus selects all of the field's text: the next key would replace it.
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
        }
        return .handled
    }

    /// Esc clears the search first, then closes the popover. Closed here: passed on, the
    /// key only takes the focus away. performClose, so popoverDidClose stops the fast scans.
    func escape() -> KeyPress.Result {
        if query.isEmpty { (NSApp.delegate as? Delegate)?.popover.performClose(nil) } else { query = "" }
        return .handled
    }
}

extension View {
    /// The selected line: the accent color at low opacity, from `lead` points left of the
    /// line, so a process line's highlight starts where its group's does.
    func highlight(_ on: Bool, lead: CGFloat = 0) -> some View {
        background {
            if on {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
                    .padding(.leading, -6 - lead).padding(.trailing, -6).padding(.vertical, -1)
            }
        }
    }

    /// Keeps the selection in view as keys move it. No animation: keys repeat fast. A group
    /// by its ForEach id: the lazy stack finds that one also for a row it has not built yet.
    func scrolls(to sel: RowID?) -> some View {
        ScrollViewReader { proxy in
            onChange(of: sel) { _, s in if let s { s.pid == nil ? proxy.scrollTo(s.group) : proxy.scrollTo(s) } }
        }
    }
}
