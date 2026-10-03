import AppKit
import SwiftUI

// The launch agent behind a respawn (Recall names its launchd label): the plist for it, and
// Disable, so Stop is not undone each time. Only this user's own agents, in ~/Library/LaunchAgents:
// AppMem never changes files, never acts on /Library or /System agents or on Apple's labels, never as
// root. Disable is launchd's own override (bootout, then disable): the plist stays as it is, and
// Settings > Disabled Launch Agents undoes it. UserDefaults key: "disabledAgents" ([String: String],
// label → plist path, the agents AppMem disabled).

/// The plist whose Label is `label`, from (path, contents) pairs in search order; nil: unknown.
func plistPath(for label: String, in plists: [(path: String, dict: [String: Any])]) -> String? {
    plists.first { $0.dict["Label"] as? String == label }?.path
}

/// May AppMem disable or enable `label`? Only a plist right in `folder` (~/Library/LaunchAgents,
/// both with symlinks resolved): an agent of /Library or /System is other apps' and macOS's. Never
/// Apple's labels, never as root (gui/0 is no user's session), never a label that would be a path.
func mayToggle(_ label: String, plist: String?, folder: String, uid: uid_t = getuid()) -> Bool {
    guard let plist, uid != 0, !label.isEmpty, !label.contains("/"), !label.hasPrefix("com.apple.") else { return false }
    let url = URL(fileURLWithPath: plist).standardized  // standardized: "/../" cannot step out of the folder
    return url.pathExtension == "plist" && url.deletingLastPathComponent().path == URL(fileURLWithPath: folder).standardized.path
}

/// launchctl's arguments. Disable: stop the job now (bootout), then keep launchd from loading it
/// again, also at the next login (disable). Enable: the other way round, from the plist.
func agentSteps(disable: Bool, label: String, plist: String, uid: uid_t = getuid()) -> [[String]] {
    let domain = "gui/\(uid)", service = "\(domain)/\(label)"
    return disable ? [["bootout", service], ["disable", service]] : [["enable", service], ["bootstrap", domain, plist]]
}

extension Group {
    /// The launch agent's label of a respawn, for the menus. Not once ignoring() took the badge away.
    var agentLabel: String? { respawns == nil ? nil : job }
}

extension UserDefaults {
    var disabledAgents: [String: String] { dictionary(forKey: "disabledAgents") as? [String: String] ?? [:] }
}

/// The *.plist files in `dir` with their contents. A file that is not a dictionary plist is left out.
func readPlists(_ dir: String) -> [(path: String, dict: [String: Any])] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".plist") }.sorted().compactMap { n in
        let p = dir + "/" + n
        guard let data = FileManager.default.contents(atPath: p),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (p, d)
    }
}

/// `label`'s plist: this user's folder first, then /Library's, which AppMem only reveals. A few small
/// files, read when a menu that names the agent is built.
func agentPlist(_ label: String, home: String = NSHomeDirectory()) -> String? {
    plistPath(for: label, in: readPlists(home + "/Library/LaunchAgents")) ?? plistPath(for: label, in: readPlists("/Library/LaunchAgents"))
}

/// Runs launchctl with each of `steps` and stops at the first that fails. `done`: how many ran
/// fine; `error`: the one that failed, with launchctl's own words. Blocking: off the main thread.
func launchctl(_ steps: [[String]]) -> (done: Int, error: String?) {
    for (i, args) in steps.enumerated() {
        let p = Process(), err = Pipe(), cmd = "launchctl " + args.joined(separator: " ")
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = err
        guard (try? p.run()) != nil else { return (i, "\(cmd): launchctl did not start") }
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)  // before wait: a full pipe blocks it
        p.waitUntilExit()
        if p.terminationStatus != 0 { return (i, "\(cmd) failed (exit \(p.terminationStatus))\n\(said.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
    return (steps.count, nil)
}

enum Agents {
    // One at a time: the list is read, changed and written back.
    private static let queue = DispatchQueue(label: "appmem.agents", qos: .userInitiated)

    /// mayToggle with the real paths: a symlink in ~/Library/LaunchAgents to a /Library plist is not ours.
    static func mine(_ label: String, plist: String?, home: String = NSHomeDirectory()) -> Bool {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        return mayToggle(label, plist: plist.map(real), folder: real(home + "/Library/LaunchAgents"))
    }

    /// Disable or enable again, with the rule checked here too: the list can hold anything that
    /// `defaults write` put in it. nil: done; else why not. Blocking: off the main thread.
    static func set(disabled: Bool, label: String, plist: String, home: String = NSHomeDirectory()) -> String? {
        guard mine(label, plist: plist, home: home) else { return "AppMem acts only on your own launch agents in ~/Library/LaunchAgents, not on Apple's." }
        let r = launchctl(agentSteps(disable: disabled, label: label, plist: plist))
        // The list is the override that AppMem set in launchd: in once `disable` ran, out once `enable` ran.
        if disabled ? r.done == 2 : r.done >= 1 {
            var l = UserDefaults.standard.disabledAgents
            l[label] = disabled ? plist : nil
            UserDefaults.standard.set(l.isEmpty ? nil : l, forKey: "disabledAgents")
        }
        return r.error
    }

    /// The menus' Disable Launch Agent…: asks first, as it also stops the job's processes now.
    static func confirmDisable(_ label: String, plist: String) {
        let a = NSAlert()
        a.messageText = "Disable launch agent \(label)?"
        a.informativeText = "launchd stops it now and does not start it again, also after a restart. AppMem does not change or delete its file:\n"
            + (plist as NSString).abbreviatingWithTildeInPath + "\n\nTo undo it: Settings > Disabled Launch Agents."
        a.addButton(withTitle: "Disable")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { run(disabled: true, label, plist) }
    }

    /// Settings > Disabled Launch Agents: undo, no question. It is what the alert promised.
    static func enable(_ label: String, plist: String) { run(disabled: false, label, plist) }

    private static func run(disabled: Bool, _ label: String, _ plist: String) {
        queue.async {
            let error = set(disabled: disabled, label: label, plist: plist)
            DispatchQueue.main.async {
                let model = (NSApp.delegate as? Delegate)?.model
                if disabled, error == nil { model?.forget(job: label) }  // its respawn mark goes, and with it this menu item
                model?.refresh()  // its processes are gone, or back
                guard let error else { return }
                let a = NSAlert()
                a.messageText = "Could not \(disabled ? "disable" : "enable") \(label)"
                a.informativeText = error
                NSApp.activate(ignoringOtherApps: true)  // the gear menu's undo: the panel may be closed by now
                // ponytail: modal, so main-queue jobs wait until it closes (as Save Report's); a failure is rare.
                a.runModal()
            }
        }
    }
}

// MARK: - UI

/// The respawn's launch agent: right-click on its row, and the Details window's header.
struct AgentItems: View {
    let label: String

    var body: some View {
        let plist = agentPlist(label)
        Button("Reveal Launch Agent") { plist.map(Actions.reveal) }
            .disabled(plist == nil)
            .help(plist ?? "No plist with the label \(label) in ~/Library/LaunchAgents or /Library/LaunchAgents")
        // No disabledAgents check: Disable clears the mark (Recall.forget), and a new mark names a job that
        // launchd ran after Stop, so it is loaded again (enabled outside AppMem) and Disable works.
        if let plist, Agents.mine(label, plist: plist) {
            Button("Disable Launch Agent…") { Agents.confirmDisable(label, plist: plist) }
        }
    }
}

/// The Details header: the label, with AgentItems as its menu.
struct AgentButton: View {
    let label: String

    var body: some View {
        Menu { AgentItems(label: label) } label: {
            Label(label, systemImage: "arrow.triangle.2.circlepath").font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.button).buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .help("It starts again after Stop: the launch agent \(label) restarts it")
        .accessibilityLabel("Launch agent \(label)")
    }
}

/// Settings > Disabled Launch Agents, while there are any. `agents`: the list, read when the menu
/// opens (see SettingsMenu). Checked = disabled, as Never Flagged; choosing one enables it again.
struct DisabledAgentsMenu: View {
    let agents: [String: String]

    var body: some View {
        if !agents.isEmpty {
            Menu("Disabled Launch Agents") {
                ForEach(agents.keys.sorted(), id: \.self) { label in
                    Toggle(label, isOn: Binding(get: { true }, set: { _ in Agents.enable(label, plist: agents[label] ?? "") }))
                        .help((agents[label].map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "") + "\nChoose it to enable it again")
                }
            }
        }
    }
}

/// Asserts for the rules above, run by selfTest.
func agentsTest() {
    let mine = "/Users/a/Library/LaunchAgents"
    let plists: [(path: String, dict: [String: Any])] = [
        (mine + "/a.plist", ["Label": "com.foo.agent"]),  // any file name: the Label decides
        (mine + "/b.plist", ["Label": 3]), (mine + "/c.plist", [:]),
        ("/Library/LaunchAgents/com.foo.agent.plist", ["Label": "com.foo.agent"]),
        ("/Library/LaunchAgents/com.bar.plist", ["Label": "com.bar"]),
    ]
    precondition(plistPath(for: "com.foo.agent", in: plists) == mine + "/a.plist")  // this user's first
    precondition(plistPath(for: "com.bar", in: plists) == "/Library/LaunchAgents/com.bar.plist" && plistPath(for: "com.nope", in: plists) == nil)
    func may(_ label: String, _ plist: String?, uid: uid_t = 501) -> Bool { mayToggle(label, plist: plist, folder: mine, uid: uid) }
    precondition(may("com.foo.agent", mine + "/a.plist") && may("com.foo.agent", mine + "/./a.plist") && !may("com.foo.agent", mine + "/a.plist", uid: 0))
    precondition(!may("com.apple.foo", mine + "/a.plist") && !may("com.bar", "/Library/LaunchAgents/com.bar.plist") && !may("x", nil))
    precondition(!may("x", "/System/Library/LaunchAgents/x.plist") && !may("x", mine + "/../../../../Library/LaunchAgents/x.plist"))
    precondition(!may("x", mine + "/sub/x.plist") && !may("x", mine + "/x.txt") && !may("x", mine) && !may("", mine + "/a.plist") && !may("a/b", mine + "/a.plist"))
    precondition(agentSteps(disable: true, label: "com.foo.agent", plist: "/p.plist", uid: 501)
                 == [["bootout", "gui/501/com.foo.agent"], ["disable", "gui/501/com.foo.agent"]])
    precondition(agentSteps(disable: false, label: "com.foo.agent", plist: "/p.plist", uid: 501)
                 == [["enable", "gui/501/com.foo.agent"], ["bootstrap", "gui/501", "/p.plist"]])
    var g = Group(name: "Foo", isApp: true, leftover: true)
    g.job = "com.foo.agent"
    precondition(g.agentLabel == nil)  // no respawn: no menu items
    g.respawns = "x"
    precondition(g.agentLabel == "com.foo.agent" && ignoring([g], ["Foo"])[0].agentLabel == nil)
    precondition(launchctl([]) == (0, nil))
}

#if DEBUG
/// `AppMem --agent-test HOME LABEL` (debug builds): the real lookup, rule, Disable and enable again,
/// for a test agent at HOME/Library/LaunchAgents that is loaded already, and the plist not changed.
/// Only com.appmem.test.* labels: it must never act on a real agent.
func agentTest(home: String, label: String) -> Int32 {
    guard label.hasPrefix("com.appmem.test.") else { fputs("AppMem: --agent-test acts only on com.appmem.test.* labels\n", stderr); return 2 }
    var failed = 0
    func check(_ ok: Bool, _ what: String) { if !ok { failed += 1 }; print((ok ? "ok    " : "FAIL  ") + what) }
    func loaded() -> Bool { !output("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).isEmpty }  // stdout only when found
    func disabled() -> Bool { String(decoding: output("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]), as: UTF8.self).contains("\"\(label)\" => disabled") }
    guard let plist = agentPlist(label, home: home) else { fputs("AppMem: no plist with the label \(label) in \(home)/Library/LaunchAgents\n", stderr); return 2 }
    let before = FileManager.default.contents(atPath: plist)
    check(Agents.mine(label, plist: plist, home: home) && !Agents.mine(label, plist: plist), "the rule takes it in HOME, not in the real home")
    check(loaded() && !disabled(), "loaded and enabled at the start")
    check(Agents.set(disabled: true, label: label, plist: plist, home: home) == nil, "Disable runs")
    check(!loaded() && disabled() && UserDefaults.standard.disabledAgents[label] == plist, "booted out, disabled, in the list")
    let again = Agents.set(disabled: true, label: label, plist: plist, home: home)
    check(again?.contains("bootout") == true && UserDefaults.standard.disabledAgents[label] == plist, "Disable again fails at bootout: \(again ?? "no error")")
    check(Agents.set(disabled: false, label: label, plist: plist, home: home) == nil, "enable runs")
    check(loaded() && !disabled() && UserDefaults.standard.disabledAgents[label] == nil, "loaded, enabled, out of the list")
    check(FileManager.default.contents(atPath: plist) == before, "the plist is as it was")
    print("\(failed) failed")
    return failed == 0 ? 0 : 1
}
#endif
