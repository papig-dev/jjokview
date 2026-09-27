import Foundation

/// 열린 위치에서 만든 시리즈(권 목록)와 현재 권.
struct Shelf {
    var volumes: [VolumeRef]
    var index: Int
    /// 부모 폴더를 읽을 권한이 없어 형제 권을 못 찾았는지(샌드박스). 폴더 접근 허용을 제안할 때 쓴다.
    var needsFolderAccess: URL?

    var current: VolumeRef { volumes[index] }
    var next: VolumeRef? { index + 1 < volumes.count ? volumes[index + 1] : nil }
    var previous: VolumeRef? { index > 0 ? volumes[index - 1] : nil }
}

enum BookLoaderError: Error, LocalizedError {
    case noImages
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noImages: return String(localized: "No images were found.")
        case .unsupported: return String(localized: "This file type is not supported.")
        }
    }
}

/// 바깥 아카이브를 한 번만 열어 두고 권 사이를 오갈 때 재사용한다.
final class ArchiveCache {
    private var zips: [URL: ZipArchive] = [:]
    private var others: [URL: LibArchiveReader] = [:]
    private var fingerprints: [URL: String] = [:]
    private let lock = NSLock()

    func zip(_ url: URL) throws -> ZipArchive {
        lock.lock(); defer { lock.unlock() }
        if let z = zips[url] { return z }
        let z = try ZipArchive(url: url)
        zips[url] = z
        return z
    }

    func fingerprint(_ url: URL) throws -> String {
        lock.lock()
        if let f = fingerprints[url] { lock.unlock(); return f }
        lock.unlock()
        let f = Hashing.fingerprint(of: try FileByteSource(url: url))
        lock.lock(); fingerprints[url] = f; lock.unlock()
        return f
    }

    /// 지금 보는 파일 말고는 놓는다(fd와 RAR/7z 해제 스레드가 쌓이지 않게).
    func keepOnly(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        zips = zips.filter { $0.key == url }
        for (u, r) in others where u != url { r.cancel() }
        others = others.filter { $0.key == url }
    }

    func other(_ url: URL, key: String) throws -> LibArchiveReader {
        lock.lock(); defer { lock.unlock() }
        if let r = others[url] { return r }
        let r = try LibArchiveReader(url: url, cacheKey: key)
        others[url] = r
        return r
    }
}

enum BookLoader {
    static func isZip(_ url: URL) -> Bool { ImageFiles.zipExtensions.contains(url.pathExtension.lowercased()) }

    // MARK: - 시리즈 구성

    /// 사용자가 연 위치에서 시리즈와 시작 권을 정한다.
    static func shelf(for url: URL, cache: ArchiveCache, preferred: (([VolumeRef]) -> Int?)? = nil) throws -> Shelf {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            let children = try listFolder(url)
            if children.contains(where: { ImageFiles.isImage($0.lastPathComponent) }) {
                return siblingShelf(for: .folder(url), in: url.deletingLastPathComponent())
            }
            // 이미지 없이 권(폴더·압축)만 있으면 시리즈 폴더로 본다(웹툰 회차 폴더, 권 zip 모음).
            let volumes = children.compactMap(volumeRef(for:)).sorted(by: VolumeRef.naturalOrder)
            guard !volumes.isEmpty else { throw BookLoaderError.noImages }
            return Shelf(volumes: volumes, index: preferred?(volumes) ?? 0)
        }

        let ext = url.pathExtension.lowercased()
        guard ImageFiles.archiveExtensions.contains(ext) else {
            if ImageFiles.isImage(url.lastPathComponent) {
                return siblingShelf(for: .folder(url.deletingLastPathComponent()), in: url.deletingLastPathComponent().deletingLastPathComponent())
            }
            throw BookLoaderError.unsupported
        }

        if isZip(url) {
            let z = try cache.zip(url)
            let enc = FilenameDecoder.detect(z.entries.map(rawName))
            let names = z.entries.map { FilenameDecoder.decode(rawName($0), using: enc) }
            // 바깥 zip 안에 권 zip이 들어 있으면(사용자 샘플 대부분) 그 권들이 시리즈다.
            let nested = names.filter { ImageFiles.isArchive($0) && ImageFiles.zipExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            if !nested.isEmpty {
                let volumes = nested.sorted(by: NaturalSort.less).map { VolumeRef.nested(outer: url, path: $0) }
                return Shelf(volumes: volumes, index: preferred?(volumes) ?? 0)
            }
            let folders = imageFolders(names)
            if folders.count > 1 {
                let volumes = folders.map { VolumeRef.archiveFolder(outer: url, prefix: $0) }
                return Shelf(volumes: volumes, index: preferred?(volumes) ?? 0)
            }
        }
        return siblingShelf(for: .archive(url), in: url.deletingLastPathComponent())
    }

    /// 이미지가 들어 있는 폴더들(자연 정렬). 폴더가 둘 이상이면 폴더마다 한 권으로 나눈다.
    private static func imageFolders(_ names: [String]) -> [String] {
        let dirs = Set(names.filter(ImageFiles.isImage).map { ($0 as NSString).deletingLastPathComponent })
        return dirs.sorted(by: NaturalSort.less)
    }

    private static func siblingShelf(for volume: VolumeRef, in parent: URL) -> Shelf {
        guard let children = try? listFolder(parent) else {
            return Shelf(volumes: [volume], index: 0, needsFolderAccess: parent)
        }
        var volumes = children.compactMap(volumeRef(for:)).sorted(by: VolumeRef.naturalOrder)
        if !volumes.contains(volume) { volumes.append(volume) }
        return Shelf(volumes: volumes, index: volumes.firstIndex(of: volume) ?? 0)
    }

    private static func listFolder(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])
    }

    private static func volumeRef(for url: URL) -> VolumeRef? {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir { return .folder(url) }
        return ImageFiles.isArchive(url.lastPathComponent) ? .archive(url) : nil
    }

    static func rawName(_ e: ZipArchive.Entry) -> FilenameDecoder.RawName {
        FilenameDecoder.RawName(bytes: e.rawName, utf8Flag: e.utf8Flag, unicodeName: e.unicodeName)
    }

    // MARK: - 권 읽기

    static func load(_ volume: VolumeRef, cache: ArchiveCache, encoding override: NameEncoding = .automatic) throws -> Book {
        switch volume {
        case .folder(let url):
            let files = try listFolder(url).filter { ImageFiles.isImage($0.lastPathComponent) }
            let named = files.map { ($0, $0.lastPathComponent.precomposedStringWithCanonicalMapping) }
                .sorted { NaturalSort.less($0.1, $1.1) }
            guard !named.isEmpty else { throw BookLoaderError.noImages }
            // 폴더 지문: 정렬된 (이름, 크기) 목록. 폴더를 옮기거나 이름을 바꿔도 같다.
            var sig = Data()
            for (u, n) in named {
                sig.append(Data(n.utf8))
                sig.append(Data(String((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0).utf8))
            }
            let pages = named.map { Page(id: $0.1, name: $0.1, ref: .file($0.0)) }
            return Book(volume: volume, title: volume.title, fingerprint: "d:" + Hashing.hex(sig),
                        seriesKey: "s:" + url.deletingLastPathComponent().path.precomposedStringWithCanonicalMapping,
                        pages: pages, detectedEncoding: .utf8, usedEncoding: .utf8, recovered: false, hasAmbiguousNames: false)

        case .archive(let url):
            let fp = try cache.fingerprint(url)
            let series = "s:" + url.deletingLastPathComponent().path.precomposedStringWithCanonicalMapping
            if isZip(url) {
                return try zipBook(cache.zip(url), volume: volume, fingerprint: "z:" + fp, seriesKey: series, prefix: nil, override: override)
            }
            return try libarchiveBook(url, volume: volume, fingerprint: "r:" + fp, seriesKey: series, cache: cache, override: override)

        case .nested(let outerURL, let path):
            let outer = try cache.zip(outerURL)
            let enc = FilenameDecoder.detect(outer.entries.map(rawName))
            guard let entry = outer.entries.first(where: { FilenameDecoder.decode(rawName($0), using: enc) == path }) else {
                throw BookLoaderError.noImages
            }
            // 바깥이 무압축(STORED)이면 풀지 않고 그 구간을 바로 zip으로 연다(실측 약 1.5ms).
            let source: ByteSource = try outer.storedSlice(of: entry) ?? DataByteSource(data: outer.data(of: entry))
            let inner = try ZipArchive(source: source)
            let fp = try cache.fingerprint(outerURL) + "/" + Hashing.hex(entry.rawName, length: 16)
            return try zipBook(inner, volume: volume, fingerprint: "n:" + fp, seriesKey: "o:" + (try cache.fingerprint(outerURL)),
                               prefix: nil, override: override)

        case .archiveFolder(let outerURL, let prefix):
            let fp = try cache.fingerprint(outerURL)
            return try zipBook(cache.zip(outerURL), volume: volume, fingerprint: "f:" + fp + "#" + prefix,
                               seriesKey: "o:" + fp, prefix: prefix, override: override)
        }
    }

    private static func zipBook(_ z: ZipArchive, volume: VolumeRef, fingerprint: String, seriesKey: String,
                                prefix: String?, override: NameEncoding) throws -> Book {
        let raws = z.entries.map(rawName)
        let detected = FilenameDecoder.detect(raws)
        let enc = override == .automatic ? detected : override
        var pages: [Page] = []
        for (e, raw) in zip(z.entries, raws) where !e.isDirectory {
            let name = FilenameDecoder.decode(raw, using: enc)
            guard ImageFiles.isImage(name) else { continue }
            // 권 폴더(prefix)는 시리즈를 만들 때 자동 판정 인코딩으로 정했다. 사용자가 인코딩을 바꿔도
            // 같은 기준으로 걸러야 권이 사라지지 않는다(바꾼 인코딩은 쪽 이름 표시에만 쓴다).
            if let prefix {
                let autoName = enc == detected ? name : FilenameDecoder.decode(raw, using: detected)
                if (autoName as NSString).deletingLastPathComponent != prefix { continue }
            }
            pages.append(Page(id: Hashing.hex(e.rawName, length: 16), name: name, ref: .zip(z, e)))
        }
        pages.sort { NaturalSort.less($0.name, $1.name) }
        guard !pages.isEmpty else { throw BookLoaderError.noImages }
        let ambiguous = raws.contains { !$0.utf8Flag && $0.unicodeName == nil && !FilenameDecoder.isASCII($0.bytes) }
        return Book(volume: volume, title: volume.title, fingerprint: fingerprint, seriesKey: seriesKey,
                    pages: pages, detectedEncoding: detected, usedEncoding: enc, recovered: z.recovered, hasAmbiguousNames: ambiguous)
    }

    private static func libarchiveBook(_ url: URL, volume: VolumeRef, fingerprint: String, seriesKey: String,
                                       cache: ArchiveCache, override: NameEncoding) throws -> Book {
        let reader = try cache.other(url, key: fingerprint.replacingOccurrences(of: ":", with: "_"))
        // RAR5·7z는 이름이 유니코드로 저장된다. 오래된 RAR만 코드페이지라 원본 바이트로 판정한다.
        let raws = reader.entries.map { e in
            FilenameDecoder.RawName(bytes: e.rawName, utf8Flag: false, unicodeName: e.utf8Name)
        }
        let detected = FilenameDecoder.detect(raws)
        let enc = override == .automatic ? detected : override
        var pages: [Page] = []
        for (e, raw) in zip(reader.entries, raws) {
            let name = override == .automatic ? FilenameDecoder.decode(raw, using: enc)
                : FilenameDecoder.decode(FilenameDecoder.RawName(bytes: raw.bytes, utf8Flag: false, unicodeName: nil), using: enc)
            guard ImageFiles.isImage(name) else { continue }
            pages.append(Page(id: Hashing.hex(e.rawName, length: 16), name: name, ref: .libarchive(reader, e.index)))
        }
        pages.sort { NaturalSort.less($0.name, $1.name) }
        guard !pages.isEmpty else { throw BookLoaderError.noImages }
        // 표시 순서가 아니라 물리 순서로 풀되, 필요한 이미지만 푼다.
        reader.startExtraction(indices: Set(pages.compactMap { if case .libarchive(_, let i) = $0.ref { return i } else { return nil } }))
        return Book(volume: volume, title: volume.title, fingerprint: fingerprint, seriesKey: seriesKey,
                    pages: pages, detectedEncoding: detected, usedEncoding: enc, recovered: false, hasAmbiguousNames: false)
    }
}
