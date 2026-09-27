import Foundation

/// 압축 파일 안 파일명의 인코딩. 아카이브 단위로 한 번 정하고 모든 이름에 같은 인코딩을 쓴다.
enum NameEncoding: String, Codable, CaseIterable, Identifiable {
    case automatic
    case utf8
    case cp949
    case shiftJIS
    case gbk
    case big5
    case cp437

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .utf8: return "UTF-8"
        case .cp949: return String(localized: "Korean (CP949)")
        case .shiftJIS: return String(localized: "Japanese (Shift_JIS)")
        case .gbk: return String(localized: "Chinese Simplified (GBK)")
        case .big5: return String(localized: "Chinese Traditional (Big5)")
        case .cp437: return "CP437"
        }
    }

    var stringEncoding: String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .automatic, .utf8: return .utf8
        // EUC-KR이 아니라 CP949(UHC)여야 똠·햏·뷁 같은 확장 음절이 풀린다(실측).
        case .cp949: return cf(.dosKorean)
        case .shiftJIS: return cf(.dosJapanese)
        case .gbk: return cf(.GB_18030_2000)
        case .big5: return cf(.big5)
        case .cp437: return cf(.dosLatinUS)
        }
    }
}

enum FilenameDecoder {
    /// 이름마다 UTF-8 여부를 알려주는 입력. `unicodeName`은 0x7075 필드에서 얻은 이름.
    struct RawName {
        var bytes: Data
        var utf8Flag: Bool
        var unicodeName: String?
    }

    /// 아카이브 전체를 보고 인코딩을 고른다. 플래그나 0x7075가 없는 이름만 판정 대상이다.
    static func detect(_ names: [RawName]) -> NameEncoding {
        let candidates = names.filter { !$0.utf8Flag && $0.unicodeName == nil && !isASCII($0.bytes) }
        if candidates.isEmpty { return .utf8 }
        // 모두 유효한 UTF-8이라도 바로 믿지 않는다. CP949 "화·회·호·표·치·카"(C2–C8 + A1–BF)는 우연히
        // 2바이트 UTF-8(U+0080–07FF, 라틴 확장·그리스·키릴 등)이 된다("1화" → "1ȭ", 실제 재현).
        // 한글·가나·한자 UTF-8은 3바이트라, 2바이트 글자가 하나도 없을 때만 바로 UTF-8로 정한다.
        let utf8Names = candidates.compactMap { String(data: $0.bytes, encoding: .utf8) }
        if utf8Names.count == candidates.count {
            let twoByte = utf8Names.contains { $0.unicodeScalars.contains { (0x80...0x7FF).contains($0.value) } }
            if !twoByte { return .utf8 }
        }

        // 첫 번째로 오류 없이 풀리는 인코딩을 고르면 틀린다. Shift_JIS "進撃の巨人"도 CP949로
        // 오류 없이 "릋똼궻땺릐"가 된다(실측). 그래서 후보별로 점수를 매긴다.
        let pool: [NameEncoding] = [.cp949, .shiftJIS, .gbk, .big5]
        let scored: [(NameEncoding, Int)] = pool.compactMap { enc -> (NameEncoding, Int)? in
            var total = 0
            for n in candidates {
                guard let s = String(data: n.bytes, encoding: enc.stringEncoding) else { return nil }
                total += score(s, for: enc)
            }
            return (enc, total)
        }
        var all = scored
        if utf8Names.count == candidates.count {
            all.append((.utf8, utf8Names.reduce(0) { $0 + utf8Score($1) }))
        }
        return all.max { $0.1 < $1.1 }?.0 ?? .cp437
    }

    /// UTF-8로 읽은 이름의 자연스러움. 3바이트 한글·가나·한자는 가점, 2바이트 영역 글자는 감점.
    private static func utf8Score(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { t, u in
            switch u.value {
            case 0x20...0x7E: return t + 1
            case 0xAC00...0xD7A3, 0x3040...0x30FF, 0x4E00...0x9FFF: return t + 3
            case 0x80...0x7FF: return t - 3
            default: return t
            }
        }
    }

    static func decode(_ name: RawName, using encoding: NameEncoding) -> String {
        let s: String
        if name.utf8Flag, let u = String(data: name.bytes, encoding: .utf8) {
            s = u
        } else if let u = name.unicodeName {
            s = u
        } else if isASCII(name.bytes) {
            s = String(decoding: name.bytes, as: UTF8.self)
        } else if let u = String(data: name.bytes, encoding: (encoding == .automatic ? .utf8 : encoding).stringEncoding) {
            s = u
        } else {
            s = String(data: name.bytes, encoding: NameEncoding.cp437.stringEncoding) ?? String(decoding: name.bytes, as: UTF8.self)
        }
        return s.precomposedStringWithCanonicalMapping
    }

    static func isASCII(_ d: Data) -> Bool { d.allSatisfy { $0 < 0x80 } }

    /// 그 인코딩에서 "흔히 쓰는 영역"의 글자일수록 높은 점수. 어떤 바이트든 한자로 읽어내는
    /// GB18030 같은 인코딩이 이기지 않도록, 글자를 그 인코딩의 바이트로 되돌려 영역을 본다.
    private static func score(_ s: String, for enc: NameEncoding) -> Int {
        var total = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x20...0x7E).contains(v) { total += 1; continue }
            let bytes = String(scalar).data(using: enc.stringEncoding) ?? Data()
            let lead = bytes.first ?? 0
            let trail = bytes.count > 1 ? bytes[bytes.startIndex + 1] : 0
            switch enc {
            case .cp949:
                if (0xAC00...0xD7A3).contains(v) {
                    // KS X 1001 완성형 2350자면 자연스러운 한글. 확장 영역(똠·햏·뷁 등)은 중립.
                    total += (0xB0...0xC8).contains(lead) && trail >= 0xA1 ? 3 : 0
                } else if (0x4E00...0x9FFF).contains(v) {
                    total -= 1   // 파일명에 한자는 드물다
                } else {
                    total -= 2
                }
            case .shiftJIS:
                switch v {
                case 0x3040...0x30FF: total += 3                                  // 히라가나·가타카나
                case 0xFF61...0xFF9F: total -= 3                                  // 반각 가나: 한국어 바이트를 SJIS로 읽으면 흔함
                case 0x4E00...0x9FFF: total += (0x88...0x9F).contains(lead) ? 1 : 0   // JIS 1수준 한자
                case 0x3000...0x303F, 0xFF01...0xFF5E: total += 1
                default: total -= 2
                }
            case .gbk:
                if (0x4E00...0x9FFF).contains(v) {
                    total += (0xB0...0xD7).contains(lead) && trail >= 0xA1 ? 1 : -2   // GB2312 1수준만 가점
                } else if (0x3000...0x303F).contains(v) || (0xFF01...0xFF5E).contains(v) {
                    total += 0
                } else {
                    total -= 2
                }
            case .big5:
                if (0x4E00...0x9FFF).contains(v) {
                    total += (0xA4...0xC6).contains(lead) ? 1 : -2   // 상용 한자 영역
                } else {
                    total -= 2
                }
            default:
                total -= 2
            }
        }
        return total
    }
}
