# SDK Spec: HeatmapKit v1 — 수집 전용 (Collection-Only)

> Status: 확정 (2026-07-01) — 사용자 스코프 재정의 반영. 이 문서가 v1의 권위 스펙이며,
> `heatmapkit.md`의 렌더링(HeatmapViz)·elementID·dwell 관련 부분을 **대체(supersede)**한다.

## 0. 한 줄 정의
호스트 iOS 앱의 **탭·스크롤 이벤트를 정규화 좌표로 수집해 서버로 직접 전송**하는 1st-party SDK.
**히트맵 렌더링은 범위 밖** — 수집된 데이터로 사용자가 직접 히트맵을 만든다.

## 1. 스코프 변경 요약 (이전 스펙 대비)
| 항목 | 이전(heatmapkit.md) | v1 확정 |
|---|---|---|
| 렌더링(HeatmapViz/CoreImage) | 포함 | **삭제** |
| 좌표 | 정규화 + 요소앵커(elementID) | **정규화 0~1만** (elementID 삭제) |
| 스크롤 | dwell(체류시간)+maxDepth | **깊이(offset+0~1)만** |
| 전송 | uploader 프로토콜 주입만 | **내장 직접 전송기**(endpoint URL) |
| 패키지 타겟 | Core/Kit/Viz 3개 | **Core/Kit 2개** (Viz 제거) |
| elementID PII(A4)/법무 L-1~5 | 핵심 이슈 | **대부분 소멸**(elementID 미수집) |

## 2. 데이터 계약 (wire format — semver 핵심)
탭·스크롤 통일 flat 스키마. JSONL 배치 또는 JSON 배열로 전송.

```json
{
  "schemaVersion": 1,
  "id": "9F2A…",            // 이벤트 UUID — 서버 측 멱등 dedup(ACK 유실 재시도 대비)
  "type": "tap",            // "tap" | "scroll"
  "screen": "loan_detail",  // 화면 이름(문자열). 매핑은 사용자가 나중에.
  "x": 0.42,                // tap: 정규화 0~1 (window 화면 bounds 기준). scroll: 생략/null
  "y": 0.73,                // tap: 정규화 0~1. scroll: 생략/null
  "scrollDepth": null,      // scroll: 정규화 깊이 0~1. tap: 생략/null
  "scrollOffsetY": null,    // scroll: 원본 contentOffset.y(참고). tap: 생략/null
  "screenW": 390,           // 정규화 기준 화면 폭(pt)
  "screenH": 844,           // 정규화 기준 화면 높이(pt)
  "device": "iPhone15,3",   // 기기 식별자(machine)
  "orientation": "portrait",// "portrait" | "landscape"
  "ts": 1719800000000       // epoch milliseconds
}
```

- **정규화 기준**: 탭은 **window(전체 화면) bounds** 기준 0~1(화면마다 안정적으로 동일). `screenW/H`는 그 화면 크기. child/컨테이너 VC에 따라 기준이 바뀌지 않도록 화면 단위로 고정.
- **스크롤 깊이**: `scrollDepth = contentOffset.y / max(1, contentSize.height - bounds.height)`, 0~1 clamp.
- **forward-compat**: 필드 *추가*는 옵셔널이면 non-breaking(schemaVersion 유지). 의미변경/삭제만 schemaVersion++.

## 3. Public API (최소 표면)
```swift
public final class HeatmapCollector {
    public static let shared: HeatmapCollector
    public func start(config: HeatmapConfig) throws
    public func stop()
    public var isRunning: Bool { get }

    public func setConsent(_ granted: Bool)   // 기본 OFF
    public var hasConsent: Bool { get }

    public func setScreen(_ name: String)      // 현재 화면 이름 설정
    public func clearScreen()

    public func track(scrollView: UIScrollView)   // 비스위즐 명시 등록(기본)
    public func untrack(scrollView: UIScrollView)

    public func flush(completion: ((Result<Void, HeatmapError>) -> Void)?)
}

public struct HeatmapConfig {
    public var endpoint: URL                  // 서버 URL(데이터 원본 전송 대상)
    public var headers: [String: String]      // 인증 등
    public var excludedScreens: Set<String>   // 민감화면 제외
    public var samplingRate: Double           // 0...1, 기본 1.0
    public var scrollSampleHz: Int            // 기본 10
    public var uploadStrategy: HeatmapUploadStrategy  // 기본 .immediate
    public var storageDirectory: URL?         // 실패/오프라인 임시 버퍼 위치
    public var uploader: HeatmapUploader?     // nil이면 내장 전송기 사용
    public init(endpoint: URL)
}

public enum HeatmapUploadStrategy: Equatable {
    case immediate                                    // 발생 즉시 전송(기본), 버스트 코얼레싱
    case batched(maxSize: Int, interval: TimeInterval)// 배치 전송(절약)
}

public protocol HeatmapUploader: AnyObject { // 커스텀 전송 원하면 주입
    func upload(batch: Data, completion: @escaping (Result<Void, Error>) -> Void)
}

public struct HeatmapError: Error, Equatable, Sendable {  // struct+code (CTO 조건)
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let notConfigured      = Code(rawValue: 1)
        public static let alreadyRunning     = Code(rawValue: 2)
        public static let consentNotGranted  = Code(rawValue: 3)
        public static let storageUnavailable = Code(rawValue: 4)
        public static let encodingFailed     = Code(rawValue: 5)
        public static let uploadFailed       = Code(rawValue: 6)
    }
    public let code: Code
    public let message: String
    public let underlying: Error?
}
```

## 4. 내장 전송기 (Direct Sender)
- **서버가 데이터 원본.** 로컬 JSONL은 영구 저장소가 아니라 전송 실패/오프라인 대비 임시 버퍼이며, 전송 성공 즉시 비워진다.
- **`.immediate`(기본)**: 이벤트 발생 즉시 `endpoint`로 POST. 전송 중 들어온 이벤트는 코얼레싱되어 다음 드레인에 함께 전송(탭 1번=요청 1개 아님). 남은 버퍼는 성공 시 계속 드레인.
- **`.batched(maxSize:interval:)`**: 버퍼가 maxSize 도달 또는 interval 경과 시 POST.
- `URLSession` 기반, 지수 백오프 재시도, 실패 시 로컬 보존 → 60초 재시도 스윕 또는 다음 이벤트/`flush()`에서 재전송.
- 한 요청당 최대 500건(`uploadChunkSize`). 앱 백그라운드 진입 시 `flush()` 권장.
- `config.uploader` 주입 시 내장 전송 대신 그걸 사용.

## 5. 성능 예산 (유지)
| 항목 | 목표 |
|---|---|
| 터치당 메인스레드 | < 0.5ms (정규화 좌표계산 + 큐 enqueue만) |
| 인코딩/디스크 IO/네트워크 | 100% 백그라운드 큐 |
| 스크롤 10Hz 샘플링 메인 점유 | < 1% |

## 6. 프라이버시 / 안전성 (금융 floor, 유지)
- **동의 = 마스터 스위치, 기본 OFF**, 수집 차단. "동의 OFF ⇒ 이벤트 0건" 회귀테스트 = 릴리즈 게이트.
- **동의 철회 시**: 신규 수집 중단 + 미전송 버퍼 업로드도 중단(재동의 시 재개). `purgePendingEvents()`로 하드 삭제.
- **멀티 씬 한계**: 단일 전역 `currentScreen` → iPad multi-window에서 라벨 혼선 가능(단일 씬은 무관). 향후 씬별 상태 분리.
- **로컬 버퍼 미암호화**(caches 평문, 전송 성공 시 삭제) — 필요 시 `storageDirectory`를 보호 경로로.
- **민감화면 제외**(`excludedScreens`): 제외 화면은 탭·스크롤 모두 미수집.
- **콘텐츠 비수집 불변식**: 좌표·화면이름·시간만. 텍스트/입력값 절대 미수집. (elementID도 미수집 → PII 경로 제거)
- **PrivacyInfo.xcprivacy**: **권장(선택) 산출물 — 1.0 필수 아님**(정정 2026-07-01).
  현재 코드는 Required Reason API(`UserDefaults`/파일 타임스탬프/`systemUptime`/디스크용량 등)를 **미사용**하므로 App Store 자동 리젝 대상이 아니다.
  데이터 수집 신고는 매니페스트 없이도 **호스트 앱의 App Privacy 라벨**로 처리 가능(호스트 책임).
  추가 시 권장값: `NSPrivacyTracking=false`, data category "Product Interaction".
  ⚠️ 향후 캐시를 `UserDefaults`로 바꾸거나 파일 타임스탬프를 읽으면 그때는 required-reason 선언이 **필수**가 된다.
- panic 금지(fatalError/강제 unwrap 없음).
- 전송 대상이 외부 서버이므로, screen 이름에 PII가 들어가지 않도록 호스트 가이드 문서화.

## 7. 패키지 / 빌드
- SwiftPM 2 타겟: `HeatmapCore`(스키마/에러) + `HeatmapKit`(수집+전송). Viz 제거.
- 서드파티 0 의존성(Foundation/UIKit만). iOS 14+, Swift 5.9+.
- CocoaPods podspec은 host-app 인벤토리 확인 후(Later).

## 8. 테스트 전략
- Core: 정규화 좌표(여러 화면크기), scrollDepth 계산, Codable round-trip, schemaVersion forward-compat.
- Kit: 제외화면 필터, 샘플링, **동의OFF=0건(게이트)**, scrollView weak untrack, 배치/재시도.
- 전송: 가짜 endpoint(URLProtocol stub)로 배치 POST·재시도·실패보존 검증.
- 성능: 터치당 <0.5ms 마이크로벤치.

## 9. 미결 / 의존
- window 후킹 방식(교체 vs 런타임 옵저버) — 구현 프로토타입에서 확정. 기본 비스위즐.
- screen 이름 PII 가이드(법무 경량 확인) — elementID 제거로 리스크 크게 축소.

---
작성: SDK Team + po-team 스코프 재정의 | 2026-07-01 | 버전 v1.0 (collection-only)
