import AppKit

if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }
if CommandLine.arguments.contains("--list") { printGroups(); exit(0) }

let app = NSApplication.shared
let delegate = Delegate()
ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app: it has no windows but must keep running")
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
