import XCTest
@testable import HeatmapKit
@testable import HeatmapCore

/// 성능 예산(A1) 회귀 가드.
///
/// 실제 `sendEvent` 핫패스의 메인스레드 작업 = 좌표 정규화 + 이벤트 생성 + 큐 enqueue.
/// (hitTest는 UIKit 내부라 이 벤치 범위 밖 — 온디바이스 Instruments로 별도 검증.)
///
/// 예산: 터치당 메인스레드 < 0.5ms. 여기서는 CPU 부분이 그보다 한참 아래임을 강제한다.
final class PerformanceTests: XCTestCase {

    /// 정규화 자체(순수 함수)의 per-op 시간이 예산을 크게 밑도는지 하드 가드.
    func test_normalize_perOp_wellUnderBudget() {
        let iterations = 100_000
        let start = DispatchTime.now()
        for i in 0..<iterations {
            let px = Double(i % 390)
            _ = Normalization.normalize(px: px, py: 422, width: 390, height: 844)
        }
        let elapsedNs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
        let perOpMs = (elapsedNs / Double(iterations)) / 1_000_000.0
        XCTAssertLessThan(perOpMs, 0.5, "정규화 per-op \(perOpMs)ms 가 예산 0.5ms 초과")
    }

    /// 메인스레드 인입 경로(정규화 + 이벤트 생성 + enqueue)의 per-op 가드.
    /// enqueue 후 실제 저장/인코딩은 백그라운드라 여기 포함되지 않아야 정상.
    func test_recordTap_mainThreadEnqueue_underBudget() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        var config = HeatmapConfig(endpoint: URL(string: "https://example.com")!)
        config.uploadStrategy = .batched(maxSize: 1_000_000, interval: 3600) // 전송 부하 배제
        let pipeline = EventPipeline(
            config: config,
            store: store, uploader: FakeUploader(), sampler: { 0.0 }, now: { 42 })
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")

        let iterations = 10_000
        let start = DispatchTime.now()
        for i in 0..<iterations {
            let n = Normalization.normalize(px: Double(i % 390), py: 422, width: 390, height: 844)!
            pipeline.recordTap(nx: n.x, ny: n.y, screenW: 390, screenH: 844,
                               device: "iPhone15,3", orientation: .portrait)
        }
        let elapsedNs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
        let perOpMs = (elapsedNs / Double(iterations)) / 1_000_000.0
        XCTAssertLessThan(perOpMs, 0.5, "인입 per-op \(perOpMs)ms 가 예산 0.5ms 초과")

        pipeline._syncForTesting()
    }

    /// 참고용 리포트(baseline 관찰). 실패 조건 없음.
    func test_normalize_measure_report() {
        measure {
            for i in 0..<10_000 {
                _ = Normalization.normalize(px: Double(i % 390), py: 422, width: 390, height: 844)
            }
        }
    }
}
