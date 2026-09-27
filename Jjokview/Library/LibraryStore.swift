import Foundation

/// 저장 파일을 읽을 때 필드가 없거나 모르는 값(새 버전에서 추가된 enum 등)이어도 기본값으로 채운다.
/// 합성 Codable은 기본값이 있는 필드도 필수로 취급해서, 필드 하나만 늘어도 라이브러리 전체를 못 읽는다.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// 딕셔너리 값 하나가 깨져도 나머지는 읽는다.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// 책 안의 위치. 쪽 번호가 아니라 쪽의 고유 id(원본 파일명 바이트의 해시)를 기준으로 삼고,
/// 번호는 id를 못 찾을 때만 쓴다. 세로 스크롤은 그 쪽 안의 세로 위치(0~1)까지 저장한다.
struct PageAnchor: Codable, Equatable {
    var pageID: String
    var pageIndex: Int
    var half: PagePart.Half = .full
    var offset: Double = 0

    init(pageID: String, pageIndex: Int, half: PagePart.Half = .full, offset: Double = 0) {
        self.pageID = pageID; self.pageIndex = pageIndex; self.half = half; self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageID = try c.decode(String.self, forKey: .pageID)
        pageIndex = c.lenient(.pageIndex, 0)
        half = c.lenient(.half, .full)
        offset = c.lenient(.offset, 0)
    }

    func resolve(in book: Book) -> (index: Int, exact: Bool) {
        if let i = book.pages.firstIndex(where: { $0.id == pageID }) { return (i, true) }
        return (min(max(pageIndex, 0), max(book.pages.count - 1, 0)), false)
    }
}

struct PageBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var anchor: PageAnchor
    var createdAt = Date()
    var note: String = ""

    init(anchor: PageAnchor) { self.anchor = anchor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(PageAnchor.self, forKey: .anchor)
        id = c.lenient(.id, UUID())
        createdAt = c.lenient(.createdAt, Date())
        note = c.lenient(.note, "")
    }
}

/// 앱 전체 설정(시리즈마다 따로 두지 않는 것).
enum AppPreferences {
    static let splitSpreadsKey = "splitSpreadsInSingle"
    static let didChange = Notification.Name("AppPreferencesDidChange")

    /// 한쪽 보기에서 두 쪽 스캔(가로 이미지)을 반씩 나눠 한 쪽씩 보여준다. 기본 켬. S 키와 설정 창이 같은 값을 바꾼다.
    static var splitSpreads: Bool {
        get { UserDefaults.standard.object(forKey: splitSpreadsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: splitSpreadsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// 자동 넘기기 설정(앱 전체).
enum AutoPlayPreferences {
    private static let d = UserDefaults.standard
    /// 한쪽·두쪽 보기에서 다음 쪽으로 넘기는 간격(초).
    static var interval: Double {
        get { d.object(forKey: "auto.interval") as? Double ?? 5 }
        set { d.set(min(max(newValue, 1), 60), forKey: "auto.interval") }
    }
    /// 세로(웹툰) 모드의 흐르는 속도(초당 포인트).
    static var speed: Double {
        get { d.object(forKey: "auto.speed") as? Double ?? 70 }
        set { d.set(min(max(newValue, 10), 600), forKey: "auto.speed") }
    }
    /// 권 끝에서 다음 권으로 이어서 계속할지.
    static var continueToNextVolume: Bool {
        get { d.object(forKey: "auto.continue") as? Bool ?? true }
        set { d.set(newValue, forKey: "auto.continue") }
    }
}

/// 책마다(또는 시리즈마다) 기억하는 보기 설정.
struct ReaderSettings: Codable, Equatable {
    var layout: PageLayout = .single
    var direction: ReadingDirection = .rightToLeft
    var coverAlone = true
    var fit: FitMode = .page
    var sharpen: SharpenLevel = .off

    init() {}

    enum CodingKeys: String, CodingKey {
        case layout, direction, coverAlone, fit, sharpen
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layout, forKey: .layout)
        try c.encode(direction, forKey: .direction)
        try c.encode(coverAlone, forKey: .coverAlone)
        try c.encode(fit, forKey: .fit)
        try c.encode(sharpen, forKey: .sharpen)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        layout = c.lenient(.layout, d.layout)
        direction = c.lenient(.direction, d.direction)
        coverAlone = c.lenient(.coverAlone, d.coverAlone)
        fit = c.lenient(.fit, d.fit)
        sharpen = c.lenient(.sharpen, d.sharpen)
    }
}

struct BookRecord: Codable, Identifiable {
    var id: String { fingerprint }
    var fingerprint: String
    var title: String
    var seriesKey: String
    var pageCount: Int
    var position: PageAnchor?
    var finished = false
    var lastOpened = Date()
    var bookmarks: [PageBookmark] = []
    var encoding: NameEncoding = .automatic
    /// 보안 범위 북마크(샌드박스에서 앱을 다시 켠 뒤 파일을 다시 열기 위해 필요).
    var location: Data?
    var lastPath: String?
    /// 권 위치(바깥 zip 안의 권 등)를 다시 찾기 위한 정보.
    var volumeKind: String?
    var volumePath: String?
    /// 시작 화면의 이어보기 목록에서만 숨긴다(북마크·위치는 그대로 둔다).
    var hiddenFromRecent = false

    /// 이어보기 목록의 권 이름. 예전 기록은 "시리즈01.zip"처럼 확장자가 붙어 있어 떼고 보여준다.
    var displayTitle: String {
        let ext = (title as NSString).pathExtension.lowercased()
        guard volumeKind != "folder", ImageFiles.archiveExtensions.contains(ext) else { return title }
        return (title as NSString).deletingPathExtension
    }

    /// 어느 시리즈의 권인지(같은 이름 구분용): 폴더·압축 한 권이면 들어 있는 폴더 이름, 묶음 압축 안의 권이면 그 압축 이름.
    var seriesName: String? {
        guard let path = lastPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let name: String
        switch volumeKind {
        case "nested", "archiveFolder": name = url.deletingPathExtension().lastPathComponent
        default: name = url.deletingLastPathComponent().lastPathComponent
        }
        return name.isEmpty || name == "/" ? nil : name.precomposedStringWithCanonicalMapping
    }

    init(fingerprint: String, title: String, seriesKey: String, pageCount: Int) {
        self.fingerprint = fingerprint; self.title = title; self.seriesKey = seriesKey; self.pageCount = pageCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        title = c.lenient(.title, "")
        seriesKey = c.lenient(.seriesKey, "")
        pageCount = c.lenient(.pageCount, 0)
        position = c.lenient(.position, nil)
        finished = c.lenient(.finished, false)
        lastOpened = c.lenient(.lastOpened, Date.distantPast)
        // 북마크는 하나씩 읽어서, 깨진 항목만 버린다.
        bookmarks = (c.lenient(.bookmarks, [Lossy<PageBookmark>]())).compactMap(\.value)
        encoding = c.lenient(.encoding, .automatic)
        location = c.lenient(.location, nil)
        lastPath = c.lenient(.lastPath, nil)
        volumeKind = c.lenient(.volumeKind, nil)
        volumePath = c.lenient(.volumePath, nil)
        hiddenFromRecent = c.lenient(.hiddenFromRecent, false)
    }

    var progress: Double {
        guard pageCount > 1, let p = position else { return finished ? 1 : 0 }
        return finished ? 1 : Double(p.pageIndex) / Double(pageCount - 1)
    }
}

/// 저장 파일 하나(JSON). UserDefaults 4MB 한계와 상한 삭제 문제를 피한다.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var books: [String: BookRecord] = [:]
    @Published private(set) var seriesSettings: [String: ReaderSettings] = [:]
    @Published var defaults = ReaderSettings()
    /// 사용자가 접근을 허용한 폴더(다음 권 이동용).
    private(set) var folderGrants: [Data] = []

    private struct Snapshot: Codable {
        var version = 1
        var books: [String: BookRecord]
        var seriesSettings: [String: ReaderSettings]
        var defaults: ReaderSettings
        var folderGrants: [Data]

        init(books: [String: BookRecord], seriesSettings: [String: ReaderSettings], defaults: ReaderSettings, folderGrants: [Data]) {
            self.books = books; self.seriesSettings = seriesSettings; self.defaults = defaults; self.folderGrants = folderGrants
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.lenient(.version, 1)
            books = c.lenient(.books, [String: Lossy<BookRecord>]()).compactMapValues(\.value)
            seriesSettings = c.lenient(.seriesSettings, [String: Lossy<ReaderSettings>]()).compactMapValues(\.value)
            defaults = c.lenient(.defaults, ReaderSettings())
            folderGrants = c.lenient(.folderGrants, [Data]())
        }
    }


    let fileURL: URL
    private var saveWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "library.save")

    init(fileURL: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jjokview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("library.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let s = try JSONDecoder().decode(Snapshot.self, from: data)
            books = s.books
            seriesSettings = s.seriesSettings
            defaults = s.defaults
            folderGrants = s.folderGrants
        } catch {
            // 읽지 못한 파일을 빈 상태로 덮어쓰면 북마크가 전부 사라진다. 따로 보관해 둔다.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("library.unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("Jjokview: library.json unreadable (\(error)); kept a copy at \(backup.path)")
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let snap = Snapshot(books: books, seriesSettings: seriesSettings, defaults: defaults, folderGrants: folderGrants)
        let url = fileURL
        let work = DispatchWorkItem {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(snap) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        let snap = Snapshot(books: books, seriesSettings: seriesSettings, defaults: defaults, folderGrants: folderGrants)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: - 책

    func record(for book: Book) -> BookRecord {
        books[book.fingerprint] ?? BookRecord(fingerprint: book.fingerprint, title: book.title,
                                              seriesKey: book.seriesKey, pageCount: book.pages.count)
    }

    func update(_ fingerprint: String, _ change: (inout BookRecord) -> Void) {
        guard var r = books[fingerprint] else { return }
        change(&r)
        books[fingerprint] = r
        scheduleSave()
    }

    func touch(book: Book, location: Data?) {
        var r = record(for: book)
        r.title = book.title
        r.pageCount = book.pages.count
        r.lastOpened = Date()
        r.hiddenFromRecent = false
        if let location { r.location = location }
        r.lastPath = book.volume.fileURL.path
        switch book.volume {
        case .folder: r.volumeKind = "folder"; r.volumePath = nil
        case .archive: r.volumeKind = "archive"; r.volumePath = nil
        case .nested(_, let p): r.volumeKind = "nested"; r.volumePath = p
        case .archiveFolder(_, let p): r.volumeKind = "archiveFolder"; r.volumePath = p
        }
        books[book.fingerprint] = r
        scheduleSave()
    }

    /// 모든 기록(최근 순). 메인 스레드에서만 부른다. 백그라운드에서는 미리 복사해 둔 배열을 넘긴다.
    var recent: [BookRecord] {
        dispatchPrecondition(condition: .onQueue(.main))
        return books.values.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// 시작 화면에 보일 목록. 숨긴 항목을 빼고, 한 시리즈는 가장 최근 권 하나만 보인다.
    var recentForDisplay: [BookRecord] {
        var seen = Set<String>()
        return recent.filter { r in
            guard !r.hiddenFromRecent else { return false }
            return seen.insert(r.seriesKey.isEmpty ? r.fingerprint : r.seriesKey).inserted
        }
    }

    /// 이어보기 목록에서만 숨긴다. 북마크와 읽던 위치는 지우지 않는다.
    func hideFromRecent(_ fingerprint: String) {
        update(fingerprint) { $0.hiddenFromRecent = true }
    }

    func forget(_ fingerprint: String) {
        books[fingerprint] = nil
        scheduleSave()
    }

    // MARK: - 북마크 (추가한 순서대로 유지)

    func toggleBookmark(_ book: Book, at anchor: PageAnchor) -> Bool {
        var r = record(for: book)
        if let i = r.bookmarks.firstIndex(where: { $0.anchor.pageID == anchor.pageID && $0.anchor.half == anchor.half }) {
            r.bookmarks.remove(at: i)
            books[book.fingerprint] = r
            scheduleSave()
            return false
        }
        r.bookmarks.append(PageBookmark(anchor: anchor))
        books[book.fingerprint] = r
        scheduleSave()
        return true
    }

    func removeBookmark(_ id: UUID, in fingerprint: String) {
        update(fingerprint) { $0.bookmarks.removeAll { $0.id == id } }
    }

    func removeAllBookmarks(in fingerprint: String) {
        update(fingerprint) { $0.bookmarks.removeAll() }
    }

    func setNote(_ note: String, bookmark id: UUID, in fingerprint: String) {
        update(fingerprint) { r in
            if let i = r.bookmarks.firstIndex(where: { $0.id == id }) { r.bookmarks[i].note = note }
        }
    }

    // MARK: - 설정

    func hasSettings(forSeries key: String) -> Bool { seriesSettings[key] != nil }

    func settings(forSeries key: String) -> ReaderSettings { seriesSettings[key] ?? defaults }

    /// 시리즈 설정만 바꾼다. 새 시리즈의 기본값은 설정 창에서만 바꾼다
    /// (웹툰을 세로로 보다가 만화를 열면 만화까지 세로로 열리는 문제를 막는다).
    func setSettings(_ s: ReaderSettings, forSeries key: String) {
        seriesSettings[key] = s
        scheduleSave()
    }

    // MARK: - 폴더 권한

    func addFolderGrant(_ data: Data) {
        folderGrants.append(data)
        scheduleSave()
    }
}
