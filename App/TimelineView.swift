import AppKit
import JammerAgent
import JammerCore
import MetalKit
import UniformTypeIdentifiers

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

    /// After a tool change: the handles and the pointer drawn again.
    func overlayNeedsDisplay() {
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: overlay)
    }
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
    /// The lane view that is worked in (the tracks' lanes or the strips' rows).
    var activeLanes: AutomationLanesView { stripLanes.isActive ? stripLanes : automation }

    /// A key came up: nudges held in either lane view go as one step.
    func automationKeyUp() {
        automation.keyUp()
        stripLanes.keyUp()
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
    /// Where the track lanes are (the ruler on top, the strip rows below excluded): the track headers line up with it.
    var tracksArea: NSView { overlay }

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

    /// The Zoom tool's dragged range filling the view.
    func zoom(to range: Range<Frame>) {
        viewport.framesPerPoint = max(0.05, Double(range.count) / Double(max(100, bounds.width - 40)))
        viewport.start = Double(range.lowerBound) - 20 * viewport.framesPerPoint
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

    /// Keeps the playhead on screen while playing, a page at a time. A page replaces the whole picture, so at most
    /// two a second, one with Reduce Motion (the flashing rule, FollowPolicy); zoomed in so far that following
    /// would need more, the view stays where it is and a steady chip says so, until it is zoomed out or playing stops.
    private func follow() {
        // While recording the playhead moves even where nothing plays (past the end): followed the same way.
        guard session.isPlaying || session.recording != nil else {
            lastPageAt = nil
            showFollowPaused(false)
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        let width = Double(bounds.width), fpp = viewport.framesPerPoint, rate = session.project.sampleRate
        let decision = FollowPolicy.next(start: viewport.start, playhead: Double(session.playhead), width: width, framesPerPoint: fpp,
                                         sampleRate: rate, lastPage: lastPageAt, now: now, reduceMotion: reduce)
        if case .page(let start) = decision {
            viewport.start = start
            lastPageAt = now
            refresh(waveform: true)
        }
        let tooClose = FollowPolicy.pagesPerSecond(width: width, framesPerPoint: fpp, sampleRate: rate) > FollowPolicy.limit(reduceMotion: reduce)
        showFollowPaused(tooClose && (decision == .paused || !followChip.isHidden))
    }
    private var lastPageAt: Double?

    /// "Following paused at this zoom": steady, in the ruler's right corner, while following would flash.
    private lazy var followChip: NSTextField = {
        let f = NSTextField(labelWithString: L10n.text("timeline.followPaused"))
        f.font = .systemFont(ofSize: 10, weight: .medium)
        f.textColor = .secondaryLabelColor
        f.wantsLayer = true
        f.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        f.layer?.cornerRadius = 4
        f.isHidden = true
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setAccessibilityIdentifier("timeline.followPaused")
        addSubview(f)
        NSLayoutConstraint.activate([f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), f.topAnchor.constraint(equalTo: topAnchor, constant: 5)])
        return f
    }()

    private func showFollowPaused(_ shown: Bool) {
        guard followChip.isHidden == shown else { return }
        followChip.isHidden = !shown
        if shown { NSAccessibility.post(element: followChip, notification: .layoutChanged) }
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
    /// Whether `columnBuffer` holds exact samples (not the block envelope), and for what shape (columns, lanes, channels).
    private var shownIsExact = false
    private var shownShape: [Int] = []
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
                    self.shownIsExact = true
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
            let shape = [columns, lanes, channels]
            // Zoomed in past the peaks, the last exact picture stays until the new view's own is ready: the block
            // envelope in between is filled and bright where the exact line is thin, a flash at every page.
            if columnBuffer == nil || WaveformBufferPolicy.drawsCoarse(needsExact: needsFiles, shownIsExact: shownIsExact, sameShape: shape == shownShape) {
                let values = Self.columnValues(project, start: start, fpc: fpc, columns: columns, lanes: lanes, channels: channels,
                                               peaks: peaks, pool: pool, allowRaw: !needsFiles)
                columnBuffer = device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
                shownIsExact = !needsFiles
            }
            shownShape = shape
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

    // The handles (the comfort block, step 2): what the pointer is over, a handle being dragged, its value so far,
    // and what Esc puts back. The zones come from HandleZones, so the pointer and the press can't disagree.
    private enum HandleDrag { case fadeIn(UUID), fadeOut(UUID), trimStart(UUID), trimEnd(UUID), marker(UUID) }
    private var hover: HandleZones.Zone = .none
    private var handleDrag: (kind: HandleDrag, value: Frame)?
    private var selectionBeforeDrag: Range<Frame>??
    private var cancelled = false
    private var snapX: CGFloat?
    private var lastDragPoint: NSPoint?
    private var autoscroll: Timer?
    /// The Gain, Zoom and Hand tools' drags: where they began and what they have so far.
    private var gainDrag: (clip: UUID, startY: CGFloat, startDB: Double, db: Double)?
    private var zoomDrag: (startX: CGFloat, x: CGFloat)?
    private var handDrag: CGFloat?
    private var tool: String { session.tool }

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        super.init(frame: .zero)
        // Files dropped from Finder (COMFORT 22, 71): audio as new tracks where it lands, a film as the picture.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Dropped files

    /// Where a drop would land, while files are dragged over: a line is drawn there.
    private var dropX: CGFloat?

    private func droppedFiles(_ info: NSDraggingInfo) -> (audio: [URL], film: URL?) {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        func kind(_ u: URL) -> UTType? { (try? u.resourceValues(forKeys: [.contentTypeKey]))?.contentType }
        let audio = urls.filter { kind($0)?.conforms(to: .audio) == true }
        let film = urls.first { kind($0)?.conforms(to: .movie) == true && !audio.contains($0) }
        return (audio, film)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = droppedFiles(sender)
        guard !files.audio.isEmpty || files.film != nil else { dropX = nil; needsDisplay = true; return [] }
        dropX = convert(sender.draggingLocation, from: nil).x
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropX = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropX = nil; needsDisplay = true }
        let files = droppedFiles(sender)
        let at = max(0, frame(at: convert(sender.draggingLocation, from: nil)))
        if !files.audio.isEmpty {
            (window?.windowController as? EditorWindowController)?.importTracks(files.audio, at: at)
        }
        if let film = files.film {
            ProjectAccess.approve([film])
            session.perform("set_video_reference", ["path": .string(film.path), "at": .number(project.seconds(at))])
        }
        return !files.audio.isEmpty || files.film != nil
    }

    // VoiceOver: the timeline reads as a slider over the playhead. Its value says where
    // the playhead and the selection are; increment and decrement move 1 s, like the arrows.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityRoleDescription() -> String? { L10n.text("timeline.ax.role") }
    override func accessibilityLabel() -> String? { L10n.text("timeline.ax.label") }
    /// The clips, as elements of their own (VoiceOver can reach each, and so can a test): named with their times and
    /// track, where they are drawn; press selects one, Show Menu gives its menu (COMFORT 37, the coordinator's note).
    override func accessibilityChildren() -> [Any]? {
        var out: [ClipAXElement] = []
        for (t, track) in project.tracks.enumerated() {
            for c in track.clips {
                let x0 = viewport.x(of: Double(c.start)), x1 = viewport.x(of: Double(c.end))
                guard x1 > 0, x0 < bounds.width else { continue }
                let e = clipElements[c.id] ?? ClipAXElement(overlay: self, clip: c.id)
                clipElements[c.id] = e
                let rect = NSRect(x: max(0, x0), y: laneTop(t), width: min(bounds.width, x1) - max(0, x0), height: laneHeight)
                e.setAccessibilityFrameInParentSpace(rect)
                e.setAccessibilityLabel(L10n.text("timeline.ax.clip", project.source(c.sourceID)?.name ?? "?", formatTime(project.seconds(c.start)),
                                                  formatTime(project.seconds(c.end)), track.name))
                out.append(e)
            }
        }
        let shown = Set(out.map(\.clip))
        clipElements = clipElements.filter { shown.contains($0.key) }
        return out
    }
    private var clipElements: [UUID: ClipAXElement] = [:]

    /// Press on a clip's element: it is selected, on its track.
    func selectClip(_ id: UUID) -> Bool {
        guard let (t, i) = project.clipLocation(id) else { return false }
        session.currentTrack = project.tracks[t].id
        session.selection = project.tracks[t].clips[i].range
        return true
    }

    /// Show Menu on a clip's element: selected, and its menu where it is drawn.
    func showClipMenu(_ id: UUID) -> Bool {
        guard selectClip(id), let (t, i) = project.clipLocation(id) else { return false }
        let c = project.tracks[t].clips[i]
        let x = (viewport.x(of: Double(c.start)) + viewport.x(of: Double(c.end))) / 2
        let at = NSPoint(x: max(4, min(bounds.width - 4, x)), y: laneTop(t) + laneHeight / 2)
        // Shown right after the action returns: a menu tracked inside it would keep VoiceOver (or any caller) waiting.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let menu = CommandCenter.contextMenu(.clip)
            self.session.addTakeItems(to: menu, clip: id)
            menu.popUp(positioning: nil, at: at, in: self)
        }
        return true
    }

    override func accessibilityValue() -> Any? {
        let p = session.project
        var text = L10n.text("timeline.ax.playhead", formatTime(p.seconds(session.playhead)), formatTime(p.duration))
        if let sel = session.selection {
            text += ", " + L10n.text("timeline.ax.selection", formatTime(p.seconds(sel.lowerBound)), formatTime(p.seconds(sel.upperBound)))
        }
        if p.tracks.count > 1 { text += ", " + L10n.count("import.tracks", p.tracks.count) }
        if areaMode, let a = session.spectralArea { text += ", " + L10n.text("timeline.ax.area", L10n.message(a.shape.summarySaid.keyed)) }
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
    /// Leaving with a key down: its nudges go now, as one step (its key-up goes elsewhere).
    override func resignFirstResponder() -> Bool {
        timeline?.automationKeyUp()
        sendClipNudge()
        return true
    }

    private var timeline: TimelineView? { superview as? TimelineView }
    private var project: Project { session.project }

    private func frame(at p: NSPoint) -> Frame {
        Frame(max(0, min(Double(project.length), viewport.frame(atX: p.x)).rounded()))
    }

    // MARK: Handles and the pointer

    private var flagAttributes: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 10, weight: .medium)] }

    /// The timeline laid out in points for HandleZones: each lane's clips with their fades, the selection, the flags.
    private func zoneLayout() -> HandleZones.Layout {
        func x(_ f: Frame) -> Double { Double(viewport.x(of: Double(f))) }
        // A locked or frozen track offers no handles: what can't be changed isn't offered (COMFORT 47).
        let lanes = project.tracks.map { t in
            t.locked || project.frozen(t.id) != nil ? [] :
            t.clips.map { c in HandleZones.ClipBox(id: c.id, start: x(c.start), end: x(c.end), fadeInEnd: x(c.start + c.fadeIn), fadeOutStart: x(c.end - c.fadeOut)) }
        }
        let sel = session.selection.map { (start: x($0.lowerBound), end: x($0.upperBound)) }
        let flags = project.markers.map { m in
            HandleZones.MarkerFlag(id: m.id, x: x(m.position), width: Double((" \(m.name) " as NSString).size(withAttributes: flagAttributes).width) + 1)
        }
        return HandleZones.Layout(rulerHeight: Double(TimelineView.rulerHeight), laneHeight: Double(laneHeight), lanes: lanes, selection: sel, markers: flags)
    }

    private func zone(at p: NSPoint) -> HandleZones.Zone {
        if areaMode { return p.y < TimelineView.rulerHeight ? .ruler : .none }
        // Split, Gain, Zoom and Hand grab no handles: the whole lane is theirs.
        if ["split", "gain", "zoom", "hand"].contains(tool) {
            if p.y < TimelineView.rulerHeight { return .ruler }
            let i = laneIndex(at: p.y)
            return project.tracks.indices.contains(i) ? .lane(i) : .none
        }
        var l = zoneLayout()
        l.trimAnywhere = tool == "trim"
        return HandleZones.zone(at: Double(p.x), Double(p.y), in: l)
    }

    /// A pointer drawn from an SF Symbol, for the tools macOS has none for (the scissors, the magnifier).
    private static func symbolCursor(_ name: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) else { return .crosshair }
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return NSCursor(image: tinted, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }
    private static let scissors = symbolCursor("scissors")
    private static let zoomIn = symbolCursor("plus.magnifyingglass")
    private static let zoomOut = symbolCursor("minus.magnifyingglass")
    private static let closedHandCursor = NSCursor.closedHand

    private func cursor(for z: HandleZones.Zone) -> NSCursor {
        if areaMode, z != .ruler { return .crosshair }
        if handleDrag.map({ if case .marker = $0.kind { true } else { false } }) == true { return .closedHand }
        if case .lane = z {
            switch tool {
            case "split": return Self.scissors
            case "trim": return .arrow
            case "fade": return .crosshair
            case "gain": return .resizeUpDown
            case "zoom": return NSEvent.modifierFlags.contains(.option) ? Self.zoomOut : Self.zoomIn
            case "hand": return handDrag != nil ? .closedHand : .openHand
            default: break
            }
        }
        switch z.pointer {
        case .arrow: return .arrow
        case .iBeam: return .iBeam
        case .resizeLeftRight: return .resizeLeftRight
        case .openHand: return .openHand
        case .crosshair: return .crosshair
        case .pointingHand: return .pointingHand
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let z = zone(at: at)
        (timeline?.automation.pointer(at: at) ?? cursor(for: z)).set()
        if z != hover { hover = z; needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) { cursor(for: zone(at: convert(event.locationInWindow, from: nil))).set() }

    override func mouseExited(with event: NSEvent) {
        if hover != .none { hover = .none; needsDisplay = true }
    }

    /// Where a dragged edge may snap: clip edges, markers, the playhead and the selection's edges (⌃ turns it off).
    private func snapped(_ f: Frame, event: NSEvent?, except: Frame? = nil) -> Frame {
        let was = snapX
        defer {
            // A light tap on a Force Touch trackpad the moment an edge snaps (COMFORT 76); nothing while it stays.
            if let x = snapX, x != was { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        snapX = nil
        if event?.modifierFlags.contains(.control) == true { return f }
        var frames = project.tracks.flatMap { $0.clips.flatMap { [$0.start, $0.end] } } + project.markers.map(\.position) + [session.playhead]
        if let s = session.selection { frames += [s.lowerBound, s.upperBound] }
        frames.removeAll { $0 == except }
        let xs = frames.map { Double(viewport.x(of: Double($0))) }
        guard let hit = HandleZones.snap(Double(viewport.x(of: Double(f))), to: xs), let i = xs.firstIndex(of: hit) else { return f }
        snapX = CGFloat(hit)
        return frames[i]
    }

    /// The pointer held past an edge keeps scrolling, also when the mouse stands still.
    private func keepScrolling() {
        guard autoscroll == nil else { return }
        autoscroll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.lastDragPoint else { return }
                if p.x > self.bounds.width - 4 { self.timeline?.scroll(byPoints: 12) } else if p.x < 4 { self.timeline?.scroll(byPoints: -12) } else { self.stopScrolling(); return }
                if let e = self.laneDragEvent, self.timeline?.automation.mouseDragged(e, at: p) == true { return }
                self.drag(to: p, event: nil)
            }
        }
    }

    private func stopScrolling() { autoscroll?.invalidate(); autoscroll = nil; laneDragEvent = nil }
    /// The last drag event of an automation point's drag, replayed while the view scrolls under it.
    private var laneDragEvent: NSEvent?

    /// A handle or the selection followed to `p` (from mouseDragged, or the autoscroll timer with no event).
    private func drag(to p: NSPoint, event: NSEvent?) {
        lastDragPoint = p
        if p.x > bounds.width - 4 || p.x < 4 { keepScrolling() }
        let f = frame(at: p)
        if let h = handleDrag {
            let c: (Clip, Int)? = {
                switch h.kind {
                case .fadeIn(let id), .fadeOut(let id), .trimStart(let id), .trimEnd(let id):
                    return project.clipLocation(id).map { (project.tracks[$0.track].clips[$0.index], $0.track) }
                case .marker: return nil
                }
            }()
            switch h.kind {
            case .fadeIn: if let (clip, _) = c { handleDrag!.value = max(0, min(f - clip.start, clip.length - clip.fadeOut)) }
            case .fadeOut: if let (clip, _) = c { handleDrag!.value = max(0, min(clip.end - f, clip.length - clip.fadeIn)) }
            case .trimStart: if let (clip, _) = c { handleDrag!.value = min(snapped(f, event: event, except: clip.start), clip.end - 1) }
            case .trimEnd: if let (clip, _) = c { handleDrag!.value = max(snapped(f, event: event, except: clip.end), clip.start + 1) }
            case .marker(let id): handleDrag!.value = snapped(f, event: event, except: project.markers.first { $0.id == id }?.position)
            }
            didDrag = true
            needsDisplay = true
            return
        }
        guard let anchor = dragAnchor else { return }
        let g = snapped(f, event: event, except: anchor)
        didDrag = true
        session.selection = min(anchor, g)..<max(anchor, g)
        needsDisplay = true
    }

    /// The end of a handle's drag: one undo step, through the same operation the agent uses.
    private func commit(_ h: (kind: HandleDrag, value: Frame)) {
        let s = Double(h.value) / project.sampleRate
        switch h.kind {
        case .fadeIn(let id): session.perform("set_clip", ["clip": .string(id.uuidString), "fadeIn": .number(s)])
        case .fadeOut(let id): session.perform("set_clip", ["clip": .string(id.uuidString), "fadeOut": .number(s)])
        case .trimStart(let id): session.perform("set_clip", ["clip": .string(id.uuidString), "start": .number(s)])
        case .trimEnd(let id): session.perform("set_clip", ["clip": .string(id.uuidString), "end": .number(s)])
        case .marker(let id): session.perform("set_marker", ["marker": .string(id.uuidString), "at": .number(s)])
        }
    }

    /// Double-click on a flag: Transport › Rename Marker… for it.
    private func renameMarker(_ id: UUID) {
        session.currentMarker = id
        (window?.windowController as? EditorWindowController)?.renameMarker(nil)
    }

    /// Esc during a drag puts back what was there and ends it without a step (COMFORT.md 41).
    private func cancelDrag() -> Bool {
        guard handleDrag != nil || (dragAnchor != nil && didDrag) || selectionBeforeDrag != nil || gainDrag != nil || zoomDrag != nil else { return false }
        gainDrag = nil
        zoomDrag = nil
        if let before = selectionBeforeDrag { session.selection = before }
        handleDrag = nil
        dragAnchor = nil
        selectionBeforeDrag = nil
        snapX = nil
        cancelled = true
        stopScrolling()
        needsDisplay = true
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        defer {
            drawArea(); if !areaMode { drawHandles() } // the drawn spectrogram area and the handles, on top
            // Where dropped files would start.
            if let x = dropX { Theme.neon.setFill(); NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill() }
        }
        let rate = project.sampleRate
        let h = TimelineView.rulerHeight
        // Ruler ticks: pick a step that leaves ~90 pt between labels (with a timecode, ~115 pt for its eleven
        // characters, and never less than a tenth of a second, so that no two labels name the same picture frame).
        let secondsPerPoint = viewport.framesPerPoint / rate
        let timecode = project.timecode
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
            .filter { timecode == nil || $0 >= 0.1 }
        let step = steps.first { $0 / secondsPerPoint >= (timecode == nil ? 90 : 115) } ?? 7_200
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
            // The picture's timecode at the tick, when the document has one; else the time.
            let label = timecode.map { $0.timecode(at: Frame((t * rate).rounded()), sampleRate: rate).text }
                ?? (step < 1 ? formatTime(t) : formatTime(t, millis: false))
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
                if c.fadeIn > 0 { drawFade(from: c.start, to: c.start + c.fadeIn, rising: true, y: y, height: laneHeight, shape: c.fadeShape) }
                if c.fadeOut > 0 { drawFade(from: c.end - c.fadeOut, to: c.end, rising: false, y: y, height: laneHeight, shape: c.fadeShape) }
            }
            // On a plate: the name lies over the waveform and must be read whatever is under it. A track that plays
            // speech made with a cloned voice says so on its plate (the mark is the file's; SEND-TO-FLIMMER-API.md).
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: AutomationLanesView.nameFont, .foregroundColor: NSColor.white]
            // The name is in the track's header; on the lane only what the sound itself is: speech made with a
            // cloned voice says so on a plate (the mark is the file's; SEND-TO-FLIMMER-API.md).
            if track.clips.contains(where: { project.source($0.sourceID)?.synthetic != nil }) {
                let plate = L10n.text("clonedVoice.badge")
                let nameSize = (plate as NSString).size(withAttributes: nameAttrs)
                NSColor(white: 0, alpha: 0.6).setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: y + 20, width: nameSize.width + 10, height: nameSize.height + 4), xRadius: 4, yRadius: 4).fill()
                // Below the row where marker flags sit, so a marker near the start doesn't cover it.
                (plate as NSString).draw(at: NSPoint(x: 8, y: y + 22), withAttributes: nameAttrs)
            }
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

    /// A fade as it sounds: a straight line for a linear fade, the quarter sine of an equal-power one.
    private func drawFade(from a: Frame, to b: Frame, rising: Bool, y: CGFloat, height: CGFloat, shape: FadeShape = .linear, colour: NSColor = NSColor(white: 1, alpha: 0.55)) {
        let x0 = viewport.x(of: Double(a)), x1 = viewport.x(of: Double(b))
        guard x1 > 0, x0 < bounds.width, x1 > x0 else { return }
        let path = NSBezierPath()
        let steps = shape == .linear ? 1 : 24
        for i in 0...steps {
            let r = Double(i) / Double(steps)
            let gain = shape == .linear ? r : sin(r * .pi / 2)
            let level = rising ? gain : (shape == .linear ? 1 - r : cos(r * .pi / 2))
            let pt = NSPoint(x: x0 + (x1 - x0) * CGFloat(r), y: y + 2 + (height - 2) * CGFloat(1 - level))
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.lineWidth = 1.2
        colour.setStroke()
        path.stroke()
    }

    /// The handles: fade squares on the lane under the pointer, grips on the selection's edges, and while a handle
    /// is dragged, the draft with its value by the pointer and the line it snapped to.
    private func drawHandles() {
        let h = TimelineView.rulerHeight
        let hoverLane: Int? = {
            switch hover {
            case .lane(let i): return i
            case .fadeIn(let id), .fadeOut(let id), .trimStart(let id), .trimEnd(let id): return project.clipLocation(id)?.track
            default: return nil
            }
        }()
        if let lane = hoverLane, handleDrag == nil, let track = project.tracks[safe: lane], !track.locked, project.frozen(track.id) == nil {
            let top = laneTop(lane)
            for c in track.clips where viewport.x(of: Double(c.end)) - viewport.x(of: Double(c.start)) > 3 * HandleZones.fadeHandle {
                let box = HandleZones.ClipBox(id: c.id, start: Double(viewport.x(of: Double(c.start))), end: Double(viewport.x(of: Double(c.end))),
                                              fadeInEnd: Double(viewport.x(of: Double(c.start + c.fadeIn))), fadeOutStart: Double(viewport.x(of: Double(c.end - c.fadeOut))))
                for (x, hot) in [(CGFloat(box.fadeInHandle), hover == .fadeIn(clip: c.id)), (CGFloat(box.fadeOutHandle), hover == .fadeOut(clip: c.id))] {
                    let s = HandleZones.fadeHandle
                    (hot ? Theme.neon : NSColor(white: 1, alpha: 0.7)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x - s / 2, y: top + 2, width: s, height: s), xRadius: 2, yRadius: 2).fill()
                }
            }
        }
        if let sel = session.selection {
            for (edge, hot) in [(sel.lowerBound, hover == .selectionStart), (sel.upperBound, hover == .selectionEnd)] {
                let x = viewport.x(of: Double(edge))
                (hot ? Theme.neon : Theme.neon.withAlphaComponent(0.7)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 3, y: h, width: 6, height: 12), xRadius: 2, yRadius: 2).fill()
            }
        }
        if let z = zoomDrag, abs(z.x - z.startX) >= 4 {
            Theme.neon.withAlphaComponent(0.15).setFill()
            NSRect(x: min(z.x, z.startX), y: h, width: abs(z.x - z.startX), height: bounds.height - h).fill()
        }
        guard let d = handleDrag else { drawDragValue(); return }
        switch d.kind {
        case .fadeIn(let id), .fadeOut(let id):
            if let l = project.clipLocation(id) {
                let c = project.tracks[l.track].clips[l.index]
                if case .fadeIn = d.kind { drawFade(from: c.start, to: c.start + d.value, rising: true, y: laneTop(l.track), height: laneHeight, shape: c.fadeShape, colour: Theme.neon) }
                else { drawFade(from: c.end - d.value, to: c.end, rising: false, y: laneTop(l.track), height: laneHeight, shape: c.fadeShape, colour: Theme.neon) }
            }
        case .trimStart(let id), .trimEnd(let id):
            if let l = project.clipLocation(id) {
                let c = project.tracks[l.track].clips[l.index]
                let x = viewport.x(of: Double(d.value))
                let old = viewport.x(of: Double({ if case .trimStart = d.kind { c.start } else { c.end } }()))
                Theme.neon.withAlphaComponent(0.15).setFill()
                NSRect(x: min(x, old), y: laneTop(l.track), width: abs(x - old), height: laneHeight).fill()
                Theme.neon.setFill()
                NSRect(x: x - 1, y: laneTop(l.track), width: 2, height: laneHeight).fill()
            }
        case .marker:
            Theme.marker.setFill()
            NSRect(x: viewport.x(of: Double(d.value)) - 1, y: h, width: 2, height: bounds.height - h).fill()
        }
        drawDragValue()
    }

    /// The value by the pointer while dragging (COMFORT.md 18): a fade's length, an edge's time, the selection's length.
    private func drawDragValue() {
        if let x = snapX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: TimelineView.rulerHeight)); line.line(to: NSPoint(x: x, y: bounds.height))
            line.setLineDash([3, 3], count: 2, phase: 0)
            Theme.neon.setStroke()
            line.stroke()
        }
        guard let p = lastDragPoint else { return }
        let text: String
        if let g = gainDrag {
            text = L10n.text("timeline.drag.gain", L10n.number(g.db, 1))
        } else if let d = handleDrag {
            let s = project.seconds(d.value)
            switch d.kind {
            case .fadeIn, .fadeOut: text = L10n.text("timeline.drag.fade", formatTime(s))
            case .trimStart, .trimEnd, .marker: text = formatTime(s)
            }
        } else if let sel = session.selection, didDrag {
            text = L10n.text("timeline.drag.length", formatTime(project.seconds(Frame(sel.count))))
        } else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: min(p.x + 12, bounds.width - size.width - 12), y: max(TimelineView.rulerHeight, p.y - size.height - 10), width: size.width + 8, height: size.height + 4)
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attrs)
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
        cancelled = false
        // A handle under the pointer is grabbed (the same zone the pointer showed).
        if !areaMode {
            let z = zone(at: p)
            func clip(_ id: UUID) -> Clip? { project.clipLocation(id).map { project.tracks[$0.track].clips[$0.index] } }
            switch z {
            case .marker(let id):
                if event.clickCount == 2 { renameMarker(id); return }
                if let m = project.markers.first(where: { $0.id == id }) { handleDrag = (.marker(id), m.position); didDrag = false; NSCursor.closedHand.set(); return }
            case .fadeIn(let id): if let c = clip(id) { handleDrag = (.fadeIn(id), c.fadeIn); didDrag = false; return }
            case .fadeOut(let id): if let c = clip(id) { handleDrag = (.fadeOut(id), c.fadeOut); didDrag = false; return }
            case .trimStart(let id): if let c = clip(id) { handleDrag = (.trimStart(id), c.start); didDrag = false; return }
            case .trimEnd(let id): if let c = clip(id) { handleDrag = (.trimEnd(id), c.end); didDrag = false; return }
            case .selectionStart, .selectionEnd:
                if let s = session.selection, event.clickCount == 1 {
                    selectionBeforeDrag = .some(s)
                    dragAnchor = z == .selectionStart ? s.upperBound : s.lowerBound
                    didDrag = false
                    return
                }
            default: break
            }
        }
        if p.y < TimelineView.rulerHeight {
            session.seek(f)
            dragAnchor = nil
            return
        }
        if let t = project.tracks[safe: laneIndex(at: p.y)] { session.currentTrack = t.id }
        if !areaMode, let lane = project.tracks[safe: laneIndex(at: p.y)] {
            let under = lane.clips.first { $0.range.contains(f) }
            // The tools that change a clip say at once why they can't on a locked or frozen track, before any drag.
            if ["split", "fade", "gain", "trim"].contains(tool), under != nil, lane.locked || project.frozen(lane.id) != nil {
                session.say(lane.locked ? L10n.text("reason.trackLocked", lane.name) : L10n.text("freeze.refused", lane.name), .info)
                return
            }
            switch tool {
            case "split":
                session.perform("split", ["at": .number(project.seconds(f)), "tracks": .array([.string(lane.id.uuidString)])])
                return
            case "fade":
                if let c = under {
                    handleDrag = f - c.start < c.length / 2 ? (.fadeIn(c.id), c.fadeIn) : (.fadeOut(c.id), c.fadeOut)
                    didDrag = false
                }
                return
            case "gain":
                if let c = under { gainDrag = (c.id, p.y, c.gainDB, c.gainDB) }
                return
            case "zoom":
                zoomDrag = (p.x, p.x)
                return
            case "hand":
                handDrag = p.x
                Self.closedHandCursor.set()
                return
            case "trim":
                return
            default: break
            }
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
            selectionBeforeDrag = .some(session.selection)
            dragAnchor = f
            didDrag = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if timeline?.automation.mouseDragged(event, at: p) == true {
            // A point dragged past the edge scrolls the view too, also with the mouse standing still (COMFORT 74).
            lastDragPoint = p
            laneDragEvent = event
            if p.x > bounds.width - 4 || p.x < 4 { keepScrolling() }
            return
        }
        if var d = drawing {
            d.points.append(p)
            drawing = d
            didDrag = true
            updateArea(d)
            return
        }
        if cancelled { return }
        if let g = gainDrag {
            // 1 dB for every 4 points up or down, from where the drag began.
            gainDrag?.db = max(-96, min(24, ((g.startDB + Double(g.startY - p.y) / 4) * 2).rounded() / 2))
            lastDragPoint = p
            needsDisplay = true
            return
        }
        if zoomDrag != nil { zoomDrag?.x = p.x; needsDisplay = true; return }
        if let start = handDrag {
            timeline?.scroll(byPoints: start - p.x)
            handDrag = p.x
            return
        }
        if p.y < TimelineView.rulerHeight && dragAnchor == nil && handleDrag == nil {
            session.seek(frame(at: p))
            return
        }
        guard handleDrag != nil || dragAnchor != nil else { return }
        drag(to: p, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if timeline?.automation.mouseUp(event, at: convert(event.locationInWindow, from: nil)) == true { stopScrolling(); return }
        stopScrolling()
        snapX = nil
        lastDragPoint = nil
        if cancelled { cancelled = false; dragAnchor = nil; handleDrag = nil; gainDrag = nil; zoomDrag = nil; handDrag = nil; needsDisplay = true; return }
        if let g = gainDrag {
            gainDrag = nil
            if g.db != g.startDB { session.perform("set_clip", ["clip": .string(g.clip.uuidString), "gainDB": .number(g.db)]) }
            needsDisplay = true
            return
        }
        if let z = zoomDrag {
            zoomDrag = nil
            if abs(z.x - z.startX) < 4 {
                timeline?.zoom(by: event.modifierFlags.contains(.option) ? 0.5 : 2, around: z.startX)
            } else {
                let a = frame(at: NSPoint(x: min(z.x, z.startX), y: 0)), b = frame(at: NSPoint(x: max(z.x, z.startX), y: 0))
                timeline?.zoom(to: a..<max(b, a + 1))
            }
            needsDisplay = true
            return
        }
        if handDrag != nil { handDrag = nil; NSCursor.openHand.set(); return }
        if let h = handleDrag {
            handleDrag = nil
            if case .marker(let id) = h.kind { session.currentMarker = id }
            if didDrag { commit(h) } else if case .marker = h.kind { session.seek(h.value) }
            needsDisplay = true
            return
        }
        selectionBeforeDrag = nil
        needsDisplay = true
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

    override func keyUp(with event: NSEvent) {
        timeline?.automationKeyUp()
        sendClipNudge()
        super.keyUp(with: event)
    }

    /// Clips nudged with ⌥←/⌥→ while the key is down, and by how much so far.
    private var heldClipNudge: (ids: [UUID], frames: Frame)?

    /// The clips a nudge moves: on the current track, those in the selection, else the one under the playhead.
    private func nudgeTargets() -> [UUID] {
        let track = project.tracks.first { $0.id == session.currentTrack }
            ?? project.tracks.first { $0.clips.contains { $0.start <= session.playhead && $0.end > session.playhead } }
        guard let track else { return [] }
        if let sel = session.selection { return track.clips.filter { $0.start < sel.upperBound && $0.end > sel.lowerBound }.map(\.id) }
        return track.clips.filter { $0.start <= session.playhead && $0.end > session.playhead }.map(\.id)
    }

    private func nudgeClips(_ direction: Int, big: Bool) {
        if heldClipNudge == nil {
            let ids = nudgeTargets()
            guard !ids.isEmpty else { session.say(L10n.text("nudge.none"), .info); return }
            heldClipNudge = (ids, 0)
        }
        heldClipNudge!.frames += Frame((project.sampleRate * (big ? 0.1 : 0.01)).rounded()) * Frame(direction)
        let ms = Double(heldClipNudge!.frames) / project.sampleRate * 1_000
        session.status = L10n.text("nudge.status", L10n.count("nudge.clips", heldClipNudge!.ids.count), L10n.number(ms, 0, sign: true))
    }

    private func sendClipNudge() {
        guard let n = heldClipNudge else { return }
        heldClipNudge = nil
        guard n.frames != 0 else { return }
        session.perform("move_clip", ["clips": .array(n.ids.map { .string($0.uuidString) }), "by": .number(Double(n.frames) / project.sampleRate)])
    }

    private func selectNeighbourClip(forward: Bool) {
        guard let track = project.tracks.first(where: { $0.id == session.currentTrack }) ?? project.tracks.first, !track.clips.isEmpty else { NSSound.beep(); return }
        let at = session.selection?.lowerBound ?? session.playhead
        let clips = track.clips.sorted { $0.start < $1.start }
        let next = forward ? clips.first { $0.start > at } : clips.last { $0.start < at }
        guard let c = next ?? (forward ? clips.first : clips.last) else { return }
        session.currentTrack = track.id
        session.selection = c.range
        session.seek(c.start)
    }

    override func keyDown(with event: NSEvent) {
        if timeline?.automationKey(event) == true { return }
        switch event.keyCode {
        case 49: session.togglePlay() // space
        case 36: session.seek(0) // return
        case 53 where cancelDrag(): break // escape: a drag in progress first
        case 53 where areaMode && session.spectralArea != nil: session.spectralArea = nil; needsDisplay = true // escape: the area first
        case 53: session.selection = nil // escape
        case _ where event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            && Commands.tools.contains(where: { $0.letter == event.charactersIgnoringModifiers?.lowercased() }):
            // A tool's letter (the palette's): A, S, T, F, G, B, L, P, Z, H.
            if let t = Commands.tools.first(where: { $0.letter == event.charactersIgnoringModifiers?.lowercased() }) {
                (window?.windowController as? EditorWindowController)?.chooseTool(t.id)
            }
        case 51, 117: delete(nil) // delete, forward delete
        // ⌥← ⌥→ nudge clips 10 ms, ⇧⌥ 100 ms; a held key is one step, sent when it comes up (COMFORT 35, 12).
        case 123, 124 where event.modifierFlags.contains(.option):
            nudgeClips(event.keyCode == 124 ? 1 : -1, big: event.modifierFlags.contains(.shift))
        // Tab, ⇧Tab: the next or the previous clip on the current track is selected.
        case 48: selectNeighbourClip(forward: !event.modifierFlags.contains(.shift))
        case 123: session.seek(session.playhead - Frame(project.sampleRate)) // left: 1 s
        case 124: session.seek(session.playhead + Frame(project.sampleRate))
        case 115: session.seek(0) // home
        case 119: session.seek(project.length) // end
        default: super.keyDown(with: event)
        }
    }

    // Selected automation points are cut, copied and pasted as points (COMFORT 33); otherwise the selection's audio.
    @objc func cut(_ sender: Any?) { if timeline?.activeLanes.copyPoints(cut: true) != true { session.perform("cut") } }
    @objc func copy(_ sender: Any?) { if timeline?.activeLanes.copyPoints(cut: false) != true { session.perform("copy") } }
    @objc func paste(_ sender: Any?) { if timeline?.activeLanes.pastePoints() != true { session.perform("paste") } }
    @objc func delete(_ sender: Any?) { if session.selection != nil { session.perform("delete") } else { NSSound.beep() } }
    @objc override func selectAll(_ sender: Any?) { session.perform("select_all") }

    func validate(_ item: NSMenuItem) -> Bool {
        let (ok, why): (Bool, String?) = switch item.action {
        case #selector(cut(_:)), #selector(copy(_:)): (session.selection != nil || timeline?.activeLanes.hasChosenPoints == true, L10n.text("reason.selection"))
        case #selector(delete(_:)): (session.selection != nil, L10n.text("reason.selection"))
        case #selector(paste(_:)): (AppClipboard.content != nil || timeline?.activeLanes.canPastePoints == true, L10n.text("reason.clipboardEmpty"))
        default: (true, nil)
        }
        // A command that is off says why (the comfort list), as in the menu bar's other items.
        item.toolTip = ok ? nil : why
        return ok
    }

    /// The timeline's context menu, from the command registry (the menu bar's names and checks): a spectral
    /// area's commands over an area, otherwise the timeline's.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let t = project.tracks[safe: laneIndex(at: p.y)] { session.currentTrack = t.id }
        if areaMode, session.spectralArea != nil { return CommandCenter.contextMenu(.area) }
        // A marker's flag has its own menu (COMFORT 37: one context menu per object): Rename and Delete.
        if case .marker(let id) = HandleZones.zone(at: Double(p.x), Double(p.y), in: zoneLayout()) {
            session.currentMarker = id
            return CommandCenter.contextMenu(.marker)
        }
        // A clip: it is selected, and its menu has what acts on it (cut, copy, delete, split, fades, gain).
        if !areaMode, let t = project.tracks[safe: laneIndex(at: p.y)], let c = t.clips.first(where: { $0.range.contains(frame(at: p)) }) {
            if session.selection.map({ !($0.lowerBound <= c.start && $0.upperBound >= c.end) }) ?? true { session.selection = c.range }
            // A recorded clip's menu also lists its takes (Recording.swift).
            let menu = CommandCenter.contextMenu(.clip)
            session.addTakeItems(to: menu, clip: c.id)
            return menu
        }
        return CommandCenter.contextMenu(.timeline)
    }
}

extension TimelineOverlay: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One clip on the timeline, as an accessibility element (TimelineOverlay.accessibilityChildren).
@MainActor
final class ClipAXElement: NSAccessibilityElement {
    weak var overlay: TimelineOverlay?
    let clip: UUID

    init(overlay: TimelineOverlay, clip: UUID) {
        self.overlay = overlay
        self.clip = clip
        super.init()
        setAccessibilityParent(overlay)
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription(L10n.text("timeline.ax.clip.role"))
        setAccessibilityIdentifier("timeline.clip")
    }

    override func accessibilityPerformPress() -> Bool { overlay?.selectClip(clip) ?? false }
    override func accessibilityPerformShowMenu() -> Bool { overlay?.showClipMenu(clip) ?? false }
}
