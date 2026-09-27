import AppKit
import CoreImage
import ImageIO

/// 스캔본 보정. 세 방식 모두 화면 크기까지 직접 키운 뒤 처리한다(키우기 전에 걸면 화면에서 효과가 거의 없다).
/// - text(글씨 선명): 약한 블러 + 레벨로 잉크는 진하게, 종이는 하얗게. 샤픈은 넣지 않는다(말풍선 OCR 비교에서 손해).
/// - art(그림 선명): JPEG 얼룩을 살짝 정리하고, 흰 테두리(헤일로)가 생기지 않게 제한한 샤픈. 스크린톤과 종이 톤을 지킨다.
/// - ai(AI 업스케일): Apple AI 초해상도 4배 → 화면 크기로 축소 → 글씨 선명(macOS 26+).
/// 예전 "약하게/강하게"(노이즈 감소 + 강한 언샤프)는 획을 뭉개서 없앴다.
enum SharpenLevel: String, Codable, CaseIterable {
    case off, text, art, ai

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .text: return String(localized: "Sharp Text")
        case .art: return String(localized: "Sharp Art")
        case .ai: return String(localized: "AI Upscale")
        }
    }

    var symbol: String {
        switch self {
        case .off: return "wand.and.stars.inverse"
        case .text: return "textformat"
        case .art: return "paintbrush.pointed"
        case .ai: return "sparkles"
        }
    }

    /// 이 맥에서 고를 수 있는 단계.
    static var available: [SharpenLevel] { AIUpscaler.shared.isAvailable ? allCases : [.off, .text, .art] }

    var next: SharpenLevel {
        let list = Self.available
        return list[((list.firstIndex(of: self) ?? 0) + 1) % list.count]
    }

    /// 예전 값(light/strong)은 글씨 선명으로 옮긴다.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "light", "strong": self = .text
        default: self = SharpenLevel(rawValue: raw) ?? .off
        }
    }
}

/// 선명도 강도(0…1, 앱 전체). 방식마다 따로 기억한다.
enum SharpenPreferences {
    static func key(_ level: SharpenLevel) -> String { "sharpen.strength.\(level.rawValue)" }
    static func defaultStrength(_ level: SharpenLevel) -> Double {
        switch level {
        case .off: return 0
        case .text, .ai, .art: return 0.5
        }
    }
    static func strength(_ level: SharpenLevel) -> Double {
        let v = UserDefaults.standard.object(forKey: key(level)) as? Double ?? defaultStrength(level)
        return min(max(v, 0), 1)
    }
    static func setStrength(_ v: Double, for level: SharpenLevel) {
        UserDefaults.standard.set(min(max(v, 0), 1), forKey: key(level))
        NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
    }
}

/// 쪽 이미지 디코딩·캐시. 화면 크기에 맞춰 다운샘플하고, 캐시 상한은 장 수가 아니라 바이트로 잡는다.
final class ImagePipeline {
    struct Key: Hashable {
        var book: String
        var page: Int
        var maxPixel: Int
        var sharpen: SharpenLevel
        /// 강도(%). 설정에서 바꾸면 키가 달라져 새로 그린다.
        var strength: Int

        init(book: String, page: Int, maxPixel: Int, sharpen: SharpenLevel) {
            self.book = book; self.page = page; self.maxPixel = maxPixel; self.sharpen = sharpen
            strength = sharpen == .off ? 0 : Int((SharpenPreferences.strength(sharpen) * 100).rounded())
        }
    }

    private let cache = NSCache<KeyBox, CGImageBox>()
    private let sizeLock = NSLock()
    private var sizes: [String: [Int: CGSize]] = [:]
    private let queue = OperationQueue()
    /// 보정(특히 AI, 한 장 0.2~0.5초)은 따로 돌린다. 같은 큐에 있으면 미리 읽기 AI가 자리를 차지해 지금 쪽 디코딩이 밀린다.
    private let enhanceQueue = OperationQueue()
    private var inflight: [Key: Operation] = [:]
    private let inflightLock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 디코딩하다 처음 알게 된 크기(풀기 전엔 모르는 RAR/7z 쪽). 배치를 다시 해야 한다.
    var onSizeLearned: ((String) -> Void)?

    init() {
        let ram = ProcessInfo.processInfo.physicalMemory
        cache.totalCostLimit = Int(min(max(ram / 16, 256 << 20), 1536 << 20))
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        enhanceQueue.maxConcurrentOperationCount = 2
        enhanceQueue.qualityOfService = .userInitiated
    }

    // MARK: - 크기

    /// 이미지 헤더만 읽어 크기를 알아낸다(디코딩 없음).
    func pixelSize(book: Book, page: Int) -> CGSize? {
        sizeLock.lock()
        if let s = sizes[book.cacheKey]?[page] { sizeLock.unlock(); return s }
        sizeLock.unlock()
        guard let head = book.pages[page].headerData() else { return nil }
        var s = Self.size(of: head)
        if s == nil, let full = try? book.pages[page].data() { s = Self.size(of: full) }
        if let s {
            sizeLock.lock(); sizes[book.cacheKey, default: [:]][page] = s; sizeLock.unlock()
        }
        return s
    }

    func knownSize(book: Book, page: Int) -> CGSize? {
        sizeLock.lock(); defer { sizeLock.unlock() }
        return sizes[book.cacheKey]?[page]
    }

    static func size(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0   // 크기 0이면 배치 계산에서 NaN이 된다
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: - 디코딩

    func cached(_ key: Key) -> CGImage? { cache.object(forKey: KeyBox(key))?.image }

    /// AI 모델을 새로 받은 뒤처럼 같은 키의 결과가 달라질 때 비운다.
    func clearImages() { cache.removeAllObjects() }

    /// 비동기 디코딩. 완료 콜백은 메인 스레드에서 부른다.
    func request(_ book: Book, page: Int, maxPixel: Int, sharpen: SharpenLevel,
                 priority: Operation.QueuePriority = .normal, completion: ((CGImage?) -> Void)? = nil) {
        let key = Key(book: book.cacheKey, page: page, maxPixel: Self.bucket(maxPixel), sharpen: sharpen)
        if let img = cached(key) {
            completion.map { c in DispatchQueue.main.async { c(img) } }
            return
        }
        inflightLock.lock()
        if let op = inflight[key] {
            if priority.rawValue > op.queuePriority.rawValue { op.queuePriority = priority }
            if let completion {
                let done = BlockOperation { [weak self] in
                    let img = self?.cached(key)
                    DispatchQueue.main.async { completion(img) }
                }
                done.addDependency(op)
                OperationQueue.main.addOperation(done)
            }
            inflightLock.unlock()
            return
        }
        let aiGeneration = AIUpscaler.shared.generation
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            var image: CGImage?
            // AI를 끈 뒤에 남은 AI 요청은 건너뛴다(세션을 다시 만들어 메모리를 붙잡지 않게, 대체 결과가 AI 키로 캐시되지 않게).
            let staleAI = { sharpen == .ai && aiGeneration != AIUpscaler.shared.generation }
            if !staleAI(), let data = try? book.pages[page].data() {
                let plain = Key(book: key.book, page: key.page, maxPixel: key.maxPixel, sharpen: .off)
                image = (sharpen != .off ? self.cached(plain) : nil) ?? Self.decode(data, maxPixel: key.maxPixel)
                if let img = image {
                    if self.knownSize(book: book, page: page) == nil, let s = Self.size(of: data) {
                        self.sizeLock.lock(); self.sizes[book.cacheKey, default: [:]][page] = s; self.sizeLock.unlock()
                        let key = book.cacheKey
                        DispatchQueue.main.async { self.onSizeLearned?(key) }
                    }
                    if sharpen != .off {
                        #if DEBUG
                        let t0 = Date()
                        defer { ImagePipeline.debugLog(String(format: "%.3f enhance %@ p%d %dpx %.0fms", t0.timeIntervalSince1970.truncatingRemainder(dividingBy: 1000), sharpen.rawValue, page + 1, key.maxPixel, Date().timeIntervalSince(t0) * 1000)) }
                        #endif
                        image = self.enhance(img, level: sharpen, strength: Double(key.strength) / 100, maxPixel: key.maxPixel,
                                             aiGeneration: aiGeneration) ?? img
                    }
                }
            }
            if staleAI() { image = nil }
            if let image {
                self.cache.setObject(CGImageBox(image), forKey: KeyBox(key), cost: image.bytesPerRow * image.height)
            }
            self.inflightLock.lock(); self.inflight[key] = nil; self.inflightLock.unlock()
            completion.map { c in DispatchQueue.main.async { c(image) } }
        }
        op.queuePriority = priority
        inflight[key] = op
        inflightLock.unlock()
        (sharpen == .off ? queue : enhanceQueue).addOperation(op)
    }

    /// 지금 보이지 않게 된 요청은 낮은 우선순위로 내린다.
    func deprioritizeAll() {
        inflightLock.lock()
        for op in inflight.values { op.queuePriority = .low }
        inflightLock.unlock()
    }

    #if DEBUG
    /// 검증용 시간 기록(DebugDriver의 스냅샷 폴더 timings.txt).
    static func debugLog(_ line: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshots/timings.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }
    #endif

    static func bucket(_ px: Int) -> Int { max(256, ((px + 255) / 256) * 256) }

    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 글씨 선명. `x`는 화면 크기로 확대가 끝난 이미지, t는 0…1(0.5 추천).
    /// 아주 약한 블러로 확대 링잉·JPEG 잡티를 누른 뒤 sRGB 값 기준 레벨(흑점·백점)로 잉크는 진하게, 종이는 하얗게.
    /// 명암 곡선(CIToneCurve)은 회색 바탕 흰 글씨를 뭉개고, 언샤프·획 굵게·잡음 제거는 OCR 비교에서 모두 손해였다.
    /// t=1은 평균은 높지만 톤 위 흰 글씨가 상한다.
    static func sharpText(_ x: CIImage, _ t: CGFloat) -> CIImage {
        guard t > 0 else { return x }
        let u = pow(t, 0.8)
        let black = 0.35 * u, white = 1 - 0.12 * u, blur = 0.8 * u.squareRoot()   // t=0.5 → 0.20 / 0.93 / 0.61px
        let k = 1 / (white - black)
        return x.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputBiasVector": CIVector(x: -black * k, y: -black * k, z: -black * k, w: 0)])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: x.extent)
    }

    /// Mitchell(B=C=1/3) 확대·축소. Lanczos와 달리 윤곽에 링잉이 없다. 바깥을 투명으로 읽지 않게 clamp 후 자른다.
    static func mitchell(_ x: CIImage, _ scale: CGFloat) -> CIImage {
        guard scale != 1 else { return x }
        return x.clampedToExtent().applyingFilter("CIBicubicScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1, "inputB": 1.0 / 3, "inputC": 1.0 / 3])
    }

    /// 그림 선명. k: 0(끔)…0.5(추천)…1(강).
    /// 1) 원본 해상도에서 감마 공간 양방향 평활(JPEG 블록·종이 얼룩 감소, 망점 유지) 2) Lanczos로 화면 크기
    /// 3) 비대칭 오버슛 제한 언샤프: 밝은 쪽은 이웃 최대값까지만(흰 헤일로 없음), 어두운 쪽은 이웃 최소값 밖 50%까지(가는 선을 진하게).
    static func artSharp(_ page: CIImage, scale: CGFloat, k: CGFloat) -> CIImage {
        let ext = page.extent
        func lanczos(_ x: CIImage) -> CIImage {
            guard scale != 1 else { return x }
            return x.clampedToExtent().cropped(to: ext.insetBy(dx: -8, dy: -8))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        guard k > 0 else { return lanczos(page) }
        let smooth = bilateralKernel?.apply(extent: ext, roiCallback: { _, r in r.insetBy(dx: -2, dy: -2) },
                                            arguments: [page.clampedToExtent(), 0.08 * k]) ?? page
        let g = lanczos(smooth).applyingFilter("CILinearToSRGBToneCurve").clampedToExtent()
        let sharp = g.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5, kCIInputIntensityKey: 3.0 * k])
        let hi = g.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.5])
        let lo = g.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5])
        let capped = sharp.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: hi])
        let floored = capped.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: lo])
        let out = capped.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: floored, kCIInputTimeKey: 0.5])
        return out.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// 감마 공간 밝기 차이로 가중하는 5×5 양방향 평활(Core Image에 내장 필터가 없다).
    /// CIKL 소스 커널은 deprecated 경고가 나지만 macOS 26에서 동작한다. Metal 커널로 옮기려면 빌드에
    /// Metal Toolchain(별도 내려받기)과 -fcikernel 설정이 필요해 보류했다. 커널이 없으면 평활 없이 샤픈만 한다.
    private static let bilateralKernel: CIKernel? = CIKernel(source: """
    kernel vec4 bilg(sampler s, float sr) {
      vec2 d = destCoord(); vec4 c = sample(s, samplerTransform(s, d));
      float cg = pow(max(c.g, 0.0), 0.4545); vec3 acc = vec3(0.0); float sum = 0.0;
      for (int j = -2; j <= 2; j++) { for (int i = -2; i <= 2; i++) {
        vec4 p = sample(s, samplerTransform(s, d + vec2(float(i), float(j))));
        float dr = pow(max(p.g, 0.0), 0.4545) - cg;
        float w = exp(-float(i*i + j*j) / 2.0 - dr*dr / (2.0*sr*sr));
        acc += p.rgb * w; sum += w; } }
      return vec4(acc / sum, c.a);
    }
    """)

    /// 보정 결과 한 장의 픽셀 상한(약 96MB). 레티나 전체 화면 한 쪽(약 6MP)을 2배 확대해도 들어간다.
    static let maxEnhancedPixels = 24_000_000

    /// 여기(백그라운드)서 픽셀을 다 그린다. 기본 createCGImage는 큰 결과를 지연 이미지로 돌려줘서,
    /// 레이어에 넣을 때마다(메인 스레드) 필터를 다시 돌렸다(4096px 넘는 결과, 실측 한 번에 50~500ms).
    /// deferred:false나 render(toBitmap:)는 한 번에 통째로 그려 GPU 메모리가 장마다 약 330MB씩 쌓였다.
    /// 지연 이미지를 우리 비트맵에 그려 넣으면 조각 단위로 그려져 메모리가 일정하고, 결과도 다시 계산되지 않는다.
    private func createImage(_ x: CIImage, _ rect: CGRect) -> CGImage? {
        guard let lazy = ciContext.createCGImage(x, from: rect), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: lazy.width, height: lazy.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        bitmap.draw(lazy, in: CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
        return bitmap.makeImage()
    }

    /// 보정. `image`는 화면 크기(maxPixel)로 줄인 디코딩 결과이고, 원본이 화면보다 작으면 원본 크기 그대로다.
    /// 결과는 긴 변이 maxPixel이 되도록 키운다(작은 원본일 때). strength는 0…1.
    func enhance(_ image: CGImage, level: SharpenLevel, strength: Double, maxPixel: Int, aiGeneration: Int? = nil) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let long = CGFloat(max(image.width, image.height))
        // 결과 크기 상한: 크게 확대하거나 긴 웹툰 조각이면 한 장이 수백 MB가 된다. 넘는 만큼은 레이어가 키운다.
        let cap = (CGFloat(Self.maxEnhancedPixels) / CGFloat(image.width * image.height)).squareRoot()
        let scale = maxPixel > 0 ? max(1, min(CGFloat(maxPixel) / long, cap)) : 1
        let t = CGFloat(strength)
        func render(_ out: CIImage, _ s: CGFloat) -> CGImage? {
            let rect = CGRect(x: 0, y: 0, width: (ci.extent.width * s).rounded(.down), height: (ci.extent.height * s).rounded(.down))
            return createImage(out.cropped(to: rect), rect)
        }
        switch level {
        case .off:
            return image
        case .text:
            return render(Self.sharpText(Self.mitchell(ci, scale), t), scale)
        case .art:
            return render(Self.artSharp(ci, scale: scale, k: t), scale)
        case .ai:
            // 2배 가까이 키울 때만 AI가 이득(1.5배 미만은 차이 없음). 입력은 가로·세로 1920 이하만 구성된다.
            if scale >= 1.5, image.width <= 1920, image.height <= 1920, let big = AIUpscaler.shared.upscale(ci, generation: aiGeneration) {
                let s = scale / 4   // 4배 결과를 화면 크기로
                let fitted = Self.mitchell(big, s)
                let rect = CGRect(x: 0, y: 0, width: (big.extent.width * s).rounded(.down), height: (big.extent.height * s).rounded(.down))
                return createImage(Self.sharpText(fitted.cropped(to: rect), t), rect)
            }
            return enhance(image, level: .text, strength: strength, maxPixel: maxPixel)   // AI를 못 쓰면 글씨 선명으로
        }
    }
}

private final class KeyBox: NSObject {
    let key: ImagePipeline.Key
    init(_ key: ImagePipeline.Key) { self.key = key }
    override var hash: Int { key.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
