import Foundation

/// A film to look at while the sound is worked on: a file the user chose, shown in a window of its own
/// and following the playhead. Only a pointer to the file: the film is never read into the project,
/// never changed, and its own sound is not played (the sound is the document's).
public struct VideoReference: Sendable, Equatable, Codable, Hashable {
    /// The film's file.
    public var path: String
    /// The place on the timeline where the film's first picture is.
    public var start: Frame
    public init(path: String, start: Frame = 0) {
        self.path = path
        self.start = start
    }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// How far into the film a place on the timeline is, in seconds; nil before the film starts.
    public func filmSeconds(at frame: Frame, sampleRate: Double) -> Double? {
        frame >= start && sampleRate > 0 ? Double(frame - start) / sampleRate : nil
    }
}
