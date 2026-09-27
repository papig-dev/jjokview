import AppKit
import Combine
import SwiftUI

/// 키 입력의 마지막 수신처. 사이드바에 포커스가 있어도 단축키가 동작하도록 창에서 처리한다.
final class ReaderWindow: NSWindow {
    var reader: ReaderViewController?

    override func keyDown(with event: NSEvent) {
        let combo = KeyCombo(event: event)
        if let action = KeyBindings.shared.action(for: combo), let reader {
            reader.controller.isKeyRepeat = event.isARepeat
            reader.perform(action, combo: combo)
            reader.controller.isKeyRepeat = false
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘ 조합은 메뉴보다 먼저 여기로 온다. 사용자가 건 조합이면 바로 처리해 메뉴와 두 번 실행되지 않게 한다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let combo = KeyCombo(event: event)
        if combo.command, let action = KeyBindings.shared.action(for: combo), let reader, !(firstResponder is NSText) {
            reader.controller.isKeyRepeat = event.isARepeat
            reader.perform(action, combo: combo)
            reader.controller.isKeyRepeat = false
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let controller = ReaderController()
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private(set) var reader: ReaderViewController!
    private var bag = Set<AnyCancellable>()
    private var layoutControl: NSSegmentedControl?
    private var directionControl: NSSegmentedControl?
    private var bookmarkButton: NSButton?
    private var pageField: NSTextField?
    private var sharpenPopup: NSPopUpButton?
    private var autoPlayView: AutoPlayButton?

    static var all: [ReaderWindowController] = []
    /// 지역화된 앱 이름(한국어 "쪽뷰", 영어 "Jjokview"). 책이 없을 때 창 제목.
    static var appName: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Jjokview"
    }

    convenience init() {
        let window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = Self.appName
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 520, height: 400)
        self.init(window: window)
        window.delegate = self
        controller.window = window

        reader = ReaderViewController(controller: controller)
        window.reader = reader
        let sidebarVC = NSHostingController(rootView: BookmarksSidebar(controller: controller))
        sidebarVC.sizingOptions = []   // SwiftUI가 창 크기를 정하지 않게 한다(0×0 창 버그의 원인)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: reader))
        split.splitView.autosaveName = "ReaderSplit"
        window.contentViewController = split
        // contentViewController를 넣으면 창이 내용 크기로 줄어든다. 그 뒤에 크기를 정하고 저장된 크기를 복원한다.
        window.setContentSize(NSSize(width: 1100, height: 800))
        window.setFrameAutosaveName("ReaderWindow")
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1100, height: 800))
        }

        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.syncToolbar() } }
            .store(in: &bag)
        Self.all.append(self)
        DispatchQueue.main.async { [weak self] in self?.syncToolbar() }   // 처음(책 없음) 상태도 맞춘다
    }

    func windowWillClose(_ notification: Notification) {
        controller.savePosition()
        LibraryStore.shared.flush()
        Self.all.removeAll { $0 === self }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { reader.refresh() }
    func windowDidExitFullScreen(_ notification: Notification) { reader.refresh() }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    func showSidebar() {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    // MARK: - 툴바

    private enum Item {
        static let sidebar = NSToolbarItem.Identifier.toggleSidebar
        static let layout = NSToolbarItem.Identifier("layout")
        static let direction = NSToolbarItem.Identifier("direction")
        static let fit = NSToolbarItem.Identifier("fit")
        static let sharpen = NSToolbarItem.Identifier("sharpen")
        static let bookmark = NSToolbarItem.Identifier("bookmark")
        static let page = NSToolbarItem.Identifier("page")
        static let volume = NSToolbarItem.Identifier("volume")
        static let autoPlay = NSToolbarItem.Identifier("autoPlay")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 나누기는 한쪽 보기의 동작이라 툴바 버튼을 두지 않는다(한쪽 보기 버튼과 겹쳐 보임). S 키·보기 메뉴·설정에서 바꾼다.
        [Item.sidebar, .sidebarTrackingSeparator, Item.volume, Item.page, .flexibleSpace,
         Item.layout, Item.direction, Item.fit, Item.sharpen, .space, Item.autoPlay, .space, Item.bookmark]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.layout:
            let seg = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: String(localized: "Single Page"))!,
                NSImage(systemSymbolName: "book", accessibilityDescription: String(localized: "Two Pages"))!,
                NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: String(localized: "Vertical Scroll"))!,
            ], trackingMode: .selectOne, target: self, action: #selector(layoutChanged(_:)))
            seg.setToolTip(String(localized: "Single Page (⌘1) — two-page scans are split into single pages (S to turn off)"), forSegment: 0)
            seg.setToolTip(String(localized: "Two Pages (⌘2)"), forSegment: 1)
            seg.setToolTip(String(localized: "Vertical Scroll for webtoons (⌘3)"), forSegment: 2)
            item.view = seg
            item.label = String(localized: "Layout")
            layoutControl = seg
        case Item.direction:
            // 글자 대신 화살표 아이콘: → 왼쪽에서 오른쪽, ← 오른쪽에서 왼쪽(일본 만화).
            let seg = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "arrow.right", accessibilityDescription: String(localized: "Left→Right"))!,
                NSImage(systemSymbolName: "arrow.left", accessibilityDescription: String(localized: "Right→Left"))!,
            ], trackingMode: .selectOne, target: self, action: #selector(directionChanged(_:)))
            seg.setToolTip(String(localized: "Read left to right"), forSegment: 0)
            seg.setToolTip(String(localized: "Read right to left, like Japanese manga (2 switches)"), forSegment: 1)
            item.view = seg
            item.label = String(localized: "Direction")
            directionControl = seg
        case Item.fit:
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            for (title, mode) in [(String(localized: "Fit to Window"), FitMode.page), (String(localized: "Fit Width"), .width),
                                  (String(localized: "Fit Height"), .height), (String(localized: "Actual Size"), .original)] {
                pop.addItem(withTitle: title)
                pop.lastItem?.representedObject = mode.rawValue
            }
            pop.target = self
            pop.action = #selector(fitChanged(_:))
            pop.toolTip = String(localized: "Zoom: 9 fit to window · 8 fit width · 0 actual size · ⌘+ / ⌘− zoom")
            item.view = pop
            item.label = String(localized: "Zoom")
        case Item.sharpen:
            // 지금 단계가 버튼 글자로 보이게 한다(아이콘만으로는 켜졌는지 알 수 없었다).
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            for level in SharpenLevel.available {
                pop.addItem(withTitle: String(localized: "Sharpen: \(level.title)"))
                pop.lastItem?.representedObject = level.rawValue
                pop.lastItem?.image = NSImage(systemSymbolName: level.symbol, accessibilityDescription: nil)
            }
            pop.menu?.addItem(.separator())
            pop.addItem(withTitle: String(localized: "Adjust Strength…"))
            pop.lastItem?.representedObject = "adjust"
            pop.target = self
            pop.action = #selector(sharpenChanged(_:))
            pop.toolTip = String(localized: "Sharpen blurry scans (E)")
            item.view = pop
            item.label = String(localized: "Sharpen")
            item.visibilityPriority = .low    // 폭이 가장 넓어 좁은 창에서는 먼저 » 안으로
            sharpenPopup = pop
        case Item.autoPlay:
            // 시계 아이콘에 간격 숫자 배지(세로는 속도 아이콘). 누르면 값을 고르는 메뉴.
            let b = AutoPlayButton()
            b.target = self
            b.action = #selector(autoPlayMenu(_:))
            b.toolTip = String(localized: "Auto advance (P) · , slower · . faster — in vertical scroll the page flows continuously")
            item.view = b
            item.label = String(localized: "Auto Advance")
            autoPlayView = b
        case Item.bookmark:
            let b = NSButton(image: NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(bookmarkTapped(_:)))
            b.bezelStyle = .texturedRounded
            b.toolTip = String(localized: "Add or remove a bookmark on this page (B, ⌘D)")
            item.view = b
            item.label = String(localized: "Bookmark")
            item.visibilityPriority = .high   // 창을 좁혀도 북마크는 마지막까지 남긴다
            bookmarkButton = b
        case Item.page:
            let f = NSTextField(labelWithString: "")
            f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            f.textColor = .secondaryLabelColor
            f.toolTip = String(localized: "Current page (⌘L or G to jump)")
            item.view = f
            item.label = String(localized: "Page")
            pageField = f
        case Item.volume:
            let seg = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: KeyAction.previousVolume.title)!,
                NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: KeyAction.nextVolume.title)!,
            ], trackingMode: .momentary, target: self, action: #selector(volumeTapped(_:)))
            seg.setToolTip(String(localized: "Previous volume ([ or ⌘[)"), forSegment: 0)
            seg.setToolTip(String(localized: "Next volume (] or ⌘])"), forSegment: 1)
            item.view = seg
            item.label = String(localized: "Volume")
        default:
            return nil
        }
        return item
    }

    private func syncToolbar() {
        let s = controller.settings
        // 책이 없으면 보기 설정 버튼은 끈다(눌러도 아무 일이 없었다).
        let has = controller.hasBook
        layoutControl?.isEnabled = has
        bookmarkButton?.isEnabled = has
        sharpenPopup?.isEnabled = has
        (window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.fit })?.view as? NSControl)?.isEnabled = has
        (window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.volume })?.view as? NSControl)?.isEnabled = has
        if !has { window?.title = Self.appName }
        layoutControl?.selectedSegment = PageLayout.allCases.firstIndex(of: s.layout) ?? 0
        directionControl?.selectedSegment = s.direction == .leftToRight ? 0 : 1
        directionControl?.isEnabled = has && s.layout != .vertical
        bookmarkButton?.image = NSImage(systemSymbolName: controller.isCurrentBookmarked ? "bookmark.fill" : "bookmark",
                                        accessibilityDescription: nil)
        pageField?.stringValue = controller.pageLabel
        autoPlayView?.update(playing: controller.autoPlaying, vertical: s.layout == .vertical, enabled: controller.hasBook)
        if let pop = sharpenPopup {
            pop.selectItem(at: SharpenLevel.available.firstIndex(of: s.sharpen) ?? 0)
            // 켜져 있으면 아이콘에 강조색을 넣어 한눈에 보이게 한다.
            pop.contentTintColor = s.sharpen == .off ? nil : .controlAccentColor
        }
        if let pop = window?.toolbar?.items.first(where: { $0.itemIdentifier == Item.fit })?.view as? NSPopUpButton {
            pop.selectItem(at: FitMode.allCases.firstIndex(of: s.fit) ?? 0)
        }
        // 부제목: 시리즈 이름 · 몇 번째 권(같은 이름의 권을 구분)
        let series = controller.book?.volume.seriesName ?? ""
        let position = controller.shelf.map { $0.volumes.count > 1 ? "\($0.index + 1) / \($0.volumes.count)" : "" } ?? ""
        let title = controller.book?.title ?? ""
        let showSeries = !series.isEmpty && series != title && !title.hasPrefix(series + " · ")   // "S · 12" 제목이면 S를 또 적지 않는다
        window?.subtitle = [showSeries ? series : "", position].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @objc private func layoutChanged(_ s: NSSegmentedControl) { controller.setLayout(PageLayout.allCases[s.selectedSegment]) }
    @objc private func directionChanged(_ s: NSSegmentedControl) {
        controller.setDirection(s.selectedSegment == 0 ? .leftToRight : .rightToLeft)
    }
    @objc private func fitChanged(_ p: NSPopUpButton) {
        reader.perform([KeyAction.fitPage, .fitWidth, .fitHeight, .fitOriginal][p.indexOfSelectedItem])
    }
    @objc private func sharpenChanged(_ p: NSPopUpButton) {
        let raw = p.selectedItem?.representedObject as? String
        if raw == "adjust" {
            syncToolbar()   // 선택 표시는 지금 단계로 되돌린다
            SettingsTab.shared.selection = "general"
            (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        } else if let raw, let l = SharpenLevel(rawValue: raw) {
            controller.setSharpen(l)
        }
    }
    @objc private func bookmarkTapped(_ b: NSButton) { controller.toggleBookmark() }
    @objc private func autoPlayMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let vertical = controller.settings.layout == .vertical
        let off = menu.addItem(withTitle: String(localized: "Off"), action: #selector(autoPlayChoice(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0
        off.state = controller.autoPlaying ? .off : .on
        menu.addItem(.separator())
        for preset in AutoPlayButton.presets(vertical: vertical) {
            let mi = menu.addItem(withTitle: preset.menuTitle, action: #selector(autoPlayChoice(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = preset.value
            mi.tag = 1
            let current = vertical ? AutoPlayPreferences.speed : AutoPlayPreferences.interval
            mi.state = controller.autoPlaying && abs(current - preset.value) < 0.01 ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func autoPlayChoice(_ item: NSMenuItem) {
        guard item.tag == 1, let value = item.representedObject as? Double else {
            controller.setAutoPlay(false)
            return
        }
        if controller.settings.layout == .vertical { AutoPlayPreferences.speed = value } else { AutoPlayPreferences.interval = value }
        if controller.autoPlaying { reader.restartAutoPlay() } else { controller.setAutoPlay(true) }
        syncToolbar()
    }
    @objc private func volumeTapped(_ s: NSSegmentedControl) {
        s.selectedSegment == 0 ? controller.previousVolume() : controller.nextVolume()
    }

    // MARK: - 메뉴 동작

    @objc func performKeyAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? KeyAction else { return }
        reader.perform(action)
    }

    @objc func openDocument(_ sender: Any?) { reader.showOpenPanel() }

    @objc func setEncoding(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = NameEncoding(rawValue: raw) { controller.setEncoding(e) }
    }

    @objc func allowFolderAccess(_ sender: Any?) {
        guard let book = controller.book else { return }
        controller.askFolderAccess(book.volume.fileURL.deletingLastPathComponent())
    }

    @objc func deleteAllBookmarks(_ sender: Any?) {
        guard controller.hasBook, !controller.bookmarks.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete all bookmarks in this book?")
        alert.informativeText = String(localized: "This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Delete All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.controller.removeAllBookmarks() }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let c = controller
        if item.action == #selector(setEncoding(_:)) {
            let raw = item.representedObject as? String
            let current = c.record?.encoding ?? .automatic
            item.state = raw == current.rawValue ? .on : .off
            return c.hasBook
        }
        if item.action == #selector(deleteAllBookmarks(_:)) { return !c.bookmarks.isEmpty }
        if item.action == #selector(allowFolderAccess(_:)) { return c.hasBook }
        guard let action = item.representedObject as? KeyAction else { return true }
        let s = c.settings
        switch action {
        case .layoutSingle: item.state = s.layout == .single ? .on : .off
        case .layoutDouble: item.state = s.layout == .double ? .on : .off
        case .layoutVertical: item.state = s.layout == .vertical ? .on : .off
        case .toggleSplit: item.state = AppPreferences.splitSpreads ? .on : .off
        case .toggleCover: item.state = s.coverAlone ? .on : .off
        case .fitPage: item.state = s.fit == .page ? .on : .off
        case .fitWidth: item.state = s.fit == .width ? .on : .off
        case .fitHeight: item.state = s.fit == .height ? .on : .off
        case .fitOriginal: item.state = s.fit == .original ? .on : .off
        case .toggleBookmark: item.state = c.isCurrentBookmarked ? .on : .off
        case .doubleRTL: item.state = s.layout == .double && s.direction == .rightToLeft ? .on : .off
        case .doubleLTR: item.state = s.layout == .double && s.direction == .leftToRight ? .on : .off
        case .shiftSpread: item.state = c.shiftOn ? .on : .off
        case .toggleAutoPlay: item.state = c.autoPlaying ? .on : .off
        case .toggleFullScreen:
            let full = window?.styleMask.contains(.fullScreen) == true
            item.title = full ? String(localized: "Exit Full Screen") : String(localized: "Enter Full Screen")
        default: break
        }
        // 메모 입력 중에는 쪽·권 이동 메뉴가 ⌘↑ ⌘[ 같은 편집 키를 가로채지 않게 한다.
        if window?.firstResponder is NSText, [.firstPage, .lastPage, .nextVolume, .previousVolume, .nextBookmark, .previousBookmark].contains(action) {
            return false
        }
        switch action {
        case .toggleSidebar, .toggleFullScreen, .exitFullScreen: return true
        case .shiftSpread: return c.hasBook && s.layout == .double
        case .toggleSplit: return c.hasBook && s.layout == .single
        case .toggleDirection, .doubleLTR, .doubleRTL, .toggleCover: return c.hasBook && s.layout != .vertical
        default: return c.hasBook
        }
    }
}
