import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private var openedAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 보기 메뉴에 앱의 "전체 화면" 항목이 있으므로 시스템이 자동으로 넣는 항목은 끈다(두 개로 보였다).
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        buildMenu()
        NotificationCenter.default.addObserver(forName: KeyBindings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.buildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessBroker.shared.restoreFolderGrants(LibraryStore.shared.folderGrants)
        DispatchQueue.global(qos: .utility).async { LibArchiveReader.pruneCache() }
        if !openedAtLaunch { newWindow().showWindow(nil) }
        // 창이 뜬 뒤에 조용히 확인한다(하루 한 번).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { UpdateChecker.shared.checkAtLaunch() }
        #if DEBUG
        DebugDriver.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow().showWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReaderWindowController.all.forEach { $0.controller.savePosition() }
        LibraryStore.shared.flush()
    }

    /// Finder "다음으로 열기", Dock에 끌어다 놓기, `open -a Jjokview 경로` 모두 여기로 온다.
    /// 이 경로로 받은 URL은 샌드박스 접근 권한이 함께 붙어 온다.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls { open(url) }
    }

    func open(_ url: URL) {
        // 빈 창이 있으면 그 창에서, 아니면 새 창에서 연다.
        let target = ReaderWindowController.all.first { !$0.controller.hasBook && !$0.controller.loading } ?? newWindow()
        target.showWindow(nil)
        target.controller.open(url)
    }

    @discardableResult
    func newWindow() -> ReaderWindowController {
        let wc = ReaderWindowController()
        wc.window?.center()
        return wc
    }

    @objc func newWindowAction(_ sender: Any?) { newWindow().showWindow(nil) }

    @objc func openDocument(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? ReaderWindowController {
            wc.openDocument(sender)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @objc func showShortcuts(_ sender: Any?) {
        SettingsTab.shared.selection = "shortcuts"
        showSettings(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 메뉴

    private func item(_ action: KeyAction) -> NSMenuItem {
        let mi = NSMenuItem(title: action.title, action: #selector(ReaderWindowController.performKeyAction(_:)), keyEquivalent: "")
        mi.representedObject = action
        // 메뉴에는 ⌘가 들어간 첫 조합을 표시하고, 나머지 단축키는 제목 옆에 적는다.
        let combos = KeyBindings.shared.combos(action)
        if let cmd = combos.first(where: { $0.command }), let ch = cmd.menuKeyEquivalent {
            mi.keyEquivalent = ch
            mi.keyEquivalentModifierMask = cmd.modifierFlags
        }
        let plain = combos.filter { !$0.command }.prefix(2).map(\.displayString)
        if !plain.isEmpty {
            mi.title = "\(action.title)    \(plain.joined(separator: " "))"
        }
        return mi
    }

    private func buildMenu() {
        let main = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Jjokview"

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: String(localized: "About \(appName)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if UpdateChecker.shared.isEnabled {
            let up = appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(UpdateChecker.checkNow(_:)), keyEquivalent: "")
            up.target = UpdateChecker.shared
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addTop(appMenu, to: main)

        let file = NSMenu(title: String(localized: "File"))
        file.addItem(withTitle: String(localized: "New Window"), action: #selector(newWindowAction(_:)), keyEquivalent: "n")
        file.addItem(withTitle: String(localized: "Open…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: String(localized: "Open Recent"))
        recentMenu.delegate = self
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Allow Folder Access…"), action: #selector(ReaderWindowController.allowFolderAccess(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addTop(file, to: main)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addTop(edit, to: main)

        let view = NSMenu(title: String(localized: "View"))
        [.layoutSingle, .layoutDouble, .layoutVertical].forEach { view.addItem(item($0)) }
        view.addItem(.separator())
        [.doubleRTL, .doubleLTR, .toggleDirection, .toggleSplit, .toggleCover, .shiftSpread].forEach { view.addItem(item($0)) }
        view.addItem(.separator())
        [.fitPage, .fitWidth, .fitHeight, .fitOriginal, .zoomIn, .zoomOut].forEach { view.addItem(item($0)) }
        view.addItem(.separator())
        view.addItem(item(.cycleSharpen))
        let enc = NSMenuItem(title: String(localized: "Filename Encoding"), action: nil, keyEquivalent: "")
        let encMenu = NSMenu()
        for e in NameEncoding.allCases {
            let mi = NSMenuItem(title: e.title, action: #selector(ReaderWindowController.setEncoding(_:)), keyEquivalent: "")
            mi.representedObject = e.rawValue
            encMenu.addItem(mi)
            if e == .automatic { encMenu.addItem(.separator()) }
        }
        enc.submenu = encMenu
        view.addItem(enc)
        view.addItem(.separator())
        view.addItem(item(.toggleSidebar))
        view.addItem(item(.toggleFullScreen))
        addTop(view, to: main)

        let go = NSMenu(title: String(localized: "Go"))
        [.nextPage, .previousPage, .firstPage, .lastPage, .forward10, .back10].forEach { go.addItem(item($0)) }
        go.addItem(.separator())
        [.nextVolume, .previousVolume].forEach { go.addItem(item($0)) }
        go.addItem(.separator())
        go.addItem(item(.goToPage))
        go.addItem(.separator())
        [.toggleAutoPlay, .autoSlower, .autoFaster].forEach { go.addItem(item($0)) }
        addTop(go, to: main)

        let bm = NSMenu(title: String(localized: "Bookmarks"))
        [.toggleBookmark, .showBookmarks, .nextBookmark, .previousBookmark].forEach { bm.addItem(item($0)) }
        bm.addItem(.separator())
        bm.addItem(withTitle: String(localized: "Delete All Bookmarks in This Book…"), action: #selector(ReaderWindowController.deleteAllBookmarks(_:)), keyEquivalent: "")
        addTop(bm, to: main)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        addTop(window, to: main)

        let help = NSMenu(title: String(localized: "Help"))
        let keys = help.addItem(withTitle: String(localized: "Keyboard Shortcuts…"), action: #selector(showShortcuts(_:)), keyEquivalent: "/")
        keys.target = self
        NSApp.helpMenu = help
        addTop(help, to: main)

        NSApp.mainMenu = main
    }

    private func addTop(_ menu: NSMenu, to main: NSMenu) {
        let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        top.submenu = menu
        main.addItem(top)
    }

    /// 최근 항목: 보안 범위 북마크로 다시 연다(샌드박스).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = LibraryStore.shared.recent.prefix(15)
        if recent.isEmpty {
            menu.addItem(withTitle: String(localized: "No Recent Books"), action: nil, keyEquivalent: "")
            return
        }
        for r in recent {
            // 같은 이름의 권을 구분하도록 시리즈 이름을 괄호로 붙인다: "시리즈01 (시리즈)"
            let series = r.seriesName.map { $0 == r.displayTitle ? "" : " (\($0))" } ?? ""
            let mi = NSMenuItem(title: r.displayTitle + series, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            mi.representedObject = r.fingerprint
            mi.target = self
            menu.addItem(mi)
        }
    }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        guard let fp = sender.representedObject as? String, let r = LibraryStore.shared.books[fp] else { return }
        let target = ReaderWindowController.all.first { !$0.controller.hasBook } ?? newWindow()
        target.showWindow(nil)
        target.reader.openRecord(r)
    }
}
