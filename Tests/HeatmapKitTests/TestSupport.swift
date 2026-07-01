import Foundation
import XCTest
@testable import HeatmapKit
@testable import HeatmapCore

/// 주입용 가짜 전송기(스레드 안전). 결과 스크립트를 순서대로 반환한다.
final class FakeUploader: HeatmapUploader {
    private let lock = NSLock()
    private var scriptedResults: [Result<Void, Error>]
    private var batches: [Data] = []
    private var index = 0

    init(results: [Result<Void, Error>] = [.success(())]) {
        self.scriptedResults = results
    }

    /// 전송된 배치 수(스레드 안전).
    var uploadCount: Int { lock.lock(); defer { lock.unlock() }; return batches.count }
    var uploadedBatches: [Data] { lock.lock(); defer { lock.unlock() }; return batches }

    func upload(batch: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        batches.append(batch)
        let result = index < scriptedResults.count ? scriptedResults[index] : (scriptedResults.last ?? .success(()))
        index += 1
        lock.unlock()
        completion(result)
    }
}

enum TestFiles {
    /// 매 테스트마다 고유한 임시 JSONL 경로.
    static func tempEventFile(_ name: String = "events") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heatmap-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).jsonl")
    }
}

extension HeatmapEvent {
    static func stubTap(screen: String = "s") -> HeatmapEvent {
        .tap(screen: screen, x: 0.5, y: 0.5, screenW: 390, screenH: 844,
             device: "iPhone15,3", orientation: .portrait, ts: 1)
    }
}

extension XCTestCase {
    /// 조건이 참이 될 때까지(또는 타임아웃까지) 런루프를 돌리며 대기.
    /// 비동기 드레인 완료처럼 sync 배리어로 못 잡는 상태를 기다릴 때 사용.
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
