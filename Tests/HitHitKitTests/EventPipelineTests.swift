import Testing
import Foundation
@testable import HitHitKit
@testable import HitHitCore

@Suite struct EventPipelineTests {

    /// 기본은 `.batched`(대용량)로 두어 이벤트가 버퍼에 남아 게이팅을 관측할 수 있게 한다.
    private func makePipeline(
        configure: (inout HitHitConfig) -> Void = { _ in },
        uploader: HitHitUploader = FakeUploader(),
        buffer: FakeBuffer = FakeBuffer(),
        sampler: @escaping () -> Double = { 0.0 }
    ) -> (EventPipeline, FakeBuffer) {
        var config = HitHitConfig(endpoint: URL(string: "https://example.com")!)
        config.uploadStrategy = .batched(maxSize: 1_000_000, interval: 3600)
        configure(&config)
        let pipeline = EventPipeline(
            config: config, store: buffer, uploader: uploader, sampler: sampler, now: { 42 })
        return (pipeline, buffer)
    }

    private func record(_ pipeline: EventPipeline, times: Int = 1) {
        for _ in 0..<times {
            pipeline.recordTap(nx: 0.5, ny: 0.5, screenW: 390, screenH: 844,
                               device: "d", orientation: .portrait)
        }
    }

    // MARK: - 릴리즈 게이트: 동의 OFF ⇒ 0건

    @Test func consentOffCollectsZero() {
        let (pipeline, buffer) = makePipeline()
        pipeline.start(); pipeline.setScreen("home")   // 동의 안 함(기본 OFF)
        record(pipeline, times: 50)
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    @Test func consentOnCollects() {
        let (pipeline, buffer) = makePipeline()
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 1)
    }

    @Test func notRunningCollectsZero() {
        let (pipeline, buffer) = makePipeline()
        pipeline.setConsent(true); pipeline.setScreen("home")   // start 안 함
        record(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    @Test func noScreenCollectsZero() {
        let (pipeline, buffer) = makePipeline()
        pipeline.start(); pipeline.setConsent(true)   // setScreen 안 함
        record(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    @Test func excludedScreenIsBlocked() {
        let (pipeline, buffer) = makePipeline { $0.excludedScreens = ["login"] }
        pipeline.start(); pipeline.setConsent(true)
        pipeline.setScreen("login"); record(pipeline)
        pipeline.setScreen("home");  record(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 1)   // login 제외, home만
    }

    @Test func samplingZeroCollectsZero() {
        let (pipeline, buffer) = makePipeline(
            configure: { $0.samplingRate = 0.0 }, sampler: { 0.5 })
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 20)
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    // MARK: - 즉시 전송(.immediate): 로컬에 안 쌓고 서버로

    @Test func immediateUploadsAndClearsLocalOnSuccess() async {
        let uploader = FakeUploader(results: [.success(())])
        let (pipeline, buffer) = makePipeline(
            configure: { $0.uploadStrategy = .immediate }, uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        await waitUntil { uploader.uploadCount > 0 && buffer.count() == 0 }
        #expect(buffer.count() == 0)
        #expect(uploader.uploadCount > 0)
    }

    @Test func immediateKeepsLocalOnFailure() {
        let uploader = FakeUploader(results: [.failure(NSError(domain: "net", code: -1))])
        let (pipeline, buffer) = makePipeline(
            configure: { $0.uploadStrategy = .immediate }, uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 1)   // 실패 시 보존
    }

    // MARK: - 수동 flush(.batched 누적 후)

    @Test func flushSuccessRemovesBatch() async {
        let uploader = FakeUploader(results: [.success(())])
        let (pipeline, buffer) = makePipeline(uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()
        #expect(buffer.count() == 3)

        let result = await awaitFlush(pipeline)
        #expect(result.isSuccess)
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    @Test func flushFailurePreservesBatch() async {
        let uploader = FakeUploader(results: [.failure(NSError(domain: "net", code: -1))])
        let (pipeline, buffer) = makePipeline(uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()

        let result = await awaitFlush(pipeline)
        #expect(result.isFailure)
        pipeline._syncForTesting()
        #expect(buffer.count() == 3)
    }

    // MARK: - 동의 철회 + purge

    @Test func consentRevokeStopsUpload() async {
        let uploader = FakeUploader(results: [.success(())])
        let (pipeline, buffer) = makePipeline(uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()
        #expect(buffer.count() == 3)

        pipeline.setConsent(false)
        _ = await awaitFlush(pipeline)
        pipeline._syncForTesting()
        #expect(buffer.count() == 3)          // 철회 후 미전송분도 안 나감
        #expect(uploader.uploadCount == 0)
    }

    @Test func purgeClearsBuffer() {
        let (pipeline, buffer) = makePipeline()
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        record(pipeline, times: 3)
        pipeline._syncForTesting()
        #expect(buffer.count() == 3)

        pipeline.purgePending()
        pipeline._syncForTesting()
        #expect(buffer.count() == 0)
    }

    // MARK: - 버퍼 상한 (오프라인 장기화 시 무한 증가 방지)

    /// offsetY를 0,1,2… 로 증가시켜 **어떤 이벤트가 살아남았는지** 식별 가능하게 한다.
    private func recordScrolls(_ pipeline: EventPipeline, count: Int) {
        for i in 0..<count {
            pipeline.recordScroll(depth: 0.5, offsetY: Double(i), screenW: 390, screenH: 844,
                                  device: "d", orientation: .portrait)
        }
    }

    @Test func bufferStopsGrowingAtCapWhenNothingIsUploaded() {
        let (pipeline, buffer) = makePipeline { $0.maxBufferedEvents = 10 }
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")

        recordScrolls(pipeline, count: 100)
        pipeline._syncForTesting()

        #expect(buffer.count() <= 10)
    }

    /// 오래된 것부터 버려야 한다 — 최신 데이터가 분석 가치가 높고, 전송 순서도 FIFO다.
    @Test func oldestEventsAreDroppedNotNewest() {
        let (pipeline, buffer) = makePipeline { $0.maxBufferedEvents = 10 }
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")

        recordScrolls(pipeline, count: 20)
        pipeline._syncForTesting()

        let survivors = buffer.loadSpan(max: 100).events.compactMap(\.scrollOffsetY)
        #expect(survivors.contains(19))     // 최신은 남고
        #expect(!survivors.contains(0))     // 가장 오래된 건 버려짐
    }

    @Test func zeroCapKeepsEverything() {
        let (pipeline, buffer) = makePipeline { $0.maxBufferedEvents = 0 }
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")

        recordScrolls(pipeline, count: 50)
        pipeline._syncForTesting()

        #expect(buffer.count() == 50)
    }

    /// 전송이 비행 중이면 앞에서 지우면 안 된다 — `startUpload`가 잡아둔 라인 수와
    /// 어긋나 **아직 안 보낸 이벤트가 전송된 것으로 오인되어 삭제**될 수 있다.
    private func makeInFlightPipeline() -> (EventPipeline, FakeBuffer, ManualUploader) {
        let uploader = ManualUploader()
        let (pipeline, buffer) = makePipeline(
            configure: {
                $0.maxBufferedEvents = 10
                $0.uploadStrategy = .batched(maxSize: 5, interval: 3600)
            },
            uploader: uploader)
        pipeline.start(); pipeline.setConsent(true); pipeline.setScreen("home")
        recordScrolls(pipeline, count: 5)          // 5건 → 전송 시작, completion 붙잡힘
        pipeline._syncForTesting()
        return (pipeline, buffer, uploader)
    }

    @Test func capIsNotEnforcedWhileUploadIsInFlight() {
        let (pipeline, buffer, uploader) = makeInFlightPipeline()
        #expect(uploader.isInFlight)

        recordScrolls(pipeline, count: 50)
        pipeline._syncForTesting()

        #expect(buffer.count() == 55)   // 상한(10)을 넘겨도 앞을 건드리지 않는다
    }

    @Test func capIsEnforcedOnceUploadSettles() {
        let (pipeline, buffer, uploader) = makeInFlightPipeline()
        recordScrolls(pipeline, count: 50)
        pipeline._syncForTesting()

        uploader.complete(.failure(HitHitError.uploadFailed(nil)))   // 실패 → 로컬 보존, 비행 종료
        pipeline._syncForTesting()
        recordScrolls(pipeline, count: 1)                            // 다음 인입에서 상한 적용
        pipeline._syncForTesting()

        #expect(buffer.count() == 9)    // max 10 → target 9
    }
}
