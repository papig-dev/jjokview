import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 읽기 영역. 한쪽·두쪽 화면과 세로 화면을 바꿔 끼우고, 알림과 시작 화면을 위에 얹는다.
final class ReaderViewController: NSViewController {
    let controller: ReaderController
    private let spread = SpreadScrollView(frame: .zero)
    private let strip = StripScrollView(frame: .zero)
    private var overlay: PassthroughHostingView<ReaderOverlay>!
    let pageBarModel = PageBarModel()
    private(set) var pageBarView: NSView?
    private var bag = Set<AnyCancellable>()
    private var lastLayout: PageLayout?
    private var lastBook: String?
    private var pageTimer: Timer?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init(controller: ReaderController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = KeyCatcherView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.registerForDraggedTypes([.fileURL])
        root.onDrop = { [weak self] url in self?.open(url) }
        view = root
        for v in [spread, strip] as [NSScrollView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        spread.controller = controller
        strip.controller = controller
        overlay = PassthroughHostingView(rootView: ReaderOverlay(controller: controller, open: { [weak self] in self?.showOpenPanel() },
                                                         openRecent: { [weak self] r in self?.openRecord(r) }))
        overlay.sizingOptions = []
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        overlay.passThrough = { [weak self] in self?.controller.hasBook ?? false }

        // 쪽 막대(아래 가운데). 숨어 있을 때는 클릭이 아래 읽기 화면으로 그대로 간다.
        let bar = PassthroughHostingView(rootView: PageBar(controller: controller, model: pageBarModel))
        bar.sizingOptions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).withPriority(.defaultHigh),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 210),
        ])
        pageBarView = bar
        bar.passThrough = { [weak self] in
            guard let m = self?.pageBarModel else { return true }
            return !(m.visible || m.dragging)
        }
        // 끄는 중(썸네일 미리보기)이 아니면 아래 막대 부분(약 64pt)만 클릭을 받는다.
        bar.passThroughAt = { [weak self] p in
            guard let m = self?.pageBarModel, !m.dragging else { return false }
            return p.y > 64
        }
        root.onMouseMoved = { [weak self] p in
            guard let self, self.controller.hasBook, self.controller.pageCount > 1 else { return }
            if p.y < 80 { self.pageBarModel.show() }   // 아래쪽 80pt에 마우스가 오면 쪽 막대
        }
        controller.focusReader = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.view)
        }
        controller.clickTurn = { [weak self] forward in self?.perform(forward ? .nextPage : .previousPage) }
        controller.onDisplayChange = { [weak self] in self?.refresh() }
        // @Published는 값이 바뀌기 직전에 알린다. 바뀐 뒤에 처리하도록 다음 차례로 미룬다.
        controller.$autoPlaying.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { self?.updateAutoPlay(on) }
        }.store(in: &bag)
        controller.$settings.map(\.layout).removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, self.controller.autoPlaying else { return }
            DispatchQueue.main.async { self.updateAutoPlay(true) }   // 보기 방식이 바뀌면 방식에 맞는 자동 넘기기로
        }.store(in: &bag)
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    /// 화면 전환과 다시 그리기.
    func refresh() {
        let vertical = controller.settings.layout == .vertical
        spread.isHidden = vertical || !controller.hasBook
        strip.isHidden = !vertical || !controller.hasBook
        let bookChanged = lastBook != controller.book?.fingerprint
        let layoutChanged = lastLayout != controller.settings.layout
        lastBook = controller.book?.fingerprint
        lastLayout = controller.settings.layout
        if vertical {
            if bookChanged || layoutChanged { strip.magnification = 1 }
            strip.rebuild(keepAnchor: true)
        } else {
            if bookChanged { spread.magnification = 1 }
            spread.reload(resetScroll: true)
        }
    }

    // MARK: - 자동 넘기기

    #if DEBUG
    var debugState: String {
        "scrollY=\(Int(strip.contentView.bounds.minY)) link=\(displayLink != nil) ticks=\(debugTicks) auto=\(controller.autoPlaying)"
    }
    private var debugTicks = 0
    #endif

    private func updateAutoPlay(_ on: Bool) {
        pageTimer?.invalidate(); pageTimer = nil
        displayLink?.invalidate(); displayLink = nil
        guard on else { return }
        if controller.settings.layout == .vertical {
            // 화면 주사율에 맞춰 조금씩 흘린다.
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            lastTick = 0
            displayLink = link
        } else {
            restartPageTimer()
        }
    }

    /// 값(간격·속도)을 바꾼 뒤 다시 시작.
    func restartAutoPlay() { updateAutoPlay(controller.autoPlaying) }

    /// 손으로 쪽을 넘기면 간격을 처음부터 다시 센다.
    private func restartPageTimer() {
        pageTimer?.invalidate()
        guard controller.autoPlaying, controller.settings.layout != .vertical else { return }
        let t = Timer(timeInterval: AutoPlayPreferences.interval, repeats: true) { [weak self] _ in
            guard !MouseTracking.dragging else { return }   // 끄는 도중에 쪽이 바뀌지 않게
            self?.controller.autoStep()
        }
        RunLoop.main.add(t, forMode: .common)
        pageTimer = t
    }

    @objc private func tick(_ link: CADisplayLink) {
        #if DEBUG
        debugTicks += 1
        #endif
        let now = link.timestamp
        defer { lastTick = now }
        guard lastTick > 0, controller.hasBook, !controller.loading, !MouseTracking.dragging else { return }   // 손으로 끄는 동안은 멈춤
        let dt = min(now - lastTick, 0.1)
        if !strip.autoScroll(by: CGFloat(AutoPlayPreferences.speed * dt)) {
            controller.autoAdvanceVolume()
        }
    }

    // MARK: - 열기

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // 파일이든 폴더든 "열기" 하나로 연다
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = String(localized: "Choose a comic archive (ZIP, CBZ, RAR, CBR, 7Z) or a folder of images.")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func open(_ url: URL) {
        controller.open(url)
    }

    func openRecord(_ r: BookRecord) {
        guard let data = r.location, let (url, refreshed) = AccessBroker.shared.resolve(data) else {
            controller.showToast(String(localized: "The file could not be found. It may have been moved or deleted."))
            return
        }
        if let refreshed { LibraryStore.shared.update(r.fingerprint) { $0.location = refreshed } }
        // 바깥 zip 안의 권이면 그 권을 연다. 접근은 창이 다른 책을 열 때 끝낸다.
        controller.open(url, bookmarkData: refreshed ?? data, accessURL: url, volumePath: r.volumePath)
    }

    // MARK: - 동작

    func perform(_ action: KeyAction, combo: KeyCombo? = nil) {
        #if DEBUG
        DebugDriver.log("perform \(action.rawValue) key=\(combo.map { String($0.keyCode) } ?? "-") auto=\(controller.autoPlaying)")
        #endif
        // 자동 넘기기 중에는 스페이스·Esc가 넘기기/전체 화면 종료 대신 멈춤(타이머 끄기)이다. P는 켜기/끄기.
        if controller.autoPlaying, let combo, [UInt16(kVK_Space), UInt16(kVK_Escape)].contains(combo.keyCode),
           !combo.command, !combo.option, !combo.control {
            controller.setAutoPlay(false)
            return
        }
        performAction(action, combo: combo)
        // 자동 넘기기 중에 손으로 쪽을 넘기면 간격을 처음부터 다시 센다.
        if [.nextPage, .previousPage, .firstPage, .lastPage, .forward10, .back10].contains(action) { restartPageTimer() }
    }

    private func performAction(_ action: KeyAction, combo: KeyCombo?) {
        let c = controller
        let vertical = c.settings.layout == .vertical
        var action = action
        // 오른쪽→왼쪽 책에서 ←/→ 화살표는 읽기 방향을 따른다(설정으로 끌 수 있음).
        if let combo, !combo.command, !combo.option, c.settings.direction == .rightToLeft, !vertical,
           UserDefaults.standard.object(forKey: "arrowsFollowDirection") as? Bool ?? true {
            if combo.keyCode == UInt16(kVK_LeftArrow), action == .previousPage { action = .nextPage }
            else if combo.keyCode == UInt16(kVK_RightArrow), action == .nextPage { action = .previousPage }
        }
        switch action {
        case .nextPage:
            if vertical {
                let isLine = combo.map { $0.keyCode == UInt16(kVK_DownArrow) } ?? false
                if !(isLine ? strip.lineDown() : strip.pageDown()) { c.reachedEnd() }
            } else if c.settings.fit != .page, Self.scrollsFirst(combo), spread.pageDownOrNext() {
            } else { c.next() }
        case .previousPage:
            if vertical {
                let isLine = combo.map { $0.keyCode == UInt16(kVK_UpArrow) } ?? false
                if !(isLine ? strip.lineUp() : strip.pageUp()) { c.reachedStartVertical() }
            } else if c.settings.fit != .page, Self.scrollsFirst(combo), spread.pageUpOrPrevious() {
            } else { c.previous() }
        case .firstPage: c.first()
        case .lastPage: c.last()
        case .forward10: c.jump(10)
        case .back10: c.jump(-10)
        case .nextVolume: c.nextVolume()
        case .previousVolume: c.previousVolume()
        case .shiftSpread: c.toggleShift()
        case .layoutSingle: c.setLayout(.single)
        case .layoutDouble: c.setLayout(.double)
        case .layoutVertical: c.setLayout(.vertical)
        case .cycleLayout: c.cycleLayout()
        case .doubleLTR: c.setDouble(.leftToRight)
        case .doubleRTL: c.setDouble(.rightToLeft)
        case .toggleDirection: c.toggleDirection()
        case .toggleSplit: c.toggleSplit()
        case .toggleCover: c.toggleCover()
        case .fitPage: resetZoom(); c.setFit(.page)
        case .fitWidth: resetZoom(); c.setFit(.width)
        case .fitHeight: resetZoom(); c.setFit(.height)
        case .fitOriginal: resetZoom(); c.setFit(.original)
        case .zoomIn: vertical ? strip.zoom(by: 1.25) : spread.zoom(by: 1.25)
        case .zoomOut: vertical ? strip.zoom(by: 0.8) : spread.zoom(by: 0.8)
        case .toggleFullScreen: view.window?.toggleFullScreen(nil)
        case .exitFullScreen:
            if view.window?.styleMask.contains(.fullScreen) == true { view.window?.toggleFullScreen(nil) }
        case .toggleBookmark: c.toggleBookmark()
        case .showBookmarks: (view.window?.windowController as? ReaderWindowController)?.showSidebar()
        case .nextBookmark: c.stepBookmark(true)
        case .previousBookmark: c.stepBookmark(false)
        case .toggleSidebar: (view.window?.windowController as? ReaderWindowController)?.toggleSidebar(nil)
        case .goToPage: askPage()
        case .cycleSharpen: c.cycleSharpen()
        case .toggleAutoPlay: c.setAutoPlay(!c.autoPlaying)
        case .autoSlower:
            c.adjustAutoSpeed(faster: false)
            restartPageTimer()
        case .autoFaster:
            c.adjustAutoSpeed(faster: true)
            restartPageTimer()
        }
    }

    /// 좌우 화살표가 아닌 넘김 키(Space, PgUp/PgDn, ↑↓, 메뉴)는 쪽이 화면보다 크면 먼저 스크롤한다.
    private static func scrollsFirst(_ combo: KeyCombo?) -> Bool {
        guard let combo else { return false }
        return ![UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow)].contains(combo.keyCode)
    }

    private func resetZoom() {
        spread.magnification = 1
        strip.magnification = 1
    }

    private func askPage() {
        guard controller.hasBook, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Page")
        alert.informativeText = String(localized: "Enter a page number (1–\(controller.pageCount)).")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(controller.currentPage + 1)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn, let n = Int(field.stringValue) { self?.controller.goToPage(n - 1) }
        }
    }
}

/// 읽기 영역 맨 아래 뷰. 첫 응답자가 되어 키 입력을 창(ReaderWindow)으로 넘기고, 파일 끌어다 놓기를 받는다.
final class KeyCatcherView: NSView {
    var onDrop: ((URL) -> Void)?
    /// 마우스 위치(이 뷰 좌표, 아래가 0). 쪽 막대를 띄우는 데 쓴다.
    var onMouseMoved: ((NSPoint) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

/// 책이 열려 있으면 마우스 입력을 아래 읽기 화면으로 넘긴다(토스트는 보이기만 한다).
extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var passThrough: () -> Bool = { false }
    /// 이 위치(자기 좌표, 아래가 0)는 아래 뷰로 넘길지. 투명한 빈 곳이 읽기 화면 클릭을 가로채지 않게.
    var passThroughAt: ((NSPoint) -> Bool)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        if passThrough() { return nil }
        if let f = passThroughAt, let sv = superview, f(convert(point, from: sv)) { return nil }
        return super.hitTest(point)
    }
}

/// 알림 토스트, 불러오는 중 표시, 책이 없을 때의 시작 화면.
struct ReaderOverlay: View {
    @ObservedObject var controller: ReaderController
    @ObservedObject var store = LibraryStore.shared
    var open: () -> Void
    var openRecent: (BookRecord) -> Void

    var body: some View {
        ZStack {
            if !controller.hasBook && !controller.loading {
                WelcomeView(open: open, openRecent: openRecent)
            }
            if controller.loading {
                ProgressView().controlSize(.large).colorScheme(.dark)
            }
            VStack {
                Spacer()
                if let t = controller.toast {
                    Text(t)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .padding(.bottom, 24)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.toast)
            .allowsHitTesting(false)
        }
    }
}
