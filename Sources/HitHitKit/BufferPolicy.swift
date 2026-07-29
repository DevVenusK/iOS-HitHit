import Foundation

/// 임시 버퍼가 무한히 커지지 않도록 **몇 건을 버릴지** 결정하는 **순수 로직**.
///
/// 전송이 계속 실패하는 상황(오프라인 장기화)에서 로컬 JSONL이 끝없이 자라는 것을 막는다.
/// 상태를 인자로만 받아 부수효과 없이 판정한다 → 단독 테스트 가능(`CollectionGate`와 같은 결).
enum BufferPolicy {

    /// 상한 초과 시 남길 목표를 정하는 제수(divisor). 10이면 상한의 90%까지 내려간다.
    static let retainDivisor = 10

    /// 상한을 넘었을 때 **앞(오래된 것)에서 버릴 개수**.
    ///
    /// 초과분만 딱 잘라내면 이후 매 append마다 파일 재작성이 발생하므로,
    /// 상한의 90%까지 내려 여유(headroom)를 만들어 재작성 비용을 분산(amortize)한다.
    ///
    /// - Parameters:
    ///   - count: 현재 버퍼에 쌓인 이벤트 수.
    ///   - max: 허용 상한. **0 이하는 무제한**을 뜻한다.
    /// - Returns: 버릴 개수(0 이상). 상한이 아주 작아도 최소 1건은 남긴다.
    static func overflowDropCount(count: Int, max cap: Int) -> Int {
        guard cap > 0 else { return 0 }          // 무제한
        guard count > cap else { return 0 }
        let target = Swift.max(1, cap - cap / retainDivisor)
        return Swift.max(0, count - target)
    }
}
