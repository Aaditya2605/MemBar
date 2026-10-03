import AppKit
import ServiceManagement
import SwiftUI

// The gear menu in the panel header, and the rules it feeds. UserDefaults keys:
// "refreshEvery" (Int, seconds), "hideSmall", "showMacOS" (Bool), and "ignored"
// ([String], group names; the right-click menu on a row adds to it).

/// Seconds between scans while the panel is open. Checked: `defaults write` can
/// store anything, and a 0 s timer would spin the CPU.
func refreshSeconds(_ stored: Int) -> TimeInterval { [2, 3, 5].contains(stored) ? TimeInterval(stored) : 3 }

/// An ignored app is never a leftover: no badge, no Stop, not in the waste total
/// or the menu bar dot. Exact names, as the right-click menu writes them.
/// `ignored` marks the ones it unflags: the app is not open, so it is not idle either.
func ignoring(_ groups: [Group], _ ignored: [String]) -> [Group] {
    groups.map { g in
        var g = g
        if g.leftover && ignored.contains(g.name) { g.leftover = false; g.ignored = true }
        return g
    }
}

/// The groups that the plain list shows, and the small ones it hides (for the
/// footer). Leftovers always show: the waste total and the menu bar dot count them.
/// So do groups with a paused process: the row's right-click menu is where it resumes.
func visible(_ groups: [Group], hideSmall: Bool, showMacOS: Bool) -> (shown: [Group], small: [Group]) {
    let gs = showMacOS ? groups : groups.filter { $0.name != "macOS" }
    func small(_ g: Group) -> Bool {  // 10 MB, as the menu says
        hideSmall && !g.leftover && !g.procs.contains(where: \.stopped) && g.mem < 10 << 20
    }
    return (gs.filter { !small($0) }, gs.filter(small))
}

// Same names as the keys: UserDefaults reports a KVO change under the key's name,
// so Model can observe(\.ignored).
extension UserDefaults {
    @objc dynamic var ignored: [String] { stringArray(forKey: "ignored") ?? [] }
    @objc dynamic var refreshEvery: Int { integer(forKey: "refreshEvery") }
}

struct SettingsMenu: View {
    @AppStorage("refreshEvery") private var refreshEvery = 3
    @AppStorage("hideSmall") private var hideSmall = false
    @AppStorage("showMacOS") private var showMacOS = true
    // Read again each time a menu opens: System Settings can turn the login item
    // off, and the right-click menu writes the list. SwiftUI makes the menu items
    // from the last body, so a Binding that reads them live would show old values.
    @State private var login = false
    @State private var ignored: [String] = []

    var body: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(get: { login }, set: setLogin))
            Picker("Refresh Every", selection: $refreshEvery) {
                ForEach([2, 3, 5], id: \.self) { Text("\($0) s") }
            }
            Divider()
            Toggle("Hide Groups Under 10 MB", isOn: $hideSmall)
            Toggle("Show macOS Group", isOn: $showMacOS)
            Menu("Ignored Apps") {
                if ignored.isEmpty { Text("None") }
                // Checked = ignored; choosing one takes it off the list.
                ForEach(ignored, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { true }, set: { _ in
                        UserDefaults.standard.set(UserDefaults.standard.ignored.filter { $0 != name }, forKey: "ignored")
                    }))
                }
            }
            Divider()
            Button("About AppMem") { NSApp.orderFrontStandardAboutPanel(nil) }  // version from Info.plist
            Button("Quit AppMem") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            login = SMAppService.mainApp.status == .enabled
            ignored = UserDefaults.standard.ignored
        }
        // SwiftUI fills the menu only when it first opens, so until then its ⌘Q
        // does nothing. A hidden button still takes the shortcut.
        .background { Button("Quit AppMem") { NSApp.terminate(nil) }.keyboardShortcut("q").hidden() }
    }

    func setLogin(_ on: Bool) {
        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { NSAlert(error: error).runModal() }
        login = SMAppService.mainApp.status == .enabled
    }
}
