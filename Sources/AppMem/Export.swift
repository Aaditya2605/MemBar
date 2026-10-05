import AppKit
import UniformTypeIdentifiers

// Gear menu > Save Report…: the report as a file. Markdown (Copy Report's text), CSV (one
// row per process, for a spreadsheet) or JSON (the shape of --json, for scripts).

/// A group's flags in the reports, as its row's badges say: report()'s and csvReport()'s.
func flagWords(_ g: Group) -> [String] {
    [g.orphan ? "orphan" : g.leftover ? "leftover" : nil, g.respawns == nil ? nil : "respawns"].compactMap { $0 }
}

/// One CSV field (RFC 4180): quoted when it holds a comma, a quote or a line break, its quotes doubled.
func csvField(_ s: String) -> String {
    s.contains { $0 == "," || $0 == "\"" || $0.isNewline } ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
}

/// One row per process, the groups in the order given. Memory in bytes, CPU in % of one core,
/// ports and flags separated by spaces. `flags`: the ones the group alone does not tell, as for
/// report(); "paused" is the process's own.
func csvReport(_ groups: [Group], flags: (Group) -> [String] = { _ in [] }, user: (uid_t) -> String = userName) -> String {
    var lines = ["group,pid,name,user,memory_bytes,cpu_percent,ports,flags"]
    for g in groups {
        let f = flagWords(g) + flags(g)
        for p in g.procs {
            lines.append([g.name, String(p.pid), p.name, user(p.uid), String(p.mem), String(format: "%.1f", p.cpu),
                          p.ports.map(String.init).joined(separator: " "), (f + (p.stopped ? ["paused"] : [])).joined(separator: " ")]
                .map(csvField).joined(separator: ","))
        }
    }
    return lines.map { $0 + "\n" }.joined()
}

extension Model {
    /// The type picked in the save panel's popup picks the format. The numbers of the click, not
    /// of the scans while the panel is open.
    /// ponytail: macOS 14 has no type popup (showsContentTypes is 15+); there the typed
    /// extension (.md, .csv, .json) picks the format.
    func saveReport() {
        let groups = groups, sys = sys, flags = reportFlags, date = Date()
        // Async: the gear menu is not done yet. A panel of its own, not a sheet on the popover:
        // when the transient popover closes, the panel stays.
        DispatchQueue.main.async {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd HH.mm"  // no ":" in a file name
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md")!, .commaSeparatedText, .json]
            if #available(macOS 15, *) { panel.showsContentTypes = true }
            panel.isExtensionHidden = false  // the extension is the format
            panel.showsTagField = false  // its tags would be ours to set
            panel.nameFieldStringValue = "AppMem Report \(df.string(from: date)).md"  // with its extension: else ".05" of the time reads as one
            NSApp.activate(ignoringOtherApps: true)  // else the panel opens behind the frontmost app
            // begin, not runModal: a modal loop inside this main-queue block holds back every other
            // main-queue job (scans, pressure, SIGTERM, the reopen after a quit) until the panel closes.
            panel.begin { r in
                guard r == .OK, let url = panel.url else { return }
                let text = switch url.pathExtension.lowercased() {
                case "csv": csvReport(groups, flags: flags)
                case "json": String(decoding: jsonReport(groups, sys: sys, cpu: true), as: UTF8.self) + "\n"
                default: report(groups: groups, sys: sys, date: date, flags: flags) + "\n"
                }
                // ponytail: this alert is modal and can hold back main-queue jobs too; a failed write is rare and the alert short.
                do { try Data(text.utf8).write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
            }
        }
    }
}
