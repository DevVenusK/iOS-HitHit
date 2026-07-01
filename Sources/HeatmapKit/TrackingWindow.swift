#if canImport(UIKit)
import UIKit
import HeatmapCore

/// 전역 탭 인터셉트용 `UIWindow` 서브클래스.
///
/// 터치를 `.began`에서 저장하고 **`.ended`에서 이동 거리가 작을 때만 탭으로 기록**한다.
/// 이렇게 해야 스크롤/드래그의 시작 터치가 탭으로 오검출되지 않는다(스크롤은 `ScrollTracker`가 담당).
/// 항상 `super.sendEvent`를 호출해 실제 터치 처리에는 영향을 주지 않는다.
/// 메인스레드 작업은 좌표 계산 + enqueue로 최소화한다(성능 예산).
public final class TrackingWindow: UIWindow {

    /// 탭으로 인정할 이동 허용치(pt). 기본값은 `TouchClassifier.defaultTapSlop`.
    public var tapSlop: Double = TouchClassifier.defaultTapSlop

    private var beganLocations: [ObjectIdentifier: CGPoint] = [:]

    public override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touches = event.allTouches {
            for touch in touches {
                handle(touch)
            }
        }
        super.sendEvent(event) // 원래 동작 보존
    }

    private func handle(_ touch: UITouch) {
        let key = ObjectIdentifier(touch)
        switch touch.phase {
        case .began:
            beganLocations[key] = touch.location(in: self)
            // 스크롤뷰 안에서 시작된 터치면 그 스크롤뷰를 자동 등록(스위즐 아님).
            HeatmapCollector.shared.noteTouch(on: touch.view)
        case .ended:
            defer { beganLocations[key] = nil }
            guard let start = beganLocations[key] else { return }
            let end = touch.location(in: self)
            guard TouchClassifier.isTap(
                fromX: Double(start.x), fromY: Double(start.y),
                toX: Double(end.x), toY: Double(end.y),
                threshold: tapSlop
            ) else { return }   // 많이 움직임 → 스크롤/드래그, 무시
            HeatmapCollector.shared.handleTap(at: start, in: self)
        case .cancelled:
            beganLocations[key] = nil
        default:
            break
        }
    }
}

extension UIView {
    /// superview 체인을 올라가며 가장 가까운 `UIScrollView`를 찾는다.
    func enclosingScrollView() -> UIScrollView? {
        var view: UIView? = self
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}
#endif
