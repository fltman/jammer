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
    /// Where the tracks' lanes lie, scrolled (LaneLayout; the timeline keeps it current).
    var lanes = LaneLayout(tracks: 0, rulerHeight: 26, areaHeight: 0)

    func frame(atX x: CGFloat) -> Double { start + Double(x) * framesPerPoint }
    func x(of frame: Double) -> CGFloat { CGFloat((frame - start) / framesPerPoint) }
}

/// The timeline: Metal waveform lanes under an AppKit overlay that draws the
/// ruler, selection and markers and handles all input; the playhead is a layer of its own over both (PlayheadView).
@MainActor
final class TimelineView: NSView {
    static let rulerHeight: CGFloat = 26

    let session: EditorSession
    let viewport = Viewport()
    private let metal: WaveformMetalView
    private let overlay: TimelineOverlay
    /// The playhead, a layer of its own over everything: moved, never drawn (TimelineRedraw).
    private let playheadView = PlayheadView()

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
                                     stripLanes.bottomAnchor.constraint(equalTo: timeScroller.topAnchor), stripHeight])
        // Time's scroller, along the bottom (Anders: "och scroll vid långa klipp"): where in the document the view is,
        // and a way to move it with a mouse that has no sideways wheel.
        NSLayoutConstraint.activate([
            timeScroller.leadingAnchor.constraint(equalTo: leadingAnchor), timeScroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeScroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            timeScroller.heightAnchor.constraint(equalToConstant: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)),
        ])
        for v in [metal, spectrogram, automation, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: stripLanes.topAnchor),
            ])
        }
        // Over the waveform, the automation lanes and the strips' rows, as the line drawn in them used to be; under the
        // overlay, which paints nothing opaque, so its handles, the drawn area and the drop line stay on top and take
        // the clicks, as before.
        playheadView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playheadView, positioned: .below, relativeTo: overlay)
        NSLayoutConstraint.activate([
            playheadView.leadingAnchor.constraint(equalTo: leadingAnchor), playheadView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playheadView.topAnchor.constraint(equalTo: topAnchor), playheadView.bottomAnchor.constraint(equalTo: timeScroller.topAnchor),
        ])
        automation.onActivate = { [weak self] in self?.stripLanes.isActive = false; self?.automation.isActive = true }
        stripLanes.onActivate = { [weak self] in
            guard let self else { return }
            automation.isActive = false
            stripLanes.isActive = true
            window?.makeFirstResponder(overlay)   // the keys stay the timeline's, which offers them to the lanes
        }
        overlay.onChange = { [weak self] in self?.refresh(waveform: true) }
        session.trackZoom = PanelMemory.value("tracks.zoom", session) ?? 1
        session.trackScroll = PanelMemory.value("tracks.scroll", session) ?? 0
        observe()
        observePlayhead()
        observeCurrentTrack()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var firstResponderView: NSView { overlay }
    /// Where the track lanes are (the ruler on top, the strip rows below excluded): the track headers line up with it.
    var tracksArea: NSView { overlay }

    override func layout() {
        super.layout()
        updateLanes()
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
    /// The page it turned, if it did; the caller draws the timeline again (once, TimelineRedraw).
    @discardableResult
    private func follow() -> FollowPolicy.Decision {
        // While recording the playhead moves even where nothing plays (past the end): followed the same way.
        guard session.isPlaying || session.recording != nil else {
            lastPageAt = nil
            showFollowPaused(false)
            return .stay
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = ProcessInfo.processInfo.systemUptime
        let width = Double(bounds.width), fpp = viewport.framesPerPoint, rate = session.project.sampleRate
        let decision = FollowPolicy.next(start: viewport.start, playhead: Double(session.playhead), width: width, framesPerPoint: fpp,
                                         sampleRate: rate, lastPage: lastPageAt, now: now, reduceMotion: reduce)
        if case .page(let start) = decision {
            viewport.start = start
            lastPageAt = now
        }
        let tooClose = FollowPolicy.pagesPerSecond(width: width, framesPerPoint: fpp, sampleRate: rate) > FollowPolicy.limit(reduceMotion: reduce)
        showFollowPaused(tooClose && (decision == .paused || !followChip.isHidden))
        return decision
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
        updateLanes()
        if waveform { metal.invalidate(); spectrogram.refresh() }
        placePlayhead()
        overlay.needsDisplay = true
        automation.invalidate()
        stripLanes.invalidate()
        sizeStripLanes()
    }

    /// The project, the selection or playing changed: the timeline is drawn again (once, a page turned with it included).
    private func observe() {
        withObservationTracking {
            _ = session.version
            _ = session.selection
            _ = session.isPlaying
            _ = session.trackZoom
            _ = session.trackScroll
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.changed(.content)
                self.observe()
            }
        }
    }

    /// Only the playhead moved (60 times a second while playing): its layer is moved; the timeline is drawn again
    /// only when following turns a page.
    private func observePlayhead() {
        withObservationTracking {
            _ = session.playhead
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.changed(.playhead)
                self.observePlayhead()
            }
        }
    }

    private func changed(_ change: TimelineRedraw.Change) {
        if change == .content { revealNewTracks() }
        let plan = TimelineRedraw.plan(change, follow: follow())
        if plan.refreshes > 0 { refresh(waveform: true) } else if plan.movePlayhead { placePlayhead() }
    }

    // MARK: Tracks scrolled in height

    /// The lanes laid out for the tracks' area as it is now, the zoom and scroll the session keeps; a scroll past the
    /// end (the window grew, a track went) is brought back.
    private func updateLanes() {
        let l = LaneLayout(tracks: session.project.tracks.count, rulerHeight: Double(Self.rulerHeight),
                           areaHeight: Double(overlay.bounds.height - Self.rulerHeight), zoom: session.trackZoom, scrollY: session.trackScroll)
        viewport.lanes = l
        if overlay.bounds.height > Self.rulerHeight, l.scrollY != session.trackScroll { session.trackScroll = l.scrollY }
        updateTrackScroller()
        updateTimeScroller()
    }

    /// The tracks scrolled by `dy` points (a vertical swipe or wheel: always the tracks, nothing when they fit).
    func scrollTracks(by dy: Double) {
        set(viewport.lanes.scrolled(by: dy))
    }

    /// Track height ×`factor` (⌃⌘+ ⌃⌘−, ⌥-wheel), the lane under `anchorY` staying where it is.
    func zoomTracks(by factor: Double, anchorY: CGFloat? = nil) {
        set(viewport.lanes.zoomed(by: factor, anchorY: anchorY.map(Double.init)))
    }

    /// Every track in view when they can be (⌃⌘0).
    func fitTracks() { set(viewport.lanes.fitted()) }

    /// Track `i` brought into view: at once, or with a short glide when Reduce Motion is off and `animated`.
    func revealTrack(_ i: Int, animated: Bool = false) {
        let target = viewport.lanes.revealing(i)
        guard target.scrollY != viewport.lanes.scrollY else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { set(target); return }
        glide?.invalidate()
        let from = viewport.lanes.scrollY, to = target.scrollY
        var step = 0
        glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                step += 1
                let k = min(1, Double(step) / 12), eased = k * k * (3 - 2 * k)
                self.set(self.viewport.lanes.scrolled(to: from + (to - from) * eased))
                if k >= 1 { self.glide?.invalidate(); self.glide = nil }
            }
        }
    }
    private var glide: Timer?

    private func set(_ l: LaneLayout) {
        guard l.zoom != session.trackZoom || l.scrollY != session.trackScroll else { return }
        session.trackZoom = l.zoom
        session.trackScroll = l.scrollY
        keepTrackView()
    }

    /// The track view kept per document, like the panels: written once the scrolling has settled.
    private func keepTrackView() {
        keepTask?.cancel()
        keepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            PanelMemory.keep(value: self.session.trackZoom, "tracks.zoom", self.session)
            PanelMemory.keep(value: self.session.trackScroll, "tracks.scroll", self.session)
        }
    }
    private var keepTask: Task<Void, Never>?

    /// The selected track (a click, Tab, ↑↓ among the headers, the agent's select_track) is brought into view.
    private func observeCurrentTrack() {
        withObservationTracking {
            _ = session.currentTrack
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let id = self.session.currentTrack, let i = self.session.project.tracks.firstIndex(where: { $0.id == id }) {
                    self.updateLanes()
                    self.revealTrack(i)
                }
                self.observeCurrentTrack()
            }
        }
    }

    /// A track added (at the bottom, or anywhere) is brought into view; the tracks a document opens with are not.
    private func revealNewTracks() {
        let ids = session.project.tracks.map(\.id)
        defer { knownTracks = Set(ids) }
        guard !knownTracks.isEmpty else { return }
        if let i = ids.lastIndex(where: { !knownTracks.contains($0) }) {
            updateLanes()
            revealTrack(i)
        }
    }
    private var knownTracks: Set<UUID> = []

    /// The tracks the selection reaches into (those with a clip in it), by index.
    var tracksInSelection: [Int] {
        guard let sel = session.selection else { return [] }
        return session.project.tracks.indices.filter { t in session.project.tracks[t].clips.contains { $0.start < sel.upperBound && $0.end > sel.lowerBound } }
    }

    // MARK: Time's scroller

    /// Always there, under the tracks and the strips' rows: its knob is the share of the document in view.
    private lazy var timeScroller: NSScroller = {
        let s = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 15))
        s.scrollerStyle = .legacy
        s.translatesAutoresizingMaskIntoConstraints = false
        s.target = self
        s.action = #selector(timeScrollerMoved(_:))
        s.setAccessibilityLabel(L10n.text("timeline.scroller.time.ax"))
        addSubview(s)
        return s
    }()

    /// The document's length and what is in view, in frames: the stretch the scroller can move over.
    private var timeSpan: (total: Double, visible: Double) {
        let visible = Double(viewport.width) * viewport.framesPerPoint
        return (max(Double(session.project.length), viewport.start + visible, visible), visible)
    }

    private func updateTimeScroller() {
        let (total, visible) = timeSpan
        let room = total - visible
        timeScroller.isEnabled = room > 1
        timeScroller.knobProportion = CGFloat(min(1, visible / max(1, total)))
        timeScroller.doubleValue = room > 1 ? min(1, max(0, viewport.start / room)) : 0
    }

    @objc private func timeScrollerMoved(_ s: NSScroller) {
        let (total, visible) = timeSpan
        switch s.hitPart {
        case .decrementPage: scroll(byPoints: -viewport.width * 0.9)
        case .incrementPage: scroll(byPoints: viewport.width * 0.9)
        default:
            viewport.start = s.doubleValue * (total - visible)
            refresh(waveform: true)
        }
    }

    // MARK: The tracks' scroller

    private lazy var trackScroller: NSScroller = {
        let s = NSScroller(frame: .zero)
        s.scrollerStyle = NSScroller.preferredScrollerStyle
        s.knobStyle = .light
        s.target = self
        s.action = #selector(trackScrollerMoved(_:))
        s.isHidden = true
        s.setAccessibilityLabel(L10n.text("timeline.scroller.tracks.ax"))
        addSubview(s, positioned: .above, relativeTo: overlay)
        return s
    }()

    /// Shown only while the tracks scroll, over the right edge of the lanes they scroll in.
    private func updateTrackScroller() {
        let l = viewport.lanes
        trackScroller.isHidden = !l.overflows
        guard l.overflows else { return }
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: trackScroller.scrollerStyle)
        // The overlay is flipped and fills the timeline's width; this view isn't flipped.
        let inOverlay = NSRect(x: overlay.bounds.width - w, y: l.lanesTop, width: w, height: l.visibleHeight)
        trackScroller.frame = overlay.convert(inOverlay, to: self)
        trackScroller.knobProportion = CGFloat(l.visibleHeight / max(1, l.contentHeight))
        trackScroller.doubleValue = l.maxScroll > 0 ? l.scrollY / l.maxScroll : 0
    }

    @objc private func trackScrollerMoved(_ s: NSScroller) {
        let l = viewport.lanes
        switch s.hitPart {
        case .decrementPage: scrollTracks(by: -l.visibleHeight * 0.9)
        case .incrementPage: scrollTracks(by: l.visibleHeight * 0.9)
        default: set(l.scrolled(to: s.doubleValue * l.maxScroll))
        }
    }

    /// The playhead's layer where the playhead is now (the view's VoiceOver value is asked for when it is read, so
    /// nothing is announced as it moves).
    private func placePlayhead() {
        playheadView.place(x: viewport.x(of: Double(session.playhead)))
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
        /// The picture's column for pixel 0, and its columns per pixel (WaveformRemap): the same layout as before
        /// (they took two of the padding floats).
        var offsetCols: Float = 0, scale: Float = 1, scroll: Float = 0
        var wave: SIMD4<Float>
        var waveSelected: SIMD4<Float>
        var background: SIMD4<Float>
        var laneBackground: SIMD4<Float>
        var selectionBackground: SIMD4<Float>
        var centerLine: SIMD4<Float>
        /// Below this, in pixels, no lane is drawn (the bottom edge row while the tracks scroll).
        var lanesBottom: Float
    }

    private let session: EditorSession
    private let viewport: Viewport
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var columnBuffer: MTLBuffer?
    /// What `columnBuffer` shows.
    private var shownKey: [Double] = []
    /// The geometry of what `columnBuffer` shows (its first frame and frames per column), and its shape (columns,
    /// lanes, channels): a new view is drawn from it, mapped, until its own columns are made (WaveformRemap).
    private var shownStart = 0.0, shownFpc = 1.0
    private var shownShape: [Int] = []
    /// The view whose columns are wanted now (the job's answer is taken only if it is still this one).
    private var wantedKey: [Double] = []
    /// Zoomed in past the peak index, exact samples come from the files on a
    /// background task (one at a time, always the latest view) and replace the
    /// block-level picture drawn meanwhile. The main thread never reads a file.
    private var exactInFlight = false
    private var wantedExact: (key: [Double], start: Double, fpc: Double, shape: [Int], job: @Sendable () -> [SIMD2<Float>])?

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

    /// A view's columns, made off the draw: one job at a time, always the latest view wanted (a view passed while a
    /// job ran is skipped). The answer is shown only if it is still the view wanted, else the next is started.
    private func requestExact(_ key: [Double], start: Double, fpc: Double, shape: [Int], _ job: @escaping @Sendable () -> [SIMD2<Float>]) {
        wantedExact = (key, start, fpc, shape, job)
        if !exactInFlight { startExact() }
    }

    private func startExact() {
        guard let (key, start, fpc, shape, job) = wantedExact else { return }
        wantedExact = nil
        exactInFlight = true
        let span = Perf.Span("waveform.exact")
        Task.detached(priority: .userInitiated) { [weak self] in
            let values = job()
            span.end()
            await MainActor.run {
                guard let self else { return }
                self.exactInFlight = false
                if self.wantedKey == key, shape == self.shownShape {
                    self.columnBuffer = self.device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
                    self.shownKey = key
                    self.shownStart = start; self.shownFpc = fpc
                    self.needsDisplay = true
                }
                if let next = self.wantedExact, next.key != key { self.startExact() } else { self.wantedExact = nil }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        let span = Perf.Span("waveform.draw")
        defer { span.end() }
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
            // Only with nothing to show, or after a change of size, are the columns made here (from the peaks, at
            // once). Otherwise the picture there is drawn onto this view, mapped, while a job makes this view's own:
            // a draw stays well under a frame however many tracks there are (it took 56–66 ms for 24).
            // Never from the files here, on the main thread: a source without peaks yet is drawn empty and comes when
            // its peaks do (2026-11-27: allowRaw was true with the whole hour in view, and the first draw of a document
            // of 24 tracks read every clip of under 8 million frames from disk, 156 s with the window unanswering).
            if WaveformRemap.computesInDraw(hasPicture: columnBuffer != nil, sameShape: shape == shownShape) {
                let values = Self.columnValues(project, start: start, fpc: fpc, columns: columns, lanes: lanes, channels: channels,
                                               peaks: peaks, pool: pool, allowRaw: false)
                columnBuffer = device?.makeBuffer(bytes: values, length: values.count * MemoryLayout<SIMD2<Float>>.stride)
                shownStart = start; shownFpc = fpc; shownShape = shape
                shownKey = needsFiles ? [] : key
            }
            if key != shownKey, key != wantedKey {
                wantedKey = key
                // Exact samples where the peaks are too coarse (zoomed in past a peak block), the peaks elsewhere. With
                // more in view than that, a source without peaks waits for them rather than being read whole from disk.
                requestExact(key, start: start, fpc: fpc, shape: shape) {
                    Self.columnValues(project, start: start, fpc: fpc, columns: columns, lanes: lanes, channels: channels,
                                      peaks: peaks, pool: pool, allowRaw: needsFiles)
                }
            }
        }
        guard let columnBuffer else { return }
        func rgba(_ c: NSColor, _ a: CGFloat? = nil) -> SIMD4<Float> {
            let s = c.usingColorSpace(.sRGB) ?? c
            return SIMD4(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), Float(a ?? s.alphaComponent))
        }
        // Where the lanes are seen, scrolled (LaneLayout): from under the ruler and the top edge row to the bottom one.
        let layout = viewport.lanes
        let ruler = Float(layout.lanesTop * scale)
        let laneHeight = Float(layout.laneHeight * scale)
        var selStart: Float = -1, selEnd: Float = -1
        if let sel = session.selection {
            selStart = Float(viewport.x(of: Double(sel.lowerBound)) * CGFloat(scale))
            selEnd = Float(viewport.x(of: Double(sel.upperBound)) * CGFloat(scale))
        }
        let map = WaveformRemap.mapping(viewStart: viewport.start, viewFramesPerColumn: fpc, shownStart: shownStart, shownFramesPerColumn: shownFpc)
        var u = Uniforms(size: SIMD2(Float(drawableSize.width), Float(drawableSize.height)), rulerHeight: ruler,
                         laneHeight: laneHeight, columns: UInt32(columns), lanes: UInt32(lanes), channels: UInt32(channels),
                         selectionStart: selStart, selectionEnd: selEnd, offsetCols: map.offset, scale: map.scale,
                         wave: rgba(Theme.neon, 0.92), waveSelected: rgba(.white, 0.95), background: rgba(Theme.ink),
                         laneBackground: rgba(Theme.lane), selectionBackground: rgba(Theme.neon, 1) * SIMD4(0.22, 0.22, 0.22, 1),
                         centerLine: rgba(.white, 0.12), lanesBottom: Float(layout.lanesBottom * scale))
        u.scroll = Float(layout.scrollY * scale)
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
        observeTool()
    }

    /// Another tool (a key, the palette, the menu) with the mouse still over the lanes: the pointer it gives, now.
    private func observeTool() {
        withObservationTracking {
            _ = session.tool
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPointer()
                self.observeTool()
            }
        }
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
        for (t, track) in project.tracks.enumerated() where viewport.lanes.visibleLanes.contains(t) {
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
        if let timeline {
            let h = viewport.lanes.hidden(timeline.tracksInSelection)
            if h.above.count + h.below.count > 0 { text += ", " + L10n.count("timeline.hidden.ax", h.above.count + h.below.count) }
        }
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
        var layout = HandleZones.Layout(rulerHeight: Double(TimelineView.rulerHeight), laneHeight: Double(laneHeight), lanes: lanes, selection: sel, markers: flags)
        layout.scrolling = viewport.lanes
        return layout
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
        pointer(at: at).set()
        if z != hover { hover = z; needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)).set() }

    /// The pointer for a place: a grip of the drawn box, an automation point, or the zone's (the same zones a press
    /// takes).
    private func pointer(at at: NSPoint) -> NSCursor {
        if let g = boxGrip(at: at) { return Self.cursor(for: g, dragging: boxDrag != nil) }
        return timeline?.automation.pointer(at: at) ?? cursor(for: zone(at: at))
    }

    /// The pointer for where the mouse is now (COMFORT 45). `afterDrag`: a drag of the timeline's own ended, so when
    /// the mouse is outside, the arrow.
    private func refreshPointer(afterDrag: Bool = false) {
        Pointer.refresh(self, ours: afterDrag) { at in pointer(at: at) }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != .none { hover = .none; needsDisplay = true }
        Pointer.left(self)
    }

    /// ⌥ turns the zoom tool's plus into a minus without the mouse moving.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if tool == "zoom" { refreshPointer() }
    }

    override func viewDidHide() { Pointer.gone(self); super.viewDidHide() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { Pointer.gone(self) }
        super.viewWillMove(toWindow: newWindow)
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
                var moved = false
                if p.x > self.bounds.width - 4 { self.timeline?.scroll(byPoints: 12); moved = true } else if p.x < 4 { self.timeline?.scroll(byPoints: -12); moved = true }
                if let dy = self.verticalAutoscroll(at: p) { self.timeline?.scrollTracks(by: dy); moved = true }
                guard moved else { self.stopScrolling(); return }
                if let e = self.laneDragEvent, self.timeline?.automation.mouseDragged(e, at: p) == true { return }
                self.drag(to: p, event: nil)
            }
        }
    }

    private func stopScrolling() { autoscroll?.invalidate(); autoscroll = nil; laneDragEvent = nil }
    /// The last drag event of an automation point's drag, replayed while the view scrolls under it.
    private var laneDragEvent: NSEvent?

    /// A handle or the selection followed to `p` (from mouseDragged, or the autoscroll timer with no event).
    /// Held at the top or bottom of the tracks while they scroll, a drag that ranges over tracks (the selection, the Zoom
    /// tool's range) scrolls them; drags that are a lane's own (a handle, a point, the Gain tool, a drawn area) don't.
    private func verticalAutoscroll(at p: NSPoint) -> Double? {
        let l = viewport.lanes
        guard l.overflows, handleDrag == nil, gainDrag == nil, handDrag == nil, laneDragEvent == nil, drawing == nil else { return nil }
        if p.y < l.lanesTop + 4 { return -12 }
        if p.y > l.lanesBottom - 4 { return 12 }
        return nil
    }

    private func drag(to p: NSPoint, event: NSEvent?) {
        lastDragPoint = p
        if p.x > bounds.width - 4 || p.x < 4 || verticalAutoscroll(at: p) != nil { keepScrolling() }
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
        Perf.count("timeline.overlay.draw")
        defer {
            // The drawn spectrogram area and the handles, on top, in the lanes that are seen.
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: viewport.lanes.lanesTop, width: bounds.width, height: viewport.lanes.visibleHeight).clip()
            drawArea(); if !areaMode { drawHandles() }
            NSGraphicsContext.restoreGraphicsState()
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

        // Clip edges and track names, in the lanes that are seen (LaneLayout), cut off at the edge rows.
        let layout = viewport.lanes
        let laneHeight = CGFloat(layout.laneHeight)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: layout.lanesTop, width: bounds.width, height: layout.visibleHeight).clip()
        for (i, track) in project.tracks.enumerated() where layout.visibleLanes.contains(i) {
            let y = CGFloat(layout.laneTop(i))
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
            // This lane's own sources, until their peaks are there: read now (how far), or waiting their turn.
            if session.project.length > Frame(project.sampleRate * 600),
               let status = PeakReading.status(of: track.clips.map(\.sourceID), progress: session.peakProgress) {
                let text = switch status {
                case .reading(let p): L10n.text("timeline.reading", String(Int(p * 100)))
                case .waiting: L10n.text("timeline.readingWaiting")
                }
                (text as NSString).draw(at: NSPoint(x: 8, y: y + 24), withAttributes: nameAttrs)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawHiddenTracks()

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
        // The playhead is not drawn here: it is a layer of its own (PlayheadView), moved as it plays.
    }

    /// The hidden tracks' mark, in the bottom edge row while the tracks scroll (a row of its own: it never lies over a
    /// lane, a handle or a point): how many tracks out of view, above and below, the selection reaches into. Steady,
    /// no motion; a click goes to the nearest.
    private func drawHiddenTracks() {
        hiddenMarks = []
        let l = viewport.lanes
        guard l.overflows, let timeline else { return }
        let h = l.hidden(timeline.tracksInSelection)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.neon]
        var right = bounds.width - 6 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        for (text, track) in [(h.below.isEmpty ? nil : L10n.count("timeline.hidden.below", h.below.count), h.below.first),
                              (h.above.isEmpty ? nil : L10n.count("timeline.hidden.above", h.above.count), h.above.last)] {
            guard let text, let track else { continue }
            let size = (text as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: right - size.width - 8, y: l.lanesBottom, width: size.width + 8, height: l.edge)
            (text as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.midY - size.height / 2), withAttributes: attrs)
            hiddenMarks.append((rect, track))
            right = rect.minX - 8
        }
    }
    /// Where the mark's parts are drawn, and the track each goes to.
    private var hiddenMarks: [(rect: NSRect, track: Int)] = []

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
    private var laneHeight: CGFloat { CGFloat(viewport.lanes.laneHeight) }
    private func laneTop(_ i: Int) -> CGFloat { CGFloat(viewport.lanes.laneTop(i)) }
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

    // MARK: The drawn box's grips (the comfort sweep of 2026-11-25, [2])

    /// A grip being dragged: which, the box as it was, where the drag began, and its lane.
    private var boxDrag: (grip: BoxGrips.Grip, start: BoxGrips.Rect, anchor: NSPoint, lane: Int)?

    /// The spectral area's box in the view's points, when the area is a box (a lasso or a brush stroke has no grips).
    private func boxRect() -> (rect: BoxGrips.Rect, lane: Int)? {
        guard areaMode, let area = session.spectralArea, case .box(let a, let b, let lo, let hi) = area.shape else { return nil }
        return (BoxGrips.Rect(minX: Double(viewport.x(of: a * project.sampleRate)), minY: Double(y(ofHz: hi, lane: area.track)),
                              maxX: Double(viewport.x(of: b * project.sampleRate)), maxY: Double(y(ofHz: lo, lane: area.track))), area.track)
    }
    private func boxGrip(at p: NSPoint) -> BoxGrips.Grip? {
        guard let (r, _) = boxRect() else { return nil }
        if let d = boxDrag { return d.grip }
        return BoxGrips.grip(atX: Double(p.x), y: Double(p.y), in: r)
    }
    private static func cursor(for g: BoxGrips.Grip, dragging: Bool) -> NSCursor {
        switch g {
        case .inside: return dragging ? .closedHand : .openHand
        case .edge(.left), .edge(.right): return .resizeLeftRight
        case .edge(.top), .edge(.bottom): return .resizeUpDown
        case .corner(let left, let top):
            return .frameResize(position: left ? (top ? .topLeft : .bottomLeft) : (top ? .topRight : .bottomRight), directions: .all)
        }
    }
    /// The box after a grip moved by (`dx`, `dy`): kept in its lane, and from the start of the document on.
    private func dragBox(_ d: (grip: BoxGrips.Grip, start: BoxGrips.Rect, anchor: NSPoint, lane: Int), to p: NSPoint) {
        var dx = Double(p.x - d.anchor.x), dy = Double(p.y - d.anchor.y)
        let top = Double(laneTop(d.lane)), bottom = top + Double(laneHeight - 1), zeroX = Double(viewport.x(of: 0))
        if d.grip == .inside {
            dx = max(dx, zeroX - d.start.minX)
            dy = min(max(dy, top - d.start.minY), bottom - d.start.maxY)
        }
        let r = BoxGrips.drag(d.grip, d.start, dx: dx, dy: dy)
        let start = max(0, seconds(atX: CGFloat(r.minX))), end = max(start, seconds(atX: CGFloat(r.maxX)))
        let high = hz(atY: CGFloat(max(top, r.minY)), lane: d.lane), low = hz(atY: CGFloat(min(bottom, r.maxY)), lane: d.lane)
        session.spectralArea = .init(shape: .box(start: start, end: end, low: min(low, high), high: max(low, high)), track: d.lane)
        needsDisplay = true
    }

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
        // A box's eight handles, where its corners and edges can be taken.
        if let (r, _) = boxRect(), drawing == nil {
            for h in BoxGrips.handles(r) {
                let sq = NSBezierPath(rect: NSRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6))
                Theme.neon.setFill(); sq.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke(); sq.lineWidth = 1; sq.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // The hidden tracks' mark: to the nearest track it counts.
        if let hit = hiddenMarks.first(where: { $0.rect.contains(p) }) { timeline?.revealTrack(hit.track, animated: true); return }
        // The edge rows are no lane (the marker flags in the top one are found by the zones below).
        if viewport.lanes.overflows, p.y >= viewport.lanes.lanesBottom { return }
        // A click on an automation point (or ⌥-click in a lane) is the lane's; everything else is the timeline's as before.
        if !areaMode, timeline?.automation.mouseDown(event, at: p) == true { dragAnchor = nil; return }
        let f = frame(at: p)
        if areaMode, p.y >= TimelineView.rulerHeight, event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let (r, lane) = boxRect(), let g = BoxGrips.grip(atX: Double(p.x), y: Double(p.y), in: r) {
            // A grip of the box there is: it is adjusted, not drawn again.
            boxDrag = (g, r, p, lane)
            didDrag = false
            dragAnchor = nil
            refreshPointer()
            return
        }
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
        if let d = boxDrag {
            didDrag = true
            dragBox(d, to: p)
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
        // Whatever the drag was, the pointer is then the one for where the mouse is (the arrow outside).
        defer { refreshPointer(afterDrag: true) }
        if timeline?.automation.mouseUp(event, at: convert(event.locationInWindow, from: nil)) == true { stopScrolling(); return }
        stopScrolling()
        snapX = nil
        lastDragPoint = nil
        if cancelled { cancelled = false; dragAnchor = nil; handleDrag = nil; gainDrag = nil; zoomDrag = nil; handDrag = nil; boxDrag = nil; needsDisplay = true; return }
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
        if handDrag != nil { handDrag = nil; return }
        if let h = handleDrag {
            handleDrag = nil
            if case .marker(let id) = h.kind { session.currentMarker = id }
            if didDrag { commit(h) } else if case .marker = h.kind { session.seek(h.value) }
            needsDisplay = true
            return
        }
        selectionBeforeDrag = nil
        needsDisplay = true
        if boxDrag != nil {
            boxDrag = nil
            needsDisplay = true
            return
        }
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

    private func laneIndex(at y: CGFloat) -> Int { viewport.lanes.lane(atY: Double(y)) ?? -1 }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            // Track height, the lane under the pointer staying where it is.
            timeline?.zoomTracks(by: pow(1.01, Double(event.scrollingDeltaY)), anchorY: p.y)
            return
        }
        if event.modifierFlags.contains(.command) {
            timeline?.zoom(by: pow(1.01, Double(event.scrollingDeltaY)), around: p.x)
            return
        }
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // Always the same meaning (the coordinator, 2026-11-26): up and down move the tracks (nothing when they fit),
        // sideways and ⇧ with a wheel move time.
        if event.modifierFlags.contains(.shift), !event.hasPreciseScrollingDeltas {
            timeline?.scroll(byPoints: -(event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX) * unit)
            return
        }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            timeline?.scroll(byPoints: -event.scrollingDeltaX * unit)
        } else if event.scrollingDeltaY != 0 {
            timeline?.scrollTracks(by: -Double(event.scrollingDeltaY * unit))
        }
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
        case 53 where areaMode && session.spectralArea != nil: boxDrag = nil; session.spectralArea = nil; needsDisplay = true // escape: the area first
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

/// The playhead: a line down the whole timeline and a small triangle in the ruler, as layers that are moved, never
/// drawn (TimelineRedraw: drawing the timeline again to move a line 1.5 points wide cost about a core while playing).
/// It lies under the overlay and takes no clicks.
@MainActor
final class PlayheadView: NSView {
    private let line = CALayer()
    private let head = CAShapeLayer()
    private var x: CGFloat = -100

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        line.backgroundColor = Theme.playhead.cgColor
        head.fillColor = Theme.playhead.cgColor
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: -5, y: 0)); tri.addLine(to: CGPoint(x: 6.5, y: 0)); tri.addLine(to: CGPoint(x: 0.75, y: -7))
        tri.closeSubpath()
        head.path = tri
        for l in [line, head] { layer?.addSublayer(l) }
        setAccessibilityElement(false)   // the timeline itself says where the playhead is
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        place(x: x)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [line, head] { l.contentsScale = scale }
    }

    /// Moved to `x` points from the left, at once (no implicit animation: a gliding line would lag the sound).
    func place(x: CGFloat) {
        self.x = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Not flipped: y counts from the bottom, so the ruler's triangle hangs from the top edge.
        line.frame = CGRect(x: x, y: 0, width: 1.5, height: bounds.height)
        head.position = CGPoint(x: x, y: bounds.height)
        CATransaction.commit()
        Perf.count("timeline.playhead.move")
    }
}
