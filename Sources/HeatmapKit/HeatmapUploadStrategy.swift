import Foundation

/// 이벤트를 서버로 언제 보낼지 정하는 전략.
///
/// 어느 전략이든 로컬 저장은 **영구 저장소가 아니라 전송 실패/오프라인 대비 임시 버퍼**이며,
/// 업로드 성공 즉시 비워진다. 서버가 데이터의 원본(source of truth)이다.
public enum HeatmapUploadStrategy: Equatable {

    /// 이벤트 발생 즉시 서버로 전송한다(기본).
    ///
    /// 전송이 진행 중일 때 들어온 이벤트는 버퍼에 모였다가 다음 드레인에 함께 전송되어
    /// 버스트가 자연스럽게 코얼레싱된다("탭 1번 = 요청 1개"가 아님). 로컬에는 미전송분만 잠깐 남는다.
    case immediate

    /// 배치 전송: 버퍼가 `maxSize`에 도달하거나 `interval`이 지나면 전송한다.
    /// 네트워크/배터리를 아끼는 대신, 전송 전까지 로컬에 더 오래 쌓인다.
    case batched(maxSize: Int, interval: TimeInterval)

    /// 30초 / 500건 배치.
    public static let defaultBatched = HeatmapUploadStrategy.batched(maxSize: 500, interval: 30)
}

extension HeatmapUploadStrategy {
    /// 주기 타이머 간격. `.immediate`도 실패/오프라인분을 주기적으로 재시도하기 위해 스윕한다.
    var timerInterval: TimeInterval {
        switch self {
        case .immediate: return 60          // 재시도 스윕
        case .batched(_, let interval): return max(1, interval)
        }
    }
}
