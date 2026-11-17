import AppKit
import JammerAgent
import JammerCore
import MetalKit

/// What part of the timeline is on screen.
@MainActor
final class Viewport {
    var start: Double = 0
    /// Timeline frames per point.
    var framesPerPoint: Double = 1_000
    var width: CGFloat = 800

    func frame(atX x: CGFloat) -> Double { start + Double(x) * framesPerPoint }
    func x(of frame: Double) -> CGFloat { CGFloat((frame - start) / framesPerPoint) }
}

/// The timeline: Metal waveform lanes under an AppKit overlay that draws the
/// ruler, selection, playhead and markers and handles all input.
@MainActor
final class TimelineView: NSView {
    static let rulerHeight: CGFloat = 26

    let session: EditorSession
    let viewport = Viewport()
    private let metal: WaveformMetalView
    private let overlay: TimelineOverlay
    private let spectrogram: SpectrogramLayerView
    let automation: AutomationLanesView
    /// The lanes of the strips that have no waveform (buses, VCA groups, the master), in thin rows under the tracks.
    let stripLanes: AutomationLanesView
    private var stripHeight: NSLayoutConstraint!
    /// Which kind of automation lane is drawn over the tracks (View › Automation). nil: none.
    var shownAutomation: AutomationLane.Param? {
        get { automation.shown }
        set { automation.shown = newValue; stripLanes.shown = newValue; sizeStripLanes() }
    }
    /// Whether the rows for buses, groups and the master are open (View › Automation).
    var showsStripLanes = false { didSet { sizeStripLanes() } }
    /// The rows take height from the tracks only while they are open and a kind of lane is shown: 44 points a row, at most half the timeline.
    private func sizeStripLanes() {
        let n = showsStripLanes && shownAutomation != nil ? stripLanes.rowList.count : 0
        let h = min(CGFloat(n) * 44, bounds.height * 0.5)
        if stripHeight.constant != h { stripHeight.constant = h }
        if !showsStripLanes || n == 0, stripLanes.isActive { stripLanes.isActive = false; automation.isActive = true }
    }
    /// A key, offered to the lane view that is worked in; ⌥↓ and ⌥↑ past its last or first row go on into the other.
    func automationKey(_ event: NSEvent) -> Bool {
        guard shownAutomation != nil else { return false }
        let here = stripLanes.isActive ? stripLanes : automation, there = stripLanes.isActive ? automation : stripLanes
        if here.key(event) { return true }
        let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
        guard flags == [.option], event.keyCode == 125 || event.keyCode == 126 else { return false }
        let down = event.keyCode == 125
        // Down from the tracks into the rows below, up from them into the tracks; nowhere else to go.
        guard down == (here === automation), stripHeight.constant > 0, !there.rowList.isEmpty else { NSSound.beep(); return true }
        here.isActive = false
        there.enter(atEnd: !down)
        return true
    }
    var showsSpectrogram: Bool {
        get { !spectrogram.isHidden }
        set { spectrogram.isHidden = !newValue; metal.isHidden = newValue; spectrogram.refresh(); refresh(waveform: true) }
    }
    private var observing = false

    init(session: EditorSession) {
        self.session = session
        metal = WaveformMetalView(session: session, viewport: viewport)
        overlay = TimelineOverlay(session: session, viewport: viewport)
        spectrogram = SpectrogramLayerView(session: session, viewport: viewport)
        automation = AutomationLanesView(session: session, viewport: viewport)
        stripLanes = AutomationLanesView(session: session, viewport: viewport, rows: .strips)
        super.init(frame: .zero)
        wantsLayer = true
        spectrogram.isHidden = true
        stripLanes.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripLanes)
        stripHeight = stripLanes.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([stripLanes.leadingAnchor.constraint(equalTo: leadingAnchor), stripLanes.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stripLanes.bottomAnchor.constraint(equalTo: bottomAnchor), stripHeight])
        for v in [metal, spectrogram, automation, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: stripLanes.topAnchor),
            ])
        }
        automation.onActivate = { [weak self] in self?.stripLanes.isActive = false; self?.automation.isActive = true }
        stripLanes.onActivate = { [weak self] in
            guard let self else { return }
            automation.isActive = false
            stripLanes.isActive = true
            window?.makeFirstResponder(overlay)   // the keys stay the timeline's, which offers them to the lanes
        }
        overlay.onChange = { [weak self] in self?.refresh(waveform: true) }
        observe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var firstResponderView: NSView { overlay }

    override func layout() {
        super.layout()
        let wasUnset = viewport.width < 10 || viewport.width == 800
        viewport.width = bounds.width
        if wasUnset { zoomToFit() } else { refresh(waveform: true) }
    }

    func zoomToFit() {
        let length = max(Double(session.project.length), session.project.sampleRate)
        viewport.start = 0
        viewport.framesPerPoint = length / Double(max(100, bounds.width - 20))
        refresh(waveform: true)
    }

    func zoom(by factor: Double, around x: CGFloat? = nil) {
        let anchorX = x ?? (session.isPlaying ? viewport.x(of: Double(session.playhead)) : bounds.width / 2)
        let anchor = viewport.frame(atX: anchorX)
        let maxFPP = max(Double(session.project.length), session.project.sampleRate) / 50
        viewport.framesPerPoint = min(maxFPP, max(0.05, viewport.framesPerPoint / factor))
        viewport.start = anchor - Double(anchorX) * viewport.framesPerPoint
        clampStart()
        refresh(waveform: true)
    }

    func zoomToSelection() {
        guard let sel = session.selection else { return }
        viewport.framesPerPoint = max(0.05, Double(sel.count) / Double(max(100, bounds.width - 40)))
        viewport.start = Double(sel.lowerBound) - 20 * viewport.framesPerPoint
        clampStart()
        refresh(waveform: true)
    }

    func scroll(byPoints dx: CGFloat) {
        viewport.start += Double(dx) * viewport.framesPerPoint
        clampStart()
        refresh(waveform: true)
    }

    private func clampStart() {
        let end = Double(session.project.length) - Double(bounds.width) * viewport.framesPerPoint * 0.5
        viewport.start = max(-Double(bounds.width) * viewport.framesPerPoint * 0.05, min(viewport.start, max(0, end)))
    }

    /// Keeps the playhead on screen while playing.
    private func follow() {
        guard session.isPlaying else { return }
        let x = viewport.x(of: Double(session.playhead))
        if x > bounds.width * 0.9 || x < 0 {
            viewport.start = Double(session.playhead) - Double(bounds.width) * 0.1 * viewport.framesPerPoint
            refresh(waveform: true)
        }
    }

    func refresh(waveform: Bool) {
        if waveform { metal.invalidate(); spectrogram.refresh() }
        overlay.needsDisplay = true
        automation.invalidate()
        stripLanes.invalidate()
        sizeStripLanes()
    }

    private func observe() {
        withObservationTracking {
            _ = session.version
            _ = session.selection
            _ = session.playhead
            _ = session.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.follow()
                self.refresh(waveform: true)
                self.observe()
            }
        }
    }
}

// MARK: Metal waveform

@MainActor
final class WaveformMetalView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var size: SIMD2<Float>
        var rulerHeight: Float
        var laneHeight: Float
        var columns: UInt32
        var lanes: UInt32
        var channels: UInt32
        var selectionStart: Float
        var selectionEnd: Float
        var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
        var wave: SIMD4<Float>
        var waveSelected: SIMD4<Float>
        var background: SIMD4<Float>
        var laneBackground: SIMD4<Float>
        var selectionBackground: SIMD4<Float>
        var centerLine: SIMD4<Float>
    }

    private let session: EditorSession
    private let viewport: Viewport
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var columnBuffer: MTLBuffer?
    /// What `columnBuffer` shows.
    private var shownKey: [Double] = []
    /// Zoomed in past the peak index, exact samples come from the files on a
    /// background task (one at a time, always the latest view) and replace the
    /// block-level picture drawn meanwhile. The main thread never reads a file.
    private var exactInFlight = false
    private var wantedExact: (key: [Double], job: @Sendable () -> [SIMD2<Float>])?

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.035, green: 0.045, blue: 0.055, alpha: 1)
        guard let device, let library = try? device.makeDefaultLibrary(bundle: .main) else { return }
        queue = device.makeCommandQueue()
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "waveform_vertex")
        d.fragmentFunction = library.makeFunction(name: "waveform_fragment")
        d.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: d)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func invalidate() { needsDisplay = true }

    nonisolated static func columnValues(_ project: Project, start: Double, fpc: Double, columns: Int, lanes: Int, channels: Int,
                                         peaks: [UUID: PeakIndex], pool: SourcePool, allowRaw: Bool) -> [SIMD2<Float>] {
        var values = [SIMD2<Float>](repeating: SIMD2(1, -1), count: lanes * channels * columns)
        for t in 0..<project.tracks.count {
            let cols = Waveform.columns(project, track: t, start: start, framesPerColumn: fpc, count: columns,
                                        peaks: peaks, pool: pool, allowRaw: allowRaw)
            for ch in 0..<min(channels, cols.count) {
                let base = (t * channels + ch) * columns
                for c in 0..<columns {
                    let col = cols[ch][c]
                    values[base + c] = col == .empty ? SIMD2(1, -1) : SIMD2(max(-1, col.min), min(1, col.max))
                }
            }
        }
        return values
    }

    private func requestExact(_ key: [Double], _ job: @escaping @Sendable () -> [SIMD2<Float>]) {
        wantedExact = (key, job)
        if !exactInFlight { startExact() }
    }

    private func startExact() {
        guard let (key, job) = wantedExact else { return }
        wantedExact = nil
        exactInFlight = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let values = job()
            await MainActor.run {
                guard let self else { return }
                self.exactInFlight = false
                if self.shownKey == key {
                    self.columnBuffer = self.device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
                    self.needsDisplay = true
                }
                if let next = self.wantedExact, next.key != key { self.startExact() } else { self.wantedExact = nil }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let pipeline, let queue, let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        let columns = max(1, Int(drawableSize.width))
        let project = session.project
        let lanes = max(1, project.tracks.count)
        let channels = max(1, project.channels)
        let fpc = viewport.framesPerPoint / scale
        let key = [Double(session.version), viewport.start, fpc, Double(columns), Double(session.peaks.count)]
        if key != shownKey || columnBuffer == nil {
            let start = viewport.start, peaks = session.peaks, pool = session.pool
            let needsFiles = fpc < Double(PeakIndex.baseBlock)
            let values = Self.columnValues(project, start: start, fpc: fpc, columns: columns, lanes: lanes, channels: channels,
                                           peaks: peaks, pool: pool, allowRaw: !needsFiles)
            columnBuffer = device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
            shownKey = key
            if needsFiles {
                requestExact(key) {
                    Self.columnValues(project, start: start, fpc: fpc, columns: columns, lanes: lanes, channels: channels,
                                      peaks: peaks, pool: pool, allowRaw: true)
                }
            }
        }
        guard let columnBuffer else { return }
        func rgba(_ c: NSColor, _ a: CGFloat? = nil) -> SIMD4<Float> {
            let s = c.usingColorSpace(.sRGB) ?? c
            return SIMD4(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), Float(a ?? s.alphaComponent))
        }
        let ruler = Float(TimelineView.rulerHeight * CGFloat(scale))
        let laneHeight = (Float(drawableSize.height) - ruler) / Float(lanes)
        var selStart: Float = -1, selEnd: Float = -1
        if let sel = session.selection {
            selStart = Float(viewport.x(of: Double(sel.lowerBound)) * CGFloat(scale))
            selEnd = Float(viewport.x(of: Double(sel.upperBound)) * CGFloat(scale))
        }
        var u = Uniforms(size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)), rulerHeight: ruler,
                         laneHeight: laneHeight, columns: UInt32(columns), lanes: UInt32(lanes), channels: UInt32(channels),
                         selectionStart: selStart, selectionEnd: selEnd,
                         wave: rgba(Theme.neon, 0.92), waveSelected: rgba(.white, 0.95), background: rgba(Theme.ink),
                         laneBackground: rgba(Theme.lane), selectionBackground: rgba(Theme.neon, 1) * SIMD4(0.22, 0.22, 0.22, 1),
                         centerLine: rgba(.white, 0.12))
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBuffer(columnBuffer, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: Overlay and input

@MainActor
final class TimelineOverlay: NSView {
    let session: EditorSession
    let viewport: Viewport
    var onChange: () -> Void = {}
    private var dragAnchor: Frame?
    private var didDrag = false

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // VoiceOver: the timeline reads as a slider over the playhead. Its value says where
    // the playhead and the selection are; increment and decrement move 1 s, like the arrows.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityRoleDescription() -> String? { L10n.text("timeline.ax.role") }
    override func accessibilityLabel() -> String? { L10n.text("timeline.ax.label") }
    override func accessibilityValue() -> Any? {
        let p = session.project
        var text = L10n.text("timeline.ax.playhead", formatTime(p.seconds(session.playhead)), formatTime(p.duration))
        if let sel = session.selection {
            text += ", " + L10n.text("timeline.ax.selection", formatTime(p.seconds(sel.lowerBound)), formatTime(p.seconds(sel.upperBound)))
        }
        if p.tracks.count > 1 { text += ", " + L10n.count("import.tracks", p.tracks.count) }
        if areaMode, let a = session.spectralArea { text += ", " + L10n.text("timeline.ax.area", a.shape.summary) }
        return text
    }
    override func accessibilityPerformIncrement() -> Bool {
        session.seek(session.playhead + Frame(session.project.sampleRate))
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        session.seek(session.playhead - Frame(session.project.sampleRate))
        return true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    private var timeline: TimelineView? { superview as? TimelineView }
    private var project: Project { session.project }

    private func frame(at p: NSPoint) -> Frame {
        Frame(max(0, min(Double(project.length), viewport.frame(atX: p.x)).rounded()))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        defer { drawArea() } // the drawn spectrogram area, on top
        let rate = project.sampleRate
        let h = TimelineView.rulerHeight
        // Ruler ticks: pick a step that leaves ~90 pt between labels.
        let secondsPerPoint = viewport.framesPerPoint / rate
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
        let step = steps.first { $0 / secondsPerPoint >= 90 } ?? 7_200
        let first = floor(viewport.start / rate / step) * step
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: Theme.text]
        var t = first
        let endTime = viewport.frame(atX: bounds.width) / rate
        while t <= endTime {
            let x = viewport.x(of: t * rate)
            Theme.grid.setFill()
            NSRect(x: x, y: h - 8, width: 1, height: 8).fill()
            NSColor(white: 1, alpha: 0.035).setFill()
            NSRect(x: x, y: h, width: 1, height: bounds.height - h).fill()
            let label = step < 1 ? formatTime(t) : formatTime(t, millis: false)
            (label as NSString).draw(at: NSPoint(x: x + 3, y: 4), withAttributes: attrs)
            for sub in 1..<5 {
                let sx = viewport.x(of: (t + step * Double(sub) / 5) * rate)
                Theme.grid.setFill()
                NSRect(x: sx, y: h - 4, width: 1, height: 4).fill()
            }
            t += step
        }
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()

        // Clip edges and track names.
        let lanes = max(1, project.tracks.count)
        let laneHeight = (bounds.height - h) / CGFloat(lanes)
        for (i, track) in project.tracks.enumerated() {
            let y = h + CGFloat(i) * laneHeight
            for c in track.clips {
                for edge in [c.start, c.end] {
                    let x = viewport.x(of: Double(edge))
                    guard x >= 0, x <= bounds.width else { continue }
                    NSColor(white: 1, alpha: 0.25).setFill()
                    NSRect(x: x, y: y + 1, width: 1, height: laneHeight - 1).fill()
                }
                if c.fadeIn > 0 { drawFade(from: c.start, to: c.start + c.fadeIn, rising: true, y: y, height: laneHeight) }
                if c.fadeOut > 0 { drawFade(from: c.end - c.fadeOut, to: c.end, rising: false, y: y, height: laneHeight) }
            }
            // On a plate: the name lies over the waveform and must be read whatever is under it.
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: AutomationLanesView.nameFont, .foregroundColor: NSColor.white]
            let nameSize = (track.name as NSString).size(withAttributes: nameAttrs)
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: y + 20, width: nameSize.width + 10, height: nameSize.height + 4), xRadius: 4, yRadius: 4).fill()
            // Below the row where marker flags sit, so a marker near the start doesn't cover it.
            (track.name as NSString).draw(at: NSPoint(x: 8, y: y + 22), withAttributes: nameAttrs)
            if session.peaks.isEmpty, !session.peakProgress.isEmpty, session.project.length > Frame(project.sampleRate * 600) {
                let p = session.peakProgress.values.first ?? 0
                (L10n.text("timeline.reading", String(Int(p * 100))) as NSString).draw(at: NSPoint(x: 8, y: y + 24), withAttributes: nameAttrs)
            }
        }

        // Selection edges.
        if let sel = session.selection {
            let a = viewport.x(of: Double(sel.lowerBound)), b = viewport.x(of: Double(sel.upperBound))
            Theme.neon.withAlphaComponent(0.9).setFill()
            NSRect(x: a, y: h, width: 1, height: bounds.height - h).fill()
            NSRect(x: b - 1, y: h, width: 1, height: bounds.height - h).fill()
            Theme.neon.withAlphaComponent(0.25).setFill()
            NSRect(x: a, y: 0, width: max(1, b - a), height: h).fill()
        }

        // Markers.
        for m in project.markers {
            let x = viewport.x(of: Double(m.position))
            guard x > -200, x < bounds.width + 10 else { continue }
            Theme.marker.setFill()
            if m.length > 0 {
                let w = viewport.x(of: Double(m.position + m.length)) - x
                Theme.marker.withAlphaComponent(0.25).setFill()
                NSRect(x: x, y: h - 6, width: w, height: 6).fill()
                Theme.marker.setFill()
            }
            NSRect(x: x, y: h, width: 1, height: bounds.height - h).fill()
            let flag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                       .foregroundColor: NSColor.black, .backgroundColor: Theme.marker]
            (" \(m.name) " as NSString).draw(at: NSPoint(x: x + 1, y: h + 2), withAttributes: flag)
        }

        // Playhead.
        let px = viewport.x(of: Double(session.playhead))
        Theme.playhead.setFill()
        NSRect(x: px, y: 0, width: 1.5, height: bounds.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: px - 5, y: 0)); tri.line(to: NSPoint(x: px + 6.5, y: 0)); tri.line(to: NSPoint(x: px + 0.75, y: 7))
        tri.close(); tri.fill()
    }

    private func drawFade(from a: Frame, to b: Frame, rising: Bool, y: CGFloat, height: CGFloat) {
        let x0 = viewport.x(of: Double(a)), x1 = viewport.x(of: Double(b))
        guard x1 > 0, x0 < bounds.width else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: rising ? y + height : y + 2))
        path.line(to: NSPoint(x: x1, y: rising ? y + 2 : y + height))
        path.lineWidth = 1.2
        NSColor(white: 1, alpha: 0.55).setStroke()
        path.stroke()
    }

    // MARK: Mouse

    // MARK: Spectrogram areas

    static let fLo = 50.0
    var fHi: Double { min(16_000, project.sampleRate / 2) }
    private var laneHeight: CGFloat { (bounds.height - TimelineView.rulerHeight) / CGFloat(max(1, project.tracks.count)) }
    private func laneTop(_ i: Int) -> CGFloat { TimelineView.rulerHeight + CGFloat(i) * laneHeight }
    /// Frequency at a height in a lane, on the spectrogram's log scale (top is high).
    private func hz(atY y: CGFloat, lane: Int) -> Double {
        let r = Double(min(max(0, y - laneTop(lane)), laneHeight - 1)) / Double(max(1, laneHeight - 1))
        return Self.fLo * pow(fHi / Self.fLo, 1 - r)
    }
    private func y(ofHz f: Double, lane: Int) -> CGFloat {
        let r = 1 - log(max(Self.fLo, f) / Self.fLo) / log(fHi / Self.fLo)
        return laneTop(lane) + CGFloat(r) * (laneHeight - 1)
    }
    private func seconds(atX x: CGFloat) -> Double { viewport.frame(atX: x) / project.sampleRate }
    private func point(_ p: NSPoint, lane: Int) -> SpectralPoint { SpectralPoint(t: seconds(atX: p.x), f: hz(atY: p.y, lane: lane)) }
    private var drawing: (lane: Int, anchor: NSPoint, points: [NSPoint])?
    private static let brushPixels: CGFloat = 10
    private var areaMode: Bool { timeline?.showsSpectrogram == true }

    private func updateArea(_ d: (lane: Int, anchor: NSPoint, points: [NSPoint])) {
        let lane = d.lane
        let shape: SpectralShape
        switch session.spectralTool {
        case .box:
            let a = point(d.anchor, lane: lane), b = point(d.points.last ?? d.anchor, lane: lane)
            shape = .box(start: min(a.t, b.t), end: max(a.t, b.t), low: min(a.f, b.f), high: max(a.f, b.f))
        case .lasso:
            shape = .polygon(d.points.map { point($0, lane: lane) })
        case .brush:
            let pts = d.points.map { point($0, lane: lane) }
            let meanF = pts.map(\.f).reduce(0, +) / Double(max(1, pts.count))
            let radius = meanF * (pow(fHi / Self.fLo, Double(Self.brushPixels) / Double(max(1, laneHeight - 1))) - 1)
            shape = .brush(pts, radius: max(1, radius), radiusTime: Double(Self.brushPixels) * viewport.framesPerPoint / project.sampleRate)
        }
        session.spectralArea = .init(shape: shape, track: lane)
        needsDisplay = true
    }

    func drawArea() {
        guard areaMode, let area = session.spectralArea else { return }
        let path = NSBezierPath()
        func pt(_ p: SpectralPoint) -> NSPoint { NSPoint(x: viewport.x(of: p.t * project.sampleRate), y: y(ofHz: p.f, lane: area.track)) }
        switch area.shape {
        case .box(let a, let b, let lo, let hi):
            path.appendRect(NSRect(x: viewport.x(of: a * project.sampleRate), y: y(ofHz: hi, lane: area.track),
                                   width: viewport.x(of: b * project.sampleRate) - viewport.x(of: a * project.sampleRate),
                                   height: y(ofHz: lo, lane: area.track) - y(ofHz: hi, lane: area.track)))
        case .polygon(let pts):
            guard let first = pts.first else { return }
            path.move(to: pt(first)); pts.dropFirst().forEach { path.line(to: pt($0)) }; path.close()
        case .brush(let pts, _, _):
            guard let first = pts.first else { return }
            path.move(to: pt(first)); pts.dropFirst().forEach { path.line(to: pt($0)) }
            path.lineWidth = Self.brushPixels * 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            Theme.neon.withAlphaComponent(0.3).setStroke()
            path.stroke()
            return
        }
        Theme.neon.withAlphaComponent(0.18).setFill()
        path.fill()
        Theme.neon.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // A click on an automation point (or ⌥-click in a lane) is the lane's; everything else is the timeline's as before.
        if !areaMode, timeline?.automation.mouseDown(event, at: p) == true { dragAnchor = nil; return }
        let f = frame(at: p)
        if areaMode, p.y >= TimelineView.rulerHeight, event.clickCount == 1, !event.modifierFlags.contains(.shift) {
            let lane = min(max(0, laneIndex(at: p.y)), max(0, project.tracks.count - 1))
            drawing = (lane, p, [p])
            didDrag = false
            dragAnchor = nil
            return
        }
        if p.y < TimelineView.rulerHeight {
            session.seek(f)
            dragAnchor = nil
            return
        }
        if event.clickCount == 2 {
            // Select the clip under the pointer.
            let lane = laneIndex(at: p.y)
            if let clip = project.tracks[safe: lane]?.clips.first(where: { $0.range.contains(f) }) {
                session.selection = clip.range
            }
            return
        }
        if event.modifierFlags.contains(.shift), let sel = session.selection {
            let anchor = abs(f - sel.lowerBound) < abs(f - sel.upperBound) ? sel.upperBound : sel.lowerBound
            dragAnchor = anchor
            session.selection = min(anchor, f)..<max(anchor, f)
        } else {
            dragAnchor = f
            didDrag = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if timeline?.automation.mouseDragged(event, at: p) == true { return }
        if var d = drawing {
            d.points.append(p)
            drawing = d
            didDrag = true
            updateArea(d)
            return
        }
        if p.y < TimelineView.rulerHeight && dragAnchor == nil {
            session.seek(frame(at: p))
            return
        }
        guard let anchor = dragAnchor else { return }
        if p.x > bounds.width - 4 { timeline?.scroll(byPoints: 12) } else if p.x < 4 { timeline?.scroll(byPoints: -12) }
        let f = frame(at: p)
        didDrag = true
        session.selection = min(anchor, f)..<max(anchor, f)
    }

    override func mouseUp(with event: NSEvent) {
        if timeline?.automation.mouseUp(event, at: convert(event.locationInWindow, from: nil)) == true { return }
        if let d = drawing {
            drawing = nil
            if !didDrag {
                session.spectralArea = nil
                session.seek(frame(at: d.anchor))
                needsDisplay = true
            } else if session.spectralTool == .lasso, d.points.count < 3 {
                session.spectralArea = nil
            }
            return
        }
        defer { dragAnchor = nil }
        guard let anchor = dragAnchor, !event.modifierFlags.contains(.shift) else { return }
        if !didDrag {
            session.selection = nil
            session.seek(anchor)
        }
    }

    private func laneIndex(at y: CGFloat) -> Int {
        let lanes = max(1, project.tracks.count)
        return Int((y - TimelineView.rulerHeight) / ((bounds.height - TimelineView.rulerHeight) / CGFloat(lanes)))
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            timeline?.zoom(by: pow(1.01, Double(event.scrollingDeltaY)), around: p.x)
            return
        }
        let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        timeline?.scroll(byPoints: -dx * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }

    override func magnify(with event: NSEvent) {
        timeline?.zoom(by: 1 + Double(event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    // MARK: Keys and edit commands

    override func keyDown(with event: NSEvent) {
        if timeline?.automationKey(event) == true { return }
        switch event.keyCode {
        case 49: session.togglePlay() // space
        case 36: session.seek(0) // return
        case 53 where areaMode && session.spectralArea != nil: session.spectralArea = nil; needsDisplay = true // escape: the area first
        case 53: session.selection = nil // escape
        case 11 where areaMode: session.spectralTool = .box; session.status = L10n.text("spectral.tool.box") // B
        case 37 where areaMode && Operations.spectralFreeform: session.spectralTool = .lasso; session.status = L10n.text("spectral.tool.lasso") // L
        case 35 where areaMode && Operations.spectralFreeform: session.spectralTool = .brush; session.status = L10n.text("spectral.tool.brush") // P
        case 51, 117: delete(nil) // delete, forward delete
        case 123: session.seek(session.playhead - Frame(project.sampleRate)) // left: 1 s
        case 124: session.seek(session.playhead + Frame(project.sampleRate))
        case 115: session.seek(0) // home
        case 119: session.seek(project.length) // end
        default: super.keyDown(with: event)
        }
    }

    @objc func cut(_ sender: Any?) { session.perform("cut") }
    @objc func copy(_ sender: Any?) { session.perform("copy") }
    @objc func paste(_ sender: Any?) { session.perform("paste") }
    @objc func delete(_ sender: Any?) { if session.selection != nil { session.perform("delete") } else { NSSound.beep() } }
    @objc override func selectAll(_ sender: Any?) { session.perform("select_all") }

    func validate(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)): session.selection != nil
        case #selector(paste(_:)): AppClipboard.content != nil
        default: true
        }
    }
}

extension TimelineOverlay: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
