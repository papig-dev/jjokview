import Foundation

/// 임의 위치를 읽을 수 있는 바이트 원본. 파일, 메모리, 그리고 다른 원본의 일부 구간
/// (무압축으로 들어 있는 안쪽 zip)을 같은 방식으로 다룬다.
protocol ByteSource: AnyObject {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

enum ByteSourceError: Error {
    case readFailed(String)
    case outOfRange
}

/// pread 기반 파일 원본. 스레드 여러 개에서 동시에 읽어도 안전하다(파일 오프셋을 공유하지 않음).
final class FileByteSource: ByteSource {
    let url: URL
    let size: UInt64
    private let fd: Int32

    init(url: URL) throws {
        self.url = url
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ByteSourceError.readFailed(String(cString: strerror(errno))) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw ByteSourceError.readFailed(String(cString: strerror(errno)))
        }
        size = UInt64(st.st_size)
    }

    deinit { close(fd) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= size else { throw ByteSourceError.outOfRange }
        let n = Int(min(UInt64(count), size - offset))
        var data = Data(count: n)
        var done = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while done < n {
                let r = pread(fd, base + done, n - done, off_t(offset) + off_t(done))
                if r < 0 {
                    if errno == EINTR { continue }
                    throw ByteSourceError.readFailed(String(cString: strerror(errno)))
                }
                if r == 0 { break }
                done += r
            }
        }
        if done < n { data.removeSubrange(done..<n) }
        return data
    }
}

final class DataByteSource: ByteSource {
    let data: Data
    var size: UInt64 { UInt64(data.count) }
    init(data: Data) { self.data = data }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= size else { throw ByteSourceError.outOfRange }
        let start = data.startIndex + Int(offset)
        let end = min(data.endIndex, start + count)
        return data.subdata(in: start..<end)
    }
}

/// 부모 원본의 [offset, offset+size) 구간. 바깥 zip에 무압축으로 들어 있는 권 zip을
/// 풀지 않고 바로 여는 데 쓴다.
final class SliceByteSource: ByteSource {
    let parent: ByteSource
    let base: UInt64
    let size: UInt64

    init(parent: ByteSource, offset: UInt64, size: UInt64) {
        self.parent = parent
        self.base = offset
        self.size = size
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= size else { throw ByteSourceError.outOfRange }
        let n = Int(min(UInt64(count), size - offset))
        return try parent.read(at: base + offset, count: n)
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 {
        let i = startIndex + o
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }
    func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }
}
