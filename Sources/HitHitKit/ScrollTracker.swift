#if canImport(UIKit)
import UIKit
import HitHitCore

/// 등록된 스크롤뷰들을 `CADisplayLink`로 샘플링해 스크롤 깊이를 수집한다.
///
/// 스위즐 없이 **명시 등록**만 추적한다. 스크롤뷰는 weak로 보관해 dealloc 시 자동 해제된다.
/// 오프셋이 바뀐 경우에만 이벤트를 방출해 노이즈를 줄인다.
///
/// 스레드 안전: `tracked`/displayLink 접근은 모두 **메인 스레드로 confine**된다.
/// 백그라운드 진입 시 displayLink를 일시정지해 배터리를 아낀다.
final class ScrollTracker {

    private struct Tracked {
        weak var view: UIScrollView?
        var lastOffsetY: CGFloat
    }

    private weak var pipeline: EventPipeline?
    private let hz: Int
    private var displayLink: CADisplayLink?
    private var tracked: [Tracked] = []

    /// 현재 추적 중인(아직 해제되지 않은) 스크롤뷰 수. 메인 스레드에서 읽어야 한다.
    var trackedCount: Int { tracked.count }

    init(pipeline: EventPipeline, hz: Int) {
        self.pipeline = pipeline
        self.hz = max(1, hz)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pause),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resume),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
    }

    func track(_ scrollView: UIScrollView) {
        runOnMain {
            guard !self.tracked.contains(where: { $0.view === scrollView }) else { return }
            self.tracked.append(Tracked(view: scrollView, lastOffsetY: scrollView.contentOffset.y))
            self.startIfNeeded()
        }
    }

    func untrack(_ scrollView: UIScrollView) {
        runOnMain {
            self.tracked.removeAll { $0.view === scrollView || $0.view == nil }
            self.stopIfEmpty()
        }
    }

    func stop() {
        runOnMain {
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.tracked.removeAll()
        }
    }

    // MARK: - Background handling

    @objc private func pause() { runOnMain { self.displayLink?.isPaused = true } }
    @objc private func resume() { runOnMain { if !self.tracked.isEmpty { self.displayLink?.isPaused = false } } }

    // MARK: - Sampling (all on main)

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = hz
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopIfEmpty() {
        tracked.removeAll { $0.view == nil }
        if tracked.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// 한 번의 샘플링 스텝. 평소엔 `CADisplayLink`가 부르고, 테스트는 직접 불러
    /// 디스플레이 링크 타이밍에 의존하지 않고 결정적으로 검증한다(internal).
    @objc func tick() {
        var stillAlive: [Tracked] = []
        for var item in tracked {
            guard let view = item.view else { continue } // dealloc된 것 제거
            let offsetY = view.contentOffset.y
            if offsetY != item.lastOffsetY {
                emit(for: view, offsetY: offsetY)
                item.lastOffsetY = offsetY
            }
            stillAlive.append(item)
        }
        tracked = stillAlive
        stopIfEmpty()
    }

    private func emit(for view: UIScrollView, offsetY: CGFloat) {
        // adjustedContentInset을 반영한 실제 스크롤 가능 영역 기준으로 깊이 계산.
        let inset = view.adjustedContentInset
        let viewport = max(0, view.bounds.height - inset.top - inset.bottom)
        let depth = Normalization.scrollDepth(
            offsetY: Double(offsetY + inset.top),
            contentHeight: Double(view.contentSize.height),
            viewportHeight: Double(viewport)
        )
        let refSize = view.window?.bounds.size ?? view.bounds.size
        let orientation = DeviceInfo.orientation(
            width: Double(refSize.width), height: Double(refSize.height))
        pipeline?.recordScroll(
            depth: depth, offsetY: Double(offsetY),
            screenW: Double(refSize.width), screenH: Double(refSize.height),
            device: DeviceInfo.modelIdentifier, orientation: orientation
        )
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
#endif
