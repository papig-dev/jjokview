import AppKit

/// 샌드박스 파일 접근 관리. 사용자가 연 파일·폴더의 보안 범위 북마크를 만들고,
/// 앱을 다시 켠 뒤 그 북마크로 접근 권한을 되살린다.
final class AccessBroker {
    static let shared = AccessBroker()

    /// 지금 접근 중인 URL. start/stop 짝을 맞춘다(안 맞추면 커널 자원이 샌다).
    private var active: [URL: Int] = [:]
    private var grantedFolders: [URL] = []

    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 북마크를 풀어 접근을 시작한다. 파일이 옮겨졌으면(stale) 새 북마크도 돌려준다.
    func resolve(_ data: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        begin(url)
        return (url, stale ? bookmark(for: url) : nil)
    }

    func begin(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            active[url, default: 0] += 1
        }
    }

    func end(_ url: URL) {
        guard let n = active[url] else { return }
        url.stopAccessingSecurityScopedResource()
        active[url] = n > 1 ? n - 1 : nil
    }

    /// 저장된 폴더 권한을 앱 시작 때 모두 되살린다(앱이 켜져 있는 동안 유지).
    func restoreFolderGrants(_ grants: [Data]) {
        for g in grants {
            if let (url, _) = resolve(g) { grantedFolders.append(url) }
        }
    }

    func canRead(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// 형제 권(다음 권)을 열려면 부모 폴더 권한이 필요하다. 폴더를 미리 골라 둔 열기 창을 띄운다.
    func requestFolderAccess(_ folder: URL, window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Allow Access")
        panel.message = String(localized: "Allow access to this folder to move between volumes with [ and ].")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { completion(nil); return }
            if let data = self.bookmark(for: url) { LibraryStore.shared.addFolderGrant(data) }
            self.grantedFolders.append(url)
            completion(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }
}
