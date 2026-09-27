import AppKit
import Combine

/// 창 하나의 읽기 상태. 화면(ReaderView)과 사이드바·툴바(SwiftUI)가 모두 이 객체를 본다.
final class ReaderController: ObservableObject {
    @Published private(set) var book: Book?
    @Published private(set) var shelf: Shelf?
    @Published private(set) var settings = LibraryStore.shared.defaults
    @Published private(set) var layout = SpreadLayout(pageCount: 0, isWide: { _ in false }, options: .init())
    @Published private(set) var viewIndex = 0
    @Published private(set) var loading = false
    @Published var toast: String?
    @Published private(set) var shiftOn = false
    /// 자동 넘기기 중인지. 실제 타이머·스크롤은 ReaderViewController가 돌린다.
    @Published private(set) var autoPlaying = false
    private var noSleep: NSObjectProtocol?
    /// 마지막 쪽에서 한 번 더 넘기면 다음 권으로 간다. 그 대기 상태.
    @Published private(set) var pendingVolume: VolumeRef?
    private var pendingSince = Date.distantPast
    /// 키를 누르고 있는 동안(자동 반복)에는 권 경계를 넘지 않는다. ReaderWindow가 채운다.
    var isKeyRepeat = false
    /// 세로 스크롤에서 현재 쪽과 쪽 안의 위치.
    private(set) var verticalAnchor: (page: Int, offset: Double) = (0, 0)

    let pipeline = ImagePipeline()
    let cache = ArchiveCache()
    let store = LibraryStore.shared
    weak var window: NSWindow?
    /// 화면 갱신 요청(위치가 크게 바뀔 때). 세로 모드에서는 스크롤 위치를 옮긴다.
    var onDisplayChange: (() -> Void)?
    /// 사이드바에서 북마크로 이동한 뒤 키보드 포커스를 읽기 화면으로 돌려준다.
    var focusReader: (() -> Void)?
    /// 마우스 클릭 넘김. 키보드와 같은 경로(ReaderViewController.perform)를 타서 자동 넘기기 간격 재시작·권 끝 안내가 같다.
    var clickTurn: ((_ forward: Bool) -> Void)?
    /// 오른쪽 클릭 메뉴(창 컨트롤러가 만든다).
    var contextMenu: (() -> NSMenu)?
    private var toastWork: DispatchWorkItem?
    private var sizeGeneration = 0
    private var accessedURL: URL?
    /// 열기 요청 번호. 빠르게 연달아 열 때 먼저 요청한 결과가 늦게 도착해 화면을 덮지 않게 한다.
    private var requestID = 0

    private var relayoutWork: DispatchWorkItem?

    init() {
        // AI 모델을 다 받으면, 그동안 글씨 선명으로 대신 보여준 쪽을 다시 그린다.
        NotificationCenter.default.addObserver(forName: AIUpscaler.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.sharpen == .ai else { return }
            self.pipeline.clearImages()
            self.onDisplayChange?()
            if AIUpscaler.shared.isReady { self.showToast(String(localized: "AI upscale is ready")) }
        }
        // 설정 창이나 다른 창에서 나누기를 바꾸면 이 창도 다시 배치한다.
        NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.book != nil else { return }
            self.relayout(keeping: self.currentAnchor())
            self.onDisplayChange?()
            self.objectWillChange.send()
        }
        // RAR/7z는 풀어야 크기를 알 수 있다. 새로 알게 되면 (몰아서) 다시 배치한다.
        pipeline.onSizeLearned = { [weak self] key in
            guard let self, self.book?.cacheKey == key else { return }
            self.relayoutWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relayout(keeping: self.currentAnchor())
                self.onDisplayChange?()
            }
            self.relayoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    deinit {
        if let u = accessedURL { AccessBroker.shared.end(u) }
        if let noSleep { ProcessInfo.processInfo.endActivity(noSleep) }
    }

    var hasBook: Bool { book != nil }
    /// 지금 보이는 쪽들. 세로 모드는 화면 맨 위의 쪽 하나로 본다(북마크·쪽 번호 판정용).
    var currentView: [PagePart] {
        if settings.layout == .vertical, pageCount > 0 {
            return [PagePart(page: min(verticalAnchor.page, pageCount - 1), half: .full)]
        }
        return layout.views.indices.contains(viewIndex) ? layout.views[viewIndex] : []
    }
    var currentPage: Int { currentView.first?.page ?? 0 }
    var pageCount: Int { book?.pages.count ?? 0 }
    var record: BookRecord? { book.map { store.record(for: $0) } }
    var bookmarks: [PageBookmark] { record?.bookmarks ?? [] }

    /// 지금 화면(펼침)에 들어 있는 북마크. 한쪽 보기에서 5쪽에 건 북마크도 4–5 펼침에서 보인다.
    var bookmarksInView: [PageBookmark] {
        guard let book else { return [] }
        let ids = Set(currentView.map { book.pages[$0.page].id })
        return bookmarks.filter { ids.contains($0.anchor.pageID) }
    }

    var isCurrentBookmarked: Bool { !bookmarksInView.isEmpty }

    var pageLabel: String {
        guard let book else { return "" }
        if settings.layout == .vertical { return "\(verticalAnchor.page + 1) / \(book.pages.count)" }
        let pages = currentView.map { $0.page + 1 }
        let shown = Array(Set(pages)).sorted().map(String.init).joined(separator: "–")
        return "\(shown) / \(book.pages.count)"
    }

    // MARK: - 열기

    /// - Parameters:
    ///   - accessURL: 보안 범위 북마크로 접근을 시작한 URL. 다른 책을 열거나 창을 닫을 때 접근을 끝낸다.
    ///   - volumePath: 바깥 zip 안의 특정 권을 열 때(이어보기 목록에서 고른 권).
    func open(_ url: URL, bookmarkData: Data? = nil, accessURL: URL? = nil, volumePath: String? = nil) {
        loading = true
        requestID += 1
        let request = requestID
        let cache = self.cache
        // 저장소는 메인 스레드에서만 만진다. 백그라운드에는 복사본을 넘긴다.
        let recent = store.recent
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let shelf = try BookLoader.shelf(for: url, cache: cache) { volumes in
                    Self.startIndex(in: volumes, recent: recent, volumePath: volumePath)
                }
                let volume = shelf.current
                let book = try BookLoader.load(volume, cache: cache, encoding: Self.savedEncoding(for: volume, recent: recent))
                DispatchQueue.main.async {
                    guard request == self.requestID else { return }
                    self.adoptAccess(accessURL)
                    self.present(book, shelf: shelf, rootURL: url, bookmarkData: bookmarkData, anchor: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.requestID else { return }
                    if let accessURL { AccessBroker.shared.end(accessURL) }
                    self.loading = false
                    self.showError(error)
                }
            }
        }
    }

    private func adoptAccess(_ url: URL?) {
        guard let url, url != accessedURL else { return }
        if let old = accessedURL { AccessBroker.shared.end(old) }
        accessedURL = url
    }

    /// 시리즈를 열 때 시작할 권: 고른 권 → 가장 최근에 읽은 권(다 읽었으면 그다음 권) → 첫 권.
    static func startIndex(in volumes: [VolumeRef], recent: [BookRecord], volumePath: String?) -> Int? {
        if let volumePath, let i = volumes.firstIndex(where: { Self.volumePath($0) == volumePath }) { return i }
        // recent는 최근 순이다. 이 시리즈에 속한 기록 중 첫 번째가 마지막으로 읽은 권.
        for r in recent {
            guard let i = volumes.firstIndex(where: {
                r.lastPath?.precomposedStringWithCanonicalMapping == $0.fileURL.comparablePath && r.volumePath == Self.volumePath($0)
            }) else { continue }
            return r.finished && i + 1 < volumes.count ? i + 1 : i
        }
        return nil
    }

    static func volumePath(_ v: VolumeRef) -> String? {
        switch v {
        case .nested(_, let p), .archiveFolder(_, let p): return p
        default: return nil
        }
    }

    private static func savedEncoding(for volume: VolumeRef, recent: [BookRecord]) -> NameEncoding {
        recent.first {
            $0.lastPath?.precomposedStringWithCanonicalMapping == volume.fileURL.comparablePath && $0.volumePath == volumePath(volume)
        }?.encoding ?? .automatic
    }

    func openVolume(_ volume: VolumeRef, anchor: PageAnchor? = nil, fromStart: Bool = false) {
        guard let shelf else { return }
        loading = true
        pendingVolume = nil
        requestID += 1
        let request = requestID
        let cache = self.cache
        let recent = store.recent
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let book = try BookLoader.load(volume, cache: cache, encoding: Self.savedEncoding(for: volume, recent: recent))
                var s = shelf
                s.index = s.volumes.firstIndex(of: volume) ?? s.index
                DispatchQueue.main.async {
                    guard request == self.requestID else { return }
                    self.present(book, shelf: s, rootURL: nil, bookmarkData: nil,
                                 anchor: fromStart ? PageAnchor(pageID: "", pageIndex: 0) : anchor)
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.requestID else { return }
                    self.loading = false
                    self.showError(error)
                }
            }
        }
    }

    private func present(_ book: Book, shelf: Shelf, rootURL: URL?, bookmarkData: Data?, anchor: PageAnchor?) {
        savePosition()
        // 다른 파일로 바뀌면 이전 파일의 열린 아카이브(fd, 해제 스레드)를 놓는다.
        cache.keepOnly(book.volume.fileURL)
        self.book = book
        self.shelf = shelf
        loading = false
        shiftOn = false
        pendingVolume = nil
        settings = store.settings(forSeries: book.seriesKey)
        if !store.hasSettings(forSeries: book.seriesKey), settings.layout != .vertical, looksLikeWebtoon(book) {
            // 처음 여는 시리즈인데 세로로 긴 이미지(웹툰 조각)면 세로 스크롤로 연다.
            settings.layout = .vertical
            store.setSettings(settings, forSeries: book.seriesKey)
        }
        let location = bookmarkData ?? AccessBroker.shared.bookmark(for: book.volume.fileURL)
        store.touch(book: book, location: location)
        window?.title = book.title
        window?.representedURL = book.volume.fileURL
        if let rootURL { NSDocumentController.shared.noteNewRecentDocumentURL(rootURL) }

        let rec = store.record(for: book)
        var start = anchor ?? rec.position
        var resumed = false
        if anchor == nil, rec.finished { start = nil }   // 다 읽은 책은 처음부터
        if anchor == nil, let p = start, p.pageIndex > 0 { resumed = true }
        relayout(keeping: start)
        // 이전 권의 세로 위치가 새 권으로 새지 않게 항상 새로 정한다.
        if let p = start { verticalAnchor = (p.resolve(in: book).index, p.offset) } else { verticalAnchor = (0, 0) }
        onDisplayChange?()
        if resumed {
            showToast(String(localized: "Resuming from page \(currentPage + 1) · ⌘↑ to start over"))
        } else if shelf.needsFolderAccess != nil, shelf.volumes.count == 1 {
            showToast(String(localized: "To use [ and ] for other volumes in this folder, press ] to allow folder access"))
        } else if book.recovered {
            showToast(String(localized: "This archive was damaged. Recovered pages are shown."))
        }
        measureSizes(book)
    }

    /// 앞쪽 몇 장의 세로/가로 비율 중앙값으로 웹툰인지 본다. 첫 장은 제목 띠(690×360)인 경우가 있어
    /// 한 장만 보면 틀린다(실제 웹툰 다운로드 샘플).
    private func looksLikeWebtoon(_ book: Book) -> Bool {
        let ratios = (0..<min(6, book.pages.count)).compactMap { i -> CGFloat? in
            guard let s = pipeline.pixelSize(book: book, page: i), s.width > 0 else { return nil }
            return s.height / s.width
        }.sorted()
        guard !ratios.isEmpty else { return false }
        return ratios[ratios.count / 2] >= 2
    }

    /// 모든 쪽의 크기를 헤더만 읽어 구한다. 넓은 쪽(두 쪽 스캔)과 세로 스크롤 배치에 필요하다.
    private func measureSizes(_ book: Book) {
        sizeGeneration += 1
        let gen = sizeGeneration
        let pipeline = self.pipeline
        DispatchQueue.global(qos: .userInitiated).async {
            var changed = false
            for i in book.pages.indices {
                if pipeline.knownSize(book: book, page: i) == nil, pipeline.pixelSize(book: book, page: i) != nil { changed = true }
                if i % 40 == 39 || i == book.pages.count - 1 {
                    let c = changed
                    changed = false
                    DispatchQueue.main.async {
                        guard gen == self.sizeGeneration, self.book === book, c else { return }
                        self.relayout(keeping: self.currentAnchor())
                        self.onDisplayChange?()
                    }
                }
            }
        }
    }

    func isWide(_ page: Int) -> Bool {
        guard let book, let s = pipeline.knownSize(book: book, page: page) else { return false }
        return ImageGeometry.isWide(s)
    }

    private func relayout(keeping anchor: PageAnchor?) {
        guard let book else { return }
        var opts = SpreadLayout.Options()
        opts.layout = settings.layout
        opts.direction = settings.direction
        opts.splitWide = AppPreferences.splitSpreads
        opts.coverAlone = settings.coverAlone
        opts.shift = shiftOn
        layout = SpreadLayout(pageCount: book.pages.count, isWide: isWide, options: opts)
        if let anchor {
            let (index, _) = anchor.resolve(in: book)
            let part = PagePart(page: index, half: anchor.half)
            viewIndex = layout.parts.contains(part) ? layout.viewIndex(containing: part) : layout.viewIndex(containingPage: index)
        } else {
            viewIndex = 0
        }
        viewIndex = min(viewIndex, max(layout.views.count - 1, 0))
    }

    func currentAnchor() -> PageAnchor? {
        guard let book else { return nil }
        if settings.layout == .vertical {
            let p = min(verticalAnchor.page, book.pages.count - 1)
            return PageAnchor(pageID: book.pages[p].id, pageIndex: p, half: .full, offset: verticalAnchor.offset)
        }
        guard let part = currentView.first else { return nil }
        return PageAnchor(pageID: book.pages[part.page].id, pageIndex: part.page, half: part.half)
    }

    func savePosition() {
        guard let book, let anchor = currentAnchor() else { return }
        let last = settings.layout == .vertical ? anchor.pageIndex >= book.pages.count - 1
            : viewIndex >= layout.views.count - 1
        store.update(book.fingerprint) { r in
            r.position = anchor
            // 끝을 한 번 본 뒤 앞으로 돌아와 읽으면 다시 "읽는 중"이다.
            r.finished = last
        }
    }

    // MARK: - 이동

    func go(toView v: Int) {
        guard !layout.views.isEmpty else { return }
        pendingVolume = nil
        viewIndex = min(max(v, 0), layout.views.count - 1)
        savePosition()
        onDisplayChange?()
    }

    func goToPage(_ page: Int) {
        guard let book else { return }
        let p = min(max(page, 0), book.pages.count - 1)
        if settings.layout == .vertical {
            verticalAnchor = (p, 0)
            savePosition()
            onDisplayChange?()
        } else {
            go(toView: layout.viewIndex(containingPage: p))
        }
    }

    func next() {
        guard book != nil else { return }
        if settings.layout == .vertical { return }   // 세로 모드는 화면이 직접 스크롤한다
        if viewIndex < layout.views.count - 1 { go(toView: viewIndex + 1); return }
        reachedEnd()
    }

    func previous() {
        guard book != nil else { return }
        if settings.layout == .vertical { return }
        if viewIndex > 0 { go(toView: viewIndex - 1); return }
        previousVolumeHint()
    }

    /// 마지막 쪽(세로 모드에서는 맨 아래)에서 앞으로 가려 할 때.
    func reachedEnd() {
        savePosition()
        guard !isKeyRepeat else { return }
        if let nextVol = shelf?.next {
            if confirmPending(nextVol) { openVolume(nextVol, fromStart: true); return }
            showToast(String(localized: "Last page · Press again for “\(nextVol.title)”"))
        } else if let folder = shelf?.needsFolderAccess {
            if confirmPending(.folder(folder)) { askFolderAccess(folder, then: .next); return }
            showToast(String(localized: "Last page · Press again to allow folder access and open the next volume"))
        } else {
            showToast(String(localized: "This is the last page."))
        }
    }

    /// 같은 대상에 대해 두 번째 누름인지. 첫 누름이면 대기 상태로 만든다.
    /// 대기는 안내가 떠 있는 동안(2.5초)만 유효하고, 너무 빠른 연타(0.35초 이내)는 무시한다.
    private func confirmPending(_ target: VolumeRef) -> Bool {
        let elapsed = Date().timeIntervalSince(pendingSince)
        if pendingVolume == target && elapsed < 2.5 {
            if elapsed < 0.35 { return false }
            pendingVolume = nil
            return true
        }
        pendingVolume = target
        pendingSince = Date()
        return false
    }

    func reachedStartVertical() { previousVolumeHint() }

    private func previousVolumeHint() {
        guard !isKeyRepeat else { return }
        if let prev = shelf?.previous {
            if confirmPending(prev) { openVolume(prev, anchor: PageAnchor(pageID: "", pageIndex: Int.max)); return }
            showToast(String(localized: "First page · Press again for “\(prev.title)”"))
        } else if let folder = shelf?.needsFolderAccess {
            if confirmPending(.folder(folder)) { askFolderAccess(folder, then: .previous); return }
            showToast(String(localized: "First page · Press again to allow folder access and open the previous volume"))
        } else {
            showToast(String(localized: "This is the first page."))
        }
    }

    func first() { settings.layout == .vertical ? goToPage(0) : go(toView: 0) }
    func last() { settings.layout == .vertical ? goToPage(pageCount - 1) : go(toView: layout.views.count - 1) }
    func jump(_ delta: Int) { settings.layout == .vertical ? goToPage(verticalAnchor.page + delta) : go(toView: viewIndex + delta) }

    enum FollowUp { case none, next, previous }

    func nextVolume() {
        guard !isKeyRepeat else { return }
        if let v = shelf?.next { openVolume(v, fromStart: false) }
        else if let folder = shelf?.needsFolderAccess { askFolderAccess(folder, then: .next) }
        else { showToast(String(localized: "There is no next volume.")) }
    }

    func previousVolume() {
        guard !isKeyRepeat else { return }
        if let v = shelf?.previous { openVolume(v) }
        else if let folder = shelf?.needsFolderAccess { askFolderAccess(folder, then: .previous) }
        else { showToast(String(localized: "There is no previous volume.")) }
    }

    func askFolderAccess(_ folder: URL, then followUp: FollowUp = .none) {
        AccessBroker.shared.requestFolderAccess(folder, window: window) { [weak self] granted in
            guard let self, granted != nil, let book = self.book else { return }
            // 권한을 받았으니 형제 권 목록을 다시 만들고, 하려던 이동을 이어서 한다.
            guard var s = try? BookLoader.shelf(for: book.volume.fileURL, cache: self.cache) else { return }
            if let i = s.volumes.firstIndex(of: book.volume) { s.index = i }
            self.shelf = s
            switch followUp {
            case .next: if let v = s.next { self.openVolume(v, fromStart: true); return }
            case .previous: if let v = s.previous { self.openVolume(v); return }
            case .none: break
            }
            self.showToast(String(localized: "Folder access allowed. Use [ and ] to change volumes."))
        }
    }

    func updateVertical(page: Int, offset: Double) {
        if page != verticalAnchor.page { pendingVolume = nil }
        verticalAnchor = (page, offset)
        savePosition()
        objectWillChange.send()
    }

    // MARK: - 보기 설정

    private func change(_ edit: (inout ReaderSettings) -> Void) {
        let anchor = currentAnchor()
        let wasVertical = settings.layout == .vertical
        edit(&settings)
        if let book { store.setSettings(settings, forSeries: book.seriesKey) }
        relayout(keeping: anchor)
        if settings.layout == .vertical, !wasVertical, let a = anchor, let book { verticalAnchor = (a.resolve(in: book).index, 0) }
        onDisplayChange?()
    }

    func setLayout(_ l: PageLayout) { change { $0.layout = l } }
    func setDirection(_ d: ReadingDirection) { change { $0.direction = d } }
    func toggleDirection() {
        change { $0.direction = $0.direction == .rightToLeft ? .leftToRight : .rightToLeft }
        showToast(settings.direction == .rightToLeft ? String(localized: "Reading right to left") : String(localized: "Reading left to right"))
    }
    func setDouble(_ d: ReadingDirection) { change { $0.layout = .double; $0.direction = d } }
    func toggleSplit() {
        guard settings.layout == .single else {
            showToast(String(localized: "Splitting works in single-page view (⌘1)"))
            return
        }
        AppPreferences.splitSpreads.toggle()   // 모든 창이 알림을 받아 다시 배치한다
        showToast(AppPreferences.splitSpreads ? String(localized: "Two-page scans are split into single pages")
                                     : String(localized: "Two-page scans are shown whole"))
    }
    func toggleCover() { change { $0.coverAlone.toggle() } }
    func setFit(_ f: FitMode) { change { $0.fit = f } }
    func setSharpen(_ s: SharpenLevel) {
        if s == .ai, !AIUpscaler.shared.isReady {
            // 처음 한 번 시스템 AI 모델을 받는다. 받는 동안은 글씨 선명으로 보여준다.
            AIUpscaler.shared.prepare()
            showToast(String(localized: "Downloading the AI upscale model… Sharp Text is used until it’s ready."))
        }
        // AI를 끄면 세션(한 개에 1.5GB 넘음)을 닫는다. 다른 창이 아직 AI를 쓰면 그대로 둔다.
        if s != .ai, settings.sharpen == .ai,
           !ReaderWindowController.all.contains(where: { $0.controller !== self && $0.controller.settings.sharpen == .ai }) {
            AIUpscaler.shared.releaseSessions()
        }
        change { $0.sharpen = s }
    }
    func cycleSharpen() {
        let next = settings.sharpen.next
        let downloading = next == .ai && !AIUpscaler.shared.isReady
        setSharpen(next)
        // AI 모델을 받기 시작했으면 그 안내(setSharpen이 띄움)를 덮지 않는다.
        if !downloading { showToast(String(localized: "Sharpen: \(settings.sharpen.title)")) }
    }
    func cycleLayout() {
        let all = PageLayout.allCases
        setLayout(all[(all.firstIndex(of: settings.layout)! + 1) % all.count])
    }

    func toggleShift() {
        guard settings.layout == .double else { return }
        let anchor = currentAnchor()
        shiftOn.toggle()
        relayout(keeping: anchor)
        onDisplayChange?()
    }

    func setEncoding(_ e: NameEncoding) {
        guard let book, let shelf else { return }
        // 이름이 바뀌면 정렬이 달라질 수 있다. 위치는 원본 바이트 id라 그대로 찾아간다.
        let anchor = currentAnchor()
        let cache = self.cache
        requestID += 1
        let request = requestID
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BookLoader.load(book.volume, cache: cache, encoding: e) }
            DispatchQueue.main.async {
                guard request == self.requestID else { return }
                switch result {
                case .success(let reloaded):
                    // 불러오기에 성공했을 때만 저장한다(실패한 인코딩이 남아 다음부터 못 여는 일 방지).
                    self.store.update(book.fingerprint) { $0.encoding = e }
                    self.present(reloaded, shelf: shelf, rootURL: nil, bookmarkData: nil, anchor: anchor)
                case .failure(let error):
                    self.loading = false
                    self.showError(error)
                }
            }
        }
    }

    // MARK: - 북마크

    func toggleBookmark() {
        guard let book, let anchor = currentAnchor() else { return }
        if settings.layout != .vertical, !bookmarksInView.isEmpty {
            for b in bookmarksInView { store.removeBookmark(b.id, in: book.fingerprint) }
            objectWillChange.send()
            showToast(String(localized: "Removed bookmark on page \(pageRangeLabel)"))
            return
        }
        let added = store.toggleBookmark(book, at: anchor)
        objectWillChange.send()
        let label = settings.layout == .vertical ? String(anchor.pageIndex + 1) : pageRangeLabel
        showToast(added ? String(localized: "Bookmarked page \(label)") : String(localized: "Removed bookmark on page \(label)"))
    }

    /// "4–5"처럼 지금 화면의 쪽 번호.
    var pageRangeLabel: String {
        let pages = Array(Set(currentView.map { $0.page + 1 })).sorted()
        return pages.map(String.init).joined(separator: "–")
    }

    func go(to bookmark: PageBookmark) {
        guard let book else { return }
        let (index, exact) = bookmark.anchor.resolve(in: book)
        if settings.layout == .vertical {
            verticalAnchor = (index, bookmark.anchor.offset)
            onDisplayChange?()
        } else {
            let part = PagePart(page: index, half: bookmark.anchor.half)
            go(toView: layout.parts.contains(part) ? layout.viewIndex(containing: part) : layout.viewIndex(containingPage: index))
        }
        if !exact { showToast(String(localized: "The page may have moved. Opened the nearest page.")) }
    }

    func stepBookmark(_ forward: Bool) {
        guard let book, !bookmarks.isEmpty else { return }
        let sorted = bookmarks.sorted { $0.anchor.resolve(in: book).index < $1.anchor.resolve(in: book).index }
        let cur = currentPage
        let target = forward ? sorted.first { $0.anchor.resolve(in: book).index > cur } ?? sorted.first
                             : sorted.last { $0.anchor.resolve(in: book).index < cur } ?? sorted.last
        if let target { go(to: target) }
    }

    func removeBookmark(_ b: PageBookmark) {
        guard let book else { return }
        store.removeBookmark(b.id, in: book.fingerprint)
        objectWillChange.send()
    }

    func removeAllBookmarks() {
        guard let book else { return }
        store.removeAllBookmarks(in: book.fingerprint)
        objectWillChange.send()
    }

    // MARK: - 자동 넘기기

    func setAutoPlay(_ on: Bool) {
        guard on != autoPlaying else { return }
        guard !on || book != nil else { return }
        autoPlaying = on
        if on {
            // 자동 넘기기 중에는 화면이 꺼지지 않게 한다.
            noSleep = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                            reason: "Auto advance")
            showToast(settings.layout == .vertical
                      ? String(localized: "Auto scroll · \(Int(AutoPlayPreferences.speed)) pt/s · , slower . faster · Space stop")
                      : String(localized: "Auto advance · every \(Self.seconds(AutoPlayPreferences.interval)) · , slower . faster · Space stop"))
        } else {
            if let noSleep { ProcessInfo.processInfo.endActivity(noSleep) }
            noSleep = nil
            showToast(String(localized: "Auto advance stopped"))
        }
    }

    /// 쪽 넘김 간격이나 세로 속도를 바꾼다. faster면 빨라진다.
    func adjustAutoSpeed(faster: Bool) {
        if settings.layout == .vertical {
            AutoPlayPreferences.speed *= faster ? 1.25 : 0.8
            showToast(String(localized: "Auto scroll speed: \(Int(AutoPlayPreferences.speed)) pt/s"))
        } else {
            let steps: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30, 45, 60]
            let cur = AutoPlayPreferences.interval
            let next = faster ? steps.last { $0 < cur } ?? steps.first! : steps.first { $0 > cur } ?? steps.last!
            AutoPlayPreferences.interval = next
            showToast(String(localized: "Auto advance: every \(Self.seconds(next))"))
        }
    }

    static func seconds(_ s: Double) -> String {
        String(localized: "\(Int(s)) s")
    }

    /// 자동 넘기기 한 걸음(쪽 모드). 마지막 쪽이면 확인 없이 다음 권으로 이어서 가거나 멈춘다.
    func autoStep() {
        guard book != nil, !loading else { return }
        #if DEBUG
        ImagePipeline.debugLog(String(format: "%.3f autoStep", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
        #endif
        if viewIndex < layout.views.count - 1 { go(toView: viewIndex + 1); return }
        autoAdvanceVolume()
    }

    /// 권 끝에 닿았을 때(쪽 모드·세로 모드 공통).
    func autoAdvanceVolume() {
        savePosition()
        if AutoPlayPreferences.continueToNextVolume, let v = shelf?.next {
            openVolume(v, fromStart: true)
        } else {
            setAutoPlay(false)
            showToast(String(localized: "Auto advance reached the end"))
        }
    }

    // MARK: - 알림

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not open")
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
