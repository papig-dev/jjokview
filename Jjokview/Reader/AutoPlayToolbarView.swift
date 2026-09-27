import AppKit

/// 툴바의 자동 넘기기 버튼. 다른 툴바 아이콘과 같은 크기의 아이콘 하나로 상태를 보여준다.
/// - 쪽 보기: 시계 아이콘 오른쪽 아래에 간격 숫자 배지(2 / 5 / 10). 꺼져 있으면 숫자 없는 시계.
/// - 세로 보기: 속도 아이콘(거북이 / 속도계 / 토끼).
final class AutoPlayButton: NSButton {
    struct Preset { let value: Double; let menuTitle: String; let symbol: String? }

    /// 쪽 보기는 간격(초), 세로 보기는 흐르는 속도(초당 포인트).
    static func presets(vertical: Bool) -> [Preset] {
        if vertical {
            return [Preset(value: 40, menuTitle: String(localized: "Flow slowly"), symbol: "tortoise.fill"),
                    Preset(value: 70, menuTitle: String(localized: "Flow at normal speed"), symbol: "gauge.with.dots.needle.50percent"),
                    Preset(value: 140, menuTitle: String(localized: "Flow quickly"), symbol: "hare.fill")]
        }
        return [2.0, 5, 10].map { Preset(value: $0, menuTitle: String(localized: "Every \(Int($0)) seconds"), symbol: nil) }
    }

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .texturedRounded
        imagePosition = .imageOnly
        update(playing: false, vertical: false, enabled: false)
    }

    func update(playing: Bool, vertical: Bool, enabled: Bool) {
        isEnabled = enabled
        contentTintColor = playing ? .controlAccentColor : nil
        let value = vertical ? AutoPlayPreferences.speed : AutoPlayPreferences.interval
        if playing && vertical {
            // 가장 가까운 속도의 아이콘
            let p = Self.presets(vertical: true).min { abs($0.value - value) < abs($1.value - value) }!
            image = NSImage(systemSymbolName: p.symbol!, accessibilityDescription: p.menuTitle)
        } else if playing {
            image = Self.timer(badge: "\(Int(value))")
        } else {
            image = NSImage(systemSymbolName: "timer", accessibilityDescription: String(localized: "Auto Advance"))
        }
    }

    /// 시계 아이콘 + 오른쪽 아래 숫자 배지. 템플릿 이미지라 툴바 색(강조색)을 그대로 따른다.
    static func timer(badge: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let clock = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let size = NSSize(width: clock.size.width + 7, height: clock.size.height + 3)
        let img = NSImage(size: size, flipped: false) { rect in
            clock.draw(at: NSPoint(x: 0, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
            let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.black])
            let ts = text.size()
            let pill = NSRect(x: rect.maxX - ts.width - 4, y: 0, width: ts.width + 4, height: ts.height)
            // 배지 뒤를 비워 시계 선과 겹치지 않게 한다.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: pill.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: NSPoint(x: pill.minX + 2, y: pill.minY))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = String(localized: "Auto advance every \(badge) seconds")
        return img
    }
}
