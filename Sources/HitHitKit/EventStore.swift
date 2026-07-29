import Foundation
import HitHitCore

/// JSONL 파일 기반 임시 버퍼. 전용 직렬 큐로 스레드 안전을 보장한다.
///
/// 각 이벤트를 한 줄(JSON + `\n`)로 append하고, 배치 로드/삭제를 지원한다.
/// 전송 실패 시 삭제하지 않으므로 다음 전송에서 재시도된다(실패 로컬 보존).
/// `count()`는 매 이벤트마다 호출될 수 있어 **캐시로 O(1)** 유지(파일 재파싱 금지).
final class EventStore: EventBuffering {

    private let queue = DispatchQueue(label: "co.finda.hithit.store")
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fm = FileManager.default
    private var cachedCount: Int

    init(fileURL: URL) {
        self.fileURL = fileURL
        // 기존 파일이 있으면(앱 재실행 등) 한 번만 라인 수를 센다.
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            self.cachedCount = data.split(separator: 0x0A).count
        } else {
            self.cachedCount = 0
        }
    }

    /// 이벤트 한 건을 파일 끝에 append. **쓰기 성공 시에만** 카운트를 올린다.
    func append(_ event: HitHitEvent) {
        queue.sync {
            guard var data = try? encoder.encode(event) else { return }
            data.append(0x0A) // "\n"
            guard writeAppending(data) else { return }  // 실패 시 카운트 증가 안 함
            cachedCount += 1
        }
    }

    /// 현재 저장된 이벤트 수 (O(1) 캐시).
    func count() -> Int {
        queue.sync { cachedCount }
    }

    /// 앞에서부터 최대 `max` **라인**을 스캔해 (디코딩된 이벤트, 스캔한 raw 라인 수)를 반환.
    ///
    /// 디코딩 실패(잘림/손상) 라인은 events에서 빠지지만 `lineCount`에는 포함된다 →
    /// 호출자가 `removeFirst(lineCount)`로 지우면 손상 라인도 함께 정리돼 정렬 어긋남/중복 전송이 없다.
    func loadSpan(max: Int) -> (events: [HitHitEvent], lineCount: Int) {
        queue.sync {
            let span = Array(lines().prefix(max))
            let events = span.compactMap { try? decoder.decode(HitHitEvent.self, from: $0) }
            return (events, span.count)
        }
    }

    /// 앞에서부터 `n` **라인** 제거(전송 성공분 + 그 사이 손상 라인).
    func removeFirst(_ n: Int) {
        queue.sync {
            let remaining = Array(lines().dropFirst(n))
            cachedCount = remaining.count
            guard !remaining.isEmpty else {
                try? fm.removeItem(at: fileURL)
                return
            }
            var joined = Data()
            for line in remaining {
                joined.append(line)
                joined.append(0x0A)
            }
            try? joined.write(to: fileURL, options: .atomic)
        }
    }

    /// 전체 삭제.
    func clear() {
        queue.sync {
            try? fm.removeItem(at: fileURL)
            cachedCount = 0
        }
    }

    // MARK: - File helpers (큐 내부에서만 호출)

    /// 파일 끝에 append. 성공 여부 반환.
    private func writeAppending(_ data: Data) -> Bool {
        if fm.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        } else {
            return (try? data.write(to: fileURL, options: .atomic)) != nil
        }
    }

    /// 파일을 줄 단위 Data 배열로.
    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }
}
