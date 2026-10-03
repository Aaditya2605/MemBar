import AppKit

// Settings > Menu Bar Shows > RAM Graph: the chip, then a small graph of RAM used in the
// last half hour, from History. The area under the line has the pressure color. A new
// image only when History has a new sample (each minute with the panel closed), never per
// frame; it draws itself again only when the menu bar does (dark and light).

/// The graph's samples: one a minute, the newest 29 (the last 28 min), oldest first. The open panel adds a sample each 15 s: thinned, so the line does
/// not squeeze the minutes before the panel opened.
func graphSamples(_ samples: [Sample]) -> [Sample] {
    var out: [Sample] = []
    // 55 s, not 60: with the panel closed a scan comes each 60 to 70 s (timer tolerance), and each counts.
    for s in samples.reversed() where out.count < 29 && out.last.map({ $0.at.timeIntervalSince(s.at) >= 55 }) ?? true {
        out.append(s)
    }
    return out.reversed()
}

/// The line in a `size` image: the values over the full width, one value as a flat line.
/// y from 0 to all the RAM (`top`), as the header chart: the height reads as how full, and
/// noise stays flat. Inset by half the 1 pt line, so 0 and full are not cut off, and on
/// 0.5 pt steps, so a flat line is sharp at 2x.
func graphPoints(_ ram: [Int64], top: Int64, size: CGSize) -> [CGPoint] {
    guard !ram.isEmpty, top > 0 else { return [] }
    let vs = ram.count == 1 ? ram + ram : ram
    return vs.indices.map { i in
        let f = CGFloat(min(1, max(0, Double(vs[i]) / Double(top))))
        return CGPoint(x: size.width * CGFloat(i) / CGFloat(vs.count - 1), y: ((0.5 + (size.height - 1) * f) * 2).rounded() / 2)
    }
}

/// The item's tooltip line: "RAM used in the last 28 min: 10.9 GB to 11.3 GB of 16 GB".
func graphTip(_ samples: [Sample], physical: Int64) -> String {
    guard let a = samples.first, let b = samples.last else { return "RAM used: no sample yet" }
    let lo = short(samples.map(\.ram).min()!), hi = short(samples.map(\.ram).max()!)
    return "RAM used in the last \(mins(b.at.timeIntervalSince(a.at))): \(lo == hi ? hi : "\(lo) to \(hi)") of \(physical >> 30) GB"
}

private var graphKey = ""  // main thread: the state and newest sample that the graph shows; "" = not shown

extension Delegate {
    /// The chip (with its dot, as dotIcon), 3 pt, then the graph, 28 x 12 pt: a frame for all
    /// the RAM, as the battery icon has; the area under the line in the text color at low
    /// alpha (orange at Warning, red at Critical, as the dot); the line in the text color.
    /// Not a template (it has colors): cacheMode .never, so it draws again in the menu bar's
    /// color when it goes dark or light.
    /// ponytail: the whole area has the pressure of now, also for the minutes before it rose;
    /// keep the level in Sample to color each minute if that misleads.
    static func graphIcon(_ s: (dot: NSColor?, desc: String, tip: String), ram: [Int64], top: Int64, pressure: Pressure) -> NSImage {
        let icon = s.dot.map { dotIcon($0, s.desc) } ?? chip, h = chip.size.height, w = chip.size.width + 3 + 28
        let i = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let c = NSRect(origin: .zero, size: chip.size)
            icon.draw(in: c)
            if icon.isTemplate { NSColor.labelColor.set(); c.fill(using: .sourceAtop) }
            let box = NSRect(x: w - 28, y: (h - 12) / 2, width: 28, height: 12), plot = box.insetBy(dx: 1, dy: 1)
            let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            frame.stroke()  // 1 pt, on whole pixels
            let pts = graphPoints(ram, top: top, size: plot.size).map { CGPoint(x: plot.minX + $0.x, y: plot.minY + $0.y) }
            guard let first = pts.first, let last = pts.last else { return true }
            NSBezierPath(roundedRect: plot, xRadius: 1.5, yRadius: 1.5).addClip()  // the area's corners follow the frame's
            let line = NSBezierPath()
            line.move(to: first)
            for p in pts.dropFirst() { line.line(to: p) }
            let area = line.copy() as! NSBezierPath
            area.line(to: CGPoint(x: last.x, y: plot.minY))
            area.line(to: CGPoint(x: first.x, y: plot.minY))
            (pressure == .critical ? NSColor.systemRed : pressure == .warning ? .systemOrange : .labelColor).withAlphaComponent(pressure == .normal ? 0.25 : 0.8).setFill()
            area.fill()
            NSColor.labelColor.setStroke()
            line.lineJoinStyle = .round
            line.stroke()
            return true
        }
        i.cacheMode = .never
        i.accessibilityDescription = s.desc  // the plain icon's: updateIcon keeps an image with the state's description
        return i
    }

    /// After updateIcon's own image and tooltip: in RAM Graph mode the graph and its tooltip
    /// line; out of it, once, the plain icon again (the graph has the plain icon's description,
    /// so updateIcon would keep it).
    func updateGraph(_ s: (dot: NSColor?, desc: String, tip: String)) {
        guard MenuBarShows(rawValue: UserDefaults.standard.menuBarShows) == .graph else {
            if !graphKey.isEmpty { graphKey = ""; item.button?.image = s.dot.map { Self.dotIcon($0, s.desc) } ?? Self.chip }
            return
        }
        let kept = graphSamples(model.history.samples), physical = Int64(ProcessInfo.processInfo.physicalMemory)
        item.button?.toolTip = s.tip + "\n" + graphTip(kept, physical: physical)
        let key = "\(s.desc) \(kept.last?.at.timeIntervalSince1970 ?? 0)"
        guard key != graphKey else { return }
        graphKey = key
        item.button?.image = Self.graphIcon(s, ram: kept.map(\.ram), top: physical, pressure: model.sys.pressure)
    }
}

#if DEBUG
/// `MENUBAR=1 AppMem --snapshot OUT.png` (debug builds): the RAM Graph item, not the panel, at 2x
/// on a light and a dark menu bar. Rows: the live RAM (as HISTORY=1); the same with the leftover
/// dot; a climb from 30% to 90% of the RAM at Warning; the same at Critical.
func snapshotMenuBar(to path: String) {
    _ = NSApplication.shared
    let physical = Int64(ProcessInfo.processInfo.physicalMemory), now = Date()
    let live = graphSamples(History.demo([], sys: systemMem()).samples)
    let climb = graphSamples((0..<40).map { (i: Int) -> Sample in
        Sample(at: now - Double(39 - i) * 60, ram: physical / 100 * Int64(30 + i * 60 / 39), swap: 0, groups: [:])
    })
    let rows: [(Pressure, Int64, [Sample])] = [(.normal, 0, live), (.normal, 1, live), (.warning, 0, climb), (.critical, 1, climb)]
    let cell = NSSize(width: 70, height: 24)  // 24 pt: the menu bar on a Mac with a notch
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell.width) * 4, pixelsHigh: Int(cell.height) * 2 * rows.count,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: cell.width * 2, height: cell.height * CGFloat(rows.count))  // points: 2 pixels each
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (n, (p, waste, samples)) in rows.enumerated() {
        let i = Delegate.graphIcon(menuState(p, waste: waste), ram: samples.map(\.ram), top: physical, pressure: p)
        for (col, dark) in [false, true].enumerated() {
            let r = NSRect(x: cell.width * CGFloat(col), y: cell.height * CGFloat(rows.count - 1 - n), width: cell.width, height: cell.height)
            NSColor(white: dark ? 0.16 : 0.92, alpha: 1).setFill()
            r.fill()
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                i.draw(in: NSRect(x: r.midX - i.size.width / 2, y: r.midY - i.size.height / 2, width: i.size.width, height: i.size.height))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
#endif
