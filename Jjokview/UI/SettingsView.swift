import AppKit
import Carbon.HIToolbox
import SwiftUI

final class SettingsTab: ObservableObject {
    static let shared = SettingsTab()
    @Published var selection = "general"
}

struct SettingsView: View {
    @ObservedObject var tab = SettingsTab.shared

    var body: some View {
        TabView(selection: $tab.selection) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
            AboutLicenses()
                .tabItem { Label("Licenses", systemImage: "doc.text") }.tag("licenses")
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettings: View {
    @ObservedObject var store = LibraryStore.shared
    @AppStorage("arrowsFollowDirection") private var arrowsFollowDirection = true
    @AppStorage(ClickMode.key) private var clickMode = ClickMode.sides.rawValue
    @AppStorage(AppPreferences.splitSpreadsKey) private var splitSpreads = true
    @AppStorage(UpdateChecker.autoKey) private var autoUpdate = true

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: binding(\.layout)) {
                    Text("Single Page").tag(PageLayout.single)
                    Text("Two Pages").tag(PageLayout.double)
                    Text("Vertical Scroll").tag(PageLayout.vertical)
                }
                Picker("Reading direction", selection: binding(\.direction)) {
                    Text("Right to Left (manga)").tag(ReadingDirection.rightToLeft)
                    Text("Left to Right").tag(ReadingDirection.leftToRight)
                }
                Toggle("Show the cover alone in two-page view", isOn: binding(\.coverAlone))
                Picker("Sharpen", selection: binding(\.sharpen)) {
                    ForEach(SharpenLevel.available, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Defaults for new books")
            } footer: {
                Text("Each series remembers its own layout and direction. These defaults apply to series you open for the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Single Page") {
                Toggle("In single-page view, split two-page scans into single pages (S)", isOn: $splitSpreads)
                    .onChange(of: splitSpreads) { _, _ in NotificationCenter.default.post(name: AppPreferences.didChange, object: nil) }
            }
            SharpenSettings()
            AutoPlaySettings()
            Section("Mouse") {
                Picker("Click", selection: $clickMode) {
                    Text("Click the left or right side to turn pages").tag(ClickMode.sides.rawValue)
                    Text("Left button next, right button previous (Honeyview)").tag(ClickMode.buttons.rawValue)
                    Text("Don’t turn pages").tag(ClickMode.off.rawValue)
                }
                Text("Drag to move a zoomed page. In right-to-left books the left side is next; in vertical view, the lower half scrolls down.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Arrow keys follow the reading direction (← is next in right-to-left books)", isOn: $arrowsFollowDirection)
            }
            if UpdateChecker.shared.isEnabled {
                Section("Updates") {
                    Toggle("Check for new versions automatically (once a day)", isOn: $autoUpdate)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ kp: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { store.defaults[keyPath: kp] }, set: { store.defaults[keyPath: kp] = $0; store.scheduleSave() })
    }
}

/// 자동 넘기기: 쪽 보기는 간격(초), 세로(웹툰)는 흐르는 속도.
/// 선명도 방식별 강도. 손을 뗄 때 한 번만 알려 다시 그린다(끄는 동안 매번 다시 계산하지 않게).
struct SharpenSettings: View {
    @State private var values: [SharpenLevel: Double] =
        Dictionary(uniqueKeysWithValues: SharpenLevel.allCases.map { ($0, SharpenPreferences.strength($0)) })

    private var levels: [SharpenLevel] { SharpenLevel.available.filter { $0 != .off } }

    var body: some View {
        Section {
            ForEach(levels, id: \.self) { level in
                HStack {
                    Label(level.title, systemImage: level.symbol).frame(width: 130, alignment: .leading)
                    Slider(value: binding(level), in: 0...1) { editing in
                        if !editing { SharpenPreferences.setStrength(values[level] ?? 0, for: level) }
                    }
                    Text("\(Int(((values[level] ?? 0) * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    Button("Reset") {
                        values[level] = SharpenPreferences.defaultStrength(level)
                        SharpenPreferences.setStrength(values[level] ?? 0, for: level)
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Sharpen Strength")
        } footer: {
            Text("Sharp Text darkens ink and whitens paper. Sharp Art crisps lines without white halos and keeps screentones. AI Upscale enlarges small scans with Apple’s on-device AI, then applies Sharp Text.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(_ level: SharpenLevel) -> Binding<Double> {
        Binding(get: { values[level] ?? 0 }, set: { values[level] = $0 })
    }
}

struct AutoPlaySettings: View {
    @AppStorage("auto.interval") private var interval = 5.0
    @AppStorage("auto.speed") private var speed = 70.0
    @AppStorage("auto.continue") private var continueToNext = true

    var body: some View {
        Section("Auto Advance") {
            Stepper(value: $interval, in: 1...60, step: 1) {
                Text("Single/two-page view: next page every \(Int(interval)) s")
            }
            LabeledContent("Vertical scroll (webtoon) speed") {
                Slider(value: $speed, in: 10...400) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "tortoise").help(String(localized: "Slower"))
                } maximumValueLabel: {
                    Image(systemName: "hare").help(String(localized: "Faster"))
                }
            }
            Toggle("Continue to the next volume at the end", isOn: $continueToNext)
        }
    }
}

/// 단축키 편집. 동작마다 키를 여러 개 걸 수 있고, 새 키는 눌러서 기록한다.
struct ShortcutSettings: View {
    @ObservedObject var bindings = KeyBindings.shared
    @State private var recording: KeyAction?
    @State private var monitor: Any?
    @State private var message: String?

    private let groups: [(String, [KeyAction])] = [
        (String(localized: "Pages"), [.nextPage, .previousPage, .firstPage, .lastPage, .forward10, .back10, .goToPage]),
        (String(localized: "Volumes"), [.nextVolume, .previousVolume]),
        (String(localized: "Layout"), [.layoutSingle, .layoutDouble, .layoutVertical, .cycleLayout, .doubleLTR, .doubleRTL,
                                       .toggleDirection, .toggleSplit, .toggleCover, .shiftSpread]),
        (String(localized: "Zoom"), [.fitPage, .fitWidth, .fitHeight, .fitOriginal, .zoomIn, .zoomOut, .toggleFullScreen, .exitFullScreen]),
        (String(localized: "Bookmarks"), [.toggleBookmark, .showBookmarks, .nextBookmark, .previousBookmark]),
        (String(localized: "Auto Advance"), [.toggleAutoPlay, .autoSlower, .autoFaster]),
        (String(localized: "Other"), [.toggleSidebar, .cycleSharpen]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { action in
                            row(action)
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Restore Defaults") { bindings.resetAll(); message = nil }
            }
            .padding(10)
        }
        .onDisappear(perform: stopRecording)
    }

    private func row(_ action: KeyAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            Button { bindings.resetOne(action) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(Text("Restore the default shortcuts for this action"))
                .opacity(bindings.combos(action) == action.defaults ? 0 : 1)
            ForEach(bindings.combos(action), id: \.self) { combo in
                HStack(spacing: 2) {
                    Text(combo.displayString).font(.system(.callout, design: .rounded)).monospacedDigit()
                    Button { bindings.remove(combo, from: action) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Remove this shortcut"))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            Button(recording == action ? String(localized: "Press a key…") : "+") {
                recording == action ? stopRecording() : startRecording(action)
            }
            .help(Text("Add a shortcut"))
        }
    }

    private func startRecording(_ action: KeyAction) {
        stopRecording()
        recording = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 설정 창에서 누른 키만 기록한다(읽기 창에서 누른 키까지 삼키지 않게).
            guard event.window === SettingsWindowController.shared.window else { return event }
            let combo = KeyCombo(event: event)
            if combo.keyCode == 53, !combo.command, !combo.shift, !combo.option, !combo.control { stopRecording(); return nil }   // Esc: 취소
            if Self.reserved.contains(combo) {
                message = String(localized: "\(combo.displayString) is a system shortcut and can’t be used.")
                stopRecording()
                return nil
            }
            if let other = bindings.conflict(for: combo, except: action) {
                message = String(localized: "\(combo.displayString) was moved from “\(other.title)”.")
            }
            bindings.add(combo, to: action)
            stopRecording()
            return nil
        }
    }

    /// 앱·창의 기본 동작 키. 녹화하면 종료·닫기가 막히므로 거부한다.
    static let reserved: Set<KeyCombo> = {
        let cmdKeys = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_Comma,
                       kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_Z, kVK_Tab]
        var s = Set(cmdKeys.map { KeyCombo($0, command: true) })
        s.insert(KeyCombo(kVK_ANSI_Z, command: true, shift: true))
        s.insert(KeyCombo(kVK_ANSI_H, command: true, option: true))
        s.insert(KeyCombo(kVK_ANSI_W, command: true, option: true))
        return s
    }()

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

struct AboutLicenses: View {
    var body: some View {
        ScrollView {
            Text(Licenses.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

enum Licenses {
    static let text = """
    Jjokview uses the following components.

    libarchive — BSD 2-Clause License (used through the macOS system library)
    The libarchive distribution as a whole is Copyright by Tim Kientzle and is subject to the following notice.

    Copyright (c) 2003-2018 Tim Kientzle and libarchive contributors
    All rights reserved.

    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
    following conditions are met:
    1. Redistributions of source code must retain the above copyright notice, this list of conditions and the
       following disclaimer in this position and unchanged.
    2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
       following disclaimer in the documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
    IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
    EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

    zlib — used through the macOS system library.
    """
}

/// 설정 창(앱 하나에 하나).
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = String(localized: "Settings")
        window.styleMask = [.titled, .closable]
        self.init(window: window)
    }
}
