import AppKit

/// 세로 스크롤(웹툰). 웹툰 다운로드는 폭 690px·높이 1600px 조각이 회차당 50~100장이라
/// 이어 붙이면 12만 px가 넘는다(실측). 조각을 간격 없이 붙이고, 높이를 화면 픽셀 단위로
/// 반올림해 조각 사이에 1px 틈이 생기지 않게 하며, 보이는 범위의 조각만 불러온다.
final class StripScrollView: NSScrollView {
    weak var controller: ReaderController?
    private let doc = FlippedView()
    private var frames: [CGRect] = []
    private var layers: [Int: CALayer] = [:]
    private var columnWidth: CGFloat = 0
    private var reportWork: DispatchWorkItem?
    private var lastReport = Date.distantPast
    private var suppressReport = false
    private var lastLayoutWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = doc
        doc.wantsLayer = true
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.5
        maxMagnification = 4
        backgroundColor = .black
        scrollerStyle = .overlay
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            rebuild(keepAnchor: true)
        }
    }

    /// 배치를 다시 계산하고 컨트롤러의 위치로 스크롤한다.
    func rebuild(keepAnchor: Bool) {
        guard let c = controller, let book = c.book else {
            layers.values.forEach { $0.removeFromSuperlayer() }
            layers = [:]; frames = []
            return
        }
        let backing = window?.backingScaleFactor ?? 2
        let viewportW = contentView.bounds.width * magnification
        let sizes = book.pages.indices.map { c.pipeline.knownSize(book: book, page: $0) }
        let fallback = sizes.compactMap { $0 }.first ?? CGSize(width: 690, height: 1600)
        let naturalW = sizes.compactMap { $0?.width }.max() ?? fallback.width
        switch c.settings.fit {
        case .width: columnWidth = viewportW
        case .original: columnWidth = naturalW / backing
        case .page, .height: columnWidth = min(viewportW, max(naturalW / backing * 1.5, 480))
        }
        columnWidth = max(columnWidth.rounded(), 100)
        var y: CGFloat = 0
        frames = sizes.map { s in
            let s = s ?? fallback
            // 화면 픽셀 단위로 반올림해 인접 조각의 경계가 정확히 맞닿게 한다.
            let h = ((columnWidth * s.height / s.width) * backing).rounded() / backing
            defer { y += h }
            return CGRect(x: 0, y: y, width: columnWidth, height: h)
        }
        suppressReport = true
        doc.frame = NSRect(x: 0, y: 0, width: columnWidth, height: max(y, 1))
        layers.values.forEach { $0.removeFromSuperlayer() }
        layers = [:]
        if keepAnchor { scrollToAnchor() }
        suppressReport = false
        updateVisible()
    }

    func scrollToAnchor() {
        guard let c = controller, !frames.isEmpty else { return }
        let a = c.verticalAnchor
        let i = min(max(a.page, 0), frames.count - 1)
        let y = frames[i].minY + frames[i].height * CGFloat(a.offset)
        suppressReport = true
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(y, max(doc.frame.height - contentView.bounds.height, 0))))
        reflectScrolledClipView(contentView)
        suppressReport = false
        updateVisible()
    }

    @objc private func boundsChanged() {
        updateVisible()
        guard !suppressReport else { return }
        // 계속 스크롤하는 동안(자동 스크롤 포함)에도 0.3초마다는 위치를 알린다. 디바운스만 쓰면
        // 스크롤이 멈출 때까지 보고가 미뤄져 쪽 번호·저장 위치가 제자리에 머문다.
        reportWork?.cancel()
        if Date().timeIntervalSince(lastReport) > 0.3 {
            reportPosition()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.reportPosition() }
        reportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reportPosition() {
        lastReport = Date()
        guard let c = controller, !frames.isEmpty else { return }
        let top = contentView.bounds.minY
        let i = frames.firstIndex { $0.maxY > top } ?? frames.count - 1
        let offset = frames[i].height > 0 ? Double((top - frames[i].minY) / frames[i].height) : 0
        c.updateVertical(page: i, offset: max(0, min(offset, 1)))
    }

    /// 보이는 범위 위아래로 한 화면씩 여유를 두고 조각 레이어를 만든다. 벗어난 레이어는 지운다.
    private func updateVisible() {
        guard let c = controller, let book = c.book, !frames.isEmpty else { return }
        let visible = contentView.bounds
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        let lo = frames.firstIndex { $0.maxY >= band.minY } ?? 0
        let hi = frames.lastIndex { $0.minY <= band.maxY } ?? lo
        let backing = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in layers where i < lo || i > hi {
            l.removeFromSuperlayer(); layers[i] = nil
        }
        for i in lo...hi {
            let f = frames[i]
            let layer = layers[i] ?? {
                let l = CALayer()
                l.contentsGravity = .resize
                l.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                doc.layer?.addSublayer(l)
                layers[i] = l
                return l
            }()
            layer.frame = f
            if layer.contents == nil {
                let maxPixel = Int(max(f.width, f.height) * backing * max(magnification, 1))
                let key = ImagePipeline.Key(book: book.cacheKey, page: i, maxPixel: ImagePipeline.bucket(maxPixel), sharpen: c.settings.sharpen)
                // 늦게 끝난 이전 설정(선명도·강도·크기)의 결과가 새 레이어에 들어가지 않게 원하는 키를 적어 둔다.
                let want = "\(key.book)#\(key.page)@\(key.maxPixel)/\(key.sharpen.rawValue)\(key.strength)"
                layer.setValue(want, forKey: "want")
                if let img = c.pipeline.cached(key) {
                    layer.contents = img
                    layer.backgroundColor = nil
                } else {
                    let onScreen = f.intersects(visible)
                    let sharpen = c.settings.sharpen
                    let show: (CGImage, Bool) -> Void = { [weak self] img, final in
                        guard let self, self.controller?.book === book, let l = self.layers[i],
                              l.value(forKey: "want") as? String == want,
                              final || l.value(forKey: "done") as? String != want else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        l.contents = img
                        l.backgroundColor = nil
                        if final { l.setValue(want, forKey: "done") }
                        CATransaction.commit()
                    }
                    // 보정(특히 AI)은 오래 걸린다. 그동안 빈 타일 대신 보정 없는 이미지를 먼저 보여준다.
                    if sharpen != .off, onScreen {
                        let plain = ImagePipeline.Key(book: key.book, page: i, maxPixel: key.maxPixel, sharpen: .off)
                        if let img = c.pipeline.cached(plain) { show(img, false) } else {
                            c.pipeline.request(book, page: i, maxPixel: maxPixel, sharpen: .off, priority: .veryHigh) { img in
                                if let img { show(img, false) }
                            }
                        }
                    }
                    c.pipeline.request(book, page: i, maxPixel: maxPixel, sharpen: sharpen,
                                       priority: onScreen ? .veryHigh : .normal) { img in
                        if let img { show(img, true) }
                    }
                }
            }
        }
        CATransaction.commit()
    }

    // MARK: - 자동 스크롤(흐르는 시간)

    /// 사용자가 휠로 움직이면 잠깐 멈춘다.
    private(set) var userScrolledAt = Date.distantPast
    private var autoScrollRemainder: CGFloat = 0

    /// dy만큼 아래로 흘린다. 맨 아래면 false.
    func autoScroll(by dy: CGFloat) -> Bool {
        guard Date().timeIntervalSince(userScrolledAt) > 1.5 else { return true }
        let clip = contentView.bounds
        let maxY = max(doc.frame.height - clip.height, 0)
        if clip.minY >= maxY - 0.5 { return false }
        // 화면 픽셀 단위로 모아서 옮긴다(소수점 이동으로 글자가 번지지 않게).
        let backing = window?.backingScaleFactor ?? 2
        autoScrollRemainder += dy
        let step = (autoScrollRemainder * backing).rounded(.down) / backing
        guard step > 0 else { return true }
        autoScrollRemainder -= step
        contentView.setBoundsOrigin(NSPoint(x: clip.minX, y: min(clip.minY + step, maxY)))
        reflectScrolledClipView(contentView)
        return true
    }

    // MARK: - 키보드 스크롤

    /// 한 화면(90%)만큼 아래로. 이미 맨 아래면 false(다음 권 안내로 넘어간다).
    func pageDown() -> Bool { scroll(by: contentView.bounds.height * 0.9) }
    func pageUp() -> Bool { scroll(by: -contentView.bounds.height * 0.9) }
    func lineDown() -> Bool { scroll(by: 80) }
    func lineUp() -> Bool { scroll(by: -80) }

    private func scroll(by dy: CGFloat) -> Bool {
        let clip = contentView.bounds
        let maxY = max(doc.frame.height - clip.height, 0)
        let target = min(max(clip.minY + dy, 0), maxY)
        if abs(target - clip.minY) < 1 { return false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            contentView.animator().setBoundsOrigin(NSPoint(x: clip.minX, y: target))
        }
        reflectScrolledClipView(contentView)
        return true
    }

    func zoom(by factor: CGFloat) {
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification),
                         centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }

    func resetZoom() {
        magnification = 1
        rebuild(keepAnchor: true)
    }

    /// 클릭: 한 화면씩 아래(위)로(키보드 Page Down/Up과 같은 경로). 끌기: 손으로 옮기듯 스크롤.
    override func mouseDown(with event: NSEvent) {
        controller?.focusReader?()
        guard let c = controller, c.hasBook else { super.mouseDown(with: event); return }
        if event.isSecondaryClick { rightMouseDown(with: event); return }
        userScrolledAt = Date()   // 끄는 동안 자동 스크롤이 위치를 덮어쓰지 않게
        if trackDragPan(from: event) { userScrolledAt = Date(); return }
        switch ClickMode.current {
        case .off: return
        case .buttons: c.clickTurn?(true)
        case .sides: c.clickTurn?(!clickSide(event).top)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard ClickMode.current == .buttons, let c = controller, c.hasBook else { super.rightMouseDown(with: event); return }
        c.clickTurn?(false)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1)
            return
        }
        userScrolledAt = Date()
        let clip = contentView.bounds
        let atBottom = clip.maxY >= doc.frame.height - 1
        let discrete = !event.hasPreciseScrollingDeltas
        super.scrollWheel(with: event)
        // 마우스 휠(단계식)은 phase가 비어 있다. 맨 아래에서 한 칸 더 내리면 다음 회차 안내.
        if discrete {
            if atBottom && event.scrollingDeltaY < 0 { controller?.reachedEnd() }
        } else if event.phase == .ended || (event.phase == [] && event.momentumPhase == .ended) {
            if atBottom && event.scrollingDeltaY <= 0 { controller?.reachedEnd() }
        }
    }
}
