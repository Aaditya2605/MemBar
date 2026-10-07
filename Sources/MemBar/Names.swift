import AppKit

// Names that say what a helper does. Ten lines of `com.apple.WebKit.WebContent` or `Claude Helper`
// do not tell which site or which part of the app holds the memory. WebKit gives each web content
// process a LaunchServices name, as Activity Monitor shows it ("Safari (apple.com) Web Content");
// Chromium and Electron helpers have their role in argv (--type=renderer). Read only for the lines
// on show: expanded groups, the Details window, search hits.

/// The site in a WebKit content process's LaunchServices name: " Web Content" and the app name
/// (`group`) go, "(…)" and "https://www." too. nil when nothing is left: "Safari Web Content" has
/// no site. "Search (local) Web Content" in the group Search reads "local".
func webName(_ ls: String?, group: String) -> String? {
    guard var s = ls?.replacingOccurrences(of: " Web Content", with: "") else { return nil }  // also before " (Prewarmed)"
    if s.hasPrefix(group + " ") { s.removeFirst(group.count + 1) } else if s == group { return nil }
    if s.hasPrefix("("), s.hasSuffix(")") { s = String(s.dropFirst().dropLast()) }
    for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
    return s.isEmpty ? nil : s
}

/// A Chromium or Electron helper's role from its argv: "Renderer", "Extension", "GPU", "Network",
/// "Storage", "Audio", "Node" (Electron's utility processes) or "Utility". nil: no --type (the
/// browser itself), or one with no plain word (crashpad-handler).
func chromiumRole(_ argv: [String]) -> String? {
    func value(_ flag: String) -> Substring? { argv.first { $0.hasPrefix(flag) }?.dropFirst(flag.count) }
    switch value("--type=") {
    case "renderer": return argv.contains("--extension-process") ? "Extension" : "Renderer"
    case "gpu-process": return "GPU"
    case "utility":  // "network.mojom.NetworkService" → network. Not video_capture: "Video Capture" reads as a camera in use.
        let sub = value("--utility-sub-type=")?.prefix { $0 != "." } ?? ""
        return ["network": "Network", "storage": "Storage", "audio": "Audio", "node": "Node"][sub] ?? "Utility"
    default: return nil
    }
}

/// Display names, cached by PID and path. Main thread only: NSRunningApplication. Read again after
/// 10 s, as WebKit renames a process when it gets a site (a prewarmed one) or changes it; dropped
/// 10 s after the last read, so a PID that is gone (or a line no longer shown) keeps nothing.
/// ponytail: a PID reused by the same executable within 10 s keeps the old name for those seconds.
enum Names {
    private static var cache: [pid_t: (path: String, name: String, at: Date)] = [:], prunedAt = Date()

    /// `p`'s name on a process line: its site or role, else its executable's name. `group`: its group's name.
    static func of(_ p: Proc, in group: String) -> String {
        let exe = p.name, web = exe.hasPrefix("com.apple.WebKit.WebContent")  // .EnhancedSecurity, .CaptivePortal too
        // " Helper": every Chromium helper ("Google Chrome Helper (Renderer)"), not "SandboxHelper".
        guard web || exe.contains(" Helper") else { return exe }
        let now = Date()
        if let c = cache[p.pid], c.path == p.path, now.timeIntervalSince(c.at) < 10 { return c.name }
        if now.timeIntervalSince(prunedAt) > 10 { cache = cache.filter { now.timeIntervalSince($0.value.at) < 10 }; prunedAt = now }
        let name = (web ? webName(NSRunningApplication(processIdentifier: p.pid)?.localizedName, group: group)
                        : chromiumRole(argv(procArgs(p.pid) ?? []))) ?? exe  // argv: other users' are not readable
        cache[p.pid] = (p.path, name, now)
        return name
    }
}

/// Asserts for the rules above, run by selfTest.
func namesTest() {
    precondition(webName("Safari Web Content", group: "Safari") == nil && webName(nil, group: "Safari") == nil)
    precondition(webName("Safari (apple.com) Web Content", group: "Safari") == "apple.com" && webName("apple.com", group: "Safari") == "apple.com")
    precondition(webName("https://www.youtube.com", group: "Safari") == "youtube.com" && webName("Search (local) Web Content", group: "Search") == "local")
    precondition(webName("Safari Web Content (Prewarmed)", group: "Safari") == "Prewarmed" && webName("Dayflow Web Content", group: "Dayflow") == nil)
    // Another app's web view (an agent's test runner in Claude's group) keeps that app's name; a name only like the group's too.
    precondition(webName("swiftpm-testing-helper Web Content", group: "Claude") == "swiftpm-testing-helper" && webName("Safari2 Web Content", group: "Safari") == "Safari2")
    precondition(webName("Safari Service Worker (apple.com)", group: "Safari") == "Service Worker (apple.com)")
    let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
    func role(_ args: String) -> String? { chromiumRole([helper] + args.split(separator: " ").map(String.init)) }
    precondition(role("--type=renderer --user-data-dir=/x") == "Renderer" && role("--type=renderer --lang=en --extension-process") == "Extension")
    precondition(role("--type=gpu-process --gpu-preferences=SAAA") == "GPU" && role("--type=utility --utility-sub-type=network.mojom.NetworkService") == "Network")
    precondition(role("--type=utility --utility-sub-type=storage.mojom.StorageService") == "Storage" && role("--type=utility --utility-sub-type=audio.mojom.AudioService") == "Audio")
    precondition(role("--type=utility --utility-sub-type=node.mojom.NodeService") == "Node" && role("--type=utility --utility-sub-type=video_capture.mojom.VideoCaptureService") == "Utility")
    precondition(role("--type=utility") == "Utility" && role("") == nil && role("--user-data-dir=/x") == nil && chromiumRole([]) == nil)
    precondition(role("--monitor-self-annotation=ptype=crashpad-handler --type=crashpad-handler") == nil)  // Spotify's crash reporter
    // Only WebKit content and Chromium helpers are read; the rest keep their executable's name, no syscall.
    let node = Proc(pid: getpid(), ppid: 1, uid: getuid(), path: "/opt/homebrew/bin/node", mem: 1)
    let me = Proc(pid: getpid(), ppid: 1, uid: getuid(), path: "/x/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper", mem: 1)
    precondition(Names.of(node, in: "node") == "node" && Names.of(me, in: "Foo") == "Foo Helper")  // this process: no --type
    precondition(detailMatch(DetailRow(p: node, name: "youtube.com"), "youtube") && !detailMatch(DetailRow(p: node, name: "apple.com"), "youtube"))
}
