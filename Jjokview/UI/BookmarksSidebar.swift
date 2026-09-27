import SwiftUI

/// 북마크 패널. 꿀뷰처럼 추가한 순서대로 쭉 보이고, 클릭하면 그 쪽으로 가고,
/// 하나씩 지우거나 전체 삭제할 수 있다.
struct BookmarksSidebar: View {
    @ObservedObject var controller: ReaderController
    @ObservedObject var store = LibraryStore.shared
    @State private var selection: UUID?
    @State private var confirmClearAll = false
    @State private var editing: UUID?
    @State private var noteDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let book = controller.book {
                header(book)
                Divider()
                if controller.bookmarks.isEmpty {
                    empty
                } else {
                    list(book)
                }
                Divider()
                footer
            } else {
                Text("No book open")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 220)
        .confirmationDialog("Delete all bookmarks in this book?", isPresented: $confirmClearAll) {
            Button("Delete All", role: .destructive) { controller.removeAllBookmarks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func header(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title).font(.headline).lineLimit(2)
            Text(controller.pageLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No bookmarks").foregroundStyle(.secondary)
            Text("Press B or ⌘D to bookmark the current page.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ book: Book) -> some View {
        List(selection: $selection) {
            ForEach(Array(controller.bookmarks.enumerated()), id: \.element.id) { n, b in
                row(b, number: n + 1, book: book)
                    .tag(b.id)
                    .contextMenu {
                        Button("Go to Page") { controller.go(to: b) }
                        Button("Edit Note") { noteDraft = b.note; editing = b.id }
                        Divider()
                        Button("Delete", role: .destructive) { controller.removeBookmark(b) }
                    }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, id in
            guard let id, let b = controller.bookmarks.first(where: { $0.id == id }) else { return }
            controller.go(to: b)
            // 같은 항목을 다시 눌러도 이동하도록 선택을 비우고, 키보드는 읽기 화면으로 돌려준다
            // (목록에 포커스가 남으면 ↑↓가 북마크를 오가고 Delete가 북마크를 지운다).
            DispatchQueue.main.async {
                selection = nil
                controller.focusReader?()
            }
        }
    }

    private func row(_ b: PageBookmark, number: Int, book: Book) -> some View {
        let (index, exact) = b.anchor.resolve(in: book)
        return HStack(spacing: 10) {
            BookmarkThumbnail(controller: controller, page: index)
                .frame(width: 36, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("p. \(index + 1)").font(.body.monospacedDigit())
                    if b.anchor.half != .full {
                        Text(b.anchor.half == .right ? "(right half)" : "(left half)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !exact {
                        Image(systemName: "questionmark.circle").foregroundStyle(.orange).help(Text("The page may have moved."))
                    }
                }
                if editing == b.id {
                    TextField("Note", text: $noteDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.setNote(noteDraft, bookmark: b.id, in: book.fingerprint); editing = nil }
                        .onExitCommand { editing = nil }
                } else if !b.note.isEmpty {
                    Text(b.note).font(.caption).lineLimit(2)
                }
                Text(b.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button {
                controller.toggleBookmark()
            } label: {
                Label(controller.isCurrentBookmarked ? "Remove" : "Add", systemImage: controller.isCurrentBookmarked ? "bookmark.slash" : "bookmark")
            }
            .help(Text("Add or remove a bookmark on this page (B, ⌘D)"))
            Spacer()
            Button(role: .destructive) { confirmClearAll = true } label: {
                Label("Delete All", systemImage: "trash")
            }
            .disabled(controller.bookmarks.isEmpty)
            .help(Text("Delete all bookmarks in this book"))
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

/// 북마크 행의 작은 썸네일.
struct BookmarkThumbnail: View {
    let controller: ReaderController
    let page: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .onAppear(perform: load)
        .onChange(of: page) { _, _ in load() }
    }

    private func load() {
        guard let book = controller.book, book.pages.indices.contains(page) else { return }
        controller.pipeline.request(book, page: page, maxPixel: 160, sharpen: .off, priority: .low) { img in image = img }
    }
}
