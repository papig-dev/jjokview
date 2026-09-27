import AppKit

/// 읽기 화면 클릭 동작(앱 전체 설정).
enum ClickMode: String, CaseIterable {
    /// 화면 좌우(세로 보기는 위아래)를 눌러 넘긴다. 오른쪽→왼쪽 책은 왼쪽이 다음.
    case sides
    /// 꿀뷰식: 어디를 누르든 왼쪽 버튼은 다음, 오른쪽 버튼은 이전.
    case buttons
    case off

    static let key = "mouse.clickMode"
    static var current: ClickMode {
        ClickMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sides
    }
}

/// 끌기 중인지(메인 스레드 전용). 자동 넘기기 타이머·디스플레이 링크가 끄는 동안 멈추는 데 쓴다.
enum MouseTracking {
    static var dragging = false
}

extension NSEvent {
    /// ⌃클릭은 원버튼 마우스·트랙패드의 오른쪽 클릭이다.
    var isSecondaryClick: Bool { type == .rightMouseDown || modifierFlags.contains(.control) }
}

extension NSScrollView {
    /// 누른 채 끌면 내용을 손으로 옮기듯 스크롤하고 true를 돌려준다. 그냥 떼면(클릭) false.
    func trackDragPan(from event: NSEvent) -> Bool {
        guard let window else { return false }
        let start = event.locationInWindow
        let origin = contentView.bounds.origin
        var dragged = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let dx = e.locationInWindow.x - start.x, dy = e.locationInWindow.y - start.y
            if !dragged {
                guard hypot(dx, dy) > 4 else { continue }   // 손떨림은 클릭으로 본다
                dragged = true
                MouseTracking.dragging = true
                NSCursor.closedHand.push()
            }
            let m = magnification
            let o = NSPoint(x: origin.x - dx / m, y: contentView.isFlipped ? origin.y + dy / m : origin.y - dy / m)
            let r = contentView.constrainBoundsRect(NSRect(origin: o, size: contentView.bounds.size))
            contentView.setBoundsOrigin(r.origin)
            reflectScrolledClipView(contentView)
        }
        if dragged { NSCursor.pop(); MouseTracking.dragging = false }
        return dragged
    }

    /// 누른 곳이 보이는 영역의 왼쪽 절반인지 / 위쪽 절반인지. 툴바 밑으로 깔린 부분(contentInsets)은 뺀다.
    func clickSide(_ event: NSEvent) -> (left: Bool, top: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let visibleTop = contentInsets.top, visibleBottom = bounds.height - contentInsets.bottom
        let yFromTop = isFlipped ? p.y : bounds.height - p.y
        return (p.x < bounds.width / 2, yFromTop < (visibleTop + visibleBottom) / 2)
    }
}
