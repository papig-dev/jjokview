import AppKit
import Carbon.HIToolbox

/// 키 조합. 문자 대신 물리 키코드로 저장한다. 한글 입력 상태에서 B가 'ㅠ'로 들어와도
/// 같은 키로 인식된다.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ keyCode: Int, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = UInt16(keyCode)
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    init(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(Int(event.keyCode), command: f.contains(.command), shift: f.contains(.shift),
                  option: f.contains(.option), control: f.contains(.control))
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if command { f.insert(.command) }
        if shift { f.insert(.shift) }
        if option { f.insert(.option) }
        if control { f.insert(.control) }
        return f
    }

    /// 메뉴 항목에 붙일 키 문자. 메뉴는 ⌘가 들어간 조합만 담당한다.
    var menuKeyEquivalent: String? {
        guard command else { return nil }
        return KeyNames.menuCharacter(keyCode)
    }

    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + KeyNames.display(keyCode)
    }
}

enum KeyNames {
    private static let named: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Escape: "Esc",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Tab: "⇥",
        kVK_PageUp: "PgUp", kVK_PageDown: "PgDn", kVK_Home: "Home", kVK_End: "End",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// 입력 소스와 무관하게 ASCII 배열(US) 기준 문자로 표시한다.
    static func display(_ code: UInt16) -> String {
        if let n = named[Int(code)] { return n }
        return asciiCharacter(code)?.uppercased() ?? "#\(code)"
    }

    static func menuCharacter(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case kVK_Home: return String(UnicodeScalar(NSHomeFunctionKey)!)
        case kVK_End: return String(UnicodeScalar(NSEndFunctionKey)!)
        case kVK_PageUp: return String(UnicodeScalar(NSPageUpFunctionKey)!)
        case kVK_PageDown: return String(UnicodeScalar(NSPageDownFunctionKey)!)
        case kVK_Return: return "\r"
        case kVK_Space: return " "
        default: return asciiCharacter(code)
        }
    }

    private static let ascii: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Grave: "`",
        kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9",
        kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadMinus: "−", kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadDivide: "/",
    ]

    static func asciiCharacter(_ code: UInt16) -> String? { ascii[Int(code)] }
}

/// 사용자가 단축키를 걸 수 있는 동작 전체.
enum KeyAction: String, CaseIterable, Codable, Identifiable {
    case nextPage, previousPage, firstPage, lastPage
    case forward10, back10
    case nextVolume, previousVolume
    case shiftSpread
    case layoutSingle, layoutDouble, layoutVertical, cycleLayout
    case doubleLTR, doubleRTL, toggleDirection
    case toggleSplit, toggleCover
    case fitPage, fitWidth, fitHeight, fitOriginal
    case zoomIn, zoomOut
    case toggleFullScreen, exitFullScreen
    case toggleBookmark, showBookmarks, nextBookmark, previousBookmark
    case toggleSidebar, goToPage
    case cycleSharpen
    case toggleAutoPlay, autoSlower, autoFaster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextPage: return String(localized: "Next Page")
        case .previousPage: return String(localized: "Previous Page")
        case .firstPage: return String(localized: "First Page")
        case .lastPage: return String(localized: "Last Page")
        case .forward10: return String(localized: "Forward 10 Pages")
        case .back10: return String(localized: "Back 10 Pages")
        case .nextVolume: return String(localized: "Next Volume")
        case .previousVolume: return String(localized: "Previous Volume")
        case .shiftSpread: return String(localized: "Shift Spread by One Page")
        case .layoutSingle: return String(localized: "Single Page")
        case .layoutDouble: return String(localized: "Two Pages")
        case .layoutVertical: return String(localized: "Vertical Scroll")
        case .cycleLayout: return String(localized: "Switch Layout")
        case .doubleLTR: return String(localized: "Two Pages, Left to Right")
        case .doubleRTL: return String(localized: "Two Pages, Right to Left")
        case .toggleDirection: return String(localized: "Switch Reading Direction")
        case .toggleSplit: return String(localized: "Split Two-Page Scans")
        case .toggleCover: return String(localized: "Show Cover Alone")
        case .fitPage: return String(localized: "Fit to Window")
        case .fitWidth: return String(localized: "Fit Width")
        case .fitHeight: return String(localized: "Fit Height")
        case .fitOriginal: return String(localized: "Actual Size")
        case .zoomIn: return String(localized: "Zoom In")
        case .zoomOut: return String(localized: "Zoom Out")
        case .toggleFullScreen: return String(localized: "Enter Full Screen")
        case .exitFullScreen: return String(localized: "Exit Full Screen")
        case .toggleBookmark: return String(localized: "Add or Remove Bookmark")
        case .showBookmarks: return String(localized: "Show Bookmarks")
        case .nextBookmark: return String(localized: "Next Bookmark")
        case .previousBookmark: return String(localized: "Previous Bookmark")
        case .toggleSidebar: return String(localized: "Show or Hide Sidebar")
        case .goToPage: return String(localized: "Go to Page…")
        case .cycleSharpen: return String(localized: "Change Sharpening")
        case .toggleAutoPlay: return String(localized: "Start or Stop Auto Advance")
        case .autoSlower: return String(localized: "Auto Advance Slower")
        case .autoFaster: return String(localized: "Auto Advance Faster")
        }
    }

    /// 기본값: 꿀뷰(Honeyview) 체계 + 맥 표준(⌘ 조합). 첫 번째 ⌘ 조합이 메뉴에 표시된다.
    var defaults: [KeyCombo] {
        switch self {
        case .nextPage: return [KeyCombo(kVK_Space), KeyCombo(kVK_PageDown), KeyCombo(kVK_DownArrow), KeyCombo(kVK_RightArrow)]
        case .previousPage: return [KeyCombo(kVK_Space, shift: true), KeyCombo(kVK_PageUp), KeyCombo(kVK_UpArrow),
                                    KeyCombo(kVK_LeftArrow), KeyCombo(kVK_Delete)]
        case .firstPage: return [KeyCombo(kVK_UpArrow, command: true), KeyCombo(kVK_Home)]
        case .lastPage: return [KeyCombo(kVK_DownArrow, command: true), KeyCombo(kVK_End)]
        case .forward10: return [KeyCombo(kVK_PageDown, control: true)]
        case .back10: return [KeyCombo(kVK_PageUp, control: true)]
        case .nextVolume: return [KeyCombo(kVK_ANSI_RightBracket, command: true), KeyCombo(kVK_ANSI_RightBracket)]
        case .previousVolume: return [KeyCombo(kVK_ANSI_LeftBracket, command: true), KeyCombo(kVK_ANSI_LeftBracket)]
        case .shiftSpread: return [KeyCombo(kVK_PageDown, shift: true), KeyCombo(kVK_RightArrow, option: true)]
        case .layoutSingle: return [KeyCombo(kVK_ANSI_1, command: true)]
        case .layoutDouble: return [KeyCombo(kVK_ANSI_2, command: true)]
        case .layoutVertical: return [KeyCombo(kVK_ANSI_3, command: true)]
        case .cycleLayout: return []
        case .doubleLTR: return [KeyCombo(kVK_ANSI_7)]
        case .doubleRTL: return [KeyCombo(kVK_ANSI_6)]
        case .toggleDirection: return [KeyCombo(kVK_ANSI_R, command: true, option: true), KeyCombo(kVK_ANSI_2)]
        case .toggleSplit: return [KeyCombo(kVK_ANSI_S)]
        case .toggleCover: return [KeyCombo(kVK_ANSI_S, shift: true)]
        case .fitPage: return [KeyCombo(kVK_ANSI_9), KeyCombo(kVK_ANSI_1)]
        case .fitWidth: return [KeyCombo(kVK_ANSI_8)]
        case .fitHeight: return []
        case .fitOriginal: return [KeyCombo(kVK_ANSI_0, command: true), KeyCombo(kVK_ANSI_0)]
        case .zoomIn: return [KeyCombo(kVK_ANSI_Equal, command: true), KeyCombo(kVK_ANSI_KeypadPlus)]
        case .zoomOut: return [KeyCombo(kVK_ANSI_Minus, command: true), KeyCombo(kVK_ANSI_KeypadMinus)]
        case .toggleFullScreen: return [KeyCombo(kVK_ANSI_F, command: true, control: true), KeyCombo(kVK_Return), KeyCombo(kVK_ANSI_F)]
        case .exitFullScreen: return [KeyCombo(kVK_Escape)]
        case .toggleBookmark: return [KeyCombo(kVK_ANSI_D, command: true), KeyCombo(kVK_ANSI_B)]
        case .showBookmarks: return [KeyCombo(kVK_ANSI_B, command: true, option: true), KeyCombo(kVK_F3)]
        case .nextBookmark: return [KeyCombo(kVK_ANSI_RightBracket, command: true, shift: true)]
        case .previousBookmark: return [KeyCombo(kVK_ANSI_LeftBracket, command: true, shift: true)]
        case .toggleSidebar: return [KeyCombo(kVK_ANSI_S, command: true, control: true)]
        case .goToPage: return [KeyCombo(kVK_ANSI_L, command: true), KeyCombo(kVK_ANSI_G)]
        case .cycleSharpen: return [KeyCombo(kVK_ANSI_E)]
        case .toggleAutoPlay: return [KeyCombo(kVK_ANSI_P, command: true, option: true), KeyCombo(kVK_ANSI_P)]
        case .autoSlower: return [KeyCombo(kVK_ANSI_Comma)]
        case .autoFaster: return [KeyCombo(kVK_ANSI_Period)]
        }
    }
}

/// 단축키 저장소. 바뀌면 메뉴가 다시 그려진다.
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()
    static let didChange = Notification.Name("KeyBindingsDidChange")

    @Published private(set) var map: [KeyAction: [KeyCombo]] = [:]
    private let defaultsKey = "keyBindings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: [KeyCombo]].self, from: data) {
            for a in KeyAction.allCases { map[a] = saved[a.rawValue] ?? a.defaults }
        } else {
            for a in KeyAction.allCases { map[a] = a.defaults }
        }
    }

    func combos(_ action: KeyAction) -> [KeyCombo] { map[action] ?? [] }

    func action(for combo: KeyCombo) -> KeyAction? {
        KeyAction.allCases.first { combos($0).contains(combo) }
    }

    /// 다른 동작에 이미 걸린 조합이면 그 동작을 돌려준다(충돌 안내용).
    func conflict(for combo: KeyCombo, except action: KeyAction) -> KeyAction? {
        KeyAction.allCases.first { $0 != action && combos($0).contains(combo) }
    }

    func add(_ combo: KeyCombo, to action: KeyAction) {
        for a in KeyAction.allCases { map[a]?.removeAll { $0 == combo } }
        map[action, default: []].append(combo)
        save()
    }

    func remove(_ combo: KeyCombo, from action: KeyAction) {
        map[action]?.removeAll { $0 == combo }
        save()
    }

    func resetOne(_ action: KeyAction) {
        let defaults = action.defaults
        for a in KeyAction.allCases where a != action { map[a]?.removeAll { defaults.contains($0) } }
        map[action] = defaults
        save()
    }

    func resetAll() {
        for a in KeyAction.allCases { map[a] = a.defaults }
        save()
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
