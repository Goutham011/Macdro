import CryptoKit
import Darwin
import Foundation
import NIOSSL
import XCTest
@testable import MacdroKit

private final class InsecureTestTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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

private final class SSEProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let firstEvent = XCTestExpectation(description: "SSE first event")
    let heartbeat = XCTestExpectation(description: "SSE heartbeat")
    let finished = XCTestExpectation(description: "SSE stream closed")
    private let lock = NSLock()
    private var buffer = Data()
    private var sawFirst = false
    private var sawHeartbeat = false

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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        buffer.append(data)
        let text = String(decoding: buffer, as: UTF8.self)
        let first = !sawFirst && text.contains("data:")
        let keepAlive = !sawHeartbeat && text.contains(": keep-alive")
        if first { sawFirst = true }
        if keepAlive { sawHeartbeat = true }
        lock.unlock()
        if first { firstEvent.fulfill() }
        if keepAlive { heartbeat.fulfill() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finished.fulfill()
    }
}

final class SecurityHardeningTests: XCTestCase {
    private func rawRequest(port: Int, head: String, timeout: TimeInterval = 3) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let request = Data(head.utf8)
        _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, request.count, 0) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        return response
    }

    private var directory: URL!
    private var server: MacdroServer!
    private var store: SessionStore!
    private var identityManager: TLSIdentityManager!
    private var trustedSession: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroSecurity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        identityManager = TLSIdentityManager(directory: directory.appendingPathComponent("identity"))
        store = SessionStore(token: "security-token")
        let configuration = MacdroServerConfiguration(identityDirectory: identityManager.directory)
        server = MacdroServer(
            store: store,
            host: "0.0.0.0",
            port: 0,
            uploadDirectory: directory.appendingPathComponent("uploads"),
            configuration: configuration
        )
        try server.start()
        trustedSession = URLSession(
            configuration: .ephemeral,
            delegate: InsecureTestTrustDelegate(),
            delegateQueue: nil
        )
    }

    override func tearDownWithError() throws {
        trustedSession?.invalidateAndCancel()
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private var httpsBase: URL {
        URL(string: "https://127.0.0.1:\(server.lanPort)/s/\(store.token)/")!
    }

    func testLoopbackHTTPAndLANHTTPSAreSeparate() async throws {
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertGreaterThan(server.lanPort, 0)
        XCTAssertNotEqual(server.port, server.lanPort)

        let (loopbackData, loopbackResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/health")!
        )
        XCTAssertEqual((loopbackResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: loopbackData, as: UTF8.self), "ok\n")

        let (tlsData, tlsResponse) = try await trustedSession.data(
            from: URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
        )
        XCTAssertEqual((tlsResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: tlsData, as: UTF8.self), "ok\n")

        var plaintext = URLRequest(url: URL(string: "http://127.0.0.1:\(server.lanPort)/health")!)
        plaintext.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: plaintext)
            XCTFail("Plaintext request unexpectedly succeeded on the LAN TLS port")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testLANHTTPSFileDownloadReturnsFullBody() async throws {
        let payload = Data(repeating: 0x42, count: 2 * 1024 * 1024 + 123)
        let source = directory.appendingPathComponent("large.bin")
        try payload.write(to: source)
        let file = SharedFile(
            sourcePath: source.path,
            relativePath: "large.bin",
            size: UInt64(payload.count),
            contentType: "application/octet-stream"
        )
        store.add([file])

        var request = URLRequest(
            url: httpsBase.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        )
        request.timeoutInterval = 15
        let (data, response) = try await trustedSession.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "\(payload.count)")
        XCTAssertEqual(data, payload)

        var rangeRequest = URLRequest(url: request.url!)
        rangeRequest.setValue("bytes=100-999", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await trustedSession.data(for: rangeRequest)
        let rangeHTTP = try XCTUnwrap(rangeResponse as? HTTPURLResponse)
        XCTAssertEqual(rangeHTTP.statusCode, 206)
        XCTAssertEqual(rangeHTTP.value(forHTTPHeaderField: "Content-Range"), "bytes 100-999/\(payload.count)")
        XCTAssertEqual(rangeData, payload.subdata(in: 100..<1000))

        let (zipData, zipResponse) = try await trustedSession.data(
            from: httpsBase.appendingPathComponent("api/zip")
        )
        XCTAssertEqual((zipResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(Array(zipData.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    }

    func testCertificateIsCAIssuedAndFingerprintMatches() throws {
        let identity = try identityManager.identity(for: ["127.0.0.1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: identity.caCertificateURL.path))
        XCTAssertTrue(identity.subjectAlternativeNames.contains("127.0.0.1"))
        XCTAssertTrue(identity.fingerprint.contains(":"))

        let leaf = try NIOSSLCertificate.fromPEMFile(identity.certificateURL.path).first
        let der = Data(try XCTUnwrap(leaf).toDERBytes())
        let expected = SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        XCTAssertEqual(identity.fingerprint, expected)
        XCTAssertFalse(identity.caCertificatePEM.isEmpty)

        let profile = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: identity.mobileConfiguration,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        let certificatePayload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(certificatePayload["PayloadType"] as? String, "com.apple.security.root")
        let installedCertificate = try XCTUnwrap(certificatePayload["PayloadContent"] as? Data)

        let ca = try NIOSSLCertificate.fromPEMFile(identity.caCertificateURL.path).first
        let expectedCA = Data(try XCTUnwrap(ca).toDERBytes())
        XCTAssertEqual(installedCertificate, expectedCA)
        XCTAssertEqual(Array(installedCertificate.prefix(2)), [0x30, 0x82])
    }

    func testRootDoesNotLeakTokenOrRedirect() async throws {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(http.value(forHTTPHeaderField: "Location"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(store.token))
    }

    func testSessionJSONDoesNotExposeSessionToken() async throws {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/api/session")!
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["token"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(store.token))
    }

    func testHTTPSReceiverSetsSecureStrictCookie() async throws {
        let (_, response) = try await trustedSession.data(from: httpsBase)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let cookie = try XCTUnwrap(http.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("SameSite=Strict"))
        XCTAssertTrue(cookie.contains("Secure"))
    }

    func testSetupServerServesOnlyCertificateMaterialAndStops() async throws {
        let setup = MacdroSetupServer(
            identityManager: identityManager,
            lifetime: 30
        )
        let port = try setup.start(host: "127.0.0.1")
        defer { setup.stop() }

        let page = URL(string: "http://127.0.0.1:\(port)/setup")!
        let (pageData, pageResponse) = try await URLSession.shared.data(from: page)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: pageData, as: UTF8.self)
        XCTAssertTrue(html.contains("Trust Macdro"))
        XCTAssertTrue(html.contains("Verify this fingerprint"))
        XCTAssertTrue(html.contains("Android CA certificate"))

        let (caData, caResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/ca.crt")!
        )
        XCTAssertEqual((caResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: caData, as: UTF8.self).contains("BEGIN CERTIFICATE"))

        let (profileData, profileResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/ca.mobileconfig")!
        )
        let profileHTTP = try XCTUnwrap(profileResponse as? HTTPURLResponse)
        XCTAssertEqual(profileHTTP.statusCode, 200)
        XCTAssertEqual(
            profileHTTP.value(forHTTPHeaderField: "Content-Type"),
            "application/x-apple-aspen-config"
        )
        let profile = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: profileData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        let payload = try XCTUnwrap(payloads.first)
        let certificate = try XCTUnwrap(payload["PayloadContent"] as? Data)
        XCTAssertEqual(Array(certificate.prefix(2)), [0x30, 0x82])

        let (missing, missingResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/api/session")!
        )
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(String(decoding: missing, as: UTF8.self), "Not found\n")
    }

    func testSSESendsHeartbeatAndClosesOnAuthRotation() async throws {
        let probe = SSEProbe()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: probe,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(
            with: URL(string: "https://127.0.0.1:\(server.lanPort)/s/\(store.token)/api/events")!
        )
        task.resume()
        await fulfillment(of: [probe.firstEvent, probe.heartbeat], timeout: 16)

        _ = store.rotateSessionCookie()
        await fulfillment(of: [probe.finished], timeout: 6)
        XCTAssertTrue(task.error != nil || task.state == .completed)
    }

    func testZipRateLimitReturns429() async throws {
        let fileURL = directory.appendingPathComponent("rate.txt")
        try Data("rate".utf8).write(to: fileURL)
        let file = SharedFile(
            sourcePath: fileURL.path,
            relativePath: "rate.txt",
            size: 4,
            contentType: "text/plain"
        )
        store.add([file])
        let url = URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/api/zip")!

        for index in 0..<MacdroLimits.zipRateLimitPerMinute {
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "ZIP request \(index)")
        }
        let (_, limited) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((limited as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual((limited as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "30")
    }

    func testExpectContinueFailureRespondsBeforeBody() throws {
        let started = Date()
        let head = """
        PUT /s/\(store.token)/api/upload?total=999999999 HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 10485760\r
        Expect: 100-continue\r
        Connection: close\r
        \r

        """
        let response = try rawRequest(port: server.port, head: head)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400"), text)
        XCTAssertFalse(text.contains("100 Continue"))
        XCTAssertTrue(text.lowercased().contains("connection: close"))
    }

    func testClipboardBodyOverOneMiBIsRejected() async throws {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/api/clipboard")!
        )
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: 0x41, count: MacdroLimits.maxClipboardBytes + 1)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    func testSetupServerAutoStopsWithoutDeadlocking() async throws {
        let setup = MacdroSetupServer(identityManager: identityManager, lifetime: 0.4)
        _ = try setup.start(host: "127.0.0.1")
        XCTAssertTrue(setup.isRunning)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(setup.isRunning)
        XCTAssertThrowsError(try setup.start(host: "127.0.0.1"))
        setup.stop()
    }

    func testETagChangesWhenSameSizeFileChangesWithinSecond() async throws {
        let fileURL = directory.appendingPathComponent("mutable.txt")
        try Data("abcdefghij".utf8).write(to: fileURL)
        let originalDate = Date()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
        let file = SharedFile(
            sourcePath: fileURL.path,
            relativePath: "mutable.txt",
            size: 10,
            contentType: "text/plain",
            modifiedAt: originalDate
        )
        store.add([file])

        let url = URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/f/\(file.id.uuidString.lowercased())")!
        let (_, firstResponse) = try await URLSession.shared.data(from: url)
        let etag = try XCTUnwrap((firstResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))

        try Data("ABCDEFGHIJ".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)

        var request = URLRequest(url: url)
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (data, secondResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("ABCDEFGHIJ".utf8))
    }

    func testResumableUploadLimitIsExactUnderConcurrency() throws {
        let uploadStore = UploadStore(
            directory: directory.appendingPathComponent("concurrent"),
            configuration: UploadStore.Configuration(
                maxActiveTransactions: 8,
                maxTransactionsPerClient: 8,
                maxConcurrentTransactions: 32,
                maxConcurrentPerClient: 32,
                quotaBytes: nil
            )
        )
        let lock = NSLock()
        var successes = 0

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            if (try? uploadStore.beginResumable(
                id: "upload-\(index)-\(UUID().uuidString)",
                name: "file-\(index).bin",
                expectedSize: 10,
                offset: 0,
                complete: false,
                client: "same-client"
            )) != nil {
                lock.lock()
                successes += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(successes, 8)
        XCTAssertEqual(uploadStore.activeResumableCount, 8)
    }

    func testIdleResumableSessionsDoNotConsumeActiveUploadSlots() throws {
        let uploadStore = UploadStore(
            directory: directory.appendingPathComponent("idle-resumable"),
            configuration: UploadStore.Configuration(quotaBytes: nil)
        )
        for index in 0..<MacdroLimits.maxResumableUploadsPerClient {
            let id = "idle-\(index)-\(UUID().uuidString)"
            let transaction = try uploadStore.beginResumable(
                id: id,
                name: "idle-\(index).bin",
                expectedSize: 4,
                offset: 0,
                complete: false,
                client: "client"
            )
            try transaction.append(Data("abcd".utf8))
            uploadStore.releaseLease(id: id)
        }
        XCTAssertEqual(uploadStore.activeResumableCount, MacdroLimits.maxResumableUploadsPerClient)

        let regular = try uploadStore.begin(name: "still-works.txt", expectedSize: 3, client: "client")
        try regular.append(Data("yes".utf8))
        _ = try regular.finish()
    }

    func testResumableChunksAreNotCountedAsNewUploads() async throws {
        let id = "chunks-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let total = 130
        for offset in 0..<125 {
            var components = URLComponents(
                url: URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/api/upload")!,
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "uploadId", value: id),
                URLQueryItem(name: "name", value: "chunks.bin"),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "total", value: String(total))
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.httpBody = Data([UInt8(offset % 251)])
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "chunk \(offset)")
        }

        var components = URLComponents(
            url: URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/api/upload")!,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadId", value: id),
            URLQueryItem(name: "name", value: "chunks.bin"),
            URLQueryItem(name: "offset", value: "125"),
            URLQueryItem(name: "total", value: String(total)),
            URLQueryItem(name: "complete", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: 0x42, count: 5)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
    }

    func testQuotaCountsInFlightTemporaryUploads() throws {
        let uploadStore = UploadStore(
            directory: directory.appendingPathComponent("quota"),
            configuration: UploadStore.Configuration(
                quotaBytes: 1_000_000,
                reservedDiskBytes: 0,
                maxUploadBytes: 10_000_000
            )
        )
        let first = try uploadStore.begin(
            name: "first.bin",
            expectedSize: 700_000,
            client: "client"
        )
        try first.append(Data(repeating: 0x41, count: 700_000))

        XCTAssertThrowsError(
            try uploadStore.begin(name: "second.bin", expectedSize: 700_000, client: "client")
        ) { error in
            XCTAssertEqual(error as? UploadError, .insufficientStorage)
        }
        first.cancel()
    }

    func testResumableWriterLeaseAndCompletedTombstone() throws {
        let uploadStore = UploadStore(
            directory: directory.appendingPathComponent("lease"),
            configuration: UploadStore.Configuration(quotaBytes: nil)
        )
        let id = "lease-upload-\(UUID().uuidString)"
        let first = try uploadStore.beginResumable(
            id: id,
            name: "lease.bin",
            expectedSize: 4,
            offset: 0,
            complete: false,
            client: "client-a"
        )
        XCTAssertThrowsError(
            try uploadStore.beginResumable(
                id: id,
                name: "lease.bin",
                expectedSize: 4,
                offset: 0,
                complete: false,
                client: "client-a"
            )
        ) { error in
            XCTAssertEqual(error as? UploadError, .uploadInProgress(offset: 0))
        }

        try first.append(Data("abcd".utf8))
        XCTAssertThrowsError(
            try uploadStore.beginResumable(
                id: id,
                name: "lease.bin",
                expectedSize: 4,
                offset: 4,
                complete: true,
                client: "client-a"
            )
        ) { error in
            XCTAssertEqual(error as? UploadError, .uploadInProgress(offset: 4))
        }

        _ = try first.finish()
        uploadStore.completeResumable(id: id, offset: 4)
        XCTAssertThrowsError(
            try uploadStore.beginResumable(
                id: id,
                name: "lease.bin",
                expectedSize: 4,
                offset: 4,
                complete: true,
                client: "client-a"
            )
        ) { error in
            XCTAssertEqual(error as? UploadError, .uploadCompleted(offset: 4))
        }
    }

    func testManifestAndArchiveSingleFlight() async throws {
        let fileURL = directory.appendingPathComponent("shared.txt")
        try Data("shared".utf8).write(to: fileURL)
        let file = SharedFile(
            sourcePath: fileURL.path,
            relativePath: "shared.txt",
            size: 6,
            contentType: "text/plain"
        )
        let snapshot = SessionSnapshot(token: "token", files: [file], createdAt: Date())
        let manifest = ManifestService()
        let archive = ArchiveService()

        let manifestDone = expectation(description: "manifest requests")
        manifestDone.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            manifest.data(for: snapshot) { result in
                if case .success = result {} else { XCTFail("manifest failed") }
                manifestDone.fulfill()
            }
        }
        await fulfillment(of: [manifestDone], timeout: 10)

        let archiveDone = expectation(description: "archive requests")
        archiveDone.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            archive.archive(for: snapshot) { result in
                if case .success = result {} else { XCTFail("archive failed") }
                archiveDone.fulfill()
            }
        }
        await fulfillment(of: [archiveDone], timeout: 20)
        XCTAssertEqual(manifest.buildCount, 1)
        XCTAssertEqual(archive.buildCount, 1)
    }

    func testUploadNameCannotImpersonateTemporaryFile() {
        let path = UploadStore.requestPath(name: ".macdro-evil.part", relativePath: nil)
        XCTAssertFalse(path.hasPrefix(".macdro-") && path.hasSuffix(".part"))
        XCTAssertEqual(path, "_.macdro-evil.part")
    }

    func testUnicodeFileNameControlsAreNeutralized() {
        let path = UploadStore.requestPath(
            name: "in\u{202E}voice\u{200B}.txt",
            relativePath: nil
        )
        XCTAssertEqual(path, "in_voice_.txt")
        XCTAssertFalse(path.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B })
    }
}
