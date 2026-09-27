import XCTest
import zlib
@testable import Jjokview

/// 테스트용 ZIP 조립기. 파일명 바이트, UTF-8 플래그, 0x7075 필드, 압축 방식을 직접 정한다.
struct ZipBuilder {
    struct Item { var name: Data; var data: Data; var utf8Flag = false; var unicodePath: String?; var deflate = false }
    var items: [Item] = []

    mutating func add(_ name: Data, _ data: Data, utf8Flag: Bool = false, unicodePath: String? = nil, deflate: Bool = false) {
        items.append(Item(name: name, data: data, utf8Flag: utf8Flag, unicodePath: unicodePath, deflate: deflate))
    }

    func build(centralDirectory: Bool = true) -> Data {
        var local = Data(), cd = Data()
        for it in items {
            let crc = it.data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(it.data.count))) }
            let body = it.deflate ? Self.rawDeflate(it.data) : it.data
            var extra = Data()
            if let u = it.unicodePath {
                let nameCRC = ZipArchive.crc(it.name)
                var f = Data([1]); f.append(le32(nameCRC)); f.append(Data(u.utf8))
                extra.append(le16(0x7075)); extra.append(le16(UInt16(f.count))); extra.append(f)
            }
            let flags: UInt16 = it.utf8Flag ? 0x800 : 0
            let method: UInt16 = it.deflate ? 8 : 0
            let offset = UInt32(local.count)
            local.append(le32(0x04034B50)); local.append(le16(20)); local.append(le16(flags)); local.append(le16(method))
            local.append(le32(0)); local.append(le32(crc)); local.append(le32(UInt32(body.count))); local.append(le32(UInt32(it.data.count)))
            local.append(le16(UInt16(it.name.count))); local.append(le16(UInt16(extra.count))); local.append(it.name); local.append(extra)
            local.append(body)
            cd.append(le32(0x02014B50)); cd.append(le16(20)); cd.append(le16(20)); cd.append(le16(flags)); cd.append(le16(method))
            cd.append(le32(0)); cd.append(le32(crc)); cd.append(le32(UInt32(body.count))); cd.append(le32(UInt32(it.data.count)))
            cd.append(le16(UInt16(it.name.count))); cd.append(le16(UInt16(extra.count))); cd.append(le16(0))
            cd.append(le16(0)); cd.append(le16(0)); cd.append(le32(0)); cd.append(le32(offset)); cd.append(it.name); cd.append(extra)
        }
        guard centralDirectory else { return local }
        var out = local
        out.append(cd)
        out.append(le32(0x06054B50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(items.count))); out.append(le16(UInt16(items.count)))
        out.append(le32(UInt32(cd.count))); out.append(le32(UInt32(local.count))); out.append(le16(0))
        return out
    }

    static func rawDeflate(_ d: Data) -> Data {
        var out = Data(count: d.count + 1024)
        let n = out.withUnsafeMutableBytes { o in
            d.withUnsafeBytes { i in
                compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, d.count + 1024,
                                          i.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

import Compression

final class CoreTests: XCTestCase {
    let cp949 = NameEncoding.cp949.stringEncoding
    let sjis = NameEncoding.shiftJIS.stringEncoding

    func tmp(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        return url
    }

    // MARK: 인코딩

    func testCP949ExtendedSyllables() throws {
        // 똠·햏·뷁은 EUC-KR(KS X 1001)에 없고 CP949 확장 영역에만 있다.
        var b = ZipBuilder()
        for n in ["모험 01권/001.jpg", "똠얌꿍/햏.png", "뷁/002.webp"] { b.add(n.data(using: cp949)!, Data([1])) }
        let z = try ZipArchive(source: DataByteSource(data: b.build()))
        let raws = z.entries.map(BookLoader.rawName)
        XCTAssertEqual(FilenameDecoder.detect(raws), .cp949)
        XCTAssertEqual(raws.map { FilenameDecoder.decode($0, using: .cp949) }, ["모험 01권/001.jpg", "똠얌꿍/햏.png", "뷁/002.webp"])
    }

    func testShiftJISIsNotMistakenForCP949() throws {
        // SJIS "進撃の巨人"은 CP949로도 오류 없이 풀린다(실측). 점수로 골라야 한다.
        var b = ZipBuilder()
        for n in ["進撃の巨人 第01巻/001.jpg", "進撃の巨人 第01巻/002.jpg"] { b.add(n.data(using: sjis)!, Data([1])) }
        let raws = try ZipArchive(source: DataByteSource(data: b.build())).entries.map(BookLoader.rawName)
        XCTAssertEqual(FilenameDecoder.detect(raws), .shiftJIS)
    }

    func testKoreanIsNotMistakenForShiftJIS() throws {
        var b = ZipBuilder()
        for n in ["모험 소년 01권.zip", "만화책 01.JPG", "만화"] { b.add(n.data(using: cp949)!, Data([1])) }
        let raws = try ZipArchive(source: DataByteSource(data: b.build())).entries.map(BookLoader.rawName)
        XCTAssertEqual(FilenameDecoder.detect(raws), .cp949)
    }

    func testUnicodePathExtraWins() throws {
        // 흔한 모음 zip: 이름은 CP949 바이트, 0x7075에 UTF-8 이름.
        var b = ZipBuilder()
        let n = "[완결] 시리즈/시리즈01.zip"
        b.add(n.data(using: cp949)!, Data([1]), unicodePath: n)
        let e = try ZipArchive(source: DataByteSource(data: b.build())).entries[0]
        XCTAssertEqual(e.unicodeName, n)
        XCTAssertEqual(FilenameDecoder.decode(BookLoader.rawName(e), using: .cp437), n)
    }

    func testNFDNamesAreNormalized() {
        let nfd = "만화".decomposedStringWithCanonicalMapping
        let raw = FilenameDecoder.RawName(bytes: Data(nfd.utf8), utf8Flag: true, unicodeName: nil)
        XCTAssertEqual(FilenameDecoder.decode(raw, using: .automatic).unicodeScalars.count, 2)
    }

    // MARK: ZIP

    func testDeflateAndStored() throws {
        var b = ZipBuilder()
        let payload = Data(repeating: 7, count: 50_000)
        b.add(Data("a.jpg".utf8), payload, deflate: true)
        b.add(Data("b.jpg".utf8), Data([1, 2, 3]))
        let z = try ZipArchive(source: DataByteSource(data: b.build()))
        XCTAssertEqual(try z.data(of: z.entries[0]), payload)
        XCTAssertEqual(try z.data(of: z.entries[1]), Data([1, 2, 3]))
    }

    func testMissingCentralDirectoryIsRecovered() throws {
        // 끝이 잘려 central directory가 없는 zip.
        var b = ZipBuilder()
        for i in 1...5 { b.add(Data("p\(i).jpg".utf8), Data(repeating: UInt8(i), count: 100 * i), deflate: i % 2 == 0) }
        let z = try ZipArchive(source: DataByteSource(data: b.build(centralDirectory: false)))
        XCTAssertTrue(z.recovered)
        XCTAssertEqual(z.entries.count, 5)
        XCTAssertEqual(try z.data(of: z.entries[3]), Data(repeating: 4, count: 400))
    }

    func testNestedStoredZipOpensWithoutExtraction() throws {
        var inner = ZipBuilder()
        inner.add(Data("002.jpg".utf8), Data([2]))
        inner.add(Data("010.jpg".utf8), Data([10]))
        inner.add(Data("001.jpg".utf8), Data([1]))
        inner.add(Data("Thumbs.db".utf8), Data([0]))
        var outer = ZipBuilder()
        outer.add("시리즈/시리즈 02권.zip".data(using: cp949)!, inner.build())
        outer.add("시리즈/시리즈 01권.zip".data(using: cp949)!, inner.build())
        outer.add("시리즈/[Cover].jpg".data(using: cp949)!, Data([9]))
        let url = try tmp("series.zip", outer.build())
        let cache = ArchiveCache()
        let shelf = try BookLoader.shelf(for: url, cache: cache)
        XCTAssertEqual(shelf.volumes.map(\.displayName), ["시리즈 01권", "시리즈 02권"])
        let outerZip = try cache.zip(url)
        XCTAssertNotNil(try outerZip.storedSlice(of: outerZip.entries[0]))
        let book = try BookLoader.load(shelf.volumes[0], cache: cache)
        XCTAssertEqual(book.pages.map(\.name), ["001.jpg", "002.jpg", "010.jpg"])   // 자연 정렬, Thumbs.db 제외
        XCTAssertEqual(try book.pages[2].data(), Data([10]))
    }

    func testFingerprintSurvivesRename() throws {
        var b = ZipBuilder()
        b.add(Data("1.jpg".utf8), Data([1]))
        let a = try tmp("a.zip", b.build())
        let moved = a.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "renamed.cbz")
        try FileManager.default.moveItem(at: a, to: moved)
        let f1 = Hashing.fingerprint(of: try FileByteSource(url: moved))
        let f2 = Hashing.fingerprint(of: DataByteSource(data: b.build()))
        XCTAssertEqual(f1, f2)
    }

    func testAnchorSurvivesEncodingChange() throws {
        var b = ZipBuilder()
        for n in ["가/01.jpg", "가/02.jpg", "가/03.jpg"] { b.add(n.data(using: cp949)!, Data([1])) }
        let url = try tmp("enc.zip", b.build())
        let cache = ArchiveCache()
        let korean = try BookLoader.load(.archive(url), cache: cache, encoding: .cp949)
        let anchor = PageAnchor(pageID: korean.pages[1].id, pageIndex: 1)
        let latin = try BookLoader.load(.archive(url), cache: cache, encoding: .cp437)
        XCTAssertEqual(anchor.resolve(in: latin).index, 1)
        XCTAssertTrue(anchor.resolve(in: latin).exact)
    }

    // MARK: RAR/7z (libarchive)

    func testSolid7z() throws {
        let src = Bundle(for: Self.self).url(forResource: "solid", withExtension: "7z")!
        let url = try tmp("solid.7z", Data(contentsOf: src))
        let book = try BookLoader.load(.archive(url), cache: ArchiveCache())
        XCTAssertEqual(book.pages.map(\.name), ["권/01.png", "권/02.png", "권/03.png"])
        XCTAssertEqual(ImagePipeline.size(of: try book.pages[1].data()), CGSize(width: 40, height: 30))
    }

    // MARK: 쪽 배치

    func testSplitWideFollowsDirection() {
        let wide: (Int) -> Bool = { $0 == 1 }
        var o = SpreadLayout.Options()
        o.layout = .single; o.splitWide = true; o.direction = .rightToLeft
        let rtl = SpreadLayout(pageCount: 3, isWide: wide, options: o)
        XCTAssertEqual(rtl.views.map { $0[0] }, [PagePart(page: 0, half: .full), PagePart(page: 1, half: .right),
                                                  PagePart(page: 1, half: .left), PagePart(page: 2, half: .full)])
        o.direction = .leftToRight
        let ltr = SpreadLayout(pageCount: 3, isWide: wide, options: o)
        XCTAssertEqual(ltr.views[1][0], PagePart(page: 1, half: .left))
    }

    func testDoubleViewShowsSpreadScansWhole() {
        // 두쪽 보기에서는 두 쪽 스캔(가로 이미지)을 나누지 않는다. 그 자체가 펼침면이다.
        var o = SpreadLayout.Options()
        o.layout = .double; o.splitWide = true; o.coverAlone = true
        let l = SpreadLayout(pageCount: 3, isWide: { $0 > 0 }, options: o)
        XCTAssertEqual(l.views, [[PagePart(page: 0, half: .full)], [PagePart(page: 1, half: .full)], [PagePart(page: 2, half: .full)]])
        // 한쪽 보기 기본값은 나누기
        XCTAssertTrue(SpreadLayout.Options().splitWide)
    }

    func testSplitIsAppWideAndDefaultsOn() throws {
        let d = UserDefaults.standard
        let saved = d.object(forKey: AppPreferences.splitSpreadsKey)
        defer { d.set(saved, forKey: AppPreferences.splitSpreadsKey) }
        d.removeObject(forKey: AppPreferences.splitSpreadsKey)
        XCTAssertTrue(AppPreferences.splitSpreads)      // 기본 켬
        AppPreferences.splitSpreads.toggle()             // S 키
        XCTAssertFalse(AppPreferences.splitSpreads)
        // 시리즈 설정에 옛 splitWide 값이 남아 있어도 읽기에 문제없다
        let old = #"{"layout":"single","direction":"rightToLeft","splitWide":false,"coverAlone":true,"fit":"page","sharpen":"off"}"#
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: Data(old.utf8)).layout, .single)
    }

    func testOldSharpenLevelsBecomeSharpText() throws {
        // 예전 "약하게/강하게"는 없앴다. 저장된 값은 글씨 선명으로 읽는다.
        for raw in ["light", "strong"] {
            XCTAssertEqual(try JSONDecoder().decode(SharpenLevel.self, from: Data("\"\(raw)\"".utf8)), .text)
        }
        XCTAssertEqual(try JSONDecoder().decode(SharpenLevel.self, from: Data("\"what\"".utf8)), .off)
        XCTAssertTrue(SharpenLevel.available.contains(.text))
    }

    func testDoubleWithCoverAndWidePage() {
        var o = SpreadLayout.Options()
        o.layout = .double; o.coverAlone = true
        let l = SpreadLayout(pageCount: 6, isWide: { $0 == 3 }, options: o)
        XCTAssertEqual(l.views.map { $0.map(\.page) }, [[0], [1, 2], [3], [4, 5]])
        o.shift = true
        let s = SpreadLayout(pageCount: 6, isWide: { $0 == 3 }, options: o)
        XCTAssertEqual(s.views.map { $0.map(\.page) }, [[0, 1], [2], [3], [4, 5]])
    }

    func testVisualOrderRTL() {
        let v = [PagePart(page: 1, half: .full), PagePart(page: 2, half: .full)]
        XCTAssertEqual(SpreadLayout.visualOrder(v, direction: .rightToLeft).map(\.page), [2, 1])
    }

    // MARK: 저장소

    func testUnreadableLibraryIsBackedUpNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("library.json")
        try Data("{broken".utf8).write(to: file)
        _ = LibraryStore(fileURL: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("library.unreadable-") })
    }

    func testKeyBindingsHaveHoneyviewDefaults() {
        let k = KeyBindings.shared
        XCTAssertEqual(k.action(for: KeyCombo(33)), .previousVolume)            // [
        XCTAssertEqual(k.action(for: KeyCombo(30)), .nextVolume)                // ]
        XCTAssertEqual(k.action(for: KeyCombo(30, command: true)), .nextVolume) // ⌘]
        XCTAssertEqual(k.action(for: KeyCombo(11)), .toggleBookmark)            // B (한글 입력에서도 같은 키코드)
    }

    // MARK: 리뷰에서 재현된 버그 (회귀 방지)

    func fixture(_ name: String) -> URL { Bundle(for: Self.self).url(forResource: name, withExtension: "zip")! }

    func testCorruptSizesDoNotCrash() throws {
        // 손상 zip의 거대한 크기 필드가 덧셈·Int 변환에서 앱을 죽였다(exit 133).
        for name in ["A_z64overflow", "B_hugeusize", "D_hugecsize_stored", "E_scan_overflow"] {
            let url = fixture(name)
            guard let z = try? ZipArchive(url: url) else { continue }   // 열기 실패는 정상적인 오류
            for e in z.entries {
                _ = try? z.data(of: e)
                _ = try? z.prefix(of: e, count: 65_536)
                _ = try? z.storedSlice(of: e)
            }
        }
    }

    func testZipBombIsRefusedWithoutAllocating() throws {
        // 헤더에 2GB라고 적힌 엔트리. 할당하기 전에 거절해야 한다.
        var b = ZipBuilder()
        b.add(Data("bomb.jpg".utf8), Data(repeating: 0, count: 10_000), deflate: true)
        var data = b.build()
        // central directory의 uncompressed size(엔트리 시작 +24)를 2GB로 바꾼다.
        let cd = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        data.replaceSubrange(cd + 24 ..< cd + 28, with: withUnsafeBytes(of: UInt32(0x8000_0000).littleEndian) { Data($0) })
        let z = try ZipArchive(source: DataByteSource(data: data))
        XCTAssertThrowsError(try z.data(of: z.entries[0]))
        XCTAssertLessThanOrEqual(try z.prefix(of: z.entries[0], count: 1000).count, 1000)
    }

    func testCP949EpisodeFoldersAreNotUTF8() throws {
        // "1화", "2화"는 CP949 바이트가 우연히 유효한 UTF-8("1ȭ")이다.
        let z = try ZipArchive(url: fixture("G_cp949folders"))
        XCTAssertEqual(FilenameDecoder.detect(z.entries.map(BookLoader.rawName)), .cp949)
        let shelf = try BookLoader.shelf(for: fixture("G_cp949folders"), cache: ArchiveCache())
        XCTAssertTrue(shelf.volumes.map(\.displayName).allSatisfy { $0.contains("화") }, "\(shelf.volumes.map(\.displayName))")
    }

    func testEncodingOverrideKeepsVolumeFolder() throws {
        // 권 폴더를 자동 판정으로 정한 뒤 사용자가 인코딩을 바꿔도 그 권의 쪽이 사라지면 안 된다.
        let url = fixture("G_cp949folders")
        let cache = ArchiveCache()
        let shelf = try BookLoader.shelf(for: url, cache: cache)
        for enc in [NameEncoding.cp949, .shiftJIS, .utf8] {
            XCTAssertFalse(try BookLoader.load(shelf.volumes[0], cache: cache, encoding: enc).pages.isEmpty, "\(enc)")
        }
    }

    func testLibraryReadsOldOrPartialRecords() throws {
        // 필드가 빠진 기록(구버전), 모르는 enum 값(신버전), 깨진 북마크 하나 — 나머지는 살아야 한다.
        let json = """
        {"books":{"x":{"fingerprint":"x","title":"T","bookmarks":[{"anchor":{"pageID":"p","pageIndex":3}},{"broken":true}],
                       "encoding":"klingon"}},
         "seriesSettings":{"s":{"layout":"hologram","direction":"leftToRight"}}}
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("library.json")
        try Data(json.utf8).write(to: file)
        let store = LibraryStore(fileURL: file)
        XCTAssertEqual(store.books["x"]?.bookmarks.count, 1)
        XCTAssertEqual(store.books["x"]?.bookmarks.first?.anchor.pageIndex, 3)
        XCTAssertEqual(store.books["x"]?.encoding, .automatic)
        XCTAssertEqual(store.seriesSettings["s"]?.direction, .leftToRight)
        XCTAssertEqual(store.seriesSettings["s"]?.layout, .single)
    }

    func testResumePicksMostRecentVolume() {
        let o = URL(fileURLWithPath: "/tmp/series.zip")
        let vols = (1...6).map { VolumeRef.nested(outer: o, path: "s/\($0).zip") }
        func rec(_ n: Int, finished: Bool, ago: TimeInterval) -> BookRecord {
            var r = BookRecord(fingerprint: "\(n)", title: "", seriesKey: "", pageCount: 10)
            r.lastPath = o.path; r.volumePath = "s/\(n).zip"; r.finished = finished
            r.lastOpened = Date().addingTimeInterval(-ago)
            return r
        }
        // 1권을 조금 보다가 5권을 읽는 중 → 5권
        var recent = [rec(5, finished: false, ago: 10), rec(1, finished: false, ago: 100)]
        XCTAssertEqual(ReaderController.startIndex(in: vols, recent: recent, volumePath: nil), 4)
        // 5권까지 다 읽음 → 6권
        recent = [rec(5, finished: true, ago: 10), rec(4, finished: true, ago: 100)]
        XCTAssertEqual(ReaderController.startIndex(in: vols, recent: recent, volumePath: nil), 5)
        // 목록에서 고른 권이 우선
        XCTAssertEqual(ReaderController.startIndex(in: vols, recent: recent, volumePath: "s/2.zip"), 1)
    }

    /// 선명도: 작은 원본은 화면 크기(긴 변 = maxPixel)까지 키우고, 큰 원본은 크기를 그대로 둔다. 결과가 1px이라도 번지면 안 된다.
    func testSharpenOutputSize() throws {
        let ctx = CGContext(data: nil, width: 460, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 460, height: 700))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 100, y: 100, width: 3, height: 500))
        let small = ctx.makeImage()!
        let p = ImagePipeline()
        for level in [SharpenLevel.text, .art] {
            let up = try XCTUnwrap(p.enhance(small, level: level, strength: 0.5, maxPixel: 1400))
            XCTAssertEqual(up.height, 1400, "\(level)")
            XCTAssertEqual(up.width, 920, "\(level)")
            let same = try XCTUnwrap(p.enhance(small, level: level, strength: 0.5, maxPixel: 512))
            XCTAssertEqual([same.width, same.height], [460, 700], "\(level)")
        }
        XCTAssertTrue(p.enhance(small, level: .off, strength: 1, maxPixel: 1400) === small)
        // 예전 저장값은 글씨 선명으로 읽는다
        let old = try JSONDecoder().decode([SharpenLevel].self, from: Data(#"["strong","light","art","nope"]"#.utf8))
        XCTAssertEqual(old, [.text, .text, .art, .off])
    }

    func testUpdateVersionCompareAndParse() throws {
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        let r = try XCTUnwrap(UpdateChecker.release(from: URL(string: "https://github.com/papig-dev/jjokview/releases/tag/v0.2.0")!))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertNil(UpdateChecker.release(from: URL(string: "https://github.com/papig-dev/jjokview/releases")!))   // 릴리스 없음
        XCTAssertNil(UpdateChecker.release(from: URL(string: "https://github.com/papig-dev/jjokview/releases/tag/nightly")!))
    }

    /// 한글 폴더·파일 이름 시리즈: 연 파일 URL(경로 전체 NFD)과 폴더 목록 URL(파일명만 NFC)이 달라도 같은 권으로 본다.
    func testKoreanSiblingShelfFindsCurrentVolume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("한글시리즈-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var b = ZipBuilder()
        b.add(Data("1.jpg".utf8), Data([1]))
        for n in ["만화01.zip", "만화02.zip", "만화03.zip"] { try b.build().write(to: dir.appendingPathComponent(n)) }
        let opened = URL(fileURLWithPath: dir.path.decomposedStringWithCanonicalMapping + "/" + "만화02.zip".decomposedStringWithCanonicalMapping)
        let shelf = try BookLoader.shelf(for: opened, cache: ArchiveCache())
        XCTAssertEqual(shelf.volumes.count, 3)
        XCTAssertEqual(shelf.index, 1)
        XCTAssertEqual(VolumeRef.archive(opened), .archive(dir.appendingPathComponent("만화02.zip")))
    }
}
