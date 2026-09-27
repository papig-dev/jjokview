import CryptoKit
import Foundation

enum ImageFiles {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jxl"]
    static let zipExtensions: Set<String> = ["zip", "cbz"]
    static let otherArchiveExtensions: Set<String> = ["rar", "cbr", "7z", "cb7", "tar", "cbt"]
    static var archiveExtensions: Set<String> { zipExtensions.union(otherArchiveExtensions) }

    static func isImage(_ name: String) -> Bool {
        guard !isJunk(name) else { return false }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isArchive(_ name: String) -> Bool {
        guard !isJunk(name) else { return false }
        return archiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// __MACOSX, AppleDouble(._), .DS_Store, Thumbs.db 등(윈도우에서 만든 만화 zip에는 Thumbs.db가 자주 섞여 있다).
    static func isJunk(_ path: String) -> Bool {
        let comps = path.split(separator: "/")
        if comps.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { return true }
        let last = comps.last.map(String.init)?.lowercased() ?? ""
        return last.hasPrefix("._") || last == "thumbs.db" || last == "desktop.ini"
    }
}

enum NaturalSort {
    /// 경로 컴포넌트 단위 자연 정렬(1 < 2 < 10). 폴더 구조가 섞여도 폴더끼리 먼저 묶인다.
    static func less(_ a: String, _ b: String) -> Bool {
        let ca = a.split(separator: "/"), cb = b.split(separator: "/")
        for (x, y) in zip(ca, cb) where x != y {
            let r = String(x).localizedStandardCompare(String(y))
            if r != .orderedSame { return r == .orderedAscending }
        }
        return ca.count < cb.count
    }
}

enum Hashing {
    static func hex(_ data: Data, length: Int = 32) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }

    /// 크기 + 앞 64KB + 뒤 64KB. 파일을 옮기거나 이름을 바꿔도 같은 책으로 인식한다.
    static func fingerprint(of source: ByteSource) -> String {
        var h = SHA256()
        var size = source.size
        h.update(data: Data(bytes: &size, count: 8))
        if let head = try? source.read(at: 0, count: 65_536) { h.update(data: head) }
        if source.size > 65_536, let tail = try? source.read(at: source.size - 65_536, count: 65_536) { h.update(data: tail) }
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

/// 한 권 안의 한 쪽(이미지 한 장).
struct Page {
    enum Ref {
        case file(URL)
        case zip(ZipArchive, ZipArchive.Entry)
        case libarchive(LibArchiveReader, Int)
    }

    /// 북마크 앵커. 디코딩된 이름이 아니라 원본 바이트의 해시라서 인코딩을 바꿔도 유지된다.
    var id: String
    var name: String
    var ref: Ref

    func data() throws -> Data {
        switch ref {
        case .file(let url): return try Data(contentsOf: url, options: .mappedIfSafe)
        case .zip(let z, let e): return try z.data(of: e)
        case .libarchive(let r, let i): return try r.data(at: i)
        }
    }

    /// 이미지 크기만 알아내기 위한 앞부분. 풀기 전인 solid 페이지는 nil.
    func headerData() -> Data? {
        switch ref {
        case .file(let url):
            guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? fh.close() }
            return try? fh.read(upToCount: 65_536)
        case .zip(let z, let e): return try? z.prefix(of: e, count: 65_536)
        case .libarchive(let r, let i): return r.isReady(i) ? try? r.data(at: i) : nil
        }
    }
}

/// 한 권을 가리키는 위치. 시리즈 안에서 이전/다음 권으로 이동할 때 쓴다.
extension URL {
    /// 비교용 경로. 같은 파일도 URL(fileURLWithPath:)는 경로 전체가 NFD, 폴더 목록은 "NFD 폴더 + NFC 파일명"이라
    /// URL == 로는 다르게 나온다(한글 이름 시리즈에서 현재 권을 못 찾아 다음 권으로 못 넘어가던 원인).
    var comparablePath: String { standardizedFileURL.path.precomposedStringWithCanonicalMapping }
}

enum VolumeRef: Equatable {
    case folder(URL)
    case archive(URL)
    /// 바깥 zip 안에 들어 있는 권 zip. 경로는 바깥 zip 기준, 디코딩 후 NFC.
    case nested(outer: URL, path: String)
    /// 아카이브 안의 폴더 하나를 한 권으로 본다(회차 폴더가 든 웹툰 zip 등).
    case archiveFolder(outer: URL, prefix: String)

    static func == (a: VolumeRef, b: VolumeRef) -> Bool {
        switch (a, b) {
        case let (.folder(x), .folder(y)), let (.archive(x), .archive(y)): return x.comparablePath == y.comparablePath
        case let (.nested(x, p), .nested(y, q)), let (.archiveFolder(x, p), .archiveFolder(y, q)):
            return x.comparablePath == y.comparablePath && p == q
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .folder(let u): return u.lastPathComponent.precomposedStringWithCanonicalMapping
        case .archive(let u): return u.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        case .nested(_, let p): return ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        case .archiveFolder(_, let p): return (p as NSString).lastPathComponent
        }
    }

    /// 시리즈 이름: 폴더·압축 한 권이면 들어 있는 폴더, 묶음 압축 안의 권이면 그 압축 이름. 루트면 빈 문자열.
    var seriesName: String {
        let name: String
        switch self {
        case .nested(let o, _), .archiveFolder(let o, _): name = o.deletingPathExtension().lastPathComponent
        case .folder(let u), .archive(let u): name = u.deletingLastPathComponent().lastPathComponent
        }
        return name == "/" ? "" : name.precomposedStringWithCanonicalMapping
    }

    /// 권 목록 정렬: 이름(확장자 뗀) 자연 정렬, 같으면 전체 파일 이름으로(a, a.cbz, a.zip 순서가 늘 같게).
    static func naturalOrder(_ a: VolumeRef, _ b: VolumeRef) -> Bool {
        let x = a.displayName, y = b.displayName
        if x != y { return NaturalSort.less(x, y) }
        return a.fileURL.lastPathComponent < b.fileURL.lastPathComponent
    }

    /// 창 제목·이어보기 목록용. 권 이름이 숫자뿐이면(시리즈.zip 안의 "12.zip") 시리즈 이름을 앞에 붙인다.
    var title: String {
        let name = displayName
        guard !name.contains(where: \.isLetter) else { return name }
        let series: String
        switch self {
        case .nested(let o, _), .archiveFolder(let o, _): series = o.deletingPathExtension().lastPathComponent
        case .folder(let u), .archive(let u): series = u.deletingLastPathComponent().lastPathComponent
        }
        guard !series.isEmpty, series != "/" else { return name }
        return "\(series.precomposedStringWithCanonicalMapping) · \(name)"
    }

    /// 보안 범위 북마크를 만들 실제 파일/폴더.
    var fileURL: URL {
        switch self {
        case .folder(let u), .archive(let u): return u
        case .nested(let o, _), .archiveFolder(let o, _): return o
        }
    }
}

final class Book {
    let volume: VolumeRef
    let title: String
    let fingerprint: String
    /// 방향·레이아웃 같은 설정을 공유하는 시리즈 단위 키.
    let seriesKey: String
    let pages: [Page]
    let detectedEncoding: NameEncoding
    let usedEncoding: NameEncoding
    /// 목록이 손상돼 로컬 헤더 스캔으로 복구했는지.
    let recovered: Bool
    /// 이름에 인코딩 판정이 필요한 비ASCII 이름이 있었는지(인코딩 메뉴 활성화용).
    let hasAmbiguousNames: Bool
    /// 이미지·크기 캐시 키. 인코딩을 바꾸면 정렬이 달라져 쪽 번호가 다른 이미지를 가리키므로 인코딩까지 넣는다.
    var cacheKey: String { fingerprint + "@" + usedEncoding.rawValue }

    init(volume: VolumeRef, title: String, fingerprint: String, seriesKey: String, pages: [Page],
         detectedEncoding: NameEncoding, usedEncoding: NameEncoding, recovered: Bool, hasAmbiguousNames: Bool) {
        self.volume = volume
        self.title = title
        self.fingerprint = fingerprint
        self.seriesKey = seriesKey
        self.pages = pages
        self.detectedEncoding = detectedEncoding
        self.usedEncoding = usedEncoding
        self.recovered = recovered
        self.hasAmbiguousNames = hasAmbiguousNames
    }
}
