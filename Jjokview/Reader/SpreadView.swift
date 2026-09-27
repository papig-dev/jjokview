import AppKit

/// 확대했을 때 문서가 창보다 작으면 가운데에 놓는다.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if doc.frame.height < r.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }

    // NSClipView는 클릭을 스크롤 뷰로 넘기지 않는다. 쪽 넘김·끌기는 스크롤 뷰가 처리하므로 넘겨준다.
    override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) ?? super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { enclosingScrollView?.rightMouseDown(with: event) ?? super.rightMouseDown(with: event) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 한쪽·두쪽 보기. 문서 뷰 안에 쪽마다 CALayer를 두고, 확대는 NSScrollView 배율로 한다.
final class SpreadScrollView: NSScrollView {
    weak var controller: ReaderController?
    private let doc = FlippedView()
    private var partLayers: [CALayer] = []
    private var wheelAccum: CGFloat = 0
    private var wheelFired = false
    private var gestureStartedAtEdge = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = doc
        doc.wantsLayer = true
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 8
        drawsBackground = true
        backgroundColor = .black
        scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        reload(resetScroll: false)
    }

    /// 창 크기를 끄는 동안에는 보정 없이 그리고(크기마다 보정 요청이 쌓이지 않게), 다 끈 뒤 한 번 보정한다.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reload(resetScroll: false)
    }

    /// 현재 화면을 다시 배치한다.
    func reload(resetScroll: Bool) {
        guard let controller, let book = controller.book else {
            partLayers.forEach { $0.removeFromSuperlayer() }
            partLayers = []
            return
        }
        let view = SpreadLayout.visualOrder(controller.currentView, direction: controller.settings.direction)
        let plan = plan(for: view)
        controller.pipeline.deprioritizeAll()   // 이전 화면·이전 크기 요청은 뒤로 미룬다
        let docSize = plan.docSize
        doc.frame = NSRect(origin: .zero, size: docSize)

        while partLayers.count < view.count {
            let l = CALayer()
            l.contentsGravity = .resize
            l.magnificationFilter = .trilinear
            l.minificationFilter = .trilinear
            doc.layer?.addSublayer(l)
            partLayers.append(l)
        }
        while partLayers.count > view.count { partLayers.removeLast().removeFromSuperlayer() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, part) in view.enumerated() {
            let frame = plan.frames[i]
            let layer = partLayers[i]
            layer.frame = frame
            layer.contentsRect = part.half == .left ? CGRect(x: 0, y: 0, width: 0.5, height: 1)
                : part.half == .right ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
            let maxPixel = plan.maxPixels[i]
            // 창 크기를 끄는 동안에는 지금 이미지를 늘려 보여주기만 한다(크기마다 디코딩·보정이 쌓이지 않게).
            if inLiveResize, layer.contents != nil, layer.value(forKey: "page") as? String == "\(book.cacheKey)#\(part.page)" { continue }
            let sharpen = inLiveResize ? .off : controller.settings.sharpen
            let key = ImagePipeline.Key(book: book.cacheKey, page: part.page, maxPixel: ImagePipeline.bucket(maxPixel),
                                        sharpen: sharpen)
            let want = "\(key.book)#\(key.page)@\(key.maxPixel)/\(sharpen.rawValue)\(key.strength)"
            layer.setValue(want, forKey: "want")
            if let img = controller.pipeline.cached(key) {
                layer.contents = img
                layer.setValue(want, forKey: "done")
            } else if layer.value(forKey: "done") as? String != want {
                // 다른 책이나 다른 쪽의 이미지가 남아 보이지 않게 비운다.
                if layer.value(forKey: "page") as? String != "\(book.cacheKey)#\(part.page)" { layer.contents = nil }
                // 보정(특히 AI)은 오래 걸린다. 그동안 보정 없는 이미지를 먼저 보여주고, 끝나면 바꿔 넣는다.
                if sharpen != .off {
                    let plainKey = ImagePipeline.Key(book: key.book, page: key.page, maxPixel: key.maxPixel, sharpen: .off)
                    let showPlain: (CGImage) -> Void = { [weak layer] img in
                        guard let layer, layer.value(forKey: "want") as? String == want,
                              layer.value(forKey: "done") as? String != want else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        layer.contents = img
                        CATransaction.commit()
                    }
                    if let img = controller.pipeline.cached(plainKey) {
                        showPlain(img)
                    } else {
                        controller.pipeline.request(book, page: part.page, maxPixel: maxPixel, sharpen: .off, priority: .veryHigh) { img in
                            if let img { showPlain(img) }
                        }
                    }
                }
                controller.pipeline.request(book, page: part.page, maxPixel: maxPixel, sharpen: sharpen,
                                            priority: .veryHigh) { [weak self, weak layer] img in
                    // 늦게 끝난 디코딩이 이미 바뀐 책·쪽에 들어가지 않게 한다.
                    guard let self, let layer, let img, self.controller?.book === book,
                          layer.value(forKey: "want") as? String == want,
                          self.controller?.currentView.contains(part) == true else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    layer.contents = img
                    layer.setValue(want, forKey: "done")
                    CATransaction.commit()
                }
            }
            layer.setValue("\(book.cacheKey)#\(part.page)", forKey: "page")
        }
        CATransaction.commit()
        if resetScroll { scrollToStart() } else { recenter() }
        prefetch()
    }

    /// 읽기 시작 위치로 스크롤(오른쪽→왼쪽이면 오른쪽 위).
    private func scrollToStart() {
        let rtl = controller?.settings.direction == .rightToLeft
        let clip = contentView.bounds
        let x = rtl ? max(doc.frame.width - clip.width, 0) : 0
        // scroll(to:)는 가운데 정렬 보정을 거치지 않는다. 보정된 위치로 직접 옮긴다.
        let target = contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: x, y: 0), size: clip.size))
        contentView.setBoundsOrigin(target.origin)
        reflectScrolledClipView(contentView)
    }

    /// 창 크기가 바뀌어 문서가 창보다 작아졌을 때 다시 가운데로.
    private func recenter() {
        let clip = contentView.bounds
        let target = contentView.constrainBoundsRect(clip)
        if target.origin != clip.origin { contentView.setBoundsOrigin(target.origin); reflectScrolledClipView(contentView) }
    }

    private struct Plan { var docSize: CGSize; var frames: [CGRect]; var maxPixels: [Int] }

    /// 한 화면(펼침면)의 배치와 쪽마다 디코딩할 크기. 화면 표시와 미리 읽기가 같은 값을 써야 캐시가 맞는다.
    private func plan(for view: [PagePart]) -> Plan {
        guard let controller, let book = controller.book else { return Plan(docSize: .zero, frames: [], maxPixels: []) }
        let viewport = contentView.bounds.size.applying(CGAffineTransform(scaleX: magnification, y: magnification))
        let viewSize = CGSize(width: max(viewport.width, 1), height: max(viewport.height, 1))
        // 각 부분을 높이 1000 기준 폭으로 바꿔 나란히 놓는다.
        let sizes: [CGSize] = view.map { part in
            var s = controller.pipeline.knownSize(book: book, page: part.page) ?? CGSize(width: 700, height: 1000)
            if part.half != .full { s.width /= 2 }
            return s
        }
        let units = sizes.map { CGSize(width: $0.width / $0.height * 1000, height: 1000) }
        let totalW = units.reduce(0) { $0 + $1.width }
        let maxPxH = sizes.map(\.height).max() ?? 1000
        let backing = window?.backingScaleFactor ?? 2
        let scale: CGFloat
        switch controller.settings.fit {
        case .page: scale = min(viewSize.width / totalW, viewSize.height / 1000)
        case .width: scale = viewSize.width / totalW
        case .height: scale = viewSize.height / 1000
        case .original: scale = maxPxH / 1000 / backing
        }
        let docSize = CGSize(width: (totalW * scale).rounded(), height: (1000 * scale).rounded())
        var frames: [CGRect] = [], pixels: [Int] = []
        var x: CGFloat = 0
        for (i, part) in view.enumerated() {
            let w = (units[i].width * scale).rounded()
            let frame = CGRect(x: x, y: 0, width: w, height: docSize.height)
            x += w
            frames.append(frame)
            let fullW = part.half == .full ? frame.width : frame.width * 2
            pixels.append(Int(max(fullW, frame.height) * backing * max(magnification, 1)))
        }
        return Plan(docSize: docSize, frames: frames, maxPixels: pixels)
    }

    private func prefetch() {
        guard let c = controller, let book = c.book, !inLiveResize else { return }
        for dv in [1, 2, -1] {
            let v = c.viewIndex + dv
            guard c.layout.views.indices.contains(v) else { continue }
            let parts = SpreadLayout.visualOrder(c.layout.views[v], direction: c.settings.direction)
            let plan = plan(for: parts)
            for (i, part) in parts.enumerated() {
                c.pipeline.request(book, page: part.page, maxPixel: plan.maxPixels[i], sharpen: c.settings.sharpen,
                                   priority: dv == 1 ? .high : .low)
            }
        }
    }

    // MARK: - 확대

    func zoom(by factor: CGFloat) {
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: center)
    }

    func resetZoom() {
        magnification = 1
        reload(resetScroll: true)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase == .ended { reload(resetScroll: false) }
    }

    /// 클릭: 설정에 따라 쪽 넘김. 끌기: 확대했거나 창보다 큰 쪽을 손으로 옮긴다.
    /// 두 번 클릭 확대는 없다(첫 클릭에 이미 넘어간다). 확대는 핀치·⌘+·⌘휠. 빠른 연타도 누를 때마다 넘긴다.
    override func mouseDown(with event: NSEvent) {
        controller?.focusReader?()
        guard let c = controller, c.hasBook else { super.mouseDown(with: event); return }
        if event.isSecondaryClick { rightMouseDown(with: event); return }
        if trackDragPan(from: event) { return }
        switch ClickMode.current {
        case .off: return
        case .buttons: c.clickTurn?(true)
        case .sides:
            let rtl = c.settings.direction == .rightToLeft
            c.clickTurn?(clickSide(event).left == rtl)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard ClickMode.current == .buttons, let c = controller, c.hasBook else { super.rightMouseDown(with: event); return }
        c.clickTurn?(false)
    }

    // MARK: - 휠·트랙패드 넘김

    /// 내용이 창에 다 들어오면 스크롤을 쪽 넘김으로 쓴다. 넘치면 먼저 스크롤하고,
    /// 가장자리에 닿은 상태에서 새로 시작한 제스처만 넘긴다(확대 중 실수로 넘어가는 것 방지).
    override func scrollWheel(with event: NSEvent) {
        guard let c = controller, c.hasBook else { super.scrollWheel(with: event); return }
        if event.modifierFlags.contains(.command) {
            zoom(by: event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1)
            return
        }
        let clip = contentView.bounds
        let fitsV = doc.frame.height <= clip.height + 1
        let fitsH = doc.frame.width <= clip.width + 1
        let atBottom = clip.maxY >= doc.frame.height - 1
        let atTop = clip.minY <= 1

        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            if event.phase == .began { wheelAccum = 0; wheelFired = false }
            gestureStartedAtEdge = fitsV || (event.scrollingDeltaY < 0 && atBottom) || (event.scrollingDeltaY > 0 && atTop)
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if !(fitsV && (fitsH || !horizontal)) && !gestureStartedAtEdge {
            super.scrollWheel(with: event)
            return
        }
        if event.momentumPhase != [] { return }
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        let discrete = !event.hasPreciseScrollingDeltas
        if discrete {
            // 마우스 휠 한 칸 = 한 화면
            if delta < 0 { c.next() } else if delta > 0 { c.previous() }
            return
        }
        guard !wheelFired else { return }
        wheelAccum += delta
        if abs(wheelAccum) > 40 {
            wheelFired = true
            let forward: Bool
            if horizontal {
                // 오른쪽→왼쪽 책은 오른쪽으로 쓸면 다음 쪽
                forward = c.settings.direction == .rightToLeft ? wheelAccum > 0 : wheelAccum < 0
            } else {
                forward = wheelAccum < 0
            }
            forward ? c.next() : c.previous()
        }
        if event.phase == .ended || event.phase == .cancelled { wheelAccum = 0; wheelFired = false }
    }

    /// 화면보다 큰 쪽(폭 맞춤 등)에서 Space는 먼저 아래로 스크롤하고, 끝에 닿으면 넘긴다.
    func pageDownOrNext() -> Bool {
        let clip = contentView.bounds
        if clip.maxY < doc.frame.height - 1 {
            contentView.animator().setBoundsOrigin(NSPoint(x: clip.minX, y: min(clip.minY + clip.height * 0.9, doc.frame.height - clip.height)))
            return true
        }
        return false
    }

    func pageUpOrPrevious() -> Bool {
        let clip = contentView.bounds
        if clip.minY > 1 {
            contentView.animator().setBoundsOrigin(NSPoint(x: clip.minX, y: max(clip.minY - clip.height * 0.9, 0)))
            return true
        }
        return false
    }
}
