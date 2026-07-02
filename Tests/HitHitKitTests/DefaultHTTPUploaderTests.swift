import Testing
import Foundation
@testable import HitHitKit
@testable import HitHitCore

/// URLProtocol 스텁 — 요청마다 스크립트된 상태코드를 반환한다.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCodes: [Int] = [200]
    nonisolated(unsafe) static var callCount = 0
    private static let lock = NSLock()

    static func reset(_ codes: [Int]) {
        lock.lock(); defer { lock.unlock() }
        statusCodes = codes
        callCount = 0
    }
    static func currentCallCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return callCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let idx = min(Self.callCount, Self.statusCodes.count - 1)
        let code = Self.statusCodes[idx]
        Self.callCount += 1
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 정적 스텁 상태를 공유하므로 직렬 실행.
@Suite(.serialized) struct DefaultHTTPUploaderTests {

    private func makeUploader(maxRetries: Int) -> DefaultHTTPUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return DefaultHTTPUploader(
            endpoint: URL(string: "https://example.com/hitmap")!,
            headers: ["X-Api-Key": "test"],
            session: URLSession(configuration: config),
            maxRetries: maxRetries,
            backoff: { _ in 0 })   // 테스트 가속
    }

    private func upload(_ uploader: DefaultHTTPUploader) async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            uploader.upload(batch: Data("[]".utf8)) { cont.resume(returning: $0) }
        }
    }

    @Test func succeedsOnFirstTry() async {
        StubURLProtocol.reset([200])
        let result = await upload(makeUploader(maxRetries: 3))
        #expect(result.isSuccess)
        #expect(StubURLProtocol.currentCallCount() == 1)
    }

    @Test func retriesThenSucceeds() async {
        StubURLProtocol.reset([500, 500, 200])
        let result = await upload(makeUploader(maxRetries: 3))
        #expect(result.isSuccess)
        #expect(StubURLProtocol.currentCallCount() == 3)   // 500 두 번 후 3번째 200
    }

    @Test func failsAfterExhaustingRetries() async {
        StubURLProtocol.reset([500])
        let result = await upload(makeUploader(maxRetries: 2))
        #expect(result.isFailure)
        if case .failure(let error) = result {
            #expect((error as? HitHitError)?.code == .uploadFailed)
        }
        #expect(StubURLProtocol.currentCallCount() == 3)   // 최초 1 + 재시도 2
    }
}
