import Foundation
import HeatmapCore

/// 수집·전송 동작을 제어하는 설정.
public struct HeatmapConfig {

    /// **서버 엔드포인트(수집 데이터 전송 대상 URL).** 데이터의 원본은 이 서버다.
    public var endpoint: URL
    /// 전송 요청에 실을 헤더(인증 등).
    public var headers: [String: String]
    /// 수집에서 제외할 화면 이름(민감화면). 탭·스크롤 모두 차단.
    public var excludedScreens: Set<String>
    /// 0...1. 1.0이면 전량 수집. 미만이면 확률적 샘플링.
    public var samplingRate: Double
    /// 스크롤 샘플링 주파수(Hz). 기본 10.
    public var scrollSampleHz: Int
    /// 서버 전송 전략. 기본 `.immediate`(발생 즉시 전송, 로컬은 실패 대비 임시 버퍼).
    public var uploadStrategy: HeatmapUploadStrategy
    /// 실패/오프라인 대비 임시 버퍼 위치. nil이면 앱 caches.
    public var storageDirectory: URL?
    /// 커스텀 전송기. nil이면 내장 HTTP 전송기 사용.
    public var uploader: HeatmapUploader?

    public init(endpoint: URL) {
        self.endpoint = endpoint
        self.headers = [:]
        self.excludedScreens = []
        self.samplingRate = 1.0
        self.scrollSampleHz = 10
        self.uploadStrategy = .immediate
        self.storageDirectory = nil
        self.uploader = nil
    }
}
