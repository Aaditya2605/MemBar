import AppKit
import SwiftUI

// The menu bar item beyond the panel: the text next to the icon (Settings > Menu Bar
// Shows, UserDefaults "menuBarShows"), the right-click menu, Copy Report, and the
// appmem:// URLs. No URL stops anything: any web page can open one.

enum MenuBarShows: String, CaseIterable {
    case icon, leftovers, ram, pressure, graph
    var title: String {
        switch self { case .icon: "Icon Only"; case .leftovers: "Leftover Size"; case .ram: "RAM Used"; case .pressure: "Memory Pressure"; case .graph: "RAM Graph" }
    }
}

/// "3.2 GB", "850 MB": one decimal, for the little room in the menu bar. Never "1000 MB".
func short(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1048576
    return mb >= 999.5 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

/// Figure spaces (each as wide as a digit) in front of `s`, up to `digits` digits. With
/// monospaced digits the item keeps its width from scan to scan, so the items to its left
/// do not move; only MB to GB changes it, by 2 pt.
func padDigits(_ s: String, _ digits: Int) -> String {
    String(repeating: "\u{2007}", count: max(0, digits - s.prefix { $0.isNumber || $0 == "." }.filter(\.isNumber).count)) + s
}

/// The text next to the icon; "" = the icon only. Leftover Size only while there are leftovers.
func menuBarText(_ shows: MenuBarShows, sys: SysMem, waste: Int64) -> String {
    switch shows {
    case .icon, .graph: ""  // the graph is in the image (MenuGraph.swift)
    case .leftovers: waste > 0 ? padDigits(short(waste), 3) : ""
    case .ram: padDigits(short(sys.ram), 3)
    case .pressure: padDigits("\(sys.usedPct)%", 2)
    }
}

/// The right-click menu's info line.
func infoLine(_ sys: SysMem, physical: Int64) -> String { "RAM \(short(sys.ram)) of \(physical >> 30) GB · Pressure \(sys.usedPct)%" }

/// Copy Report: Markdown to paste in a chat, an issue or a note. The 15 largest groups.
/// `flags`: the ones the group alone does not tell (growing, idle).
func report(groups: [Group], sys: SysMem, date: Date, physical: Int64 = Int64(ProcessInfo.processInfo.physicalMemory),
            flags: (Group) -> [String] = { _ in [] }) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd HH:mm"
    let left = groups.filter(\.leftover), top = groups.sorted { $0.mem > $1.mem }
    var lines = ["## AppMem report, \(df.string(from: date))", "",
                 "- RAM used: \(fmt(sys.ram)) of \(physical >> 30) GB",
                 "- Swap: \(fmt(sys.swap))",
                 "- Memory pressure: \(sys.pressure.label), \(sys.usedPct)%",
                 "- Leftovers: " + (left.isEmpty ? "none" : "\(fmt(left.reduce(0) { $0 + $1.mem })) ("
                     + left.map { "\($0.name) \(fmt($0.mem))" }.joined(separator: ", ") + ")"),
                 "", "| App | Memory | CPU | Processes | Flags |", "|:--|--:|--:|--:|:--|"]
    for g in top.prefix(15) {
        let f = flagWords(g) + flags(g) + (isPaused(g) ? ["paused"] : [])  // Export.swift
        let name = g.name.replacingOccurrences(of: "|", with: "\\|")  // a bare | ends the cell
        lines.append("| \(name) | \(fmt(g.mem)) | \(cpu(g.cpu)) | \(g.procs.count) | \(f.joined(separator: ", ")) |")
    }
    let rest = top.dropFirst(15)
    if !rest.isEmpty { lines += ["", "_\(rest.count) more groups: \(fmt(rest.reduce(0) { $0 + $1.mem }))_"] }
    return lines.joined(separator: "\n")
}

/// What an appmem:// URL asks for.
enum URLCommand: String { case open, refresh, report }

/// appmem://open, appmem://open/, appmem:open → .open. Anything else, appmem://open/x too → nil.
func urlCommand(_ s: String) -> URLCommand? {
    guard let u = URL(string: s), u.scheme?.lowercased() == "appmem" else { return nil }
    return URLCommand(rawValue: ((u.host ?? "") + u.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())
}

// Same name as the key: UserDefaults reports a KVO change under the key's name.
extension UserDefaults {
    @objc dynamic var menuBarShows: String { string(forKey: "menuBarShows") ?? "" }
}

/// Settings > Menu Bar Shows. Icon Only by default: a number in the menu bar read as
/// the total RAM use, and a quiet menu bar is the better default.
struct MenuBarShowsPicker: View {
    @AppStorage("menuBarShows") private var shows = MenuBarShows.icon

    var body: some View {
        Picker("Menu Bar Shows", selection: $shows) {
            ForEach(MenuBarShows.allCases, id: \.self) { Text($0.title) }
        }
    }
}

extension Model {
    /// The gear menu's, the right-click menu's and appmem://report's Copy Report.
    func copyReport() { Actions.copy(report(groups: groups, sys: sys, date: Date(), flags: reportFlags)) }

    /// The flags the group alone does not tell (growing, idle): Copy Report's and Save Report's.
    var reportFlags: (Group) -> [String] {
        let h = history
        return { g in [growthText(h.points(g.id)) == nil ? nil : "growing", Usage.idle(g) == nil ? nil : "idle"].compactMap { $0 } }
    }
}

private var showsWatch: NSKeyValueObservation?

extension Delegate {
    // Here, not in didFinishLaunching: the URL that launches AppMem comes before that.
    func applicationWillFinishLaunching(_ note: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        showsWatch = UserDefaults.standard.observe(\.menuBarShows) { [weak self] _, _ in DispatchQueue.main.async { self?.updateIcon() } }
    }

    /// Set only when the text changes: each set redraws the item.
    func updateTitle() {
        guard let b = item.button else { return }
        let t = menuBarText(MenuBarShows(rawValue: UserDefaults.standard.menuBarShows) ?? .icon, sys: model.sys, waste: model.waste)
        guard b.title != t else { return }
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        b.title = t
        b.imagePosition = t.isEmpty ? .imageOnly : .imageLeading
    }

    /// Left click: the panel. Right click or Control-click: the quick menu.
    @objc func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showQuickMenu() } else { toggle() }
    }

    func showQuickMenu() {
        if popover.isShown { popover.performClose(nil) }
        // With the panel closed the numbers can be a minute old. This scan lands while the menu
        // is open and can find more leftovers: Stop All stops only the ones this menu named.
        model.refresh()
        let menu = NSMenu()
        @discardableResult func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            i.target = self
            return i
        }
        add("Open AppMem", #selector(openPanel))
        add(infoLine(model.sys, physical: Int64(ProcessInfo.processInfo.physicalMemory)), nil)  // no action: disabled
        if model.waste > 0 {
            let left = model.groups.filter(\.leftover), i = add("Stop All Leftovers (\(short(model.waste)))", #selector(stopAllLeftovers))
            i.toolTip = "Stop every leftover: " + left.map(\.name).joined(separator: ", ")
            i.representedObject = Set(left.map(\.id))
        }
        add("Copy Report", #selector(copyReport))
        add("Refresh", #selector(refreshNow), key: "r")
        menu.addItem(.separator())
        add("Quit AppMem", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
        item.menu = menu
        item.button?.performClick(nil)  // the menu opens under the item, with the menu bar highlight
        item.menu = nil  // else a left click opens the menu too, not the panel
    }

    // Async: the menu, or the launch, is not done yet; a popover shown in it can close at once.
    @objc func openPanel() { DispatchQueue.main.async { [self] in if !popover.isShown { toggle() } } }
    @objc func stopAllLeftovers(_ sender: NSMenuItem) { model.stopAll(only: sender.representedObject as? Set<String> ?? []) }
    @objc func copyReport() { model.copyReport() }
    @objc func refreshNow() { model.refresh(force: true) }

    /// ponytail: appmem://report that launches AppMem copies before the first scan, so with no
    /// groups; open the URL again. A completion on Model.refresh would fix it.
    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let cmd = urlCommand(s) else { return }
        switch cmd {
        case .open: openPanel()
        case .refresh: model.refresh(force: true)
        case .report: DispatchQueue.main.async { self.model.copyReport() }
        }
    }
}
