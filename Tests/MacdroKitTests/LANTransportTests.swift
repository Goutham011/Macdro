import Foundation
import XCTest
@testable import MacdroKit

private final class PlainTransportTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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

final class LANTransportTests: XCTestCase {
    private var directory: URL!
    private var server: MacdroServer!
    private var store: SessionStore!
    private var tlsSession: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroTransport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(token: "transport-token")
        tlsSession = URLSession(
            configuration: .ephemeral,
            delegate: PlainTransportTrustDelegate(),
            delegateQueue: nil
        )
    }

    override func tearDownWithError() throws {
        tlsSession?.invalidateAndCancel()
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeServer(lanUsesTLS: Bool) throws -> MacdroServer {
        let configuration = MacdroServerConfiguration(
            identityDirectory: directory.appendingPathComponent("identity"),
            lanUsesTLS: lanUsesTLS
        )
        let server = MacdroServer(
            store: store,
            host: "0.0.0.0",
            port: 0,
            uploadDirectory: directory.appendingPathComponent("uploads"),
            configuration: configuration
        )
        try server.start()
        return server
    }

    private func status(
        _ url: URL,
        session: URLSession,
        timeout: TimeInterval = 5
    ) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private func cookieHeader(_ url: URL, session: URLSession) async throws -> String? {
        let (_, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "Set-Cookie")
    }

    private func body(_ url: URL, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

    func testDefaultLANTransportIsTLS() async throws {
        server = try makeServer(lanUsesTLS: true)

        XCTAssertGreaterThan(server.lanPort, 0)
        XCTAssertTrue(server.lanIsSecure)
        XCTAssertEqual(server.lanURLBase?.scheme, "https")
        XCTAssertNotNil(server.tlsIdentity)
        XCTAssertNotNil(server.tlsFingerprint)
        XCTAssertNotNil(server.caFingerprint)

        let health = URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
        let tlsHealth = await status(health, session: tlsSession)
        XCTAssertEqual(tlsHealth, 200)

        let plaintext = URL(string: "http://127.0.0.1:\(server.lanPort)/health")!
        let plainHealth = await status(plaintext, session: URLSession.shared)
        XCTAssertNil(plainHealth)

        let index = URL(string: "https://127.0.0.1:\(server.lanPort)/s/\(store.token)/")!
        let cookie = try await cookieHeader(index, session: tlsSession)
        XCTAssertEqual(cookie?.contains("macdro_session="), true)
        XCTAssertEqual(cookie?.contains("; Secure"), true)

        let tlsBody = try await body(index, session: tlsSession)
        XCTAssertTrue(tlsBody.contains("Encrypted transfer on your local network."))
        XCTAssertFalse(tlsBody.contains("Easy mode: connections are not encrypted in transit."))
    }

    func testEasyModeServesPlainHTTP() async throws {
        server = try makeServer(lanUsesTLS: false)

        XCTAssertGreaterThan(server.lanPort, 0)
        XCTAssertFalse(server.lanIsSecure)
        XCTAssertEqual(server.lanURLBase?.scheme, "http")
        XCTAssertNil(server.tlsIdentity)
        XCTAssertNil(server.tlsFingerprint)
        XCTAssertNil(server.caFingerprint)

        let health = URL(string: "http://127.0.0.1:\(server.lanPort)/health")!
        let plainHealth = await status(health, session: URLSession.shared)
        XCTAssertEqual(plainHealth, 200)

        let tlsRequest = URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
        let tlsHealth = await status(tlsRequest, session: tlsSession)
        XCTAssertNil(tlsHealth)

        let index = URL(string: "http://127.0.0.1:\(server.lanPort)/s/\(store.token)/")!
        let cookie = try await cookieHeader(index, session: URLSession.shared)
        XCTAssertEqual(cookie?.contains("macdro_session="), true)
        XCTAssertEqual(cookie?.contains("; Secure"), false)
    }

    func testSetLANTransportRebindsListener() async throws {
        server = try makeServer(lanUsesTLS: true)
        let originalPort = server.lanPort

        server.setLANTransport(useTLS: false)
        XCTAssertFalse(server.lanIsSecure)
        XCTAssertNil(server.tlsIdentity)
        XCTAssertEqual(server.lanURLBase?.scheme, "http")
        let httpHealth = URL(string: "http://127.0.0.1:\(server.lanPort)/health")!
        let plainHealth = await status(httpHealth, session: URLSession.shared)
        XCTAssertEqual(plainHealth, 200)
        let deadTLS = URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
        let deadTLSHealth = await status(deadTLS, session: tlsSession)
        XCTAssertNil(deadTLSHealth)

        server.setLANTransport(useTLS: true)
        XCTAssertTrue(server.lanIsSecure)
        XCTAssertNotNil(server.tlsIdentity)
        XCTAssertEqual(server.lanURLBase?.scheme, "https")
        let restoredTLS = URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
        let restoredHealth = await status(restoredTLS, session: tlsSession)
        XCTAssertEqual(restoredHealth, 200)
        XCTAssertGreaterThan(server.lanPort, 0)
        XCTAssertNotEqual(server.port, server.lanPort)
        XCTAssertNotEqual(originalPort, 0)
    }

    func testFooterWordingMatchesTransport() async throws {
        server = try makeServer(lanUsesTLS: false)

        let plainIndex = URL(string: "http://127.0.0.1:\(server.lanPort)/s/\(store.token)/")!
        let plainBody = try await body(plainIndex, session: URLSession.shared)
        XCTAssertTrue(plainBody.contains("Easy mode: connections are not encrypted in transit."))
        XCTAssertFalse(plainBody.contains("Encrypted transfer on your local network."))

        let loopbackIndex = URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/")!
        let loopbackBody = try await body(loopbackIndex, session: URLSession.shared)
        XCTAssertTrue(loopbackBody.contains("Encrypted transfer on your local network."))
        XCTAssertFalse(loopbackBody.contains("Easy mode: connections are not encrypted in transit."))
    }
}
