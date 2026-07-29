import Foundation
import HitHitCore

/// 수집 파이프라인의 순수 코어(UIKit 무의존, 생성자 주입 → 단위테스트 가능).
///
/// 게이팅(실행/동의/제외화면/샘플링) → 임시 버퍼 저장 → 서버 전송을 담당한다.
/// UIKit 글루(`HitHitCollector`)가 좌표를 정규화해 `recordTap`/`recordScroll`을 호출한다.
///
/// 전송 정책은 `HitHitUploadStrategy`가 결정한다. 로컬 저장은 실패/오프라인 대비 임시 버퍼일 뿐,
/// 전송 성공 시 즉시 비워진다(서버가 원본). **동의가 꺼지면 신규 수집과 전송 모두 중단된다.**
///
/// 스레드 안전: 모든 상태 변경/판정/전송 트리거는 전용 직렬 큐에서 직렬화된다.
final class EventPipeline {

    /// 한 번의 HTTP 요청에 담는 최대 이벤트 수.
    static let uploadChunkSize = 500

    private let queue = DispatchQueue(label: "co.finda.hithit.pipeline")
    private let store: EventBuffering
    private let uploader: HitHitUploader
    private let config: HitHitConfig
    private let sampler: () -> Double
    private let now: () -> Int64

    private var running = false
    private var consent = false        // 기본 OFF (fail-safe)
    private var currentScreen: String?
    private var uploading = false       // 코얼레싱 가드

    init(
        config: HitHitConfig,
        store: EventBuffering,
        uploader: HitHitUploader,
        sampler: @escaping () -> Double = { Double.random(in: 0..<1) },
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.config = config
        self.store = store
        self.uploader = uploader
        self.sampler = sampler
        self.now = now
    }

    // MARK: - Lifecycle / state

    func start() { queue.sync { running = true } }
    func stop()  { queue.sync { running = false } }
    func setConsent(_ granted: Bool) { queue.async { self.consent = granted } }
    func isConsentGranted() -> Bool { queue.sync { consent } }
    func setScreen(_ name: String) { queue.async { self.currentScreen = name } }
    func clearScreen() { queue.async { self.currentScreen = nil } }

    /// 저장된 미전송 이벤트를 하드 삭제(동의 철회 등).
    func purgePending() { queue.async { self.store.clear() } }

    // MARK: - Recording

    func recordTap(
        nx: Double, ny: Double, screenW: Double, screenH: Double,
        device: String, orientation: HitHitOrientation
    ) {
        queue.async {
            guard let screen = self.currentScreen, self.passesGate(screen: screen) else { return }
            let event = HitHitEvent.tap(
                screen: screen, x: nx, y: ny,
                screenW: screenW, screenH: screenH,
                device: device, orientation: orientation, ts: self.now()
            )
            self.store.append(event)
            self.enforceBufferCap()
            self.maybeTriggerUpload()
        }
    }

    func recordScroll(
        depth: Double, offsetY: Double, screenW: Double, screenH: Double,
        device: String, orientation: HitHitOrientation
    ) {
        queue.async {
            guard let screen = self.currentScreen, self.passesGate(screen: screen) else { return }
            let event = HitHitEvent.scroll(
                screen: screen, scrollDepth: depth, scrollOffsetY: offsetY,
                screenW: screenW, screenH: screenH,
                device: device, orientation: orientation, ts: self.now()
            )
            self.store.append(event)
            self.enforceBufferCap()
            self.maybeTriggerUpload()
        }
    }

    /// 버퍼 상한 초과분을 앞(오래된 것)에서 버린다. (큐 내부)
    ///
    /// **전송이 비행 중이면 건너뛴다.** `startUpload`는 스팬의 `lineCount`를 미리 잡아두고
    /// 성공 시 `removeFirst(lineCount)`로 지우는데, 그 사이 앞을 잘라내면 인덱스가 어긋나
    /// **아직 전송하지 않은 이벤트를 전송 성공분으로 오인해 삭제**하게 된다.
    /// 전송은 재시도까지 수 초 내에 끝나므로, 그 동안의 초과분은 다음 인입에서 정리된다.
    private func enforceBufferCap() {
        guard !uploading else { return }
        let drop = BufferPolicy.overflowDropCount(
            count: store.count(), max: config.maxBufferedEvents)
        guard drop > 0 else { return }
        store.removeFirst(drop)
    }

    /// 수집 게이트 — 순수 판정 로직에 위임. (큐 내부에서만 호출)
    private func passesGate(screen: String) -> Bool {
        CollectionGate.allows(
            running: running, consent: consent, screen: screen,
            excludedScreens: config.excludedScreens,
            samplingRate: config.samplingRate, roll: sampler()
        )
    }

    // MARK: - Upload

    /// 이벤트 기록 직후 전략에 따라 전송을 트리거. (큐 내부)
    private func maybeTriggerUpload() {
        switch config.uploadStrategy {
        case .immediate:
            startUpload(completion: nil)
        case .batched(let maxSize, _):
            if store.count() >= maxSize { startUpload(completion: nil) }
        }
    }

    /// 수동/주기 flush. 버퍼에 남은 걸 서버로 보낸다.
    func flush(completion: ((Result<Void, HitHitError>) -> Void)?) {
        queue.async { self.startUpload(completion: completion) }
    }

    /// 한 청크 전송 → 성공 시 로컬 제거 후 남은 게 있으면 계속 드레인. (큐 내부)
    private func startUpload(completion: ((Result<Void, HitHitError>) -> Void)?) {
        guard consent, !uploading else { completion?(.success(())); return } // 철회/코얼레싱

        let (chunk, lineCount) = store.loadSpan(max: Self.uploadChunkSize)
        guard lineCount > 0 else { completion?(.success(())); return }

        if chunk.isEmpty {                       // 스팬 전체가 손상 라인 → 정리 후 다음으로
            purge(lineCount, then: completion)
            return
        }

        switch encodeBatch(chunk) {
        case .failure(let error):
            completion?(.failure(error))
        case .success(let data):
            uploading = true
            uploader.upload(batch: data) { [weak self] result in
                self?.queue.async { self?.finishUpload(result, lineCount: lineCount, completion: completion) }
            }
        }
    }

    /// 손상 라인 정리 후 남은 게 있으면 드레인. (큐 내부)
    private func purge(_ lineCount: Int, then completion: ((Result<Void, HitHitError>) -> Void)?) {
        store.removeFirst(lineCount)
        completion?(.success(()))
        if store.count() > 0 { startUpload(completion: nil) }
    }

    /// 전송 결과 처리: 성공 시 정확히 라인 수만큼 제거 후 드레인, 실패 시 로컬 보존. (큐 내부)
    private func finishUpload(
        _ result: Result<Void, Error>, lineCount: Int,
        completion: ((Result<Void, HitHitError>) -> Void)?
    ) {
        uploading = false
        switch result {
        case .success:
            store.removeFirst(lineCount)
            completion?(.success(()))
            if consent, store.count() > 0 { startUpload(completion: nil) }
        case .failure(let error):
            completion?(.failure(HitHitError.uploadFailed(error)))
        }
    }

    /// 이벤트 배치를 JSON으로 인코딩(순수).
    private func encodeBatch(_ events: [HitHitEvent]) -> Result<Data, HitHitError> {
        Result { try JSONEncoder().encode(events) }
            .mapError { HitHitError.encodingFailed($0) }
    }

    // MARK: - Testing hook

    /// 큐에 쌓인 비동기 작업이 모두 끝날 때까지 대기(테스트 전용).
    func _syncForTesting() { queue.sync {} }
}
