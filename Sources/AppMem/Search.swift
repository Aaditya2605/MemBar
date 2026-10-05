import AppKit
import SwiftUI

// Power search: words in the panel's search that filter by state, size, port, user or PID
// ("leftover", ">1gb", "cpu>5", ":3000", "user:root", "pid:123"), with free text as before:
// "leftover >1gb node". Every token must hold; the other words, joined, are today's text
// (a group name, a process name, a PID or a port, see matching).
// ponytail: a token wins over a name, so a process named "idle" is found only by its PID.

struct Search {
    enum Token: Hashable {
        case leftover, orphan, paused, growing, idle, new, ignored
        case memOver(Int64), memUnder(Int64), cpuOver(Double)  // the group's memory and CPU %
        case port(UInt16), user(String), pid(pid_t)  // these pick processes: the hits shown in the group

        var picksProcs: Bool { switch self { case .port, .user, .pid: true; default: false } }
    }

    /// What the Group alone does not tell: from History, Usage, the mark and the Never Flagged list.
    struct Facts { var growing = false, idle = false, new = false, ignored = false }

    var tokens: [Token] = [], text = ""
    var isEmpty: Bool { tokens.isEmpty && text.isEmpty }

    /// Any case. A word that only looks like a token (">1tb", "cpu>x", "pid:abc") is text. A bare prefix
    /// (the filter menu's "port:", "pid:", or ":" typed before 3000) waits for its number, not "No Results".
    init(_ query: String) {
        var words: [Substring] = []
        for w in query.lowercased().split(whereSeparator: \.isWhitespace) where ![":", "port:", "pid:"].contains(w) {
            if let t = Token(w) { tokens.append(t) } else { words.append(w) }
        }
        text = words.joined(separator: " ")
    }
}

extension Search.Token {
    /// A word of the lower-cased query as a token; nil: it is text.
    init?(_ w: Substring) {
        let flags: [Substring: Self] = ["leftover": .leftover, "orphan": .orphan, "paused": .paused, "growing": .growing,
                                        "idle": .idle, "new": .new, "ignored": .ignored]
        let cpu = w.hasPrefix("cpu>") ? Double(w.hasSuffix("%") ? w.dropFirst(4).dropLast() : w.dropFirst(4)) : nil
        let port = w.hasPrefix(":") ? UInt16(w.dropFirst()) : w.hasPrefix("port:") ? UInt16(w.dropFirst(5)) : nil
        if let t = flags[w] { self = t }
        else if w.first == ">" || w.first == "<", let b = Self.bytes(w.dropFirst()) { self = w.first == ">" ? .memOver(b) : .memUnder(b) }
        else if let cpu, (0..<1e6).contains(cpu) { self = .cpuOver(cpu) }  // not inf or nan
        else if let port { self = .port(port) }
        else if w.hasPrefix("user:"), w.count > 5 { self = .user(String(w.dropFirst(5))) }
        else if w.hasPrefix("pid:"), let pid = pid_t(w.dropFirst(4)) { self = .pid(pid) }
        else { return nil }
    }

    /// "1gb", "1.5gb", "500mb" in bytes. nil for another unit, or inf and nan, which Int64() traps on.
    static func bytes(_ s: Substring) -> Int64? {
        guard let unit: Double = s.hasSuffix("gb") ? 1073741824 : s.hasSuffix("mb") ? 1048576 : nil,
              let v = Double(s.dropLast(2)), (0..<1e6).contains(v) else { return nil }
        return Int64(v * unit)
    }

    /// A size as typed: "1 GB", "1.5 GB", "500 MB" (fmt would say "1.00 GB").
    static func size(_ b: Int64) -> String {
        b >= 1 << 30 ? String(format: "%g GB", Double(b) / 1073741824) : String(format: "%g MB", Double(b) / 1048576)
    }

    /// The token in words, for the empty result.
    var label: String {
        switch self {
        case .leftover: "leftover"
        case .orphan: "orphan"
        case .paused: "paused"
        case .growing: "growing"
        case .idle: "idle"
        case .new: "new since the mark"
        case .ignored: "never flagged"
        case .memOver(let b): "over \(Self.size(b))"
        case .memUnder(let b): "under \(Self.size(b))"
        case .cpuOver(let v): "CPU over \(String(format: "%g", v))%"
        case .port(let n): "port \(n)"
        case .user(let u): "user \(u)"
        case .pid(let n): "PID \(n)"
        }
    }
}

/// Does `t` hold for group `g`? A process token holds when one of its processes matches.
func matches(_ t: Search.Token, _ g: Group, _ f: Search.Facts = .init()) -> Bool {
    switch t {
    case .leftover: g.leftover
    case .orphan: g.orphan
    case .paused: isPaused(g)
    case .growing: f.growing
    case .idle: f.idle
    case .new: f.new
    case .ignored: g.ignored || f.ignored  // an unflagged leftover, or an app on the list that is open
    case .memOver(let b): g.mem > b
    case .memUnder(let b): g.mem < b
    case .cpuOver(let v): g.cpu > v
    case .port, .user, .pid: g.procs.contains { matches(t, $0) }
    }
}

/// Does process token `t` hold for `p`? A group token: no process decides it.
func matches(_ t: Search.Token, _ p: Proc) -> Bool {
    switch t {
    case .port(let n): p.ports.contains(n)
    case .user(let u): userName(p.uid).lowercased() == u || String(p.uid) == u
    case .pid(let n): p.pid == n
    default: true
    }
}

/// The search hits inside `g`, shown expanded: the processes that the process tokens and the
/// text pick. nil when none picks: no process token, and no text or the group's name has it.
func hits(_ g: Group, _ s: Search) -> [Proc]? {
    let picks = s.tokens.filter(\.picksProcs), named = s.text.isEmpty || g.name.lowercased().contains(s.text)
    if picks.isEmpty && named { return nil }
    return (named ? g.procs : matching(g, s.text)).filter { p in picks.allSatisfy { matches($0, p) } }
}

/// A group the search keeps: each group token holds, and it has hits when anything picks them.
func found(_ g: Group, _ s: Search, _ f: Search.Facts = .init()) -> Bool {
    s.tokens.allSatisfy { $0.picksProcs || matches($0, g, f) } && hits(g, s)?.isEmpty != true
}

/// The empty result's words: "Filters: leftover, over 1 GB", the text, and why "new" finds nothing with no mark.
func noResultsText(_ s: Search, marked: Bool = true) -> String {
    "Filters: " + s.tokens.map(\.label).joined(separator: ", ") + (s.text.isEmpty ? "" : "\nText: “\(s.text)”")
        + (!marked && s.tokens.contains(.new) ? "\nNo mark yet: the flag button sets one." : "")
}

extension Panel {
    /// The groups the search keeps. History's line fit, Usage and the mark are read only for a
    /// token that asks: the search runs on each key and each scan.
    func searched(_ q: Search) -> [Group] {
        let need = Set(q.tokens), d = need.contains(.new) ? markDelta : nil
        let never = need.contains(.ignored) ? UserDefaults.standard.ignored : []
        return model.groups.filter { g in
            found(g, q, Search.Facts(growing: need.contains(.growing) && growthText(model.history.points(g.id)) != nil,
                                     idle: need.contains(.idle) && Usage.idle(g) != nil,
                                     new: d?.new.contains(g.id) == true, ignored: never.contains(g.name)))
        }
    }

    /// The filter menu's choice, after the typed text. The field gets the focus with the caret
    /// at the end, so typing goes on (the number after "pid:").
    func insert(_ token: String) {
        let typed = query.trimmingCharacters(in: .whitespaces)
        query = (typed.isEmpty ? "" : typed + " ") + token
        focus = .search
        DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
    }
}

extension View {
    /// The search field with its filter menu on the right.
    func searchMenu(marked: Bool, insert: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) { self; SearchMenu(marked: marked, insert: insert) }
    }
}

/// Each token with what it keeps; choosing one adds it to the search. A trailing space ends a
/// whole token; "port:" and "pid:" wait for a number.
struct SearchMenu: View {
    let marked: Bool  // "new" needs a mark
    let insert: (String) -> Void
    static let state = [("leftover", "Its app is not open"), ("orphan", "Left by a terminal or an agent"),
                        ("paused", "Its processes do not run"), ("growing", "Memory keeps growing"),
                        ("idle", "Open, not used for 2 hours"), ("new", "New since the mark"), ("ignored", "Never flagged")]
    static let size = [(">1gb", "Memory over 1 GB"), (">500mb", "Memory over 500 MB"), ("<100mb", "Memory under 100 MB"), ("cpu>5", "CPU over 5%")]
    static let procs = [("port:", "Listens on a port: port:3000 or :3000"), ("user:root", "Has processes of a user"), ("pid:", "One process by its PID")]

    var body: some View {
        Menu {
            items(Self.state)
            Divider()
            items(Self.size)
            Divider()
            items(Self.procs)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        .help("Filters: leftover, orphan, paused, growing, idle, new, ignored, >1gb, <100mb, cpu>5, :3000, user:root, pid:123")
        .accessibilityLabel("Search filters")
    }

    func items(_ list: [(String, String)]) -> some View {
        ForEach(list, id: \.0) { token, help in
            Button("\(token) — \(help)") { insert(token.hasSuffix(":") ? token : token + " ") }
                .disabled(token == "new" && !marked)
        }
    }
}

/// No group matches. With tokens, the filters in words: a token that hides everything ("new"
/// with no mark), or a word read as text (">1tb"), is plain to see.
struct NoResults: View {
    let typed: String, q: Search, marked: Bool

    var body: some View {
        if q.tokens.isEmpty {
            ContentUnavailableView.search(text: typed)
        } else {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text(noResultsText(q, marked: marked)))
        }
    }
}
