import Foundation
import XCTest
@testable import MacdroKit

private final class BenchTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class TLSStreamingBenchmarkTests: XCTestCase {
    private var directory: URL!
    private var server: MacdroServer!
    private var store: SessionStore!
    private var tlsSession: URLSession!
    private var httpSession: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(token: "bench-token")
        tlsSession = URLSession(
            configuration: .ephemeral,
            delegate: BenchTrustDelegate(),
            delegateQueue: nil
        )
        httpSession = URLSession(configuration: .ephemeral)
        let configuration = MacdroServerConfiguration(
            identityDirectory: directory.appendingPathComponent("identity")
        )
        server = MacdroServer(
            store: store,
            host: "0.0.0.0",
            port: 0,
            uploadDirectory: directory.appendingPathComponent("uploads"),
            configuration: configuration
        )
        try server.start()
    }

    override func tearDownWithError() throws {
        tlsSession?.invalidateAndCancel()
        httpSession?.invalidateAndCancel()
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func download(url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    private func primeCookie(session: URLSession, scheme: String, port: Int) async throws {
        let index = URL(string: "\(scheme)://127.0.0.1:\(port)/s/\(store.token)/")!
        _ = try await session.data(from: index)
    }

    func testTLSStreamingThroughputVsLoopback() async throws {
        let size = 64 * 1024 * 1024
        let payload = Data(repeating: 0x5A, count: size)
        let source = directory.appendingPathComponent("bench.bin")
        try payload.write(to: source)
        let file = SharedFile(
            sourcePath: source.path,
            relativePath: "bench.bin",
            size: UInt64(payload.count),
            contentType: "application/octet-stream"
        )
        store.add([file])

        try await primeCookie(session: tlsSession, scheme: "https", port: server.lanPort)
        try await primeCookie(session: httpSession, scheme: "http", port: server.port)

        let lanTLS = URL(string: "https://127.0.0.1:\(server.lanPort)/f/\(file.id.uuidString.lowercased())")!
        var start = Date()
        let tlsData = try await download(url: lanTLS, session: tlsSession)
        let tlsSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(tlsData.count, payload.count)
        XCTAssertEqual(tlsData, payload)

        let loopback = URL(string: "http://127.0.0.1:\(server.port)/f/\(file.id.uuidString.lowercased())")!
        start = Date()
        let httpData = try await download(url: loopback, session: httpSession)
        let httpSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(httpData.count, payload.count)
        XCTAssertEqual(httpData, payload)

        let mb = Double(size) / (1024 * 1024)
        print(
            String(
                format: "BENCH 64 MiB: LAN TLS %.1f MB/s (%.3fs) | loopback HTTP %.1f MB/s (%.3fs)",
                mb / tlsSeconds, tlsSeconds,
                mb / httpSeconds, httpSeconds
            )
        )
    }
}
