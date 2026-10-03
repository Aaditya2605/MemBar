import Charts
import SwiftUI

// RAM history for the last hour: the header chart, the "growing" badge and the
// sparkline of an expanded group. In memory only; it starts empty at each launch.

struct Sample {
    let at: Date
    let ram: Int64, swap: Int64
    let groups: [String: Int64]  // group id → memory, only for groups of 50 MB or more
}

struct History {
    private(set) var samples: [Sample] = []
    static let cap = 240  // 60 min at one sample each 15 s

    /// One sample per scan, but at most one each 15 s: the open panel scans every 2-5 s.
    mutating func add(_ groups: [Group], sys: SysMem, at now: Date = Date()) {
        // ponytail: wall clock, so a clock set back stops new samples until it catches up.
        if let last = samples.last, now.timeIntervalSince(last.at) < 15 { return }
        let big = groups.filter { $0.mem >= 50 << 20 }
        samples.append(Sample(at: now, ram: sys.ram, swap: sys.swap,
                              groups: Dictionary(uniqueKeysWithValues: big.map { ($0.id, $0.mem) })))
        samples.removeAll { now.timeIntervalSince($0.at) > 3600 }
        if samples.count > Self.cap { samples.removeFirst(samples.count - Self.cap) }
    }

    /// One group's memory over time; it has no point when it was below 50 MB or not running.
    func points(_ id: String) -> [(at: Date, mem: Int64)] {
        samples.compactMap { s in s.groups[id].map { (s.at, $0) } }
    }
}

/// The growth when memory rose by 25% and 300 MB or more across 15 min or more, and
/// mostly rose: a least-squares line fits well (R² >= 0.8). A spike or a single step
/// up fits a line badly (R² <= 0.75); noise around a climb fits it well.
/// ponytail: one line over the whole history, so a leak that starts after a long flat
/// stretch shows only when it covers about half of it; fit the newest 20 min too if
/// that is too late.
func isGrowing(_ points: [(at: Date, mem: Int64)]) -> Int64? {
    guard let t0 = points.first?.at, let t1 = points.last?.at, t1.timeIntervalSince(t0) >= 15 * 60 else { return nil }
    let xs = points.map { $0.at.timeIntervalSince(t0) }, ys = points.map { Double($0.mem) }
    let n = Double(points.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
    guard syy > 0 else { return nil }  // flat
    let slope = sxy / sxx, rise = slope * t1.timeIntervalSince(t0), start = my - slope * mx
    guard sxy * sxy / (sxx * syy) >= 0.8, rise >= 300 * 1048576, rise >= 0.25 * start else { return nil }
    return Int64(rise)
}

/// "+600 MB in 30 min" for a group that grows, else nil.
func growthText(_ points: [(at: Date, mem: Int64)]) -> String? {
    guard let g = isGrowing(points), let a = points.first?.at, let b = points.last?.at else { return nil }
    return "+\(fmt(g)) in \(mins(b.timeIntervalSince(a)))"
}

func mins(_ t: TimeInterval) -> String { "\(max(1, Int((t / 60).rounded()))) min" }

/// Header: RAM used (area) and swap (line, when there is any), from 0 to all the RAM,
/// so the height reads as "how full".
struct RAMChart: View {
    let samples: [Sample]

    var body: some View {
        if let a = samples.first, let b = samples.last, samples.count >= 2 {
            let swap = samples.contains { $0.swap > 0 }
            let top = max(Int64(ProcessInfo.processInfo.physicalMemory), samples.map(\.swap).max() ?? 0)
            let ram = samples.map(\.ram)
            let label = "RAM used in the last \(mins(b.at.timeIntervalSince(a.at))): lowest \(fmt(ram.min()!)), highest \(fmt(ram.max()!))"
                + (swap ? ". Swap: highest \(fmt(samples.map(\.swap).max()!))" : "")
            Chart(samples, id: \.at) { s in
                AreaMark(x: .value("Time", s.at), y: .value("RAM", Double(s.ram)))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.at), y: .value("RAM", Double(s.ram)), series: .value("Series", "RAM"))
                    .foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 1))
                if swap {
                    LineMark(x: .value("Time", s.at), y: .value("Swap", Double(s.swap)), series: .value("Series", "Swap"))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartXScale(domain: a.at...b.at)
            .chartYScale(domain: 0...Double(top))
            .frame(height: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .help(label)
        } else {  // same height, so the list does not jump when the second sample comes
            Text("RAM history starts in 15 s").font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
    }
}

/// Expanded group: its memory history, from 0 so that a leak looks steep and noise flat.
struct Sparkline: View {
    let points: [(at: Date, mem: Int64)]
    let growing: Bool

    var body: some View {
        let mem = points.map { $0.mem }, top = mem.max() ?? 0, lo = fmt(mem.min() ?? 0), hi = fmt(top)
        let text = "\(mins(points.last!.at.timeIntervalSince(points.first!.at))): \(lo == hi ? hi : "\(lo) to \(hi)")"
        let color = growing ? Color.red : Color.secondary
        HStack(spacing: 6) {
            Chart(points.indices, id: \.self) { i in
                AreaMark(x: .value("Time", points[i].at), y: .value("Memory", Double(points[i].mem)))
                    .foregroundStyle(color.opacity(0.15))
                LineMark(x: .value("Time", points[i].at), y: .value("Memory", Double(points[i].mem)))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...Double(max(top, 1)) * 1.15)  // headroom: a flat line is not an underline
            .frame(width: 150, height: 16)  // fixed, so the sparklines line up; 150 leaves room for "10.24 GB to 12.50 GB"
            Text(text).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory in the last \(text)")
    }
}

#if DEBUG
extension History {
    /// `HISTORY=1 AppMem --snapshot ...`: an hour of made-up samples around the live
    /// numbers, so the chart, badge and sparkline show without an hour of waiting.
    /// The largest group grows from half its size, so it gets the badge.
    static func demo(_ groups: [Group], sys: SysMem) -> History {
        var h = History()
        let now = Date(), big = groups.max { $0.mem < $1.mem }?.id
        for i in 0..<cap {
            let f = Double(i) / Double(cap - 1), wave = sin(Double(i) / 7)
            let gs = groups.filter { $0.mem >= 50 << 20 }.map { g in
                (g.id, g.id == big ? Int64(Double(g.mem) * (0.5 + 0.5 * f + 0.02 * wave)) : g.mem)
            }
            h.samples.append(Sample(at: now - Double(cap - 1 - i) * 15, ram: Int64(Double(sys.ram) * (0.9 + 0.1 * f + 0.02 * wave)),
                                    swap: Int64(Double(sys.swap) * f), groups: Dictionary(uniqueKeysWithValues: gs)))
        }
        return h
    }
}
#endif

/// `AppMem --test`: the history parts of the self-check.
func historySelfTest() {
    let t0 = Date(timeIntervalSince1970: 0), mb: Int64 = 1 << 20
    func series(_ minutes: Int, _ f: (Int) -> Double) -> [(at: Date, mem: Int64)] {
        (0...minutes * 4).map { i in (t0 + Double(i) * 15, Int64(f(i) * Double(mb))) }  // one each 15 s
    }
    precondition(abs(isGrowing(series(30) { 1000 + Double($0) * 10 })! - 1200 * mb) < mb)  // steady: +40 MB a minute
    precondition(isGrowing(series(30) { _ in 1000 }) == nil)  // flat
    // noisy but rising: half the steps go down, but the line fits (R² ≈ 0.92)
    precondition(isGrowing(series(30) { 1000 + Double($0) * 10 + ($0 % 2 == 0 ? 100 : -100) }) != nil)
    precondition(isGrowing(series(30) { 1000 + ($0 >= 40 && $0 < 50 ? 1500 : 0) }) == nil)  // spike, then drop
    precondition(isGrowing(series(30) { 1000 + Double(min($0, 120 - $0)) * 25 }) == nil)  // rise, then drop
    precondition(isGrowing(series(30) { $0 < 60 ? 1000 : 2000 }) == nil)  // one step up: not a leak
    precondition(isGrowing(series(14) { 1000 + Double($0) * 50 }) == nil)  // short history
    precondition(isGrowing(series(30) { 400 + Double($0) * 2 }) == nil)  // +240 MB: below 300 MB
    precondition(isGrowing(series(30) { 4000 + Double($0) * 3 }) == nil)  // +360 MB: below 25%
    precondition(growthText(series(30) { 1000 + Double($0) * 5 }) == "+600 MB in 30 min")

    var h = History()
    let g = [Group(name: "Big", isApp: true, procs: [Proc(pid: 2, ppid: 1, uid: 501, path: "/b", mem: 60 * mb)]),
             Group(name: "Small", isApp: true, procs: [Proc(pid: 3, ppid: 1, uid: 501, path: "/s", mem: 10 * mb)])]
    h.add(g, sys: SysMem(), at: t0)
    h.add(g, sys: SysMem(), at: t0 + 5)  // under 15 s after the last one: skipped
    precondition(h.samples.count == 1 && h.samples[0].groups == ["Big|true": 60 * mb])
    for i in 1...600 { h.add(g, sys: SysMem(), at: t0 + Double(i) * 15) }  // 2.5 h, one each 15 s
    precondition(h.samples.count == History.cap && h.points("Big|true").count == History.cap)
    precondition(h.points("Small|true").isEmpty)
    for i in 1...120 { h.add(g, sys: SysMem(), at: t0 + 9000 + Double(i) * 60) }  // panel closed: one a minute
    precondition(h.samples.count == 61)  // only the last hour
}
