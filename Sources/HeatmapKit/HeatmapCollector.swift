#if canImport(UIKit)
import UIKit
import HeatmapCore

/// SDK 공개 진입점. 탭·스크롤을 수집해 서버로 직접 전송한다.
///
/// 연결 예시(SceneDelegate):
/// ```swift
/// let cfg = HeatmapConfig(endpoint: URL(string: "https://api.example.com/heatmap")!)
/// try? HeatmapCollector.shared.start(config: cfg)
/// HeatmapCollector.shared.setConsent(true)   // 동의 획득 후
/// ```
/// 화면 전환 시 `setScreen(_:)`, 스크롤뷰는 `track(scrollView:)`로 등록한다.
///
/// 스레드 안전: public 메서드는 어느 스레드에서나 호출 가능(내부에서 직렬화).
/// 단 `track`/`setScreen`은 UIKit 접근이 있어 메인 스레드 호출을 권장한다.
public final class HeatmapCollector {

    public static let shared = HeatmapCollector()

    private var pipeline: EventPipeline?
    private var scrollTracker: ScrollTracker?
    private var flushTimer: DispatchSourceTimer?
    private let lifecycleQueue = DispatchQueue(label: "co.finda.heatmap.lifecycle")
    private(set) public var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    /// 수집을 시작한다. 동의는 별도로 `setConsent(true)`가 필요하다(기본 OFF).
    public func start(config: HeatmapConfig) throws {
        try lifecycleQueue.sync {
            guard !isRunning else { throw HeatmapError.alreadyRunning() }

            let fileURL = try Self.resolveStorageURL(config.storageDirectory)
            let store = EventStore(fileURL: fileURL)
            let uploader = config.uploader
                ?? DefaultHTTPUploader(endpoint: config.endpoint, headers: config.headers)
            let pipeline = EventPipeline(config: config, store: store, uploader: uploader)
            pipeline.start()

            self.pipeline = pipeline
            self.scrollTracker = ScrollTracker(pipeline: pipeline, hz: config.scrollSampleHz)
            // `.immediate`는 실패/오프라인분 재시도 스윕용, `.batched`는 주기 전송용 타이머.
            self.scheduleFlushTimer(interval: config.uploadStrategy.timerInterval)
            self.isRunning = true
        }
    }

    /// 수집을 중단한다. 저장된 미전송 이벤트는 보존된다.
    public func stop() {
        lifecycleQueue.sync {
            pipeline?.stop()
            scrollTracker?.stop()
            flushTimer?.cancel()
            flushTimer = nil
            isRunning = false
        }
    }

    // MARK: - Consent / screen

    public func setConsent(_ granted: Bool) { pipeline?.setConsent(granted) }
    public var hasConsent: Bool { pipeline?.isConsentGranted() ?? false }
    public func setScreen(_ name: String) { pipeline?.setScreen(name) }
    public func clearScreen() { pipeline?.clearScreen() }

    // MARK: - Scroll registration

    public func track(scrollView: UIScrollView) { scrollTracker?.track(scrollView) }
    public func untrack(scrollView: UIScrollView) { scrollTracker?.untrack(scrollView) }

    // MARK: - Flush

    public func flush(completion: ((Result<Void, HeatmapError>) -> Void)? = nil) {
        guard let pipeline = pipeline else {
            completion?(.failure(HeatmapError.notConfigured()))
            return
        }
        pipeline.flush(completion: completion)
    }

    // MARK: - Tap intake (TrackingWindow → here)

    /// `TrackingWindow.sendEvent`에서 호출. 메인 스레드에서 좌표 정규화 + enqueue만 수행.
    func handleTap(at point: CGPoint, in window: UIWindow) {
        guard let pipeline = pipeline else { return }
        guard let hitView = window.hitTest(point, with: nil) else { return }
        let rootView = hitView.owningViewController?.view ?? window
        let local = rootView.convert(point, from: window)
        let bounds = rootView.bounds
        guard let n = Normalization.normalize(
            px: Double(local.x), py: Double(local.y),
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

    // MARK: - Helpers

    private func scheduleFlushTimer(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.flush(completion: nil) }
        timer.resume()
        flushTimer = timer
    }

    private static func resolveStorageURL(_ directory: URL?) throws -> URL {
        let dir: URL
        if let directory = directory {
            dir = directory
        } else {
            guard let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask).first else {
                throw HeatmapError.storageUnavailable(
                    CocoaError(.fileNoSuchFile))
            }
            dir = caches.appendingPathComponent("HeatmapKit", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }
}
#endif
