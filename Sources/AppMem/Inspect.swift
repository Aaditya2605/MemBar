import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Right-click a process > Inspect, as Activity Monitor's Sample and Open Files: what a process
// does (sample), what it holds open (lsof), what it was started with (its environment). Each in a
// text window of its own; several can be open. Read-only, and only this user's processes.

// MARK: - Pure rules

/// `sample` for 3 s. -mayDie: read the symbols at once, in case it quits. -file: the report to
/// stdout only; else sample also leaves a copy in /tmp each time.
func sampleArgs(_ pid: pid_t) -> [String] { [String(pid), "3", "-mayDie", "-file", "/dev/stdout"] }

/// `lsof` of one process. -n -P: numbers, not host and port names: a DNS lookup can take seconds.
func lsofArgs(_ pid: pid_t) -> [String] { ["-nP", "-p", String(pid)] }

/// "NAME=value" strings (argvEnv(_:)) as pairs, sorted by name. One with no "=" is all name.
func envPairs(_ env: [String]) -> [(name: String, value: String)] {
    env.map { e in
        let i = e.firstIndex(of: "=") ?? e.endIndex
        return (String(e[..<i]), String(e[i...].dropFirst()))
    }.sorted { $0.name < $1.name }
}

/// A name that looks like it holds a secret (GITHUB_TOKEN, api_key, DB_PASSWORD): its value is masked.
func isSecret(_ name: String) -> Bool {
    let n = name.uppercased()
    return ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "COOKIE", "SESSION"].contains { n.contains($0) }
}

/// The Environment window's text: a line per variable, a secret's value as "•••" unless `show`.
func envText(_ env: [(name: String, value: String)], show: Bool) -> String {
    env.map { "\($0.name)=\(show || !isSecret($0.name) ? $0.value : "•••")" }.joined(separator: "\n")
}

// MARK: - System reads

/// A tool's output for the window: its stdout; else its stderr (sample's "cannot examine process");
/// else a note. After `timeout` s it gets SIGTERM: AppMem started it, it is the only one signalled.
/// Off the main thread: it waits for the tool.
/// ponytail: stderr is read after stdout ends, so a tool that fills the stderr pipe (64 KB) first
/// would wait for ever; sample and lsof write a few lines there.
func toolText(_ exe: String, _ args: [String], timeout: TimeInterval) -> String {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice  // run from a terminal: no tool reads its keys
    guard (try? p.run()) != nil else { return "\(exe) did not start." }
    let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    stop.cancel()
    let note = p.terminationReason == .uncaughtSignal ? "Stopped: it took more than \(Int(timeout)) s.\n\n" : ""
    return note + [o, e, "No output: the process may have quit."].first { !$0.isEmpty }!
}

// MARK: - UI

/// Right-click > Inspect on a process line, in the panel and in the Details window (ProcMenu).
/// Only this user's processes: without root, macOS shows none of these for other users'.
struct InspectMenu: View {
    let p: Proc

    var body: some View {
        if p.uid == getuid() {
            Divider()
            Menu("Inspect") {
                Button("Sample Process") { Inspect.open(p, .sample) }
                    .help("What its threads do: 3 s of call stacks, as Activity Monitor's Sample")
                Button("Open Files and Ports") { Inspect.open(p, .files) }.help("Its files, sockets and pipes, from lsof")
                Button("Environment") { Inspect.open(p, .env) }.help("The variables it was started with")
            }
        }
    }
}

enum Inspect {
    enum Kind: String, CaseIterable { case sample = "Sample", files = "Open Files and Ports", env = "Environment" }

    fileprivate static var windows: Set<NSWindow> = []  // the open ones: closing one drops it here, which frees it
    private static var next = NSPoint.zero  // where the next window goes: a step down and right from the last

    static func open(_ p: Proc, _ k: Kind) {
        // 900 wide: lsof's NAME column, the path, starts at about 590 pt.
        let w = Window(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540), styleMask: [.titled, .closable, .resizable],
                       backing: .buffered, defer: true)
        w.title = "\(p.name) (PID \(p.pid)) — \(k.rawValue)"
        w.isReleasedWhenClosed = false  // `windows` holds it
        let v = NSHostingView(rootView: view(p, k))
        v.sizingOptions = .minSize  // as Details: the user can make it smaller than the text
        w.contentView = v
        if windows.isEmpty { next = .zero }
        w.center()
        next = w.cascadeTopLeft(from: next)  // .zero: it stays centered
        windows.insert(w)
        (NSApp.delegate as? Delegate)?.popover.performClose(nil)  // as Details: the user works in the window now
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// What the window shows. The PID is checked first: it may be another process's by now.
    static func view(_ p: Proc, _ k: Kind) -> InspectView {
        let file = "\(p.name) \(p.pid) \(k.rawValue).txt"
        guard same(p) else { return InspectView(file: file, text: "\(p.name) (PID \(p.pid)) is no longer running.") }
        switch k {
        case .sample:
            return InspectView(file: file, busy: "Sampling for 3 seconds…") { toolText("/usr/bin/sample", sampleArgs(p.pid), timeout: 30) }
        case .files:
            return InspectView(file: file, busy: "Reading open files…") { toolText("/usr/sbin/lsof", lsofArgs(p.pid), timeout: 5) }
        case .env:
            let env = argvEnv(procArgs(p.pid) ?? []).env  // one sysctl: no need to wait
            return env.isEmpty ? InspectView(file: file, text: "No environment: macOS hides it for its own programs, such as /bin/zsh and Finder.")
                : InspectView(file: file, env: envPairs(env))
        }
    }

    /// Closed: out of `windows`, so it is freed. Async: AppKit is still in its close.
    private final class Window: NSWindow {
        override func close() {
            super.close()
            DispatchQueue.main.async { Inspect.windows.remove(self) }
        }
    }
}

/// An Inspect window's content: the text, monospaced and selectable, with Copy and Save….
struct InspectView: View {
    let file: String  // Save's file name
    var text: String?  // fixed text, or nil while `load` runs
    var busy = ""  // what `load` does, shown while it runs
    var load: (() -> String)?  // sample and lsof take seconds: off the main thread
    var env: [(name: String, value: String)]?  // Environment: secrets masked until Show Values
    @State private var loaded: String?
    @State private var show = false

    var body: some View {
        let t = env.map { envText($0, show: show) } ?? loaded ?? text
        VStack(spacing: 0) {
            if let t {
                InspectText(text: t)
            } else {
                ProgressView(busy).controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                if let env, env.contains(where: { isSecret($0.name) }) {
                    Toggle("Show Values", isOn: $show)
                        .help("Values whose names have KEY, TOKEN, SECRET, PASSWORD, AUTH, COOKIE or SESSION in them show as •••")
                }
                Spacer()
                Button("Copy") { Actions.copy(t ?? "") }.help("Copy all the text, as shown")
                Button("Save…") { save(t ?? "") }.help("Save the text, as shown, to a file")
            }
            .disabled(t == nil)
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 200)
        // No menu bar in an accessory app, so no File > Close: ⌘W from a hidden button, as in Details.
        .background { Button("Close") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w").hidden() }
        .task {
            guard let load else { return }
            loaded = await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: load()) } }
        }
    }

    /// A sheet on its window. Not runModal: that would hold back the main queue (see saveReport).
    func save(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = file
        let write = { (r: NSApplication.ModalResponse) in
            guard r == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: write) } else { panel.begin(completionHandler: write) }
    }
}

/// Read-only, selectable, monospaced, not wrapped (lsof's lines are long): an NSTextView, as a
/// SwiftUI Text of a few thousand lines (the sample of a busy app) lays out slowly.
struct InspectText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let s = NSTextView.scrollableTextView(), t = s.documentView as! NSTextView
        t.isEditable = false; t.isRichText = false
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.textContainerInset = NSSize(width: 4, height: 6)
        t.isHorizontallyResizable = true
        t.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        t.textContainer?.widthTracksTextView = false
        t.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        s.hasHorizontalScroller = true
        return s
    }

    func updateNSView(_ s: NSScrollView, context: Context) {
        let t = s.documentView as! NSTextView
        if t.string != text { t.string = text }
    }
}

#if DEBUG
/// `INSPECT=sample|files|env AppMem --snapshot out.png` (debug builds): an Inspect window of AppMem
/// itself as a PNG. sample shows its progress: the snapshot draws after 1 s, the sample takes 3.
func snapshotInspect(to path: String, _ what: String) {
    let k = Inspect.Kind.allCases.first { "\($0)" == what } ?? .env
    snapshot(to: path, size: NSSize(width: 900, height: 540)) { _ in Inspect.view(scan(top: [:])[getpid()]!, k) }
}

extension Drive {
    /// 3b. Inspect on AppMem's own process: two windows at once, their text loads, ⌘W and the
    /// close button close them, and nothing holds them after (weak refs only here).
    @MainActor static func inspect() async {
        guard let me = scan(top: [:])[getpid()] else { return check(false, "AppMem's own process for Inspect") }
        Inspect.open(me, .env)
        Inspect.open(me, .files)
        let ws: [() -> NSWindow?] = Inspect.windows.sorted { $0.title < $1.title }.map { w in { [weak w] in w } }
        func text(_ w: NSWindow?) -> String {
            func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
            return w?.contentView.flatMap(find)?.string ?? ""
        }
        guard ws.count == 2 else { return check(false, "Inspect opens a window each: \(ws.count) windows") }
        check(ws.allSatisfy { $0()?.isVisible == true }, "Inspect opens a window each: \(ws.map { $0()?.title ?? "gone" })")
        check(await until(6) { ws.allSatisfy { !text($0()).isEmpty } }, "their text loads: \(ws.map { text($0()).split(separator: "\n").count }) lines")
        let env = text(ws[0]()).split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        check(env.allSatisfy { !isSecret($0[0]) || $0.last == "•••" }, "secret values are masked: \(env.filter { isSecret($0[0]) }.count) of \(env.count)")
        shot("8-inspect-env", ws[0]())
        shot("9-inspect-files", ws[1]())
        let byKey = ws[1]()?.isKeyWindow == true  // ⌘W goes to the key window only
        if let w = ws[1](), byKey { await press(Key(chars: "w", code: 13, mods: .command), w) } else { ws[1]()?.performClose(nil) }
        ws[0]()?.performClose(nil)
        let freed = await until(3) { ws.allSatisfy { $0() == nil } } && Inspect.windows.isEmpty
        let state = ws.map { $0().map { $0.isVisible ? "open" : "closed, still held" } ?? "freed" }
        check(freed, "closed (\(byKey ? "⌘W" : "not key: close button"), close button), both are freed: \(state), \(Inspect.windows.count) in the set")
    }
}
#endif
