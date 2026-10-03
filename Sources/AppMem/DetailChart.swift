import Charts
import SwiftUI

// The Details window's header: the group's memory over the last hour or 24 hours (History,
// Day.swift), its memory now, lowest and highest in that range, when it peaked, and its CPU now.
// A view of its own: a hover redraws the header only, not the table (it reads threads per row).

/// One group's memory over time, in runs: a new run where the group has no point (gone, under
/// 50 MB, not measured) or where no sample came for 10 min (asleep, AppMem quit), so the chart
/// breaks its line there and draws no slope over a time it knows nothing about.
/// ponytail: one 10 min gap for both ranges (a 24 h point is 5 min), so a shorter sleep in the
/// last hour is a straight line.
func groupSeries(_ id: String, _ samples: [Sample]) -> [(at: Date, mem: Int64, run: Int)] {
    var out: [(at: Date, mem: Int64, run: Int)] = [], run = 0, missed = false, prev: Date?
    for s in samples {
        defer { prev = s.at }
        guard let m = s.groups[id] else { missed = true; continue }
        if !out.isEmpty, missed || prev.map({ s.at.timeIntervalSince($0) > 600 }) == true { run += 1 }
        missed = false
        out.append((s.at, m, run))
    }
    return out
}

/// The lowest and the highest memory, and when it was highest: the first time, as peaks(). nil for none.
func extremes(_ points: [(at: Date, mem: Int64)]) -> (lo: Int64, hi: Int64, at: Date)? {
    guard let lo = points.map(\.mem).min(), let top = points.max(by: { $0.mem < $1.mem }) else { return nil }
    return (lo, top.mem, top.at)
}

/// The point nearest to `t`: the hover's.
func nearest(_ points: [(at: Date, mem: Int64, run: Int)], to t: Date) -> Int? {
    points.indices.min { abs(points[$0].at.timeIntervalSince(t)) < abs(points[$1].at.timeIntervalSince(t)) }
}

/// The time of a peak or a hovered point; with the day when not today ("Fri 9:40 PM"): the 24 h range.
func whenText(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> String {
    cal.isDate(d, inSameDayAs: now) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// 1 h / 24 h: the panel's header chart and the Details header share the choice ("chartDay").
struct RangePicker: View {
    @Binding var day: Bool

    var body: some View {
        Picker("Chart Range", selection: $day) {
            Text("1 h").tag(false).accessibilityLabel("1 hour")
            Text("24 h").tag(true).accessibilityLabel("24 hours")
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Show the last hour or the last 24 hours")
    }
}

struct DetailChart: View {
    let history: History, g: Group
    @AppStorage("chartDay") private var day = false
    @State private var hover: Date?

    var body: some View {
        let all = groupSeries(g.id, history.older + history.samples)
        if all.isEmpty {
            Text("No memory history: AppMem keeps one for groups of 50 MB or more.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
        } else {
            // The last hour can be empty while the 24 h are not (after a long quit): the picker stays.
            let now = Date(), pts = day ? all : groupSeries(g.id, history.samples)
            let x = pts.isEmpty ? nil : extremes(pts.map { ($0.at, $0.mem) } + [(now, g.mem)])  // now too: never "highest" under "now"
            let range = day ? "In the last 24 hours and now. Before the last hour: the highest of each 5 min, for groups of 100 MB or more."
                : "In the last hour and now: one sample each 15 s, each minute while the panel and this window are closed."
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    RangePicker(day: $day).controlSize(.small)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        row("Now", fmt(g.mem), help: "The memory of all its processes")
                        row("Lowest", x.map { fmt($0.lo) } ?? "–", help: range)
                        row("Highest", x.map { fmt($0.hi) } ?? "–", x.map { "at \(whenText($0.at, now: now))" }, help: range)
                        row("CPU", cpu(g.cpu), help: cpuHelp(g))
                    }
                    .font(.callout).monospacedDigit()
                }
                // At least 210: the chart does not shift as the numbers change width. Wider, never cut, for
                // a long peak time: "at Wed 12:40 PM" in a 12-hour clock.
                .fixedSize().frame(minWidth: 210, alignment: .leading)
                if let x {
                    chart(pts, now: now, span: day ? 86400 : 3600, top: x.hi)
                } else {
                    Text("No samples in the last hour").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 90)
            .padding(10)
        }
    }

    func row(_ name: String, _ value: String, _ note: String? = nil, help: String) -> some View {
        // A GridRow gives its modifiers to each cell, as a Group, so it cannot combine them: the value
        // cell reads the row, "Highest, 5.34 GB, at 08:50", one line for VoiceOver.
        GridRow {
            Text(name).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(value).gridColumnAlignment(.trailing)
                .accessibilityLabel(name).accessibilityValue([value, note].compactMap { $0 }.joined(separator: ", "))
            if let note { Text(note).foregroundStyle(.secondary).accessibilityHidden(true) }
        }
        .help(help)  // on each cell: the whole row shows it
    }

    /// `pts`: not empty. From 0, as the sparkline: a leak looks steep, noise flat. In MB or GB, so the
    /// axis has round numbers. No animation: the hover follows the pointer at once.
    func chart(_ pts: [(at: Date, mem: Int64, run: Int)], now: Date, span: TimeInterval, top: Int64) -> some View {
        let unit: Double = top >= 1 << 30 ? 1_073_741_824 : 1_048_576
        return Chart {
            ForEach(pts.indices, id: \.self) { i in line(pts, i, unit: unit) }
            if let i = hover.flatMap({ nearest(pts, to: $0) }) { picked(pts[i], now: now, unit: unit) }
        }
        // The oldest point can be a little older than the span: History trims by its newest sample's time, before now.
        .chartXScale(domain: min(now - span, pts[0].at)...now)
        .chartYScale(domain: 0...Double(max(top, 1)) / unit * 1.25)  // headroom: the hover's label sits above the line
        .chartXSelection(value: $hover)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in  // aligned: a label at now is not cut off
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())  // hour() alone reads "15" in a 24-hour clock
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { Text(v.as(Double.self).map { String(format: "%g", $0) + (unit > 1_048_576 ? " GB" : " MB") } ?? "") }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory in the last \(span > 3600 ? "24 hours" : "hour"), from \(fmt(pts[0].mem)) to \(fmt(pts[pts.count - 1].mem))")
    }

    /// Point `i`: its run's area and line; a dot when it is a run of its own, as a line needs two points.
    @ChartContentBuilder func line(_ pts: [(at: Date, mem: Int64, run: Int)], _ i: Int, unit: Double) -> some ChartContent {
        let p = pts[i], x: PlottableValue<Date> = .value("Time", p.at), y: PlottableValue<Double> = .value("Memory", Double(p.mem) / unit)
        AreaMark(x: x, y: y, series: .value("Run", p.run), stacking: .unstacked)
            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.05)], startPoint: .top, endPoint: .bottom))
        LineMark(x: x, y: y, series: .value("Run", p.run)).foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 1.5))
        if (i == 0 || pts[i - 1].run != p.run) && (i == pts.count - 1 || pts[i + 1].run != p.run) {
            PointMark(x: x, y: y).symbolSize(12).foregroundStyle(Color.accentColor)
        }
    }

    /// The hovered point: a rule, a dot, and its memory and time above.
    @ChartContentBuilder func picked(_ p: (at: Date, mem: Int64, run: Int), now: Date, unit: Double) -> some ChartContent {
        RuleMark(x: .value("Time", p.at)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                Text("\(fmt(p.mem))  \(whenText(p.at, now: now))").font(.caption).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            }
        PointMark(x: .value("Time", p.at), y: .value("Memory", Double(p.mem) / unit)).symbolSize(30).foregroundStyle(Color.accentColor)
    }
}

/// `AppMem --test`: the Details chart's series, its numbers and the hover.
func detailChartTest() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000), mb: Int64 = 1 << 20
    func s(_ at: TimeInterval, _ g: [String: Int64]) -> Sample { Sample(at: t0 + at, ram: 0, swap: 0, groups: g.mapValues { $0 * mb }) }
    // Missing points, gone and back, and a 10 min gap with no sample start a new run; other groups do not matter.
    let samples = [s(0, ["B|true": 9]), s(15, ["A|true": 100, "B|true": 9]), s(30, ["A|true": 120, "B|true": 9]), s(45, ["B|true": 9]),  // A gone
                   s(60, ["A|true": 300]), s(75, ["A|true": 310]), s(676, ["A|true": 200]), s(691, ["A|true": 200]), s(1291, ["A|true": 50])]
    let a = groupSeries("A|true", samples)
    precondition(a.map(\.run) == [0, 0, 1, 1, 2, 2, 2] && a.map(\.mem) == [100, 120, 300, 310, 200, 200, 50].map { $0 * mb })
    precondition(a.map(\.at) == [15, 30, 60, 75, 676, 691, 1291].map { t0 + $0 })  // 601 s with no sample is a gap, 600 is not
    precondition(groupSeries("A|true", [s(0, [:]), s(15, ["A|true": 1])]).map(\.run) == [0] && groupSeries("C|true", samples).isEmpty)
    precondition(groupSeries("A|true", []).isEmpty && groupSeries("B|true", samples).map(\.run) == [0, 0, 0, 0])  // gone at the end: no run to start
    // Lowest, highest, and the first time it was highest.
    let x = extremes(a.map { ($0.at, $0.mem) })!
    precondition(x.lo == 50 * mb && x.hi == 310 * mb && x.at == t0 + 75 && extremes([]) == nil)
    precondition(extremes([(t0, 5), (t0 + 1, 7), (t0 + 2, 7)])!.at == t0 + 1 && extremes([(t0, 5)])! == (5, 5, t0))
    precondition(nearest(a, to: t0 + 70) == 3 && nearest(a, to: t0) == 0 && nearest(a, to: t0 + 9999) == 6 && nearest([], to: t0) == nil)
    let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    precondition(whenText(noon - 3600, now: noon) == (noon - 3600).formatted(date: .omitted, time: .shortened))
    precondition(whenText(noon - 86400, now: noon) == (noon - 86400).formatted(.dateTime.weekday(.abbreviated).hour().minute()))
}
