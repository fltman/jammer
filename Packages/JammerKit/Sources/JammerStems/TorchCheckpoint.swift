import Foundation

/// Reads float tensors out of a PyTorch checkpoint (`torch.save` of a state dict): a zip
/// archive, stored uncompressed, holding `data.pkl` (a pickle that names each tensor's
/// storage, shape and offset) and one raw little-endian file per storage. Only what a state
/// dict of float tensors needs: enough to load MERL's MRX weights as published.
public struct TorchCheckpoint {
    public struct Entry: Equatable {
        public var shape: [Int]
        var storage: String
        var offset: Int   // in elements
        var isFloat: Bool
    }

    public enum ReadError: Error { case malformed(String) }

    public let entries: [String: Entry]
    public let names: [String]
    let data: Data
    let files: [String: Range<Int>]
    let prefix: String

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        files = try Self.zipEntries(data)
        guard let pkl = files.keys.first(where: { $0.hasSuffix("/data.pkl") }), let range = files[pkl] else { throw ReadError.malformed("no data.pkl") }
        prefix = String(pkl.dropLast("data.pkl".count))
        (entries, names) = try Self.unpickle([UInt8](data.subdata(in: range)))
    }

    public func floats(_ name: String) throws -> (shape: [Int], values: [Float]) {
        guard let e = entries[name], e.isFloat, let range = files[prefix + "data/" + e.storage] else { throw ReadError.malformed("no float tensor \(name)") }
        let count = e.shape.reduce(1, *)
        let start = range.lowerBound + e.offset * 4
        guard start + count * 4 <= range.upperBound else { throw ReadError.malformed("\(name) runs past its storage") }
        return (e.shape, data.subdata(in: start..<(start + count * 4)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }

    // MARK: Zip (stored entries only)

    static func zipEntries(_ d: Data) throws -> [String: Range<Int>] {
        func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func u64(_ at: Int) -> Int { u32(at) | u32(at + 4) << 32 }
        // End of central directory, searched from the back.
        var eocd = d.count - 22
        while eocd >= 0, u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= 0 else { throw ReadError.malformed("not a zip") }
        var count = u16(eocd + 10), dir = u32(eocd + 16)
        if dir == 0xFFFF_FFFF || count == 0xFFFF, eocd >= 20, u32(eocd - 20) == 0x0706_4B50 {
            let z = u64(eocd - 20 + 8)                       // zip64 end of central directory
            guard u32(z) == 0x0606_4B50 else { throw ReadError.malformed("zip64") }
            count = u64(z + 32); dir = u64(z + 48)
        }
        var out: [String: Range<Int>] = [:]
        var at = dir
        for _ in 0..<count {
            guard u32(at) == 0x0201_4B50 else { throw ReadError.malformed("central directory") }
            let method = u16(at + 10), nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
            var size = u32(at + 24), local = u32(at + 42)
            let name = String(decoding: d.subdata(in: (at + 46)..<(at + 46 + nameLength)), as: UTF8.self)
            // Zip64 extra: sizes and offset that didn't fit in 32 bits, in order.
            var x = at + 46 + nameLength
            let extraEnd = x + extraLength
            while x + 4 <= extraEnd {
                let id = u16(x), len = u16(x + 2)
                if id == 1 {
                    var p = x + 4
                    if u32(at + 24) == 0xFFFF_FFFF { size = u64(p); p += 8 }
                    if u32(at + 20) == 0xFFFF_FFFF { p += 8 }
                    if u32(at + 42) == 0xFFFF_FFFF { local = u64(p) }
                }
                x += 4 + len
            }
            guard method == 0 else { throw ReadError.malformed("\(name) is compressed") }
            guard u32(local) == 0x0403_4B50 else { throw ReadError.malformed("local header") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            out[name] = start..<(start + size)
            at = extraEnd + commentLength
        }
        return out
    }

    // MARK: Pickle (the subset torch.save writes for a state dict)

    indirect enum Value {
        case none, int(Int), string(String), global(String), tuple([Value]), list([Value])
        case dict([(Value, Value)])
        case storage(key: String, isFloat: Bool)
        case tensor(Entry)
        case opaque
    }

    static func unpickle(_ b: [UInt8]) throws -> ([String: Entry], [String]) {
        var at = 0
        var stack: [Value] = [], marks: [Int] = [], memo: [Int: Value] = [:]
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard at + n <= b.count else { throw ReadError.malformed("pickle ends early") }
            defer { at += n }
            return b[at..<(at + n)]
        }
        func int(_ n: Int) throws -> Int { try take(n).reversed().reduce(0) { $0 << 8 | Int($1) } }
        func line() throws -> String {
            guard let end = b[at...].firstIndex(of: 0x0A) else { throw ReadError.malformed("pickle line") }
            defer { at = end + 1 }
            return String(decoding: b[at..<end], as: UTF8.self)
        }
        func popMark() throws -> [Value] {
            guard let m = marks.popLast(), m <= stack.count else { throw ReadError.malformed("pickle mark") }
            defer { stack.removeSubrange(m...) }
            return Array(stack[m...])
        }
        func pop() throws -> Value {
            guard let v = stack.popLast() else { throw ReadError.malformed("pickle stack") }
            return v
        }
        func setItems(_ items: [Value]) throws {
            guard case .dict(var d) = try pop() else { throw ReadError.malformed("pickle setitems") }
            for i in stride(from: 0, to: items.count - 1, by: 2) { d.append((items[i], items[i + 1])) }
            stack.append(.dict(d))
        }
        loop: while at < b.count {
            let op = b[at]; at += 1
            switch op {
            case 0x80: _ = try take(1)                                   // PROTO
            case 0x2E: break loop                                        // STOP
            case 0x28: marks.append(stack.count)                         // MARK
            case 0x4E: stack.append(.none)
            case 0x88, 0x89: stack.append(.int(op == 0x88 ? 1 : 0))      // NEWTRUE, NEWFALSE
            case 0x4B: stack.append(.int(try int(1)))                    // BININT1
            case 0x4D: stack.append(.int(try int(2)))                    // BININT2
            case 0x4A: stack.append(.int(Int(Int32(truncatingIfNeeded: try int(4)))))
            case 0x8A: stack.append(.int(try int(try int(1))))           // LONG1
            case 0x58: stack.append(.string(String(decoding: try take(try int(4)), as: UTF8.self))) // BINUNICODE
            case 0x8C: stack.append(.string(String(decoding: try take(try int(1)), as: UTF8.self))) // SHORT_BINUNICODE
            case 0x63: stack.append(.global(try line() + "." + (try line())))                        // GLOBAL
            case 0x71: memo[try int(1)] = stack.last                     // BINPUT
            case 0x72: memo[try int(4)] = stack.last                     // LONG_BINPUT
            case 0x94: memo[memo.count] = stack.last                     // MEMOIZE
            case 0x68: stack.append(memo[try int(1)] ?? .opaque)         // BINGET
            case 0x6A: stack.append(memo[try int(4)] ?? .opaque)         // LONG_BINGET
            case 0x29: stack.append(.tuple([]))
            case 0x74: stack.append(.tuple(try popMark()))
            case 0x85: stack.append(.tuple([try pop()]))
            case 0x86: let y = try pop(), x = try pop(); stack.append(.tuple([x, y]))
            case 0x87: let z = try pop(), y = try pop(), x = try pop(); stack.append(.tuple([x, y, z]))
            case 0x5D: stack.append(.list([]))
            case 0x61: let v = try pop(); if case .list(let l) = try pop() { stack.append(.list(l + [v])) }
            case 0x65: let items = try popMark(); if case .list(let l) = try pop() { stack.append(.list(l + items)) }
            case 0x7D: stack.append(.dict([]))
            case 0x73: let v = try pop(), k = try pop(); try setItems([k, v])
            case 0x75: try setItems(try popMark())
            case 0x51:                                                   // BINPERSID: ('storage', type, key, device, count)
                guard case .tuple(let t) = try pop(), t.count >= 3, case .global(let type) = t[1], case .string(let key) = t[2] else {
                    throw ReadError.malformed("pickle storage")
                }
                stack.append(.storage(key: key, isFloat: type.hasSuffix("FloatStorage")))
            case 0x52:                                                   // REDUCE
                let args = try pop(), callable = try pop()
                guard case .global(let name) = callable, case .tuple(let a) = args else { stack.append(.opaque); continue }
                if name.hasSuffix("_rebuild_tensor_v2"), a.count >= 3, case .storage(let key, let isFloat) = a[0], case .int(let offset) = a[1], case .tuple(let dims) = a[2] {
                    let shape = dims.compactMap { v -> Int? in if case .int(let i) = v { return i }; return nil }
                    stack.append(.tensor(Entry(shape: shape, storage: key, offset: offset, isFloat: isFloat)))
                } else if name.hasSuffix("OrderedDict") {
                    stack.append(.dict([]))
                } else {
                    stack.append(.opaque)
                }
            case 0x62: _ = try pop()                                     // BUILD (state on an object): keep the object
            default: throw ReadError.malformed(String(format: "pickle opcode 0x%02x", op))
            }
        }
        guard case .dict(let items) = stack.last else { throw ReadError.malformed("no state dict") }
        var out: [String: Entry] = [:], names: [String] = []
        for (k, v) in items {
            if case .string(let name) = k, case .tensor(let e) = v { out[name] = e; names.append(name) }
        }
        return (out, names)
    }
}
