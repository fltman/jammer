import Foundation

/// Reads float tensors out of a TensorFlow checkpoint (the "bundle" format: `model.index`
/// is a LevelDB-style table of tensor name → shape, offset and size; `model.data-00000-of-00001`
/// holds the raw little-endian floats). Just enough to load Spleeter's weights as Deezer
/// publishes them, so Jämmer needs no converted copy hosted anywhere.
public struct TFCheckpoint {
    public struct Entry: Equatable {
        public var shape: [Int]
        public var offset: Int
        public var size: Int
    }

    public enum ReadError: Error { case malformed(String) }

    public let entries: [String: Entry]
    let data: Data

    public init(index: URL, data dataURL: URL) throws {
        entries = try Self.readIndex(try Data(contentsOf: index))
        data = try Data(contentsOf: dataURL, options: .alwaysMapped)
    }

    public func floats(_ name: String) throws -> (shape: [Int], values: [Float]) {
        guard let e = entries[name], e.offset + e.size <= data.count, e.size == e.shape.reduce(1, *) * 4 else {
            throw ReadError.malformed("no float tensor \(name)")
        }
        let values = data.subdata(in: e.offset..<(e.offset + e.size)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (e.shape, values)
    }

    // MARK: Table

    struct Reader {
        let bytes: [UInt8]
        var at = 0
        mutating func varint() throws -> Int {
            var result = 0, shift = 0
            while at < bytes.count {
                let b = bytes[at]; at += 1
                result |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            throw ReadError.malformed("varint")
        }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, at + n <= bytes.count else { throw ReadError.malformed("short read") }
            defer { at += n }
            return Array(bytes[at..<(at + n)])
        }
    }

    /// The key/value pairs of one table block (prefix-compressed keys, restart array at the end).
    static func block(_ all: [UInt8], offset: Int, size: Int) throws -> [(key: [UInt8], value: [UInt8])] {
        guard offset >= 0, size >= 4, offset + size + 1 <= all.count else { throw ReadError.malformed("block bounds") }
        guard all[offset + size] == 0 else { throw ReadError.malformed("compressed blocks aren't supported") }
        let b = Array(all[offset..<(offset + size)])
        let restarts = Int(UInt32(b[size - 4]) | UInt32(b[size - 3]) << 8 | UInt32(b[size - 2]) << 16 | UInt32(b[size - 1]) << 24)
        let end = size - 4 - restarts * 4
        guard end >= 0 else { throw ReadError.malformed("restarts") }
        var r = Reader(bytes: Array(b[0..<end]))
        var out: [([UInt8], [UInt8])] = []
        var key: [UInt8] = []
        while r.at < end {
            let shared = try r.varint(), unshared = try r.varint(), valueLength = try r.varint()
            guard shared <= key.count else { throw ReadError.malformed("key prefix") }
            key = Array(key[0..<shared]) + (try r.take(unshared))
            out.append((key, try r.take(valueLength)))
        }
        return out
    }

    static func readIndex(_ file: Data) throws -> [String: Entry] {
        let all = [UInt8](file)
        guard all.count >= 48 else { throw ReadError.malformed("too short") }
        var footer = Reader(bytes: Array(all[(all.count - 48)...]))
        _ = try footer.varint(); _ = try footer.varint() // metaindex handle
        let indexOffset = try footer.varint(), indexSize = try footer.varint()
        var out: [String: Entry] = [:]
        for (_, handle) in try block(all, offset: indexOffset, size: indexSize) {
            var h = Reader(bytes: handle)
            let off = try h.varint(), size = try h.varint()
            for (key, value) in try block(all, offset: off, size: size) where !key.isEmpty {
                // BundleEntryProto: 1 dtype, 2 shape { 2 dim { 1 size } }, 3 shard, 4 offset, 5 size, 6 crc.
                var p = Reader(bytes: value)
                var dtype = 0, shape: [Int] = [], offset = 0, bytes = 0
                while p.at < value.count {
                    let tag = try p.varint()
                    switch (tag >> 3, tag & 7) {
                    case (1, 0): dtype = try p.varint()
                    case (2, 2):
                        var s = Reader(bytes: try p.take(try p.varint()))
                        while s.at < s.bytes.count {
                            let t = try s.varint()
                            if t >> 3 == 2, t & 7 == 2 {
                                var d = Reader(bytes: try s.take(try s.varint()))
                                while d.at < d.bytes.count {
                                    let dt = try d.varint()
                                    if dt >> 3 == 1, dt & 7 == 0 { shape.append(try d.varint()) } else if dt & 7 == 2 { _ = try d.take(try d.varint()) } else { _ = try d.varint() }
                                }
                            } else if t & 7 == 2 { _ = try s.take(try s.varint()) } else { _ = try s.varint() }
                        }
                    case (4, 0): offset = try p.varint()
                    case (5, 0): bytes = try p.varint()
                    case (_, 0): _ = try p.varint()
                    case (_, 5): _ = try p.take(4)
                    case (_, 1): _ = try p.take(8)
                    case (_, 2): _ = try p.take(try p.varint())
                    default: throw ReadError.malformed("wire type")
                    }
                }
                if dtype == 1 { out[String(decoding: key, as: UTF8.self)] = Entry(shape: shape, offset: offset, size: bytes) } // DT_FLOAT
            }
        }
        return out
    }
}
