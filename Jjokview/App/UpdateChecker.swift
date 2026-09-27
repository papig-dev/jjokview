import AppKit

/// 새 버전 알림(DMG판 전용). github.com/…/releases/latest 가 최신 릴리스 태그(…/releases/tag/v0.2.0)로
/// 이동하는 주소만 읽는다(API와 달리 요청 횟수 제한이 없다). 새 버전이 있으면 다운로드 페이지를 열어 준다.
/// 보내는 것은 HEAD 요청 하나와 "Jjokview/<버전>" User-Agent뿐이다. App Store판은 스토어가 업데이트하므로 쓰지 않는다.
final class UpdateChecker {
    static let shared = UpdateChecker()

    static var latestURL: URL {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["JJOKVIEW_UPDATE_URL"], let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://github.com/papig-dev/jjokview/releases/latest")!
    }
    static let releasesPage = URL(string: "https://github.com/papig-dev/jjokview/releases")!
    static let autoKey = "update.auto"
    private let lastCheckKey = "update.lastCheck"
    private let skipKey = "update.skipVersion"
    private var checking = false

    /// App Store에서 받은 앱이면 번들 안에 영수증(_MASReceipt)이 있다.
    var isEnabled: Bool {
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        return !FileManager.default.fileExists(atPath: receipt.path)
    }

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// 앱을 켤 때: 하루 한 번만, 조용히(실패해도 알리지 않는다).
    func checkAtLaunch() {
        guard isEnabled, Self.autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    /// 메뉴의 "업데이트 확인…": 결과를 항상 알려 준다.
    @objc func checkNow(_ sender: Any?) { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard isEnabled, !checking else {
            if checking, userInitiated { NSSound.beep() }
            return
        }
        checking = true
        var req = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        req.setValue("Jjokview/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let http = response as? HTTPURLResponse
            let ok = http.map { (200..<400).contains($0.statusCode) } ?? false
            let release = ok ? http?.url.flatMap(Self.release(from:)) : nil
            DispatchQueue.main.async {
                self.checking = false
                if ok { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey) }
                self.present(release, failed: !ok, userInitiated: userInitiated)
            }
        }.resume()
    }

    struct Release: Equatable { var version: String; var page: URL }

    /// 이동한 최종 주소 …/releases/tag/v1.2.3 에서 버전을 읽는다. 릴리스가 없으면 …/releases 로 가서 nil.
    static func release(from url: URL) -> Release? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "tag"), i + 1 < parts.count else { return nil }
        var tag = parts[i + 1]
        if tag.first == "v" || tag.first == "V" { tag.removeFirst() }
        guard tag.first?.isNumber == true else { return nil }
        return Release(version: tag, page: url)
    }

    /// "0.10.0" > "0.9.1"처럼 숫자 단위로 비교한다.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func present(_ release: Release?, failed: Bool, userInitiated: Bool) {
        #if DEBUG
        ImagePipeline.debugLog("update: latest=\(release?.version ?? "-") failed=\(failed) current=\(currentVersion)")
        #endif
        let alert = NSAlert()
        if let release, Self.isNewer(release.version, than: currentVersion) {
            if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == release.version { return }
            alert.messageText = String(localized: "Jjokview \(release.version) is available")
            alert.informativeText = String(localized: "You have \(currentVersion).")
            alert.addButton(withTitle: String(localized: "Open Download Page"))
            alert.addButton(withTitle: String(localized: "Later"))
            alert.addButton(withTitle: String(localized: "Skip This Version"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(release.page)
            case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: skipKey)
            default: break
            }
            return
        }
        guard userInitiated else { return }
        if failed {
            alert.messageText = String(localized: "Couldn’t check for updates")
            alert.informativeText = String(localized: "Check your internet connection and try again.")
        } else {
            alert.messageText = String(localized: "Jjokview is up to date")
            alert.informativeText = String(localized: "Version \(currentVersion) is the latest version.")
        }
        alert.runModal()
    }
}
