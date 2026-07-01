import Foundation
import HeatmapCore

/// JSONL 파일 기반 임시 버퍼. 전용 직렬 큐로 스레드 안전을 보장한다.
///
/// 각 이벤트를 한 줄(JSON + `\n`)로 append하고, 배치 로드/삭제를 지원한다.
/// 전송 실패 시 삭제하지 않으므로 다음 전송에서 재시도된다(실패 로컬 보존).
/// `count()`는 매 이벤트마다 호출될 수 있어 **캐시로 O(1)** 유지(파일 재파싱 금지).
final class EventStore {

    private let queue = DispatchQueue(label: "co.finda.heatmap.store")
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

    /// 이벤트 한 건을 파일 끝에 append.
    func append(_ event: HeatmapEvent) {
        queue.sync {
            guard var data = try? encoder.encode(event) else { return }
            data.append(0x0A) // "\n"
            if fm.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
            cachedCount += 1
        }
    }

    /// 현재 저장된 이벤트 수 (O(1) 캐시).
    func count() -> Int {
        queue.sync { cachedCount }
    }

    /// 앞에서부터 최대 `max`건 디코딩해 반환.
    func loadBatch(max: Int) -> [HeatmapEvent] {
        queue.sync {
            lines().prefix(max).compactMap { try? decoder.decode(HeatmapEvent.self, from: $0) }
        }
    }

    /// 앞에서부터 `n`건 제거(전송 성공분).
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

    /// 파일을 줄 단위 Data 배열로. (큐 내부에서만 호출)
    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }
}
