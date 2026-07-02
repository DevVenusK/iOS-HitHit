import Foundation
@testable import HitHitKit
@testable import HitHitCore

/// 주입용 가짜 전송기(스레드 안전). 결과 스크립트를 순서대로 반환한다.
final class FakeUploader: HitHitUploader, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedResults: [Result<Void, Error>]
    private var batches: [Data] = []
    private var index = 0

    init(results: [Result<Void, Error>] = [.success(())]) {
        self.scriptedResults = results
    }

    var uploadCount: Int { lock.lock(); defer { lock.unlock() }; return batches.count }

    func upload(batch: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        batches.append(batch)
        let result = index < scriptedResults.count ? scriptedResults[index] : (scriptedResults.last ?? .success(()))
        index += 1
        lock.unlock()
        completion(result)
    }
}

/// 인메모리 이벤트 버퍼(파일 I/O 없이 파이프라인 테스트). POP 덕분에 교체 가능.
final class FakeBuffer: EventBuffering, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HitHitEvent] = []

    func append(_ event: HitHitEvent) { lock.lock(); events.append(event); lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return events.count }
    func loadSpan(max: Int) -> (events: [HitHitEvent], lineCount: Int) {
        lock.lock(); defer { lock.unlock() }
        let span = Array(events.prefix(max))
        return (span, span.count)
    }
    func removeFirst(_ n: Int) { lock.lock(); events.removeFirst(Swift.min(n, events.count)); lock.unlock() }
    func clear() { lock.lock(); events.removeAll(); lock.unlock() }
}

enum TestFiles {
    /// 매 테스트마다 고유한 임시 JSONL 경로.
    static func tempEventFile(_ name: String = "events") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hitmap-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).jsonl")
    }
}

extension HitHitEvent {
    static func stubTap(screen: String = "s") -> HitHitEvent {
        .tap(screen: screen, x: 0.5, y: 0.5, screenW: 390, screenH: 844,
             device: "iPhone15,3", orientation: .portrait, ts: 1)
    }
}

/// 조건이 참이 될 때까지(또는 타임아웃까지) 폴링 대기(비동기 드레인 대기용).
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
    }
}

/// 콜백 기반 flush를 async로 감싸 결과를 반환.
func awaitFlush(_ pipeline: EventPipeline) async -> Result<Void, HitHitError> {
    await withCheckedContinuation { cont in
        pipeline.flush { cont.resume(returning: $0) }
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailure: Bool { !isSuccess }
}
