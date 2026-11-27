import Compression
import Foundation

/// The ZIP container a DAWproject is (and only what it needs): written stored (no compression, so nothing
/// outside Apple's frameworks is needed), read stored or deflated (through the Compression framework).
/// Untrusted input: sizes, counts and names are checked before anything is read.
enum Zip {
    struct Entry { let name: String; let method: UInt16; let crc: UInt32; let compressed: Int; let size: Int; let offset: Int }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// A ZIP of the files given (name → contents), stored.
    static func write(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: UInt16, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: UInt32, _ d: inout Data) { u16(UInt16(v & 0xFFFF), &d); u16(UInt16(v >> 16), &d) }
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), offset = UInt32(out.count)
            u32(0x0403_4b50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)   // version, UTF-8 names, stored, time, date (1980-01-01)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(UInt16(n.count), &out); u16(0, &out)
            out.append(n); out.append(data)
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central); u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central); u16(UInt16(n.count), &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central)
            central.append(n)
        }
        let at = UInt32(out.count)
        out.append(central)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(UInt16(files.count), &out); u16(UInt16(files.count), &out)
        u32(UInt32(central.count), &out); u32(at, &out); u16(0, &out)
        return out
    }

    enum Failure: Error { case notZip(Said) }
    static let maxDeflateRatio = 1_032

    /// The entries of a ZIP's central directory.
    static func entries(_ d: Data) throws -> [Entry] {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 22 else { throw Failure.notZip(Said("error.zip.too_short_zip_file", "it is too short to be a ZIP file.")) }
        var eocd = -1
        for i in stride(from: b.count - 22, through: max(0, b.count - 22 - 65_535), by: -1) where u32(i) == 0x0605_4b50 { eocd = i; break }
        guard eocd >= 0 else { throw Failure.notZip(Said("error.zip.isn_t_zip_file", "it isn't a ZIP file (no central directory).")) }
        let count = u16(eocd + 10), dir = u32(eocd + 16)
        guard count <= 100_000, dir < b.count else { throw Failure.notZip(Said("error.zip.directory_damaged", "its directory is damaged.")) }
        var out: [Entry] = [], p = dir
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4b50 else { throw Failure.notZip(Said("error.zip.directory_damaged", "its directory is damaged.")) }
            let method = UInt16(u16(p + 10)), crc = UInt32(u32(p + 16)), csize = u32(p + 20), size = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32), offset = u32(p + 42)
            guard p + 46 + nlen <= b.count else { throw Failure.notZip(Said("error.zip.directory_damaged", "its directory is damaged.")) }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            out.append(Entry(name: name, method: method, crc: crc, compressed: csize, size: size, offset: offset))
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    /// One entry's contents, at most `limit` bytes; its checksum checked.
    static func read(_ e: Entry, in d: Data, limit: Int) throws -> Data {
        guard e.size <= limit, e.compressed <= d.count else { throw Failure.notZip(Said("error.zip.larger_than_j_mmer", "%@ is larger than Jämmer reads from a project file.", "\(e.name)")) }
        let b = d.startIndex
        guard e.offset + 30 <= d.count else { throw Failure.notZip(Said("error.zip.outside_file", "%@ is outside the file.", "\(e.name)")) }
        let h = d.subdata(in: (b + e.offset)..<(b + e.offset + 30))
        let nlen = Int(h[26]) | Int(h[27]) << 8, xlen = Int(h[28]) | Int(h[29]) << 8
        let start = e.offset + 30 + nlen + xlen
        guard start + e.compressed <= d.count else { throw Failure.notZip(Said("error.zip.outside_file", "%@ is outside the file.", "\(e.name)")) }
        let raw = d.subdata(in: (b + start)..<(b + start + e.compressed))
        let out: Data
        switch e.method {
        case 0: out = raw
        case 8:
            // Deflate makes at most about 1 032 bytes of each one (RFC 1951's longest match from a two-bit code): an
            // entry that claims more is a bomb or a lie, and is refused before its size is set aside.
            guard e.size <= e.compressed * maxDeflateRatio + 1_024 else { throw Failure.notZip(Said("error.zip.couldn_t_unpacked", "%@ couldn't be unpacked.", "\(e.name)")) }
            var buffer = [UInt8](repeating: 0, count: max(1, e.size))
            let n = raw.withUnsafeBytes { src in
                compression_decode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
            guard n == e.size else { throw Failure.notZip(Said("error.zip.couldn_t_unpacked", "%@ couldn't be unpacked.", "\(e.name)")) }
            out = Data(buffer.prefix(n))
        default: throw Failure.notZip(Said("error.zip.1_packed_way_j", "%1$@ is packed in a way Jämmer doesn't read (method %2$@).", "\(e.name)", "\(e.method)"))
        }
        guard crc32(out) == e.crc else { throw Failure.notZip(Said("error.zip.damaged_checksum_doesn_t", "%@ is damaged (its checksum doesn't match).", "\(e.name)")) }
        return out
    }
}
