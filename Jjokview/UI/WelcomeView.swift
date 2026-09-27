import SwiftUI

/// 책이 없을 때의 시작 화면: 열기 버튼과 이어보기 목록.
struct WelcomeView: View {
    @ObservedObject var store = LibraryStore.shared
    var open: () -> Void
    var openRecent: (BookRecord) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.pages")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a comic archive or folder here")
                .font(.title3)
            Text("ZIP · CBZ · RAR · CBR · 7Z · folders")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: open) {
                Label("Open…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            if !store.recentForDisplay.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue Reading")
                        .font(.headline)
                        .padding(.bottom, 2)
                    ForEach(store.recentForDisplay.prefix(8)) { r in
                        Button { openRecent(r) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: r.finished ? "checkmark.circle.fill" : "book.closed")
                                    .foregroundStyle(r.finished ? .green : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.displayTitle).lineLimit(1)
                                    if let series = r.seriesName, series != r.displayTitle {
                                        Text(series).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 12)
                                ProgressView(value: r.progress)
                                    .frame(width: 60)
                                Text(r.lastOpened, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from List") { store.hideFromRecent(r.fingerprint) }
                        }
                    }
                }
                .frame(maxWidth: 520)
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
