import AppKit
import SwiftUI

// The RAM history over 24 hours: on disk, so the Details chart, the sparklines and the growth
// check have data at once after a restart; Settings > Peaks Today. History keeps the last hour at one
// sample each 15 s; older samples fold into one point each 5 min (fold). The file is
// ~/Library/Application Support/AppMem/history.json, written at most every 5 min and at quit.
// UserDefaults key: "chartDay" (Bool: the Details chart shows 24 h).

// MARK: - Pure rules

/// The groups that a 24 h point and the file keep: 100 MB or more, the 15 largest. A group that is
/// not among them at its peak is not among the 5 peaks either, and a day stays near 100 KB.
func topGroups(_ groups: [String: Int64]) -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: groups.filter { $0.value >= 100 << 20 }.sorted { $0.value > $1.value }.prefix(15).map { ($0.key, $0.value) })
}

/// Downsampling for the 24 h points: `s` joins the last point when both fall in the same 5 min of
/// the clock (2:00 to 2:05), each number at its highest so that a peak stays; else it starts a new
/// point. Points older than 24 h drop out in add() and init?(decoding:).
/// ponytail: a point keeps the time of its first sample, so a peak's time can be up to 5 min early.
func fold(_ older: inout [Sample], _ s: Sample) {
    func slot(_ d: Date) -> Double { (d.timeIntervalSince1970 / 300).rounded(.down) }
    if let last = older.last, slot(last.at) == slot(s.at) {
        older[older.count - 1] = Sample(at: last.at, ram: max(last.ram, s.ram),
                                        groups: topGroups(last.groups.merging(s.groups, uniquingKeysWith: max)))
    } else {
        older.append(Sample(at: s.at, ram: s.ram, groups: topGroups(s.groups)))
    }
}

/// A group's highest memory in a stretch of history, and when.
struct Peak: Equatable {
    let id: String, mem: Int64, at: Date
    var name: String { String(id[..<(id.lastIndex(of: "|") ?? id.endIndex)]) }  // id = "name|isApp"
}

/// The `n` groups with the most memory since `start`, each at its peak, highest first. Not macOS:
/// it has nothing to quit, and it would take a line every day.
func peaks(_ samples: [Sample], since start: Date, n: Int = 5) -> [Peak] {
    var best: [String: Peak] = [:]
    for s in samples where s.at >= start {
        for (id, m) in s.groups where id != "macOS|false" && m > best[id]?.mem ?? 0 { best[id] = Peak(id: id, mem: m, at: s.at) }
    }
    return Array(best.values.sorted { $0.mem > $1.mem }.prefix(n))
}

/// A Peaks Today item: "Google Chrome: 3.20 GB at 2:05 PM".
func peakLine(_ p: Peak) -> String { "\(p.name): \(fmt(p.mem)) at \(p.at.formatted(date: .omitted, time: .shortened))" }

/// history.json: the group ids once, then each point with its time in whole seconds since 1970,
/// memory in MB, and its groups by their place in `ids`. Bytes and a name in each point made a
/// day about three times larger.
private struct HistoryJSON: Codable {
    struct Point: Codable { let t: Int, ram: Int, g: [Int: Int] }  // an old file's "swap" is ignored
    let ids: [String]
    let points: [Point]
}

extension History {
    /// Settings > Peaks Today.
    func peaksToday(now: Date = Date()) -> [Peak] { peaks(older + samples, since: Calendar.current.startOfDay(for: now)) }

    /// The file's content: every point, each with topGroups only (the last hour's too).
    func encoded() -> Data {
        var ids: [String] = [], place: [String: Int] = [:]
        func index(_ id: String) -> Int {
            if let i = place[id] { return i }
            ids.append(id)
            place[id] = ids.count - 1
            return ids.count - 1
        }
        let points = (older + samples).map { s in
            HistoryJSON.Point(t: Int(s.at.timeIntervalSince1970), ram: Int(s.ram >> 20),
                              g: Dictionary(uniqueKeysWithValues: topGroups(s.groups).map { (index($0.key), Int($0.value >> 20)) }))
        }
        return (try? JSONEncoder().encode(HistoryJSON(ids: ids, points: points))) ?? Data()
    }

    /// From the file's content; nil when it is not one (damaged, another format): the next save
    /// replaces it. Points older than 24 h drop out, and so do points after `now` (the clock was set
    /// back): add() takes no sample until the clock passes the last one.
    init?(decoding data: Data, now: Date = Date()) {
        guard let f = try? JSONDecoder().decode(HistoryJSON.self, from: data) else { return nil }
        let all = f.points.map { p in
            Sample(at: Date(timeIntervalSince1970: TimeInterval(p.t)), ram: Int64(p.ram) << 20,
                   groups: Dictionary(p.g.compactMap { i, mb in f.ids.indices.contains(i) ? (f.ids[i], Int64(mb) << 20) : nil },
                                      uniquingKeysWith: max))  // not uniqueKeys: a damaged file must not trap
        }.filter { $0.at <= now && now.timeIntervalSince($0.at) <= 86400 }.sorted { $0.at < $1.at }
        var older: [Sample] = []
        for s in all where now.timeIntervalSince(s.at) > 3600 { fold(&older, s) }
        self.init(samples: Array(all.filter { now.timeIntervalSince($0.at) <= 3600 }.suffix(Self.cap)), older: older)
    }
}

// MARK: - The file

/// ~/Library/Application Support/AppMem/history.json. Main thread only, except the writes.
/// ponytail: the last hour's groups of 50 to 100 MB are not saved, so after a restart their
/// sparkline and growth check start again.
enum HistoryFile {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppMem/history.json")
    private static let queue = DispatchQueue(label: "appmem.history", qos: .background)
    private static var latest: History?  // the last scan's: what the save at quit writes
    private static var savedAt = Date()  // set at the first scan: the first write comes 5 min after it
    #if DEBUG
    static var readOnly = false  // --drive (Drive.swift): it reads the file, and leaves it as it was
    #endif

    /// The Model's history at launch, so the charts have data at once. Also sets up the save at quit,
    /// of the last scan's history: so never in --snapshot, which does not scan.
    static func load() -> History {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            if let h = latest { queue.sync { write(h) } }  // sync: after a write that still runs, and before the exit
        }
        return (try? Data(contentsOf: url)).flatMap { History(decoding: $0) } ?? History()
    }

    /// After each scan: a write at most every 5 min, encoded and written off the main thread.
    static func save(_ h: History) {
        #if DEBUG
        if readOnly { return }  // no latest either: no write at quit
        #endif
        latest = h
        guard -savedAt.timeIntervalSinceNow >= 300 else { return }
        savedAt = Date()
        queue.async { write(h) }
    }

    /// Atomic: a crash or power cut in the middle leaves the old file, not half of a new one.
    private static func write(_ h: History) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? h.encoded().write(to: url, options: .atomic)
    }
}

// MARK: - UI

/// Settings > Peaks Today. `peaks`: read when the menu opens (see SettingsMenu).
struct PeaksMenu: View {
    let peaks: [Peak]

    var body: some View {
        Menu("Peaks Today") {
            if peaks.isEmpty { Text("None") }
            ForEach(peaks.indices, id: \.self) { Text(peakLine(peaks[$0])) }
        }
    }
}

/// `AppMem --test`: the 24 h history, its file and the peaks.
func dayTest() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000), mb: Int64 = 1 << 20  // a 5 min slot starts at t0
    func s(_ at: TimeInterval, ram: Int64 = 0, _ g: [String: Int64] = [:]) -> Sample {
        Sample(at: t0 + at, ram: ram * mb, groups: g.mapValues { $0 * mb })
    }

    // Downsampling: one point each 5 min of the clock, each number at its highest, at its first sample's time.
    var o: [Sample] = []
    for i in 0..<40 { fold(&o, s(Double(i) * 15, ram: 1000 + Int64(i), ["A|true": 200 + Int64(i % 7), "B|true": 60])) }
    precondition(o.map(\.at) == [t0, t0 + 300] && o.map(\.ram) == [1019 * mb, 1039 * mb])
    precondition(o[0].groups == ["A|true": 206 * mb])  // B: under 100 MB
    do {  // a restart with an empty last hour: nothing folds, but each add drops the points older than 24 h
        var r = History(older: o)
        r.add([], sys: SysMem(), at: t0 + 86401)
        precondition(r.older.map(\.at) == [t0 + 300] && r.samples.count == 1)
    }
    // From add: the samples that leave the last hour.
    var h = History()
    let big = [Group(name: "Big", isApp: true, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: "/b", mem: 150 * mb)])]
    for i in 0...480 { h.add(big, sys: SysMem(), at: t0 + Double(i) * 15) }  // 2 h
    precondition(h.samples.count == History.cap && h.older.count == 13 && h.older.allSatisfy { $0.groups == ["Big|true": 150 * mb] })

    // The cap: 100 MB or more, the 15 largest.
    let many = Dictionary(uniqueKeysWithValues: (1...30).map { ("G\($0)|true", Int64($0) * 10 * mb) })  // 10 MB to 300 MB
    precondition(Set(topGroups(many).keys) == Set((16...30).map { "G\($0)|true" }) && topGroups(["A|true": 100 * mb]).count == 1)
    // A full day, 20 groups of GBs in each point, 40 names: the file stays under 200 KB.
    let names = (0..<40).map { "Some Application Name \($0 + 10)|true" }
    func full(_ at: TimeInterval, _ k: Int) -> Sample {
        Sample(at: t0 + at, ram: 15_000 * mb,
               groups: Dictionary(uniqueKeysWithValues: (0..<20).map { (names[(k + $0) % 40], Int64(10_000 + $0) * mb) }))
    }
    let day = History(samples: (0..<240).map { full(82800 + Double($0) * 15, $0) }, older: (0..<276).map { full(Double($0) * 300, $0) })
    let file = day.encoded(), back = History(decoding: file, now: t0 + 86399)!
    precondition(file.count < 200_000 && back.samples.count == 240 && back.older.count == 276)
    precondition(back.older.allSatisfy { $0.groups.count == 15 } && back.samples[5].groups == topGroups(day.samples[5].groups))

    // Round trip: times in seconds, memory in MB; the last hour's points keep only topGroups.
    let two = History(samples: [s(86370, ram: 9000, ["A|true": 300, "B|false": 50]), s(86385, ram: 9100, ["A|true": 320])],
                      older: [s(0, ram: 8000, ["A|true": 250, "macOS|false": 3000]), s(300, ram: 8100)])
    let rt = History(decoding: two.encoded(), now: t0 + 86400)!
    precondition(rt.samples.map(\.at) == two.samples.map(\.at) && rt.samples.map(\.ram) == two.samples.map(\.ram))
    precondition(rt.samples[0].groups == ["A|true": 300 * mb])
    precondition(rt.older.map(\.at) == two.older.map(\.at) && rt.older.map(\.groups) == two.older.map(\.groups))
    // An hour later: the last hour's points fold into one 5 min point, the first two are older than 24 h.
    let later = History(decoding: two.encoded(), now: t0 + 90000)!
    precondition(later.samples.isEmpty && later.older.map(\.at) == [t0 + 86370] && later.older[0].ram == 9100 * mb)
    precondition(later.older[0].groups == ["A|true": 320 * mb])
    // Damaged or another format: nil, so the next save replaces it. An unknown place drops; a future point drops; an old "swap" is ignored.
    precondition(History(decoding: Data("{".utf8)) == nil && History(decoding: Data()) == nil && History(decoding: Data("[]".utf8)) == nil)
    precondition(History(decoding: Data(#"{"ids":[],"points":[{"t":1}]}"#.utf8)) == nil)
    let odd = #"{"ids":["A|true","A|true"],"points":[{"t":1800000000,"ram":1,"swap":0,"g":{"0":200,"1":300,"7":400}},{"t":1800003000,"ram":2,"swap":0,"g":{}}]}"#
    let oh = History(decoding: Data(odd.utf8), now: t0 + 60)!
    precondition(oh.samples.count == 1 && oh.samples[0].groups == ["A|true": 300 * mb] && oh.older.isEmpty)

    // Peaks: the highest of each group since the start, macOS left out.
    let p = [s(0, ["A|true": 900, "B|true": 500, "macOS|false": 5000]), s(300, ["A|true": 1200, "C|true": 700]),
             s(600, ["A|true": 1200, "B|true": 400, "D|true": 300, "E|true": 200, "F|true": 150])]
    precondition(peaks(p, since: t0) == [Peak(id: "A|true", mem: 1200 * mb, at: t0 + 300), Peak(id: "C|true", mem: 700 * mb, at: t0 + 300),
                                         Peak(id: "B|true", mem: 500 * mb, at: t0), Peak(id: "D|true", mem: 300 * mb, at: t0 + 600),
                                         Peak(id: "E|true", mem: 200 * mb, at: t0 + 600)])
    precondition(peaks(p, since: t0 + 301).map(\.name) == ["A", "B", "D", "E", "F"] && peaks(p, since: t0 + 301)[1].mem == 400 * mb)
    precondition(peaks([], since: t0).isEmpty && Peak(id: "A|B|true", mem: 0, at: t0).name == "A|B")
    precondition(peakLine(Peak(id: "Google Chrome|true", mem: 1200 * mb, at: t0)) == "Google Chrome: 1.17 GB at " + t0.formatted(date: .omitted, time: .shortened))
    precondition(History(samples: [Sample(at: Date(), ram: 0, groups: ["A|true": mb])]).peaksToday().map(\.id) == ["A|true"])
}
