import CLibArchive
import Foundation

/// RAR4/RAR5/7z 등 ZIP이 아닌 형식. libarchive는 순차 스트림 API라 임의 접근이 안 되고,
/// solid 압축은 뒤쪽 페이지를 보려면 앞을 모두 풀어야 한다(실측: 300MB solid 7z 마지막 장 약 12초).
/// 그래서 목록은 헤더만 훑어 즉시 만들고, 페이지 데이터는 백그라운드 스레드 하나가 물리 순서대로
/// 한 번 풀어 디스크 캐시에 쌓는다. 페이지 요청은 해당 파일이 생길 때까지 기다린다.
final class LibArchiveReader {
    struct Entry {
        var index: Int          // 아카이브 안의 물리 순서
        var rawName: Data
        var utf8Name: String?
        var size: Int64
        var isEncrypted: Bool
    }

    enum ReaderError: Error, LocalizedError {
        case open(String)
        case encrypted
        case missing

        var errorDescription: String? {
            switch self {
            case .open(let s): return String(localized: "Could not open the archive (\(s)).")
            case .encrypted: return String(localized: "Password-protected archives are not supported yet.")
            case .missing: return String(localized: "The page could not be extracted.")
            }
        }
    }

    let url: URL
    private(set) var entries: [Entry] = []
    private let cacheDir: URL
    private let state = State()
    private var started = false

    /// 해제 스레드와 공유하는 상태. 스레드가 reader 자체를 붙잡지 않아서, 권을 넘기면
    /// reader가 사라지며 cancel()이 불리고 스레드가 멈춘다.
    private final class State {
        let condition = NSCondition()
        var extracted = Set<Int>()
        var finished = false
        var failure: Error?
        var cancelled = false
    }

    init(url: URL, cacheKey: String) throws {
        self.url = url
        cacheDir = Self.cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)
        entries = try Self.list(url)
        if entries.contains(where: \.isEncrypted) { throw ReaderError.encrypted }
    }

    deinit { cancel() }

    /// 해제를 멈춘다. 기다리던 쪽 요청은 오류로 끝난다.
    func cancel() {
        state.condition.lock(); state.cancelled = true; state.condition.broadcast(); state.condition.unlock()
    }

    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("extracted", isDirectory: true)
    }

    private static func list(_ url: URL) throws -> [Entry] {
        guard let a = archive_read_new() else { throw ReaderError.open("alloc") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 1 << 16) == ARCHIVE_OK else {
            throw ReaderError.open(String(cString: archive_error_string(a)))
        }
        var result: [Entry] = []
        var entry: OpaquePointer?
        var i = 0
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK || r == ARCHIVE_WARN, let e = entry else {
                if result.isEmpty { throw ReaderError.open(String(cString: archive_error_string(a))) }
                break   // 손상: 읽힌 데까지만 쓴다
            }
            if archive_entry_filetype(e) & mode_t(AE_IFMT) == mode_t(AE_IFREG) {
                let raw = archive_entry_pathname(e).map { Data(bytes: $0, count: strlen($0)) } ?? Data()
                let utf8 = archive_entry_pathname_utf8(e).map { String(cString: $0) }
                result.append(Entry(index: i, rawName: raw, utf8Name: utf8,
                                    size: archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : -1,
                                    isEncrypted: archive_entry_is_encrypted(e) != 0))
            }
            archive_read_data_skip(a)
            i += 1
        }
        return result
    }

    /// 백그라운드 순차 해제를 시작한다. `indices`는 실제로 필요한 엔트리(이미지)만. 두 번 불러도 한 번만 돈다.
    func startExtraction(indices: Set<Int>) {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        let dir = cacheDir
        // 이전 실행에서 끝까지 풀어 둔 캐시는, 필요한 파일이 실제로 다 있을 때만 믿는다.
        if fm.fileExists(atPath: dir.appendingPathComponent(".complete").path),
           indices.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent(String($0)).path) }) {
            state.condition.lock(); state.extracted = indices; state.finished = true; state.condition.unlock()
            return
        }
        try? fm.removeItem(at: dir.appendingPathComponent(".complete"))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = self.state
        let url = self.url
        let thread = Thread { Self.runExtraction(url: url, dir: dir, wanted: indices, state: state) }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func runExtraction(url: URL, dir: URL, wanted: Set<Int>, state: State) {
        func finish(_ error: Error?) {
            state.condition.lock(); state.finished = true; state.failure = error; state.condition.broadcast(); state.condition.unlock()
        }
        guard let a = archive_read_new() else { finish(ReaderError.open("alloc")); return }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 1 << 16) == ARCHIVE_OK else {
            finish(ReaderError.open(String(cString: archive_error_string(a))))
            return
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var entry: OpaquePointer?
        var i = 0
        var written = 0
        var allWritten = true
        while written < wanted.count {
            state.condition.lock(); let stop = state.cancelled; state.condition.unlock()
            if stop { finish(nil); return }
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK || r == ARCHIVE_WARN else {
                finish(ReaderError.open(String(cString: archive_error_string(a))))
                return
            }
            defer { i += 1 }
            guard wanted.contains(i) else { archive_read_data_skip(a); continue }
            var data = Data()
            while true {
                let n = archive_read_data(a, buffer, 1 << 20)
                if n <= 0 { break }
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: n)
                if data.count > Int(ZipArchive.maxEntryBytes) { break }
            }
            written += 1
            // 쓰기에 실패하면(디스크 가득 등) 준비됨으로 표시하지 않는다. 그 쪽은 오류로 끝난다.
            guard (try? data.write(to: dir.appendingPathComponent(String(i)), options: .atomic)) != nil else {
                allWritten = false
                continue
            }
            state.condition.lock()
            state.extracted.insert(i)
            state.condition.broadcast()
            state.condition.unlock()
        }
        // 필요한 엔트리를 다 풀면 거기서 멈춘다. 나머지를 끝까지 읽지 않는다.
        if allWritten && written == wanted.count {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(".complete").path, contents: nil)
        }
        finish(nil)
    }

    private func file(for index: Int) -> URL { cacheDir.appendingPathComponent(String(index)) }

    func isReady(_ index: Int) -> Bool {
        state.condition.lock(); defer { state.condition.unlock() }
        return state.extracted.contains(index)
    }

    /// 해당 엔트리가 풀릴 때까지 기다린다. 메인 스레드에서 부르면 안 된다.
    func data(at index: Int) throws -> Data {
        state.condition.lock()
        while !state.extracted.contains(index) && !state.finished && !state.cancelled {
            state.condition.wait()
        }
        let ready = state.extracted.contains(index)
        let err = state.failure
        state.condition.unlock()
        if ready { return try Data(contentsOf: file(for: index), options: .mappedIfSafe) }
        throw err ?? ReaderError.missing
    }

    /// 7일 넘게 안 쓴 캐시와 총량 상한(5GB)을 넘는 오래된 캐시를 지운다.
    static func pruneCache(limitBytes: Int64 = 5 << 30) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var items: [(URL, Date, Int64)] = dirs.map { d in
            let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let size = (fm.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return (d, date, size)
        }
        items.sort { $0.1 > $1.1 }
        var total: Int64 = 0
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        for (url, date, size) in items {
            total += size
            let recentlyUsed = date > Date().addingTimeInterval(-86400)
            if !recentlyUsed && (total > limitBytes || date < weekAgo) { try? fm.removeItem(at: url) }
        }
    }
}
