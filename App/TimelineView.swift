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
    private var observing = false

    init(session: EditorSession) {
        self.session = session
        metal = WaveformMetalView(session: session, viewport: viewport)
        overlay = TimelineOverlay(session: session, viewport: viewport)
        super.init(frame: .zero)
        wantsLayer = true
        for v in [metal, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
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
        if waveform { metal.invalidate() }
        overlay.needsDisplay = true
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
    private var cacheKey: [Double] = []

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
        if key != cacheKey || columnBuffer == nil {
            var values = [SIMD2<Float>](repeating: SIMD2(1, -1), count: lanes * channels * columns)
            for t in 0..<project.tracks.count {
                let cols = Waveform.columns(project, track: t, start: viewport.start, framesPerColumn: fpc, count: columns,
                                            peaks: session.peaks, pool: session.pool)
                for ch in 0..<channels {
                    let base = (t * channels + ch) * columns
                    for c in 0..<columns {
                        let col = cols[ch][c]
                        values[base + c] = col == .empty ? SIMD2(1, -1) : SIMD2(max(-1, col.min), min(1, col.max))
                    }
                }
            }
            columnBuffer = device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
            cacheKey = key
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
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                            .foregroundColor: Theme.text]
            (track.name as NSString).draw(at: NSPoint(x: 8, y: y + 6), withAttributes: nameAttrs)
            if session.peaks.isEmpty, !session.peakProgress.isEmpty, session.project.length > Frame(project.sampleRate * 600) {
                let p = session.peakProgress.values.first ?? 0
                ("Reading waveform… \(Int(p * 100)) %" as NSString).draw(at: NSPoint(x: 8, y: y + 24), withAttributes: nameAttrs)
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let f = frame(at: p)
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
        switch event.keyCode {
        case 49: session.togglePlay() // space
        case 36: session.seek(0) // return
        case 53: session.selection = nil // escape
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
