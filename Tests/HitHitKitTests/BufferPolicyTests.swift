import Testing
import Foundation
@testable import HitHitKit

/// 버퍼 상한 **순수 판정 로직**. `CollectionGate`와 같은 결. 부수효과 없이 "몇 개 버릴까"만 답한다.
@Suite struct BufferPolicyTests {

    @Test func zeroMaxMeansUnlimited() {
        #expect(BufferPolicy.overflowDropCount(count: 1_000_000, max: 0) == 0)
    }

    @Test func negativeMaxMeansUnlimited() {
        #expect(BufferPolicy.overflowDropCount(count: 500, max: -1) == 0)
    }

    @Test func noDropBelowCap() {
        #expect(BufferPolicy.overflowDropCount(count: 9, max: 10) == 0)
    }

    @Test func noDropExactlyAtCap() {
        #expect(BufferPolicy.overflowDropCount(count: 10, max: 10) == 0)
    }

    /// 상한을 넘으면 상한의 90%까지 내려간다 — 매 append마다 파일을 다시 쓰지 않도록
    /// 여유(headroom)를 확보해 재작성 비용을 분산(amortize)한다.
    @Test func dropsDownToNinetyPercentOfCap() {
        // max 10 → target 9. count 11이면 2개 버려 9가 된다.
        #expect(BufferPolicy.overflowDropCount(count: 11, max: 10) == 2)
    }

    @Test func dropsWholeExcessOnLargeOverflow() {
        // count 100, max 10 → target 9 → 91개 버림
        #expect(BufferPolicy.overflowDropCount(count: 100, max: 10) == 91)
    }

    @Test func amortizationHeadroomScalesWithCap() {
        // max 20000 → target 18000 → 2001개 버림(이후 2000건은 재작성 없음)
        #expect(BufferPolicy.overflowDropCount(count: 20_001, max: 20_000) == 2_001)
    }

    /// 상한이 아주 작아도 전부 비우지 않고 최소 1건은 남긴다.
    @Test func tinyCapStillKeepsOneEvent() {
        #expect(BufferPolicy.overflowDropCount(count: 5, max: 1) == 4)
    }

    @Test func neverReturnsNegative() {
        #expect(BufferPolicy.overflowDropCount(count: 0, max: 10) == 0)
    }
}
