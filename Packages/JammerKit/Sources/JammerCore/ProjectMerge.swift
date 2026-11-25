import Foundation

/// A late result laid onto edits made meanwhile (COMFORT 77; the series' form, Glimmer 31cee9e): a run of steps, a
/// repair or a transcription was worked out from the document as it was (`base`) and gave `ours`; meanwhile the
/// document became `theirs`. When the two changed different things, the result goes on top as its own undo step and
/// nothing made meanwhile is undone. When both changed the same thing (the same clip, the same marker, the same
/// field), that is a conflict: the result isn't applied, and the caller keeps it (History, as a branch).
///
/// The documents are compared as their JSON. Objects merge key by key. A list whose items carry an identity (`id`, or
/// `sourceID` for a transcript) merges item by item and keeps the order either side gave it. An item both sides
/// changed is a conflict, unless it holds lists of such items itself (a track holds clips), when the merge goes one
/// level down. Any other value both sides changed differently is a conflict.
public enum ProjectMerge {
    public enum Outcome: Sendable {
        case merged(Project)
        /// Where the two met, as a path into the document ("tracks[…].clips[…]").
        case conflict(String)
    }

    struct Conflict: Error { let path: String }
    private static let identities = ["id", "sourceID"]

    public static func merge(base: Project, ours: Project, theirs: Project) -> Outcome {
        if ours == base { return .merged(theirs) }
        if theirs == base || theirs == ours { return .merged(ours) }
        let encoder = JSONEncoder()
        guard let b = try? json(base, encoder), let o = try? json(ours, encoder), let t = try? json(theirs, encoder) else {
            return .conflict("(the document couldn't be compared)")
        }
        do {
            let merged = try value(b, o, t, path: "")
            let data = try JSONSerialization.data(withJSONObject: merged)
            return .merged(try JSONDecoder().decode(Project.self, from: data))
        } catch let c as Conflict {
            return .conflict(c.path.isEmpty ? "(the document)" : c.path)
        } catch {
            return .conflict("(the merged document couldn't be read: \(error.localizedDescription))")
        }
    }

    private static func json(_ p: Project, _ e: JSONEncoder) throws -> Any {
        try JSONSerialization.jsonObject(with: e.encode(p))
    }

    /// nil stands for "not there".
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): (x as AnyObject).isEqual(y)
        default: false
        }
    }

    private static func value(_ b: Any?, _ o: Any?, _ t: Any?, path: String) throws -> Any? {
        if same(o, b) { return t }
        if same(t, b) || same(o, t) { return o }
        if let bd = b as? [String: Any], let od = o as? [String: Any], let td = t as? [String: Any] {
            var out: [String: Any] = [:]
            for k in Set(bd.keys).union(od.keys).union(td.keys) {
                if let v = try value(bd[k], od[k], td[k], path: path.isEmpty ? k : path + "." + k) { out[k] = v }
            }
            return out
        }
        if let oa = o as? [Any], let ta = t as? [Any], let ba = (b as? [Any]) ?? (b == nil ? [] : nil),
           let key = identity(ba + oa + ta) {
            return try list(ba, oa, ta, key: key, path: path)
        }
        throw Conflict(path: path)
    }

    /// The identity every item of a list has, if they all have one.
    private static func identity(_ items: [Any]) -> String? {
        guard !items.isEmpty else { return nil }
        return identities.first { k in items.allSatisfy { ($0 as? [String: Any])?[k] is String } }
    }

    private static func list(_ b: [Any], _ o: [Any], _ t: [Any], key: String, path: String) throws -> [Any] {
        func ids(_ a: [Any]) -> [String] { a.map { ($0 as! [String: Any])[key] as! String } }
        func byID(_ a: [Any]) -> [String: Any] { Dictionary(zip(ids(a), a), uniquingKeysWith: { x, _ in x }) }
        let bi = ids(b), oi = ids(o), ti = ids(t)
        let bm = byID(b), om = byID(o), tm = byID(t)
        // Each item: merged, or gone.
        var items: [String: Any] = [:]
        for id in Set(bi).union(oi).union(ti) {
            let here = path + "[\(id.prefix(8))]"
            let (bv, ov, tv) = (bm[id], om[id], tm[id])
            if same(ov, bv) { if let tv { items[id] = tv }; continue }
            if same(tv, bv) || same(ov, tv) { if let ov { items[id] = ov }; continue }
            // Both sides changed this item (or one removed it and the other changed it).
            guard let bd = bv as? [String: Any], let od = ov as? [String: Any], let td = tv as? [String: Any],
                  bd.values.contains(where: { identity(($0 as? [Any]) ?? []) != nil }) else { throw Conflict(path: here) }
            var out: [String: Any] = [:]
            for k in Set(bd.keys).union(od.keys).union(td.keys) {
                let sub = here + "." + k
                let lists = [bd[k], od[k], td[k]].compactMap { $0 as? [Any] }
                if lists.count == 3, identity(lists.flatMap { $0 }) != nil || lists.allSatisfy(\.isEmpty) {
                    if let v = try value(bd[k], od[k], td[k], path: sub) { out[k] = v }
                } else if !same(od[k], bd[k]), !same(td[k], bd[k]), !same(od[k], td[k]) {
                    // A plain field of a container both changed: that is the target itself.
                    throw Conflict(path: sub)
                } else if let v = same(od[k], bd[k]) ? td[k] : od[k] {
                    out[k] = v
                }
            }
            items[id] = out
        }
        // The order: either side's, if only one changed it; what the other added goes before the item that follows it
        // there (at the end when nothing followed it).
        let kept = { (order: [String]) in order.filter { items[$0] != nil } }
        let common = Set(bi)
        let oOrder = oi.filter(common.contains), tOrder = ti.filter(common.contains), bOrder = bi.filter { oi.contains($0) && ti.contains($0) }
        let oReordered = oOrder.filter(ti.contains) != bOrder, tReordered = tOrder.filter(oi.contains) != bOrder
        if oReordered, tReordered, oOrder.filter(ti.contains) != tOrder.filter(oi.contains) { throw Conflict(path: path + " (order)") }
        var order = kept(oReordered ? oi : ti)
        let other = oReordered ? ti : oi
        for (n, id) in other.enumerated().reversed() where !order.contains(id) && items[id] != nil {
            let next = other[(n + 1)...].first { order.contains($0) }
            order.insert(id, at: next.flatMap { order.firstIndex(of: $0) } ?? order.count)
        }
        return order.compactMap { items[$0] }
    }
}
