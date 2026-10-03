import AppKit

if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }
if CommandLine.arguments.contains("--list") { printGroups(); exit(0) }
if let status = runCLI(Array(CommandLine.arguments.dropFirst())) { exit(status) }  // CLI.swift
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    snapshot(to: CommandLine.arguments[i + 1]) { Panel(model: $0, query: CommandLine.arguments.dropFirst(i + 2).first ?? "") }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-details"), i + 2 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    snapshotDetails(to: a[i + 1], group: a[i + 2], query: a.dropFirst(i + 3).first ?? "")  // Details.swift
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = Delegate()
ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app: it has no windows but must keep running")
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
