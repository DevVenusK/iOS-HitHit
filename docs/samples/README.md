# 샘플 이벤트 데이터

`hitmap-example-events.jsonl` — 최상단 README의 예시 히트맵 2장을 만든 데이터.

| | |
|---|---|
| 이벤트 | 31건 (탭 10 · 스크롤 21) |
| 화면 | `HomeMainViewController` (심볼릭 이름, PII 없음) |
| 기기 | `iPhone18,1` · 402×874pt · portrait |
| 형식 | HitHitKit wire format(schemaVersion 1) 한 줄 = 1 이벤트 |

## 재현 방법

렌더러는 별도 저장소 [`hithitkit-server`](../architecture.html)에 있다.

```bash
DATA="file://$(pwd)/docs/samples/hitmap-example-events.jsonl"

# 스크롤 깊이
python3 -m hithitkit hitmap --storage "$DATA" --type scroll \
  --screen HomeMainViewController --device "iPhone18,1" \
  --out docs/images/example-scroll-depth.png

# 탭 × 스크롤 통합
python3 -m hithitkit hitmap --storage "$DATA" --type both --points \
  --screen HomeMainViewController --device "iPhone18,1" \
  --out docs/images/example-tap-scroll-combined.png
```

렌더러는 결정적(deterministic)이다 — 같은 입력이면 **바이트 단위로 같은 PNG**가 나오므로,
위 명령으로 `docs/images/`의 두 파일이 그대로 재생성되는지 확인할 수 있다.

## 이 데이터의 출처 (중요)

**실제 사용자 트래픽이 아니다.** 원래 예시 이미지는 2026-07-01에 렌더링됐는데 그 소스
데이터가 남아있지 않아, 이미지에 적힌 수치로 **역산해 복원**한 것이다.

- **스크롤 깊이 — 정확히 복원됨.** 렌더러의 도달률이
  `reached(frac) = 1 - (depth < frac 인 개수) / n` 이므로, 원본 이미지의 다섯 라벨
  (0%→100%, 25%→81%, 50%→67%, 75%→57%, 100%→43%)을 만족하는 분포를 되돌릴 수 있다.
  21건 = `[0,.25)` 4 · `[.25,.5)` 3 · `[.5,.75)` 2 · `[.75,1)` 3 · `1.0` 9건 → 다섯 값이 원본과 일치.
- **탭 좌표 — 추정값.** 정규화 좌표는 되돌릴 방법이 없어 원본 이미지의 점 위치를 읽어 넣었다.
  겹침 분포는 원본의 강도 관계(상단=넓은 붉은 영역 / 중앙=붉은 코어 / 하단=초록 코어)에 맞췄다.

즉 **그림을 재현하기 위한 데이터**이며, 수집 스키마의 예시로 읽어도 된다.
실제 앱에서 뽑은 데이터로 교체하려면 이 파일만 바꾸고 위 명령을 다시 돌리면 된다.
