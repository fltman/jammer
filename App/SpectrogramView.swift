import AppKit
import JammerCore

/// The spectrogram behind the timeline overlay: one image per visible stretch, computed
/// off the main thread, frequency on a log scale from 50 Hz to 16 kHz (or Nyquist).
@MainActor
final class SpectrogramLayerView: NSView {
    let session: EditorSession
    let viewport: Viewport
    private var shownKey: [Double] = []
    private var task: Task<Void, Never>?
    private let message = NSTextField(labelWithString: L10n.text("spectrogram.zoomIn"))

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.backgroundColor = Theme.ink.cgColor
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: centerXAnchor), message.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh() {
        guard !isHidden, bounds.width > 10 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let columns = Int(bounds.width * scale), height = Int(bounds.height * scale)
        let lanes = viewport.lanes
        let key = [Double(session.version), viewport.start, viewport.framesPerPoint, Double(columns), Double(height),
                   lanes.laneHeight, lanes.scrollY, lanes.lanesTop]
        guard key != shownKey else { return }
        shownKey = key
        let p = session.project, pool = session.pool
        let span = viewport.framesPerPoint * Double(bounds.width)
        message.isHidden = span <= p.sampleRate * 600
        guard message.isHidden else { layer?.contents = nil; return }
        let start = viewport.start
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let image = Self.render(p, pool: pool, start: start, span: span, columns: columns, height: height, lanes: lanes, scale: Double(scale))
            await MainActor.run {
                guard let self, !Task.isCancelled, self.shownKey == key else { return }
                self.layer?.contents = image
            }
        }
    }

    /// Only the lanes that are seen (LaneLayout), each where it is drawn, cut off at the edge rows.
    nonisolated static func render(_ p: Project, pool: SourcePool, start: Double, span: Double, columns: Int, height: Int,
                                   lanes layout: LaneLayout, scale: Double) -> CGImage? {
        let laneHeight = max(1, Int(layout.laneHeight * scale))
        let top = Int(layout.lanesTop * scale), bottom = min(height, Int(layout.lanesBottom * scale))
        let size = 2_048
        let nyquist = p.sampleRate / 2
        let fLo = 50.0, fHi = min(16_000, nyquist)
        var pixels = [UInt32](repeating: 0, count: columns * height)
        // Row → bin, on a log frequency scale; row 0 is the top (high frequencies).
        let binHz = p.sampleRate / Double(size)
        let rowBin = (0..<laneHeight).map { r -> Int in
            let f = fLo * pow(fHi / fLo, 1 - Double(r) / Double(max(1, laneHeight - 1)))
            return min(size / 2 - 1, max(1, Int(f / binHz)))
        }
        for t in p.tracks.indices where layout.visibleLanes.contains(t) {
            let laneY = Int(layout.laneTop(t) * scale)
            var solo = p
            solo.tracks = [p.tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].isMuted = false
            let plan = PlanCompiler.compile(solo, pool: pool)
            let first = Frame(max(0, start - Double(size / 2)))
            let count = Int(span) + size * 2
            let raw = plan.render(from: first, frames: count)
            let mono = stride(from: 0, to: raw.count, by: p.channels).map { i in (0..<p.channels).reduce(Float(0)) { $0 + raw[i + $1] } / Float(p.channels) }
            let stft = Spectral.STFT(size: size)
            let norm = 2 / stft.window.reduce(0, +)
            mono.withUnsafeBufferPointer { m in
                for c in 0..<columns {
                    if Task.isCancelled { return }
                    let centre = Int(start + span * (Double(c) + 0.5) / Double(columns)) - Int(first)
                    let at = centre - size / 2
                    guard at >= 0, at + size <= m.count else { continue }
                    let (re, im) = stft.forward(m.baseAddress! + at)
                    for r in 0..<laneHeight {
                        let y = laneY + r
                        guard y >= top, y < bottom else { continue }
                        let k = rowBin[r]
                        let mag = (re[k] * re[k] + im[k] * im[k]).squareRoot() * norm / 2
                        let db = 20 * log10(max(1e-7, Double(mag)))
                        pixels[y * columns + c] = colour((db + 100) / 90)
                    }
                }
            }
        }
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: columns, height: height, bitsPerComponent: 8, bytesPerRow: columns * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Dark ink → neon teal → white, as 0…1 rises.
    nonisolated static func colour(_ v: Double) -> UInt32 {
        let x = max(0, min(1, v))
        let (r, g, b): (Double, Double, Double) = x < 0.6
            ? (0.035 + (0.18 - 0.035) * x / 0.6, 0.045 + (0.95 - 0.045) * x / 0.6, 0.055 + (0.85 - 0.055) * x / 0.6)
            : (0.18 + (1 - 0.18) * (x - 0.6) / 0.4, 0.95 + 0.05 * (x - 0.6) / 0.4, 0.85 + 0.15 * (x - 0.6) / 0.4)
        return UInt32(r * 255) | UInt32(g * 255) << 8 | UInt32(b * 255) << 16 | 0xFF00_0000
    }
}
