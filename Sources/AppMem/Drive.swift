import AppKit
import UserNotifications

#if DEBUG
// `AppMem --drive OUTDIR` (debug builds): the real app (status item, Delegate, popover, Model)
// with a scripted scenario on the main run loop, for what --snapshot cannot reach: the status
// item's click, keys in the popover window, Esc, the Details window, the quick menu, the
// appmem:// handler and the notifications. A PNG of the window after each step, and one line
// per check in OUTDIR/drive.log. It only looks: no Stop, Stop All, Quit or Pause, no menu
// tracked, nothing posted, and it does not run while a rule that acts by itself is on.

enum Drive {
    private static var dir = "", lines: [String] = [], failed = 0
    private static var scans = 0  // Model.onUpdate calls: one per scan

    static func start(_ out: String) {
        // An .app reads the installed app's settings (same bundle id); the bare binary has its own.
        guard Bundle.main.bundleIdentifier == nil else { fail("run the bare binary .build/debug/AppMem, not an .app") }
        let d = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        // They act in each scan: a test run must not stop or quit the apps of this Mac.
        guard autoStopAfter(d.integer(forKey: "autoStop")) == nil, d.quitIdle.isEmpty else {
            fail("Auto-Stop or Quit When Idle is on in the \(domain) defaults: turn them off first")
        }
        dir = out
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        setvbuf(stdout, nil, _IOLBF, 0)  // in order with AppKit's warnings on stderr
        // The app writes its status item's and window's positions, Usage's times: all back as they were.
        let saved = d.persistentDomain(forName: domain)
        func restore() { if let saved { d.setPersistentDomain(saved, forName: domain) } else { d.removePersistentDomain(forName: domain) } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            restore()
            if failed > 0 { exit(1) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { restore(); fputs("drive: timed out\n", stderr); exit(3) }
        Task { @MainActor in await run() }
    }

    private static func fail(_ why: String) -> Never { fputs("AppMem: --drive: \(why)\n", stderr); exit(2) }

    @MainActor static func run() async {
        await pause(2)  // launch and the first scan
        guard let d = NSApp.delegate as? Delegate else { check(false, "the app delegate is Delegate"); return NSApp.terminate(nil) }
        let update = d.model.onUpdate
        d.model.onUpdate = { scans += 1; update() }
        let pb = NSPasteboard.general  // ⌘C and appmem://report write it: the user's clipboard back at the end
        let clip: [NSPasteboardItem] = pb.pasteboardItems?.map { i in
            let c = NSPasteboardItem()
            for t in i.types { if let data = i.data(forType: t) { c.setData(data, forType: t) } }
            return c
        } ?? []
        await openPanel(d)
        await keys(d)
        await details(d)
        quickMenu(d)
        await urls(d)
        notifications()
        pb.clearContents()
        pb.writeObjects(clip)
        note("\(failed) failed")
        NSApp.terminate(nil)  // 7. quit as the menu's Quit does
    }

    /// 1. A click on the status item: its action, as the button sends it.
    @MainActor static func openPanel(_ d: Delegate) async {
        d.item.button?.performClick(nil)
        check(await until(3) { d.popover.isShown }, "a click on the status item shows the popover")
        await pause(1)  // the open scan, and the focus that didShow sets
        let w = d.popover.contentViewController?.view.window
        checkKey(w, "the popover's window is key")
        check(d.model.panelOpen, "the Model scans as open")
        check(!d.model.groups.isEmpty, "the list has rows: \(d.model.groups.count) groups")
        check(!editing(w), "the focus is not in the search field: \(responder(w))")
        shot("1-open", w)
    }

    /// 2. Keys through the popover's window, as the keyboard sends them.
    @MainActor static func keys(_ d: Delegate) async {
        guard let w = d.popover.contentViewController?.view.window, let nav = Nav.shown else { return check(false, "the popover's window and Nav") }
        await press(.down, w)
        let first = nav.sel
        check(first != nil && first?.pid == nil, "Down selects a row: \(first?.group ?? "none")")
        await press(.down, w)
        check(nav.sel != first && nav.sel?.pid == nil, "Down again selects the next row: \(nav.sel?.group ?? "none")")
        shot("2-down", w)
        await press(.right, w)
        check(nav.sel.map { nav.expanded.contains($0.group) } == true, "Right opens it")
        shot("3-right", w)
        await press(.left, w)
        check(nav.expanded.isEmpty, "Left closes it")
        await press(Key(chars: "c", code: 8, mods: .command), w)  // through the main menu's Copy (main.swift)
        let name = d.model.groups.first { $0.id == nav.sel?.group }?.name ?? "?"
        check(NSPasteboard.general.string(forType: .string)?.hasPrefix("\(name): ") == true, "⌘C copies the row's summary")
        let n = scans
        await press(Key(chars: "r", code: 15, mods: .command), w)
        check(await until(5) { scans > n }, "⌘R scans")
        await press(Key(chars: "f", code: 3, mods: .command), w)
        check(editing(w), "⌘F puts the focus in the search field: \(responder(w))")
        for (c, code) in [("f", 3), ("i", 34), ("n", 45)] as [(String, UInt16)] { await press(Key(chars: c, code: code), w) }
        check(search(w) == "fin", "typing fills the search: \"\(search(w) ?? "no field")\"")
        shot("4-search", w)
        await press(.escape, w)
        check(search(w) == "" && d.popover.isShown, "Esc clears the search, the popover stays: \"\(search(w) ?? "no field")\"")
        shot("5-cleared", w)
        await press(.escape, w)
        // didClose comes after the close animation
        check(await until(3) { !d.popover.isShown && !d.model.panelOpen }, "Esc again closes the popover and the fast scans")
    }

    /// 3. Show Details… from the open panel, then its close button.
    @MainActor static func details(_ d: Delegate) async {
        d.item.button?.performClick(nil)
        _ = await until(3) { d.popover.isShown }
        await pause(0.5)
        let pw = d.popover.contentViewController?.view.window
        check(d.popover.isShown && search(pw) == "" && !editing(pw), "open again: no search, the focus on the list: \(responder(pw))")
        if let pw {  // a letter on the list starts a search with it; the next one adds to it
            for (c, code) in [("s", 1), ("p", 35)] as [(String, UInt16)] { await press(Key(chars: c, code: code), pw) }
            check(search(pw) == "sp" && editing(pw), "typing on the list searches: \"\(search(pw) ?? "no field")\"")
            shot("6-typed", pw)
            await press(.escape, pw)
        }
        guard let g = d.model.groups.first(where: { $0.name != "macOS" }) else { return check(false, "a group for Details") }
        let n0 = scans
        Details.show(g)  // what the right-click menu's Show Details… calls
        let w = NSApp.windows.first { $0.title == "\(g.name) — AppMem" }
        check(await until(3) { w?.isVisible == true && !d.popover.isShown }, "Details shows for \(g.name), the popover closed")
        await pause(1.5)  // the table's first layout
        // Still open, panel to window: the timer's scans only, at most one in this time.
        check(scans - n0 <= 1, "no extra scan from panel to window: \(scans - n0) in 2 s")
        checkKey(w, "the Details window is key")
        check(d.model.windowOpen, "the Model scans as open for the window (visible: \(w?.occlusionState.contains(.visible) == true))")
        shot("7-details", w)
        let byKey = w?.isKeyWindow == true  // ⌘W goes to the key window only
        if let w, byKey { await press(Key(chars: "w", code: 13, mods: .command), w) } else { w?.performClose(nil) }
        check(await until(3) { w?.isVisible == false }, byKey ? "⌘W closes it" : "its close button closes it (not key: no ⌘W)")
        await pause(1)  // the close's own refresh
        let n = scans
        await pause(6)  // longer than the 2-5 s of the open panel
        check(!d.model.windowOpen && !d.model.panelOpen && scans == n, "closed, the Model scans as closed: \(scans - n) scans in 6 s")
    }

    /// 4. The right-click menu, built by its own builder, never tracked (that would wait for a click).
    @MainActor static func quickMenu(_ d: Delegate) {
        let m = d.quickMenu()
        m.update()  // validation: an item with no action is disabled
        note("quick menu: " + m.items.filter { !$0.isSeparatorItem }.map { "\($0.title)\($0.isEnabled ? "" : " (off)")" }.joined(separator: " | "))
        check(m.items.first?.title == "Open AppMem" && m.items.first?.isEnabled == true, "the quick menu starts with Open AppMem")
        check(m.items.count > 1 && !m.items[1].isEnabled, "its info line is not a button: \(m.items.count > 1 ? m.items[1].title : "")")
        check(m.items.contains { $0.title.hasPrefix("Stop All") } == (d.model.waste > 0), "Stop All Leftovers only with leftovers")
        check(m.items.filter { ["Copy Report", "Refresh", "Quit AppMem"].contains($0.title) && $0.isEnabled }.count == 3, "Copy Report, Refresh and Quit are on")
    }

    /// 5. appmem:// as an Apple event to this process, so the handler that the app registered answers.
    /// Not NSWorkspace.open: Launch Services would send it to the installed AppMem.
    @MainActor static func urls(_ d: Delegate) async {
        let n = scans, pb = NSPasteboard.general
        url("appmem://refresh")
        check(await until(5) { scans > n }, "appmem://refresh scans")  // a scan can take seconds on a busy Mac
        url("appmem://report")
        let ok = await until(3) { pb.string(forType: .string)?.hasPrefix("## AppMem report") == true }
        check(ok, "appmem://report copies a report: \(pb.string(forType: .string)?.split(separator: "\n").count ?? 0) lines")
        url("appmem://open")
        check(await until(3) { d.popover.isShown }, "appmem://open shows the popover")
        d.popover.performClose(nil)
        check(await until(3) { !d.popover.isShown && !d.model.panelOpen }, "and it closes")
    }

    @MainActor static func url(_ s: String) {
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL), targetDescriptor: .currentProcess(),
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        e.setParam(NSAppleEventDescriptor(string: s), forKeyword: keyDirectObject)
        do { _ = try e.sendEvent(options: [.noReply], timeout: 2) } catch { check(false, "\(s): \(error)") }
    }

    /// 6. Each kind of notification from made-up groups, built by the real builder. Never posted:
    /// the bare binary has no notification center (Alerts.center is nil), so no permission prompt.
    @MainActor static func notifications() {
        var sys = SysMem()
        sys.pressure = .critical
        let g = Group.crowd[0], t0 = Date()  // a leftover of 2 GB of this user, pids that cannot exist
        let s = AlertSettings(leftovers: true, pressure: true, growth: true, limits: true, limitMB: [g.name: 1024])
        let alerts = alertsToSend(prev: AlertState(leftovers: [g.name: t0 - 60]), groups: [g], sys: sys,
                                  growth: [g.name: "+600 MB in 30 min"], now: t0, settings: s).1
        check(alerts.map(\.kind) == [.leftover, .pressure, .growth, .limit], "each kind of alert: \(alerts.map(\.kind.rawValue))")
        for a in alerts {
            let r = Alerts.request(a), c = r.content
            check(!c.title.isEmpty && !c.body.isEmpty && (c.categoryIdentifier == "leftover") == (a.kind == .leftover),
                  "\(r.identifier): \(c.title) / \(c.body)\(c.categoryIdentifier.isEmpty ? "" : " [Stop]")")
        }
        check(Alerts.center == nil, "nothing is posted: no notification center for the bare binary")
    }

    // MARK: - Helpers

    struct Key {
        let chars: String, code: UInt16
        var mods: NSEvent.ModifierFlags = []
        static let down = Key(chars: "\u{F701}", code: 125, mods: [.numericPad, .function])
        static let right = Key(chars: "\u{F703}", code: 124, mods: [.numericPad, .function])
        static let left = Key(chars: "\u{F702}", code: 123, mods: [.numericPad, .function])
        static let escape = Key(chars: "\u{1b}", code: 53)
    }

    /// Down and up through NSApp, as the window server sends them: key equivalents, then the key window.
    @MainActor static func press(_ k: Key, _ w: NSWindow) async {
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: k.mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, characters: k.chars,
                                             charactersIgnoringModifiers: k.chars, isARepeat: false, keyCode: k.code)!)
        }
        await pause(0.4)
    }

    /// The search field: the panel's only text field.
    @MainActor static func search(_ w: NSWindow?) -> String? {
        func find(_ v: NSView) -> NSTextField? { (v as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? v.subviews.lazy.compactMap(find).first }
        return w?.contentView.flatMap(find)?.stringValue
    }

    /// The focus is in a text field: its field editor is the first responder.
    @MainActor static func editing(_ w: NSWindow?) -> Bool { (w?.firstResponder as? NSTextView)?.isFieldEditor == true }

    /// The app that has the focus by the window server. A system alert (UserNotificationCenter) keeps
    /// it from an app that the user did not click, so a window that AppMem makes key may not get it.
    static func frontmost() -> String {
        NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier == getpid() ? "AppMem" : $0.localizedName ?? "?" } ?? "none"
    }

    @MainActor static func responder(_ w: NSWindow?) -> String { w?.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }

    @MainActor static func shot(_ name: String, _ w: NSWindow?) {
        guard let v = w?.contentView else { return check(false, "\(name).png: no window") }
        writePNG(v, to: "\(dir)/\(name).png")
    }

    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// Waits up to `s` seconds for `ok`: an animation or a scan on a busy Mac takes its own time.
    @MainActor static func until(_ s: Double, _ ok: () -> Bool) async -> Bool {
        for _ in 0..<Int(s * 10) where !ok() { await pause(0.1) }
        return ok()
    }

    /// `w` is key. Not counted as a failure while another app keeps the focus (see frontmost).
    /// ponytail: then that check is not made at all; run it again with no system alert on screen.
    @MainActor static func checkKey(_ w: NSWindow?, _ what: String) {
        if w?.isKeyWindow != true, frontmost() != "AppMem" { return note("skip  \(what): \(frontmost()) has the focus") }
        check(w?.isKeyWindow == true, what)
    }

    static func check(_ ok: Bool, _ what: String) {
        if !ok { failed += 1 }
        note((ok ? "ok    " : "FAIL  ") + what)
    }

    /// Written at each line: a crash or the timeout keeps what came before.
    static func note(_ s: String) {
        print(s)
        lines.append(s)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/drive.log", atomically: true, encoding: .utf8)
    }
}
#endif
