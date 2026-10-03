import AppKit

if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }
if CommandLine.arguments.contains("--list") { printGroups(); exit(0) }
if let status = runCLI(Array(CommandLine.arguments.dropFirst())) { exit(status) }  // CLI.swift
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    if ProcessInfo.processInfo.environment["LEGEND"] != nil { snapshotLegend(to: CommandLine.arguments[i + 1]); exit(0) }  // Legend.swift
    snapshot(to: CommandLine.arguments[i + 1]) { Panel(model: $0, query: CommandLine.arguments.dropFirst(i + 2).first ?? "") }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-details"), i + 2 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    snapshotDetails(to: a[i + 1], group: a[i + 2], query: a.dropFirst(i + 3).first ?? "")  // Details.swift
    exit(0)
}
#endif
// getuid() is 0 under sudo: root's daemons would pass the "this user only" rules of Stop, Quit and Pause.
if getuid() == 0 { fputs("AppMem: the menu bar app does not run as root: run it without sudo\n", stderr); exit(2) }

let app = NSApplication.shared
let delegate = Delegate()
ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app: it has no windows but must keep running")
app.delegate = delegate
app.setActivationPolicy(.accessory)
// An accessory app shows no menu bar, but text fields take ⌘X ⌘C ⌘V ⌘A ⌘Z only from the
// main menu's Edit items: without them the search fields ignore these keys.
let edit = NSMenu(title: "Edit")
for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                             ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
    edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
}
app.mainMenu = NSMenu()
app.mainMenu?.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
app.run()
