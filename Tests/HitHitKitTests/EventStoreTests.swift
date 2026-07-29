import Testing
import Foundation
@testable import HitHitKit
@testable import HitHitCore

@Suite struct EventStoreTests {

    @Test func appendIncrementsCount() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        #expect(store.count() == 0)
        store.append(.stubTap())
        store.append(.stubTap())
        #expect(store.count() == 2)
    }

    @Test func loadSpanRespectsMax() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        for _ in 0..<5 { store.append(.stubTap()) }
        #expect(store.loadSpan(max: 3).events.count == 3)
        #expect(store.loadSpan(max: 100).events.count == 5)
    }

    @Test func removeFirstDropsFromFront() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        for i in 0..<5 { store.append(.stubTap(screen: "s\(i)")) }
        store.removeFirst(2)
        let remaining = store.loadSpan(max: 100).events
        #expect(remaining.count == 3)
        #expect(remaining.first?.screen == "s2")
    }

    @Test func roundTripPreservesEvent() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        let original = HitHitEvent.scroll(
            screen: "detail", scrollDepth: 0.65, scrollOffsetY: 1240,
            screenW: 390, screenH: 844, device: "iPhone15,3",
            orientation: .portrait, ts: 99)
        store.append(original)
        #expect(store.loadSpan(max: 1).events.first == original)
    }

    @Test func clearEmptiesStore() {
        let store = EventStore(fileURL: TestFiles.tempEventFile())
        store.append(.stubTap())
        store.clear()
        #expect(store.count() == 0)
    }

    /// H3: 손상 라인이 있어도 라인 단위 정렬로 중복/블록 없음.
    @Test func loadSpanCountsCorruptLinesForAlignment() throws {
        let url = TestFiles.tempEventFile()
        let store = EventStore(fileURL: url)
        store.append(.stubTap(screen: "good"))
        // 앱 강제종료로 잘린 것처럼 손상 라인을 직접 추가
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{corrupt-partial\n".utf8))
        try handle.close()

        let span = store.loadSpan(max: 10)
        #expect(span.events.count == 1)     // 유효 이벤트만 디코딩
        #expect(span.lineCount == 2)        // 손상 라인도 라인 수엔 포함

        store.removeFirst(span.lineCount)
        #expect(store.loadSpan(max: 10).lineCount == 0)   // 손상 라인까지 정리
    }
}
