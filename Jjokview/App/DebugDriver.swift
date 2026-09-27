#if DEBUG
import AppKit

/// 개발용 자동 조작. 환경변수 JJOKVIEW_SCRIPT="wait:2;snap:one;do:layoutDouble;wait:1;snap:two" 처럼
/// 동작을 차례로 실행하고, 창 화면을 PNG로 저장한다(화면 녹화 권한 없이 검증하기 위함).
/// 저장 위치는 샌드박스 컨테이너의 tmp/snapshots.
enum DebugDriver {
    static func runIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["JJOKVIEW_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map { $0.split(separator: ":", maxSplits: 1).map(String.init) }
        run(steps[...])
    }

    private static func run(_ steps: ArraySlice<[String]>) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let arg = step.count > 1 ? step[1] : ""
        var delay = 0.3
        let wc = ReaderWindowController.all.first
        switch step[0] {
        case "wait": delay = Double(arg) ?? 1
        case "snap": snapshot(wc?.window, name: arg)
        case "do": if let a = KeyAction(rawValue: arg) { wc?.reader.perform(a) }
        case "page": wc?.controller.goToPage((Int(arg) ?? 1) - 1)
        case "sidebar": wc?.showSidebar()
        case "size":
            let p = arg.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { wc?.window?.setContentSize(NSSize(width: p[0], height: p[1])) }
        case "click", "rclick":   // click:0.25,0.5 = 읽기 영역에서 가로·세로 비율 위치(위에서부터)를 한 번 누른다
            let f = arg.split(separator: ",").compactMap { Double($0) }
            if f.count == 2, let w = wc?.window, let v = wc?.reader.view {
                let r = v.convert(v.bounds, to: nil)
                let p = NSPoint(x: r.minX + r.width * f[0], y: r.maxY - r.height * f[1])
                let right = step[0] == "rclick"
                let make = { (t: NSEvent.EventType) in
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let hit = w.contentView?.superview?.hitTest(p) ?? w.contentView?.hitTest(p)
                ImagePipeline.debugLog(String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + "click \(arg) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                NSApp.postEvent(make(right ? .rightMouseUp : .leftMouseUp), atStart: false)
                w.sendEvent(make(right ? .rightMouseDown : .leftMouseDown))
            }
        case "menu":   // 오른쪽 클릭 메뉴 항목과 체크·사용 가능 상태 기록
            if let wc, let menu = wc.controller.contextMenu?() {
                func dump(_ m: NSMenu, _ indent: String) -> [String] {
                    m.items.flatMap { i -> [String] in
                        if i.isSeparatorItem { return [indent + "---"] }
                        let ok = wc.validateMenuItem(i)
                        return [indent + i.title + (i.state == .on ? " ✓" : "") + (ok ? "" : " (off)")] + (i.submenu.map { dump($0, indent + "  ") } ?? [])
                    }
                }
                ImagePipeline.debugLog("menu:\n" + dump(menu, "  ").joined(separator: "\n"))
            }
        case "pagebar":   // 쪽 막대 띄우기(드래그 중 미리보기는 pagebar:drag)
            wc?.reader.pageBarModel.show()
            if arg == "drag" { wc?.reader.pageBarModel.dragging = true }
        case "snapbar", "snapsidebar":   // 쪽 막대 / 사이드바(SwiftUI)만 이미지로
            let target = step[0] == "snapbar" ? wc?.reader.pageBarView : (wc?.window?.contentViewController as? NSSplitViewController)?.splitViewItems.first?.viewController.view
            if let v = target, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(arg.isEmpty ? "bar" : arg).png"))
            }
        case "quit": NSApp.terminate(nil)
        default: NSLog("DebugDriver: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest) }
    }

    /// 창 전체를 CoreAnimation처럼 직접 합성한다. 시스템 캡처 API는 화면 녹화 권한이 필요하고,
    /// layer.render·cacheDisplay는 최신 macOS에서 GPU 합성 레이어를 비워서 돌려주기 때문이다.
    /// 배경색과 이미지 contents(쪽 레이어)만 그린다. 툴바·SwiftUI 글자는 나오지 않는다.
    static func log(_ line: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("keys.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    static func snapshot(_ window: NSWindow?, name: String) {
        guard let root = window?.contentView?.layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = root.bounds.size
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.magenta.cgColor)   // 아무것도 안 그려진 곳은 자홍색으로 드러난다
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        func draw(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0.01 else { return }
            var r = layer.convert(layer.bounds, to: root)
            if !root.isGeometryFlipped && !(window?.contentView?.isFlipped ?? false) { } else { r.origin.y = size.height - r.maxY }
            if let masks = layer.superlayer, masks.masksToBounds {
                let clip = masks.convert(masks.bounds, to: root)
                ctx.saveGState(); ctx.clip(to: clip)
            }
            if let bg = layer.backgroundColor { ctx.setFillColor(bg); ctx.fill(r) }
            if let obj = layer.contents, CFGetTypeID(obj as CFTypeRef) == CGImage.typeID {
                let img = obj as! CGImage
                let cr = layer.contentsRect
                let crop = CGRect(x: cr.minX * CGFloat(img.width), y: cr.minY * CGFloat(img.height),
                                  width: cr.width * CGFloat(img.width), height: cr.height * CGFloat(img.height)).integral
                if let part = img.cropping(to: crop) { ctx.draw(part, in: r) }
            }
            if let masks = layer.superlayer, masks.masksToBounds { ctx.restoreGState() }
            layer.sublayers?.forEach(draw)
        }
        draw(root)
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        if let c = ReaderWindowController.all.first?.controller {
            ImagePipeline.debugLog(String(format: "%.3f snap %@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000), name))
            let state = "\(name): title=\(c.book?.title ?? "-") page=\(c.pageLabel) view=\(c.currentView.map { "\($0.page + 1)\($0.half == .full ? "" : $0.half == .left ? "L" : "R")" }) layout=\(c.settings.layout.rawValue) dir=\(c.settings.direction.rawValue) split=\(AppPreferences.splitSpreads) fit=\(c.settings.fit.rawValue) sharpen=\(c.settings.sharpen.rawValue) toast=\(c.toast ?? "-") bookmarks=\(c.bookmarks.map { $0.anchor.pageIndex + 1 }) volume=\((c.shelf?.index ?? 0) + 1)/\(c.shelf?.volumes.count ?? 0) pending=\(c.pendingVolume?.displayName ?? "-") finished=\(c.record?.finished ?? false) bm=\(c.isCurrentBookmarked) \(ReaderWindowController.all.first?.reader.debugState ?? "")\n"
            let log = dir.appendingPathComponent("state.txt")
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(state.utf8)); try? h.close() }
            else { try? Data(state.utf8).write(to: log) }
        }
    }
}
#endif
