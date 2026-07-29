#if canImport(UIKit)
import Testing
import UIKit
@testable import HitHitKit
@testable import HitHitCore

// MARK: - 스크롤뷰 탐색 (TrackingWindow 자동 추적의 핵심 배선)

@Suite @MainActor struct EnclosingScrollViewTests {

    @Test func findsScrollViewUpTheSuperviewChain() {
        let scrollView = UIScrollView()
        let middle = UIView()
        let leaf = UIView()
        scrollView.addSubview(middle)
        middle.addSubview(leaf)

        #expect(leaf.enclosingScrollView() === scrollView)
    }

    @Test func returnsSelfWhenViewIsTheScrollView() {
        let scrollView = UIScrollView()
        #expect(scrollView.enclosingScrollView() === scrollView)
    }

    @Test func returnsNilWhenNoScrollViewInChain() {
        let root = UIView()
        let leaf = UIView()
        root.addSubview(leaf)

        #expect(leaf.enclosingScrollView() == nil)
    }

    /// 중첩 스크롤뷰에서는 **가장 가까운** 것을 잡아야 한다(바깥 것을 잡으면 깊이가 엉뚱해진다).
    @Test func picksNearestNotOutermostScrollView() {
        let outer = UIScrollView()
        let inner = UIScrollView()
        let leaf = UIView()
        outer.addSubview(inner)
        inner.addSubview(leaf)

        #expect(leaf.enclosingScrollView() === inner)
    }
}

// MARK: - 탭 정규화 (커밋 8a456a6 회귀 가드: 기준은 항상 window bounds)

@Suite(.serialized) @MainActor final class HitHitCollectorTapTests {

    private let uploader = FakeUploader()
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    init() throws {
        HitHitCollector.shared.stop()   // 앞 테스트 잔여 상태 초기화
        var config = HitHitConfig(endpoint: URL(string: "https://example.invalid/hit")!)
        config.uploader = uploader
        config.storageDirectory = TestFiles.tempDirectory()
        try HitHitCollector.shared.start(config: config)
        HitHitCollector.shared.setConsent(true)
        HitHitCollector.shared.setScreen("loan_detail")
    }

    private func firstUploadedEvent() async -> HitHitEvent? {
        await waitUntil { self.uploader.uploadCount > 0 }
        return uploader.uploadedEvents.first
    }

    @Test func tapCenterNormalizesToHalfOfWindowBounds() async throws {
        HitHitCollector.shared.handleTap(at: CGPoint(x: 195, y: 422), in: window)

        let event = try #require(await firstUploadedEvent())
        #expect(event.type == .tap)
        #expect(event.screen == "loan_detail")
        #expect(event.x == 0.5)
        #expect(event.y == 0.5)
    }

    /// 정규화 기준이 window 크기로 실려야 한다 — 이 값이 없으면 서버가 기기별 좌표를 합칠 수 없다.
    @Test func tapCarriesWindowSizeAsNormalizationBasis() async throws {
        HitHitCollector.shared.handleTap(at: CGPoint(x: 39, y: 84.4), in: window)

        let event = try #require(await firstUploadedEvent())
        #expect(event.screenW == 390)
        #expect(event.screenH == 844)
        #expect(abs(event.x! - 0.1) < 0.0001)
        #expect(abs(event.y! - 0.1) < 0.0001)
    }

    @Test func tapOutsideWindowIsClampedToUnitRange() async throws {
        HitHitCollector.shared.handleTap(at: CGPoint(x: 9_999, y: -50), in: window)

        let event = try #require(await firstUploadedEvent())
        #expect(event.x == 1.0)
        #expect(event.y == 0.0)
    }

    /// 세로 window면 portrait, 가로면 landscape — 방향이 섞이면 집계가 무의미해진다.
    @Test func orientationFollowsWindowShape() async throws {
        let landscape = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        HitHitCollector.shared.handleTap(at: CGPoint(x: 422, y: 195), in: landscape)

        let event = try #require(await firstUploadedEvent())
        #expect(event.orientation == .landscape)
        #expect(event.screenW == 844)
    }

    /// 동의 OFF 게이트가 UIKit 경로에서도 살아있는지 — 릴리즈 게이트의 실제 진입점 검증.
    @Test func consentOffCollectsNothingThroughUIKitPath() async {
        HitHitCollector.shared.setConsent(false)
        HitHitCollector.shared.handleTap(at: CGPoint(x: 195, y: 422), in: window)

        await waitUntil(timeout: 0.3) { self.uploader.uploadCount > 0 }
        #expect(uploader.uploadCount == 0)
    }

    @Test func startingTwiceReportsAlreadyRunning() {
        let config = HitHitConfig(endpoint: URL(string: "https://example.invalid/hit")!)
        #expect(throws: HitHitError.alreadyRunning()) {
            try HitHitCollector.shared.start(config: config)
        }
    }
}

// MARK: - 스크롤 샘플링 (스펙 §8이 약속한 weak untrack 포함)

@Suite(.serialized) @MainActor final class ScrollTrackerTests {

    private let buffer = FakeBuffer()
    private let pipeline: EventPipeline
    private let tracker: ScrollTracker

    init() {
        var config = HitHitConfig(endpoint: URL(string: "https://example.invalid/hit")!)
        config.uploadStrategy = .batched(maxSize: .max, interval: 3600)  // 전송 배제, 버퍼만 본다
        pipeline = EventPipeline(
            config: config, store: buffer, uploader: FakeUploader(),
            sampler: { 0 }, now: { 1 })
        pipeline.start()
        pipeline.setConsent(true)
        pipeline.setScreen("loan_detail")
        tracker = ScrollTracker(pipeline: pipeline, hz: 10)
    }

    /// contentSize 2000 - viewport 800 = 1200 스크롤 가능, offset 600 → 정확히 0.5.
    private func makeScrollView(offsetY: CGFloat = 0) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 2000)
        scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        return scrollView
    }

    @Test func offsetChangeEmitsScrollEventWithNormalizedDepth() {
        let scrollView = makeScrollView()
        tracker.track(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 600)
        tracker.tick()
        pipeline._syncForTesting()

        let events = buffer.loadSpan(max: 10).events
        #expect(events.count == 1)
        #expect(events.first?.type == .scroll)
        #expect(events.first?.scrollDepth == 0.5)
        #expect(events.first?.scrollOffsetY == 600)
    }

    @Test func unchangedOffsetEmitsNothing() {
        let scrollView = makeScrollView(offsetY: 300)
        tracker.track(scrollView)

        tracker.tick()
        pipeline._syncForTesting()

        #expect(buffer.count() == 0)
    }

    @Test func trackingSameScrollViewTwiceDoesNotDoubleEmit() {
        let scrollView = makeScrollView()
        tracker.track(scrollView)
        tracker.track(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 600)
        tracker.tick()
        pipeline._syncForTesting()

        #expect(buffer.count() == 1)
    }

    @Test func untrackedScrollViewStopsEmitting() {
        let scrollView = makeScrollView()
        tracker.track(scrollView)
        tracker.untrack(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 600)
        tracker.tick()
        pipeline._syncForTesting()

        #expect(buffer.count() == 0)
    }

    /// 스펙 §8이 약속한 항목: 스크롤뷰는 weak 보관이라 해제되면 자동으로 추적 목록에서 빠진다.
    @Test func deallocatedScrollViewIsPrunedWithoutCrashing() {
        do {
            let scrollView = makeScrollView()
            tracker.track(scrollView)
            #expect(tracker.trackedCount == 1)
        }

        tracker.tick()
        pipeline._syncForTesting()

        #expect(tracker.trackedCount == 0)
        #expect(buffer.count() == 0)
    }

    @Test func stopClearsAllTracking() {
        let scrollView = makeScrollView()
        tracker.track(scrollView)
        tracker.stop()

        scrollView.contentOffset = CGPoint(x: 0, y: 600)
        tracker.tick()
        pipeline._syncForTesting()

        #expect(tracker.trackedCount == 0)
        #expect(buffer.count() == 0)
    }
}
#endif
