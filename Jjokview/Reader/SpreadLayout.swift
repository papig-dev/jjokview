import CoreGraphics
import Foundation

enum ReadingDirection: String, Codable, CaseIterable {
    case leftToRight
    case rightToLeft
}

enum PageLayout: String, Codable, CaseIterable {
    case single     // 한쪽 보기
    case double     // 두쪽 보기
    case vertical   // 세로 스크롤(웹툰)
}

enum FitMode: String, Codable, CaseIterable {
    case page       // 화면에 맞춤
    case width      // 폭 맞춤
    case height     // 높이 맞춤
    case original   // 원본 크기
}

/// 한 화면에 보이는 단위. 두 쪽이 한 장에 스캔된 이미지를 나누면 한 이미지가 두 부분이 된다.
struct PagePart: Hashable {
    enum Half: Int, Codable { case full, left, right }
    var page: Int
    var half: Half
}

/// 쪽 배치 계산을 한 곳에서만 한다. 이동·표시·위치 복원이 모두 이 결과를 쓰므로
/// 짝이 한 칸 밀리는 문제가 구조적으로 생기지 않는다(Panely의 SpreadCalculator에서 얻은 교훈).
struct SpreadLayout {
    struct Options: Equatable {
        var layout: PageLayout = .single
        var direction: ReadingDirection = .rightToLeft
        /// 한쪽 보기에서 가로로 넓은 이미지(한 장에 두 쪽 스캔)를 반으로 나눠 한 쪽씩 본다.
        /// 두쪽 보기에서는 그 이미지가 곧 펼침면이라 나누지 않는다.
        var splitWide = true
        /// 두쪽 보기에서 첫 장을 표지로 단독 표시.
        var coverAlone = true
        /// 한 장 밀기. 짝을 한 칸 옮긴다.
        var shift = false
    }

    /// 읽는 순서대로의 화면 목록. 각 화면은 읽는 순서대로의 부분들(1~2개).
    let views: [[PagePart]]
    let parts: [PagePart]

    init(pageCount: Int, isWide: (Int) -> Bool, options: Options) {
        var parts: [PagePart] = []
        for i in 0..<pageCount {
            if options.splitWide && options.layout == .single && isWide(i) {
                // 읽기 방향이 첫 번째 반쪽을 정한다. 오른쪽→왼쪽이면 오른쪽 반이 먼저.
                if options.direction == .rightToLeft {
                    parts.append(PagePart(page: i, half: .right))
                    parts.append(PagePart(page: i, half: .left))
                } else {
                    parts.append(PagePart(page: i, half: .left))
                    parts.append(PagePart(page: i, half: .right))
                }
            } else {
                parts.append(PagePart(page: i, half: .full))
            }
        }
        self.parts = parts

        guard options.layout == .double else {
            views = parts.map { [$0] }
            return
        }
        var views: [[PagePart]] = []
        var i = 0
        let aloneFirst = options.coverAlone != options.shift
        while i < parts.count {
            let p = parts[i]
            let wideFull = p.half == .full && isWide(p.page)
            if (i == 0 && aloneFirst) || wideFull || i + 1 >= parts.count {
                views.append([p]); i += 1; continue
            }
            let q = parts[i + 1]
            if q.half == .full && isWide(q.page) {
                views.append([p]); i += 1; continue
            }
            views.append([p, q]); i += 2
        }
        self.views = views
    }

    /// 부분이 들어 있는 화면 번호.
    func viewIndex(containing part: PagePart) -> Int {
        views.firstIndex { $0.contains(part) } ?? views.firstIndex { $0.contains { $0.page == part.page } } ?? 0
    }

    func viewIndex(containingPage page: Int) -> Int {
        views.firstIndex { $0.contains { $0.page == page } } ?? 0
    }

    /// 화면 위에 놓는 순서(왼쪽부터). 오른쪽→왼쪽이면 읽는 순서를 뒤집는다.
    static func visualOrder(_ view: [PagePart], direction: ReadingDirection) -> [PagePart] {
        direction == .rightToLeft ? view.reversed() : view
    }
}

enum ImageGeometry {
    /// 가로가 세로보다 충분히 긴 이미지를 "두 쪽 스캔"으로 본다.
    static func isWide(_ size: CGSize) -> Bool {
        size.width > size.height * 1.05
    }
}
