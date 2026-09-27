import Compression
import Foundation
import zlib

/// ZIP 파서. 파일 끝의 central directory만 읽어 목록을 즉시 만들고, 페이지는 필요할 때
/// 해당 엔트리만 읽는다. central directory가 없는 손상 파일은 로컬 헤더를 순서대로 훑어 복구한다.
final class ZipArchive {
    struct Entry {
        var rawName: Data
        var utf8Flag: Bool
        var unicodeName: String?
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var crc32: UInt32
        /// 로컬 헤더를 이미 읽어 데이터 시작 위치를 알고 있으면 채운다(복구 스캔 경로).
        var knownDataOffset: UInt64?
        /// 파일 끝에서 잘린 엔트리(복구 스캔). 남은 데이터까지만 풀어 보여준다.
        var truncated = false

        var isDirectory: Bool { rawName.last == UInt8(ascii: "/") }
        var isEncrypted: Bool { flags & 0x1 != 0 }
    }

    /// 한 쪽(이미지 한 장)으로 풀 수 있는 최대 크기. 손상·악성 zip(zip 폭탄)이 메모리를 다 먹지 않게 한다.
    static let maxEntryBytes: UInt64 = 256 << 20

    enum ZipError: Error, LocalizedError {
        case notZip
        case tooLarge
        case unsupportedMethod(UInt16)
        case encrypted
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return String(localized: "This file is not a ZIP archive.")
            case .tooLarge: return String(localized: "This page is too large to open.")
            case .unsupportedMethod(let m): return String(localized: "Unsupported compression method (\(m)).")
            case .encrypted: return String(localized: "Password-protected pages are not supported yet.")
            case .corrupt(let s): return String(localized: "The archive is damaged (\(s)).")
            }
        }
    }

    let source: ByteSource
    private(set) var entries: [Entry] = []
    /// central directory가 없어 로컬 헤더 스캔으로 복구했는지.
    private(set) var recovered = false

    init(source: ByteSource) throws {
        self.source = source
        if let list = try? readCentralDirectory() {
            entries = list
        } else {
            entries = try scanLocalHeaders()
            recovered = true
        }
    }

    convenience init(url: URL) throws {
        try self.init(source: FileByteSource(url: url))
    }

    // MARK: - Central directory

    private func readCentralDirectory() throws -> [Entry] {
        let size = source.size
        guard size >= 22 else { throw ZipError.notZip }
        let tailLen = Int(min(size, 65_557))
        let tail = try source.read(at: size - UInt64(tailLen), count: tailLen)
        var e = tail.count - 22
        while e >= 0 {
            if tail[tail.startIndex + e] == 0x50, tail.u32(e) == 0x0605_4B50 { break }
            e -= 1
        }
        guard e >= 0 else { throw ZipError.notZip }

        var count = UInt64(tail.u16(e + 10))
        var cdSize = UInt64(tail.u32(e + 12))
        var cdOffset = UInt64(tail.u32(e + 16))

        // zip64: EOCD 바로 앞의 locator가 zip64 EOCD 위치를 알려준다.
        if e >= 20, tail.u32(e - 20) == 0x0706_4B50 {
            let z64Offset = tail.u64(e - 20 + 8)
            let z64 = try source.read(at: z64Offset, count: 56)
            if z64.count == 56, z64.u32(0) == 0x0606_4B50 {
                count = z64.u64(32)
                cdSize = z64.u64(40)
                cdOffset = z64.u64(48)
            }
        }
        // 손상 파일의 거대한 값으로 덧셈이 넘치지 않게 뺄셈으로 검사한다.
        guard cdOffset <= size, cdSize <= size - cdOffset, cdSize < 512 * 1024 * 1024 else { throw ZipError.corrupt("central directory") }
        let cd = try source.read(at: cdOffset, count: Int(cdSize))

        var list: [Entry] = []
        list.reserveCapacity(Int(min(count, 200_000)))
        var p = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 {
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            var offset = UInt64(cd.u32(p + 42))
            guard p + 46 + nameLen + extraLen <= cd.count else { throw ZipError.corrupt("entry") }
            let name = cd.subdata(in: cd.startIndex + p + 46 ..< cd.startIndex + p + 46 + nameLen)
            let extra = cd.subdata(in: cd.startIndex + p + 46 + nameLen ..< cd.startIndex + p + 46 + nameLen + extraLen)
            var unicodeName: String?
            Self.parseExtra(extra) { id, body in
                switch id {
                case 0x0001:
                    var q = 0
                    if usize == 0xFFFF_FFFF, q + 8 <= body.count { usize = body.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= body.count { csize = body.u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= body.count { offset = body.u64(q) }
                case 0x7075:
                    // Info-ZIP Unicode Path: version(1) + 원래 이름의 CRC32(4) + UTF-8 이름.
                    // CRC가 원래 이름과 맞을 때만 믿는다(이름을 바꾼 뒤 필드만 남은 경우를 거름).
                    unicodeName = Self.unicodePath(body, originalName: name)
                default: break
                }
            }
            list.append(Entry(rawName: name, utf8Flag: flags & 0x800 != 0, unicodeName: unicodeName,
                              method: method, flags: flags, compressedSize: csize, uncompressedSize: usize,
                              localHeaderOffset: offset, crc32: crc, knownDataOffset: nil, truncated: false))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !list.isEmpty || count == 0 else { throw ZipError.corrupt("central directory") }
        return list
    }

    private static func parseExtra(_ extra: Data, _ body: (UInt16, Data) -> Void) {
        var q = 0
        while q + 4 <= extra.count {
            let id = extra.u16(q)
            let len = Int(extra.u16(q + 2))
            guard q + 4 + len <= extra.count else { break }
            body(id, extra.subdata(in: extra.startIndex + q + 4 ..< extra.startIndex + q + 4 + len))
            q += 4 + len
        }
    }

    static func unicodePath(_ body: Data, originalName: Data?) -> String? {
        guard body.count > 5, body[body.startIndex] == 1 else { return nil }
        if let original = originalName {
            let stored: UInt32 = body.u32(1)
            guard stored == crc(original) else { return nil }
        }
        let utf8 = body.subdata(in: body.startIndex + 5 ..< body.endIndex)
        return String(data: utf8, encoding: .utf8)
    }

    static func crc(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(d.count)))
        }
    }

    // MARK: - 손상 복구: 로컬 헤더 순차 스캔

    private func scanLocalHeaders() throws -> [Entry] {
        let size = source.size
        var list: [Entry] = []
        var pos: UInt64 = 0
        while pos + 30 <= size {
            let h = try source.read(at: pos, count: 30)
            guard h.count == 30, h.u32(0) == 0x0403_4B50 else {
                // 다음 서명을 찾는다(데이터 디스크립터 뒤 등).
                guard let next = try findSignature(from: pos + 1) else { break }
                pos = next
                continue
            }
            let flags = h.u16(6)
            let method = h.u16(8)
            let crc = h.u32(14)
            var csize = UInt64(h.u32(18))
            var usize = UInt64(h.u32(22))
            let nameLen = Int(h.u16(26))
            let extraLen = Int(h.u16(28))
            let name = try source.read(at: pos + 30, count: nameLen)
            let extra = try source.read(at: pos + 30 + UInt64(nameLen), count: extraLen)
            var unicodeName: String?
            Self.parseExtra(extra) { id, body in
                if id == 0x0001, body.count >= 16, usize == 0xFFFF_FFFF { usize = body.u64(0); csize = body.u64(8) }
                if id == 0x7075 { unicodeName = Self.unicodePath(body, originalName: name) }
            }
            let dataStart = pos + 30 + UInt64(nameLen) + UInt64(extraLen)
            if flags & 0x8 != 0 && csize == 0 {
                // 크기가 뒤의 데이터 디스크립터에 있다. 다음 로컬 헤더까지를 데이터로 본다.
                let next = try findSignature(from: dataStart) ?? size
                var end = next
                if end >= dataStart + 16 {
                    let dd = try source.read(at: end - 16, count: 16)
                    if dd.u32(0) == 0x0807_4B50 { csize = UInt64(dd.u32(8)); usize = UInt64(dd.u32(12)); end -= 16 }
                    else { csize = end - dataStart }
                } else {
                    csize = end - dataStart
                }
            }
            guard dataStart < size else { break }
            // 파일 끝에서 잘린 마지막 엔트리: 버리지 않고 남은 데이터까지만 쓴다(JPEG는 윗부분이 보인다).
            let truncated = csize > size - dataStart
            if truncated { csize = size - dataStart }
            list.append(Entry(rawName: name, utf8Flag: flags & 0x800 != 0, unicodeName: unicodeName,
                              method: method, flags: flags, compressedSize: csize, uncompressedSize: usize,
                              localHeaderOffset: pos, crc32: crc, knownDataOffset: dataStart, truncated: truncated))
            pos = dataStart + csize
        }
        guard !list.isEmpty else { throw ZipError.notZip }
        return list
    }

    private func findSignature(from start: UInt64) throws -> UInt64? {
        let chunk = 1 << 20
        var pos = start
        let sig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        while pos < source.size {
            let d = try source.read(at: pos, count: chunk + 3)
            if d.count < 4 { return nil }
            if let r = d.firstRange(of: Data(sig)) { return pos + UInt64(r.lowerBound - d.startIndex) }
            pos += UInt64(chunk)
        }
        return nil
    }

    // MARK: - 엔트리 읽기

    func dataOffset(of entry: Entry) throws -> UInt64 {
        if let known = entry.knownDataOffset { return known }
        let h = try source.read(at: entry.localHeaderOffset, count: 30)
        guard h.count == 30, h.u32(0) == 0x0403_4B50 else { throw ZipError.corrupt("local header") }
        return entry.localHeaderOffset + 30 + UInt64(h.u16(26)) + UInt64(h.u16(28))
    }

    /// 무압축 엔트리를 복사 없이 구간으로 연다(안쪽 zip용).
    /// 엔트리 데이터의 시작 위치. 크기가 파일 안에 들어오는지까지 확인한다.
    private func checkedStart(_ entry: Entry) throws -> UInt64 {
        let start = try dataOffset(of: entry)
        guard start <= source.size, entry.compressedSize <= source.size - start else { throw ZipError.corrupt("size") }
        return start
    }

    func storedSlice(of entry: Entry) throws -> ByteSource? {
        guard entry.method == 0, !entry.isEncrypted else { return nil }
        return SliceByteSource(parent: source, offset: try checkedStart(entry), size: entry.compressedSize)
    }

    func data(of entry: Entry, limit: UInt64 = ZipArchive.maxEntryBytes) throws -> Data {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        let start = try checkedStart(entry)
        guard entry.compressedSize <= limit, entry.truncated || entry.uncompressedSize <= limit else { throw ZipError.tooLarge }
        let raw = try source.read(at: start, count: Int(entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8:
            if entry.truncated { return try Self.inflate(raw, expected: 0, limit: Int(limit), partial: true) }
            return try Self.inflate(raw, expected: Int(entry.uncompressedSize), limit: Int(limit))
        default: throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// 앞부분만 필요할 때(이미지 크기 읽기). 압축된 엔트리도 앞 count 바이트까지만 푼다.
    func prefix(of entry: Entry, count: Int) throws -> Data {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        let start = try checkedStart(entry)
        switch entry.method {
        case 0:
            return try source.read(at: start, count: Int(min(UInt64(count), entry.compressedSize)))
        case 8:
            // 헤더는 보통 앞쪽에 있으니 압축 데이터도 앞부분만 읽는다(압축률 감안해 넉넉히).
            let readLen = Int(min(entry.compressedSize, UInt64(count) * 4))
            return try Self.inflate(source.read(at: start, count: readLen), expected: 0, limit: count, partial: true)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// raw DEFLATE 해제. Apple Compression의 ZLIB 모드는 헤더 없는 DEFLATE(RFC 1951)다.
    /// `limit`을 넘기면 멈춘다. `partial`이면 거기까지 푼 것을 돌려주고(앞부분 읽기), 아니면 오류.
    static func inflate(_ src: Data, expected: Int, limit: Int = Int(ZipArchive.maxEntryBytes), partial: Bool = false) throws -> Data {
        guard !src.isEmpty else { throw ZipError.corrupt("inflate") }
        if expected > 0, expected <= limit {
            var out = Data(count: expected)
            let n = out.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                              s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n == expected { return out }
        }
        // 크기를 모르거나 맞지 않으면 스트림으로 끝까지 푼다.
        var result = Data()
        let bufSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("inflate")
        }
        defer { compression_stream_destroy(&stream) }
        try src.withUnsafeBytes { s in
            stream.src_ptr = s.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                result.append(dst, count: bufSize - stream.dst_size)
                if result.count >= limit {
                    if partial { result = result.prefix(limit); break }
                    throw ZipError.tooLarge
                }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR {
                    if partial && !result.isEmpty { break }   // 앞부분만 읽어 스트림이 잘린 건 정상
                    throw ZipError.corrupt("inflate")
                }
                if stream.src_size == 0 && stream.dst_size == bufSize { break }
            }
        }
        return result
    }
}
