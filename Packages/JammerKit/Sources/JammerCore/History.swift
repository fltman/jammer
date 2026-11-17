import CryptoKit
import Foundation

/// The document's history as a tree: every change is a node whose parent is the state it
/// was made from. Undo and redo move along the tree; a new change after an undo starts a
/// branch instead of throwing the old future away. Projects are pure values, so a node
/// just stores one (compressed). Transcripts and speaker turns, the bulky parts that
/// rarely change, are stored once per distinct content and shared between nodes.
public struct History: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var parent: UUID?
        public var action: String
        public var time: Date
        /// LZFSE-compressed project JSON without transcripts and speaker turns.
        var body: Data
        /// Keys into `blobs` for those.
        var transcriptsKey: String
        var turnsKey: String
    }

    public private(set) var nodes: [Node]
    public private(set) var current: UUID
    /// How many old steps were dropped to stay under `limit`, shown so nothing vanishes quietly.
    public private(set) var pruned: Int
    public var limit: Int
    var blobs: [String: Data]
    /// The transcripts and the speaker turns of the step before, and their keys: a step that leaves them
    /// as they were (most do) doesn't code 20 000 words again to find that out. Not saved, and not part
    /// of what makes two histories equal.
    private var lastWords: LastWords?
    private struct LastWords: Sendable { var transcripts: [SourceTranscript]; var turns: [SourceSpeakers]; var tKey: String; var sKey: String }
    private enum CodingKeys: String, CodingKey { case nodes, current, pruned, limit, blobs }
    public static func == (a: History, b: History) -> Bool {
        a.nodes == b.nodes && a.current == b.current && a.pruned == b.pruned && a.limit == b.limit && a.blobs == b.blobs
    }

    public init(root project: Project, action: String = "Open", limit: Int = 500) throws {
        nodes = []
        blobs = [:]
        pruned = 0
        self.limit = limit
        current = UUID()
        let node = try makeNode(project, parent: nil, action: action)
        nodes = [node]
        current = node.id
    }

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }

    /// The nodes from the root to `current`: the branch you're on.
    public var activePath: [UUID] {
        var path: [UUID] = []
        var at: UUID? = current
        while let id = at, let n = node(id) {
            path.append(id)
            at = n.parent
        }
        return path.reversed()
    }

    public func children(of id: UUID) -> [Node] { nodes.filter { $0.parent == id } }

    /// Records a change made from `current`; the new node becomes current.
    public mutating func record(_ project: Project, action: String) throws {
        let node = try makeNode(project, parent: current, action: action)
        nodes.append(node)
        current = node.id
        prune()
    }

    /// Makes `id` current (undo, redo, or a jump) and returns its project.
    @discardableResult
    public mutating func move(to id: UUID) throws -> Project {
        guard node(id) != nil else { throw HistoryError.unknownNode }
        current = id
        return try project(of: id)
    }

    public func project(of id: UUID) throws -> Project {
        guard let n = node(id) else { throw HistoryError.unknownNode }
        // The history travels in the project package, so each state is as untrusted as the project:
        // expanded under a size limit and checked like one.
        let limit = ProjectSafety.Limits().bytes
        let json = try ProjectSafety.decompress(n.body, limit: limit)
        var p = try ProjectPackage.decodeChecked(json).project
        let dec = JSONDecoder()
        if let t = blobs[n.transcriptsKey] { p.transcripts = try dec.decode([SourceTranscript].self, from: ProjectSafety.decompress(t, limit: limit)) }
        if let s = blobs[n.turnsKey] { p.speakerTurns = try dec.decode([SourceSpeakers].self, from: ProjectSafety.decompress(s, limit: limit)) }
        return p
    }

    mutating func makeNode(_ project: Project, parent: UUID?, action: String) throws -> Node {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        func store(_ data: Data) throws -> String {
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if blobs[key] == nil { blobs[key] = try (data as NSData).compressed(using: .lzfse) as Data }
            return key
        }
        let tKey: String, sKey: String
        if let last = lastWords, blobs[last.tKey] != nil, blobs[last.sKey] != nil, last.transcripts == project.transcripts, last.turns == project.speakerTurns {
            (tKey, sKey) = (last.tKey, last.sKey)
        } else {
            tKey = try store(enc.encode(project.transcripts))
            sKey = try store(enc.encode(project.speakerTurns))
            lastWords = LastWords(transcripts: project.transcripts, turns: project.speakerTurns, tKey: tKey, sKey: sKey)
        }
        var bare = project
        bare.transcripts = []
        bare.speakerTurns = []
        let body = try (enc.encode(bare) as NSData).compressed(using: .lzfse) as Data
        return Node(id: UUID(), parent: parent, action: action, time: Date(), body: body, transcriptsKey: tKey, turnsKey: sKey)
    }

    /// Over the limit: drop the oldest leaves that aren't on the active path (old branches
    /// first), then, if still over, the oldest steps at the root.
    mutating func prune() {
        guard nodes.count > limit else { return }
        let keep = Set(activePath)
        while nodes.count > limit {
            let leaves = nodes.filter { n in !keep.contains(n.id) && !nodes.contains { $0.parent == n.id } }
            if let oldest = leaves.min(by: { $0.time < $1.time }) {
                nodes.removeAll { $0.id == oldest.id }
            } else if let root = nodes.first(where: { $0.parent == nil }), root.id != current {
                // Everything left is the active path: the root goes, its child becomes the root.
                nodes.removeAll { $0.id == root.id }
                for i in nodes.indices where nodes[i].parent == root.id { nodes[i].parent = nil }
            } else {
                break
            }
            pruned += 1
        }
        let used = Set(nodes.flatMap { [$0.transcriptsKey, $0.turnsKey] })
        blobs = blobs.filter { used.contains($0.key) }
    }
}

public enum HistoryError: Error, LocalizedError, Equatable {
    case unknownNode
    public var errorDescription: String? { "That step isn't in the history." }
}
