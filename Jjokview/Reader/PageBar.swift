import SwiftUI

/// 쪽 막대 표시 상태. 마우스가 읽기 화면 아래쪽에 오면 보이고, 잠시 가만히 있으면 숨는다.
final class PageBarModel: ObservableObject {
    @Published var visible = false
    @Published var dragging = false
    private var hideWork: DispatchWorkItem?

    func show() {
        if !visible { visible = true }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging else { return }
            self.visible = false
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    func hideSoon() { show() }   // 끌기를 마친 뒤 같은 시간만큼 두고 숨는다
}

/// 읽기 화면 아래 쪽 막대: 끌면 그 쪽의 썸네일을 미리 보여주고, 놓으면 이동한다.
/// 오른쪽→왼쪽 책은 막대도 오른쪽이 1쪽이다.
struct PageBar: View {
    @ObservedObject var controller: ReaderController
    @ObservedObject var model: PageBarModel
    @State private var value: Double = 0
    private var target: Int { min(max(Int(value.rounded()), 0), max(controller.pageCount - 1, 0)) }

    var body: some View {
        let count = controller.pageCount
        let rtl = controller.settings.direction == .rightToLeft && controller.settings.layout != .vertical
        let shown = controller.hasBook && count > 1 && (model.visible || model.dragging)
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if model.dragging, controller.book != nil {
                VStack(spacing: 4) {
                    BookmarkThumbnail(controller: controller, page: target)
                        .frame(width: 96, height: 134)
                    Text(verbatim: "\(target + 1)").font(.caption.monospacedDigit().bold())
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Text(controller.pageLabel).font(.caption.monospacedDigit()).frame(minWidth: 64, alignment: .leading)
                // step을 주면 쪽마다 눈금 점이 찍혀 긴 책에서 빽빽해진다. 값은 반올림해서 쓴다.
                Slider(value: $value, in: 0...Double(max(count - 1, 1))) { editing in
                    model.dragging = editing
                    if editing {
                        model.show()
                    } else {
                        controller.goToPage(target)
                        controller.focusReader?()
                        model.hideSoon()
                    }
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .help(Text("Drag to jump to a page"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
        .frame(maxWidth: 560)
        .padding(.bottom, 14)
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: shown)
        .onAppear { value = Double(controller.currentPage) }
        .onChange(of: controller.currentPage) { _, p in if !model.dragging { value = Double(p) } }
        .onChange(of: controller.book?.fingerprint) { _, _ in value = Double(controller.currentPage) }
    }
}
