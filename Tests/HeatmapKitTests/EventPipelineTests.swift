import XCTest
@testable import HeatmapKit
@testable import HeatmapCore

final class EventPipelineTests: XCTestCase {

    /// 기본은 `.batched`(대용량)로 두어 이벤트가 버퍼에 남아 게이팅을 관측할 수 있게 한다.
    /// (전송을 검증하는 테스트는 전략/uploader를 명시적으로 설정한다.)
    private func makePipeline(
        configure: (inout HeatmapConfig) -> Void = { _ in },
        uploader: HeatmapUploader = FakeUploader(),
        sampler: @escaping () -> Double = { 0.0 }
    ) -> (EventPipeline, EventStore) {
        var config = HeatmapConfig(endpoint: URL(string: "https://example.com")!)
        config.uploadStrategy = .batched(maxSize: 1_000_000, interval: 3600)
        configure(&config)
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        let pipeline = EventPipeline(
            config: config, store: store, uploader: uploader,
            sampler: sampler, now: { 42 }
        )
        return (pipeline, store)
    }

    private func record(_ pipeline: EventPipeline, times: Int = 1) {
        for _ in 0..<times {
            pipeline.recordTap(nx: 0.5, ny: 0.5, screenW: 390, screenH: 844,
                               device: "d", orientation: .portrait)
        }
    }

    // MARK: - 릴리즈 게이트: 동의 OFF ⇒ 0건

    func test_consentOff_recordsZeroEvents() {
        let (pipeline, store) = makePipeline()
        pipeline.start()
        pipeline.setScreen("home")
        record(pipeline, times: 50)   // 동의를 켜지 않음 (기본 OFF)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 0, "동의 OFF 상태에서는 단 한 건도 수집되면 안 된다")
    }

    func test_consentOn_recordsEvents() {
        let (pipeline, store) = makePipeline()
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 1)
    }

    func test_notRunning_recordsZero() {
        let (pipeline, store) = makePipeline()
        pipeline.setConsent(true); pipeline.setScreen("home")   // start() 안 함
        record(pipeline)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 0)
    }

    func test_noScreenSet_recordsZero() {
        let (pipeline, store) = makePipeline()
        pipeline.start(); pipeline.setConsent(true)             // setScreen 안 함
        record(pipeline)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 0)
    }

    // MARK: - 민감화면 제외

    func test_excludedScreen_isBlocked() {
        let (pipeline, store) = makePipeline { $0.excludedScreens = ["login"] }
        pipeline.start(); pipeline.setConsent(true)
        pipeline.setScreen("login"); record(pipeline)
        pipeline.setScreen("home");  record(pipeline)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 1, "제외화면(login)은 빠지고 home만 수집")
    }

    // MARK: - 샘플링

    func test_samplingZero_recordsZero() {
        let (pipeline, store) = makePipeline(
            configure: { $0.samplingRate = 0.0 },
            sampler: { 0.5 }   // 0.5 < 0.0 → false → 차단
        )
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 20)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 0)
    }

    // MARK: - 즉시 전송 (.immediate) — 로컬에 쌓지 않고 서버로

    func test_immediate_uploadsAndClearsLocal_onSuccess() {
        let uploader = FakeUploader(results: [.success(())])
        let (pipeline, store) = makePipeline(
            configure: { $0.uploadStrategy = .immediate },
            uploader: uploader
        )
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        waitUntil { uploader.uploadCount > 0 && store.count() == 0 }  // 전송+드레인 완료 대기
        XCTAssertEqual(store.count(), 0, "즉시 전송 성공 시 로컬 버퍼는 비워져야 한다")
        XCTAssertGreaterThan(uploader.uploadCount, 0, "서버로 전송되어야 한다")
    }

    func test_immediate_keepsLocal_onFailure_forRetry() {
        let uploader = FakeUploader(results: [.failure(NSError(domain: "net", code: -1))])
        let (pipeline, store) = makePipeline(
            configure: { $0.uploadStrategy = .immediate },
            uploader: uploader
        )
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 1, "전송 실패 시에만 로컬 보존(재시도 대상)")
    }

    // MARK: - 수동 flush (.batched 누적 후)

    func test_flush_success_removesBatch() {
        let uploader = FakeUploader(results: [.success(())])
        let (pipeline, store) = makePipeline(uploader: uploader)   // batched 대용량 → 누적
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 3)

        let exp = expectation(description: "flush")
        pipeline.flush { result in
            if case .failure = result { XCTFail("성공해야 함") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 0, "전송 성공분은 로컬에서 제거")
    }

    func test_flush_failure_preservesBatch() {
        let uploader = FakeUploader(results: [.failure(NSError(domain: "net", code: -1))])
        let (pipeline, store) = makePipeline(uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()

        let exp = expectation(description: "flush")
        pipeline.flush { result in
            if case .success = result { XCTFail("실패해야 함") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        pipeline._syncForTesting()
        XCTAssertEqual(store.count(), 3, "전송 실패 시 로컬 보존(재시도 대상)")
    }
}
