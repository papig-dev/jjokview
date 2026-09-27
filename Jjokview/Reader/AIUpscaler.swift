import CoreImage
import VideoToolbox

/// Apple 내장 AI 초해상도(VideoToolbox VTSuperResolutionScaler, macOS 26+)로 저해상도 스캔을 4배 키운다.
/// 실측(M 시리즈, macOS 26.6): 921×703 두 쪽 스캔 → 3684×2812 약 0.46초. 배율은 4배만, 큰 입력(1600×2400)은 구성 불가.
/// 처음에는 시스템 모델을 내려받아야 한다. 입력은 가로·세로 1920 이하만 구성된다.
/// 세션 하나가 메모리를 1.5GB 넘게 잡고 끝내도 잘 줄지 않아, 크기별 세션은 2개까지만 두고 AI를 끄면 모두 닫는다.
final class AIUpscaler {
    static let shared = AIUpscaler()
    static let didChange = Notification.Name("AIUpscalerDidChange")

    private let lock = NSLock()          // 한 번에 하나씩(GPU/신경망 엔진 공유)
    private var sessions: [String: AnyObject] = [:]
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private(set) var downloading = false
    /// AI를 끌 때마다 올라간다. 그 전에 큐에 들어간 AI 요청은 이 값이 달라진 걸 보고 건너뛴다.
    /// 변환 중에는 `lock`을 오래 쥐므로 따로 잠근다(메인 스레드가 기다리지 않게).
    private let generationLock = NSLock()
    private var _generation = 0
    var generation: Int { generationLock.withLock { _generation } }

    /// 이 맥·이 macOS에서 쓸 수 있는지(메뉴 표시 여부).
    var isAvailable: Bool {
        if #available(macOS 26.0, *) { return VTSuperResolutionScalerConfiguration.isSupported }
        return false
    }

    /// 모델이 준비됐는지. 크기와 상관없이 같은 모델이라 대표 크기로 묻는다.
    var isReady: Bool {
        guard #available(macOS 26.0, *), let c = Self.config(960, 720) else { return false }
        return c.configurationModelStatus == .ready
    }

    /// 모델을 내려받는다. 끝나면 알림을 보낸다.
    func prepare() {
        guard #available(macOS 26.0, *), !isReady, !downloading, let c = Self.config(960, 720) else { return }
        downloading = true
        c.downloadConfigurationModel { [weak self] _ in
            DispatchQueue.main.async {
                self?.downloading = false
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }

    @available(macOS 26.0, *)
    private static func config(_ w: Int, _ h: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: 4, inputType: .image,
                                             usePrecomputedFlow: false, qualityPrioritization: .normal,
                                             revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    /// 4배로 키운 이미지. 쓸 수 없으면(모델 없음, 크기 초과 등) nil — 호출한 쪽이 일반 보정으로 대신한다.
    func upscale(_ image: CIImage, generation: Int? = nil) -> CIImage? {
        guard #available(macOS 26.0, *) else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cfg = Self.config(w, h), cfg.configurationModelStatus == .ready else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let generation, generation != self.generation { return nil }   // 락을 기다리는 동안 AI가 꺼졌다
        let key = "\(w)x\(h)"
        let proc: VTFrameProcessor
        if let p = sessions[key] as? VTFrameProcessor {
            proc = p
        } else {
            if sessions.count >= 2 { endAll() }   // 새로 열기 전에 닫는다(잠깐이라도 3개가 동시에 있지 않게)
            let p = VTFrameProcessor()
            guard (try? p.startSession(configuration: cfg)) != nil else { return nil }
            sessions[key] = p
            proc = p
        }
        guard let src = Self.buffer(cfg.sourcePixelBufferAttributes, w, h),
              let dst = Self.buffer(cfg.destinationPixelBufferAttributes, w * 4, h * 4),
              let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: .zero),
              let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: .zero),
              let params = VTSuperResolutionScalerParameters(sourceFrame: sf, previousFrame: nil, previousOutputFrame: nil,
                                                              opticalFlow: nil, submissionMode: .random, destinationFrame: df)
        else { return nil }
        ctx.render(image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY)), to: src)
        let sem = DispatchSemaphore(value: 0)
        var failed = false
        proc.process(parameters: params) { _, err in failed = err != nil; sem.signal() }
        // 콜백이 오지 않으면 락을 쥔 채 멈추지 않게. 그 세션은 버린다.
        guard sem.wait(timeout: .now() + 10) == .success else {
            proc.endSession(); sessions[key] = nil
            return nil
        }
        return failed ? nil : CIImage(cvPixelBuffer: dst)
    }

    /// AI 업스케일을 끌 때 세션을 닫아 메모리를 돌려준다.
    func releaseSessions() {
        generationLock.withLock { _generation += 1 }
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock(); defer { lock.unlock() }
            endAll()
        }
    }

    private func endAll() {
        if #available(macOS 26.0, *) {
            for p in sessions.values { (p as? VTFrameProcessor)?.endSession() }
        }
        sessions.removeAll()
    }

    private static func buffer(_ attrs: [String: Any], _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let fmt = (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? kCVPixelFormatType_32BGRA
        var a = attrs
        a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        CVPixelBufferCreate(nil, w, h, fmt, a as CFDictionary, &pb)
        return pb
    }
}
