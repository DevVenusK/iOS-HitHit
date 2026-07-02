#if canImport(UIKit)
import UIKit
import HitHitCore

/// SDK 공개 진입점. 탭·스크롤을 수집해 서버로 직접 전송한다.
///
/// 연결 예시(SceneDelegate):
/// ```swift
/// let cfg = HitHitConfig(endpoint: URL(string: "https://api.example.com/hitmap")!)
/// try? HitHitCollector.shared.start(config: cfg)
/// HitHitCollector.shared.setConsent(true)   // 동의 획득 후
/// ```
/// 화면 전환 시 `setScreen(_:)`, 스크롤뷰는 `track(scrollView:)`로 등록한다.
///
/// 스레드 안전: public 메서드는 어느 스레드에서나 호출 가능(내부 상태는 lock으로 보호).
/// 단 `track`/`setScreen`은 UIKit 접근이 있어 메인 스레드 호출을 권장한다.
public final class HitHitCollector {

    public static let shared = HitHitCollector()

    // 아래 mutable 상태는 모두 `lock`으로 보호한다(메인 sendEvent 경로 ↔ start/stop 레이스 방지).
    private let lock = NSLock()
    private var pipeline: EventPipeline?
    private var scrollTracker: ScrollTracker?
    private var flushTimer: DispatchSourceTimer?
    private var _isRunning = false
    private var autoTrackScrollViews = true

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }

    private init() {}

    // MARK: - Lifecycle

    /// 수집을 시작한다. 동의는 별도로 `setConsent(true)`가 필요하다(기본 OFF).
    public func start(config: HitHitConfig) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !_isRunning else { throw HitHitError.alreadyRunning() }

        let fileURL = try Self.resolveStorageURL(config.storageDirectory)
        let store = EventStore(fileURL: fileURL)
        let uploader = config.uploader
            ?? DefaultHTTPUploader(endpoint: config.endpoint, headers: config.headers)
        let pipeline = EventPipeline(config: config, store: store, uploader: uploader)
        pipeline.start()

        self.pipeline = pipeline
        self.scrollTracker = ScrollTracker(pipeline: pipeline, hz: config.scrollSampleHz)
        self.autoTrackScrollViews = config.autoTrackScrollViews
        // `.immediate`는 실패/오프라인분 재시도 스윕용, `.batched`는 주기 전송용 타이머.
        self.flushTimer = Self.makeFlushTimer(interval: config.uploadStrategy.timerInterval) { [weak self] in
            self?.flush(completion: nil)
        }
        self._isRunning = true

        Self.warnIfNoTrackingWindowInstalled()
    }

    /// 수집을 중단한다. 저장된 미전송 이벤트는 보존된다.
    public func stop() {
        lock.lock()
        let pipeline = self.pipeline
        let tracker = self.scrollTracker
        let timer = self.flushTimer
        self.flushTimer = nil
        self._isRunning = false
        lock.unlock()

        pipeline?.stop()
        tracker?.stop()
        timer?.cancel()
    }

    // MARK: - Consent / screen

    public func setConsent(_ granted: Bool) { currentPipeline()?.setConsent(granted) }
    public var hasConsent: Bool { currentPipeline()?.isConsentGranted() ?? false }
    public func setScreen(_ name: String) { currentPipeline()?.setScreen(name) }
    public func clearScreen() { currentPipeline()?.clearScreen() }

    /// 저장된 미전송 이벤트를 하드 삭제(동의 철회 시 등).
    public func purgePendingEvents() { currentPipeline()?.purgePending() }

    // MARK: - Scroll registration

    public func track(scrollView: UIScrollView) { currentTracker()?.track(scrollView) }
    public func untrack(scrollView: UIScrollView) { currentTracker()?.untrack(scrollView) }

    // MARK: - Flush

    public func flush(completion: ((Result<Void, HitHitError>) -> Void)? = nil) {
        guard let pipeline = currentPipeline() else {
            completion?(.failure(HitHitError.notConfigured()))
            return
        }
        pipeline.flush(completion: completion)
    }

    // MARK: - Tap intake (TrackingWindow → here)

    /// `TrackingWindow.sendEvent`에서 호출. 메인 스레드에서 좌표 정규화 + enqueue만 수행.
    ///
    /// 정규화 기준은 **항상 window(전체 화면) bounds**로 고정한다. 탭된 뷰가 속한
    /// child/컨테이너 VC에 따라 기준이 달라지면 같은 화면의 좌표가 서로 비교 불가능해지고
    /// orientation도 오판되므로, 화면 단위의 안정적인 기준을 쓴다. `point`는 이미 window 좌표계다.
    func handleTap(at point: CGPoint, in window: UIWindow) {
        guard let pipeline = currentPipeline() else { return }
        let bounds = window.bounds
        guard let n = Normalization.normalize(
            px: Double(point.x), py: Double(point.y),
            width: Double(bounds.width), height: Double(bounds.height)
        ) else { return }
        let orientation = DeviceInfo.orientation(
            width: Double(bounds.width), height: Double(bounds.height))
        pipeline.recordTap(
            nx: n.x, ny: n.y,
            screenW: Double(bounds.width), screenH: Double(bounds.height),
            device: DeviceInfo.modelIdentifier, orientation: orientation
        )
    }

    // MARK: - Auto scroll tracking (TrackingWindow → here)

    /// 터치가 시작된 뷰가 스크롤뷰 안에 있으면 그 스크롤뷰를 자동 등록한다.
    /// `TrackingWindow`가 `.began`에서 호출. `autoTrackScrollViews`가 true일 때만 동작.
    func noteTouch(on view: UIView?) {
        lock.lock()
        let enabled = autoTrackScrollViews
        let tracker = scrollTracker
        lock.unlock()
        guard enabled, let scrollView = view?.enclosingScrollView() else { return }
        tracker?.track(scrollView)
    }

    // MARK: - Locked accessors

    private func currentPipeline() -> EventPipeline? {
        lock.lock(); defer { lock.unlock() }; return pipeline
    }
    private func currentTracker() -> ScrollTracker? {
        lock.lock(); defer { lock.unlock() }; return scrollTracker
    }

    // MARK: - Helpers

    private static func makeFlushTimer(interval: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private static func resolveStorageURL(_ directory: URL?) throws -> URL {
        let dir: URL
        if let directory = directory {
            dir = directory
        } else {
            guard let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask).first else {
                throw HitHitError.storageUnavailable(CocoaError(.fileNoSuchFile))
            }
            dir = caches.appendingPathComponent("HitHitKit", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }

    /// 호스트가 TrackingWindow를 설치하지 않으면 탭이 조용히 수집되지 않는다 → DEBUG에서 경고.
    private static func warnIfNoTrackingWindowInstalled() {
        #if DEBUG
        DispatchQueue.main.async {
            let hasTrackingWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .contains { $0 is TrackingWindow }
            if !hasTrackingWindow {
                print("⚠️ [HitHitKit] TrackingWindow가 설치되지 않았습니다. 탭이 수집되지 않습니다. " +
                      "SceneDelegate에서 window를 TrackingWindow로 교체하세요.")
            }
        }
        #endif
    }
}
#endif
