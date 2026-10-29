import Darwin
import Foundation
import JavaScriptCore
import XCTest
@testable import MacdroKit

// MARK: - Helpers

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private final class RotationSSEProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let firstEvent = XCTestExpectation(description: "SSE first event")
    let finished = XCTestExpectation(description: "SSE stream closed")
    private let lock = NSLock()
    private var buffer = Data()
    private var sawFirst = false
    private var sawFinished = false

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        buffer.append(data)
        let ready = !sawFirst && buffer.range(of: Data("data:".utf8)) != nil
        if ready { sawFirst = true }
        lock.unlock()
        if ready { firstEvent.fulfill() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let once = !sawFinished
        sawFinished = true
        lock.unlock()
        if once { finished.fulfill() }
    }
}

private func socketConnect(port: Int, timeout: TimeInterval) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
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
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func socketSend(_ data: Data, fd: Int32) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
            guard written > 0 else { return }
            offset += written
        }
    }
}

private func socketReadUntilClosed(fd: Int32) -> (Data, Bool) {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count > 0 {
            response.append(buffer, count: count)
            continue
        }
        if count == 0 { return (response, true) }
        if errno == EAGAIN || errno == EWOULDBLOCK { return (response, false) }
        return (response, true)
    }
}

private func httpResponseText(_ raw: Data) -> String {
    String(decoding: raw, as: UTF8.self)
}

// MARK: - Tests

final class RemediationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroRemediation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Fixture

    private struct Fixture {
        let server: MacdroServer
        let store: SessionStore
        let directory: URL

        var uploadDirectory: URL {
            directory.appendingPathComponent("uploads", isDirectory: true)
        }

        var tokenBase: URL {
            URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/")!
        }

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(
        files: [(name: String, data: Data)] = [],
        bodyTimeoutPolicy: BodyTimeoutPolicy = BodyTimeoutPolicy(),
        upload: UploadStore.Configuration = UploadStore.Configuration(),
        token: String = "remediation-token"
    ) throws -> Fixture {
        let directory = root
            .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        let uploadDirectory = directory.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var shared: [SharedFile] = []
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: url)
            shared.append(
                SharedFile(
                    sourcePath: url.path,
                    relativePath: file.name,
                    size: UInt64(file.data.count),
                    contentType: "application/octet-stream",
                    modifiedAt: Date()
                )
            )
        }

        let store = SessionStore(token: token)
        store.add(shared)
        let configuration = MacdroServerConfiguration(
            upload: upload,
            bodyTimeoutPolicy: bodyTimeoutPolicy
        )
        let server = MacdroServer(
            store: store,
            host: "127.0.0.1",
            port: 0,
            uploadDirectory: uploadDirectory,
            configuration: configuration
        )
        try server.start()
        return Fixture(server: server, store: store, directory: directory)
    }

    // MARK: BUG-001 — setup server handler isolation

    func testSetupServerInterleavedConnectionsGetIndependentResponses() throws {
        let identityManager = TLSIdentityManager(
            directory: root.appendingPathComponent("identity-bug001")
        )
        let setup = MacdroSetupServer(identityManager: identityManager, lifetime: 60)
        let port = try setup.start(host: "127.0.0.1")
        defer { setup.stop() }

        let fd1 = try XCTUnwrap(socketConnect(port: port, timeout: 5))
        defer { close(fd1) }

        socketSend(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n".utf8), fd: fd1)

        let fd2 = try XCTUnwrap(socketConnect(port: port, timeout: 5))
        defer { close(fd2) }
        socketSend(
            Data("GET /ca.crt HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8),
            fd: fd2
        )
        let (response2, closed2) = socketReadUntilClosed(fd: fd2)
        XCTAssertTrue(closed2, "second client must receive a complete response")
        let text2 = httpResponseText(response2)
        XCTAssertTrue(text2.hasPrefix("HTTP/1.1 200"), text2)
        XCTAssertTrue(text2.contains("BEGIN CERTIFICATE"), text2)

        socketSend(Data("\r\n".utf8), fd: fd1)
        let (response1, closed1) = socketReadUntilClosed(fd: fd1)
        let text1 = httpResponseText(response1)
        XCTAssertTrue(closed1, "first client must complete after its head finishes")
        XCTAssertTrue(text1.hasPrefix("HTTP/1.1 200"), "first client got: \(text1)")
        XCTAssertTrue(text1.contains("ok"), "first client got: \(text1)")
    }

    func testSetupServerConcurrentClientsReceiveCorrectResources() async throws {
        let identityManager = TLSIdentityManager(
            directory: root.appendingPathComponent("identity-concurrent")
        )
        let identity = try identityManager.identity(
            for: NetworkInterfaces.ipv4Addresses().map(\.ipAddress)
        )
        let setup = MacdroSetupServer(identityManager: identityManager, lifetime: 60)
        let port = try setup.start(host: "127.0.0.1")
        defer { setup.stop() }

        let paths = [
            "/health", "/ca.der", "/setup", "/ca.crt",
            "/health", "/ca.mobileconfig", "/ca.crt", "/ca.der",
            "/setup", "/health", "/ca.crt", "/ca.mobileconfig"
        ]
        let results = try await withThrowingTaskGroup(
            of: (Int, Int, Data).self,
            returning: [(path: String, status: Int, body: Data)].self
        ) { group in
            for (index, path) in paths.enumerated() {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
                    let (data, response) = try await URLSession.shared.data(from: url)
                    return (index, (response as? HTTPURLResponse)?.statusCode ?? -1, data)
                }
            }
            var collected: [(path: String, status: Int, body: Data)] = []
            for try await (index, status, data) in group {
                collected.append((path: paths[index], status: status, body: data))
            }
            return collected
        }

        XCTAssertEqual(results.count, paths.count)
        for result in results {
            XCTAssertEqual(result.status, 200, result.path)
            switch result.path {
            case "/health":
                XCTAssertEqual(httpResponseText(result.body), "ok\n")
            case "/ca.der":
                XCTAssertEqual(result.body, try identity.caCertificateDER())
            case "/ca.crt":
                XCTAssertTrue(httpResponseText(result.body).contains("BEGIN CERTIFICATE"))
            case "/ca.mobileconfig":
                let profile = httpResponseText(result.body)
                XCTAssertTrue(
                    profile.hasPrefix("<?xml"),
                    "mobileconfig must be an XML profile, got: \(profile.prefix(80))"
                )
                XCTAssertTrue(profile.contains("Macdro Local CA"))
            case "/setup":
                let html = httpResponseText(result.body)
                XCTAssertTrue(html.contains("Trust Macdro"))
                XCTAssertTrue(html.contains(identity.caFingerprint))
                XCTAssertFalse(html.contains("PRIVATE KEY"))
            default:
                XCTFail("unexpected path \(result.path)")
            }
        }
    }

    func testSetupServerRepeatedAndAbruptlyClosedConnections() throws {
        let identityManager = TLSIdentityManager(
            directory: root.appendingPathComponent("identity-repeat")
        )
        let setup = MacdroSetupServer(identityManager: identityManager, lifetime: 60)
        let port = try setup.start(host: "127.0.0.1")
        defer { setup.stop() }

        for _ in 0..<10 {
            guard let fd = socketConnect(port: port, timeout: 5) else {
                XCTFail("connection refused during repeated requests")
                return
            }
            socketSend(
                Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8),
                fd: fd
            )
            let (response, closed) = socketReadUntilClosed(fd: fd)
            close(fd)
            XCTAssertTrue(closed)
            XCTAssertTrue(httpResponseText(response).contains("HTTP/1.1 200"))
        }

        if let fd = socketConnect(port: port, timeout: 5) {
            socketSend(Data("GET /health HTTP/1.1\r\n".utf8), fd: fd)
            close(fd)
        }

        let fd = try XCTUnwrap(socketConnect(port: port, timeout: 5))
        defer { close(fd) }
        socketSend(
            Data("GET /ca.crt HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8),
            fd: fd
        )
        let (response, closed) = socketReadUntilClosed(fd: fd)
        XCTAssertTrue(closed)
        XCTAssertTrue(httpResponseText(response).contains("BEGIN CERTIFICATE"))
    }

    func testSetupServerStopsPromptlyWithConnectedClients() throws {
        let identityManager = TLSIdentityManager(
            directory: root.appendingPathComponent("identity-stop")
        )
        let setup = MacdroSetupServer(identityManager: identityManager, lifetime: 60)
        let port = try setup.start(host: "127.0.0.1")
        let fd = try XCTUnwrap(socketConnect(port: port, timeout: 5))
        socketSend(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8), fd: fd)

        let stopStarted = Date()
        setup.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStarted), 5)
        XCTAssertFalse(setup.isRunning)
        close(fd)
    }

    // MARK: SEC-001 — absolute body deadline

    private static let shortBodyPolicy = BodyTimeoutPolicy(
        minSeconds: 1,
        maxSeconds: 2,
        chunkedSeconds: 1,
        minimumThroughputBytesPerSecond: 1_000_000
    )

    func testPartialBodyTrickleIsClosedByAbsoluteDeadline() throws {
        let fixture = try fixture(bodyTimeoutPolicy: Self.shortBodyPolicy)
        defer { fixture.stop() }

        let started = Date()
        let fd = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 8))
        defer { close(fd) }

        let head = """
        PUT /s/\(fixture.store.token)/api/upload?name=slow.bin HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 50\r
        Connection: close\r
        \r

        """
        socketSend(Data(head.utf8), fd: fd)
        socketSend(Data("01234".utf8), fd: fd)

        for _ in 0..<5 {
            usleep(300_000)
            socketSend(Data("6789A".utf8), fd: fd)
        }

        let (response, closed) = socketReadUntilClosed(fd: fd)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(closed, "trickling client must be disconnected")
        XCTAssertTrue(
            httpResponseText(response).contains("408"),
            "expected request timeout, got: \(httpResponseText(response))"
        )
        XCTAssertLessThan(elapsed, 6, "deadline must fire well before the read timeout")
    }

    func testTimedOutResumableUploadReleasesLeaseAndResumes() throws {
        let fixture = try fixture(bodyTimeoutPolicy: Self.shortBodyPolicy)
        defer { fixture.stop() }

        let id = "trickle-resume-\(UUID().uuidString.prefix(8))"
        let fd = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 8))
        let head = """
        PUT /s/\(fixture.store.token)/api/upload?uploadId=\(id)&name=resume.bin&offset=0&total=50 HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 50\r
        Connection: close\r
        \r

        """
        socketSend(Data(head.utf8), fd: fd)
        socketSend(Data("01234".utf8), fd: fd)
        usleep(400_000)
        socketSend(Data("56789".utf8), fd: fd)
        let (timeoutResponse, closed) = socketReadUntilClosed(fd: fd)
        close(fd)
        XCTAssertTrue(closed)
        XCTAssertTrue(httpResponseText(timeoutResponse).contains("408"))

        let completeHead = """
        PUT /s/\(fixture.store.token)/api/upload?uploadId=\(id)&name=resume.bin&offset=0&total=50&complete=1 HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 50\r
        Connection: close\r
        \r

        """
        let fd2 = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 8))
        defer { close(fd2) }
        socketSend(Data(completeHead.utf8), fd: fd2)
        socketSend(Data(String(repeating: "x", count: 50).utf8), fd: fd2)
        let (resumeResponse, _) = socketReadUntilClosed(fd: fd2)
        let resumeText = httpResponseText(resumeResponse)
        XCTAssertTrue(
            resumeText.hasPrefix("HTTP/1.1 201"),
            "lease must be released so the upload can resume, got: \(resumeText.prefix(200))"
        )
        let saved = try Data(
            contentsOf: fixture.uploadDirectory.appendingPathComponent("resume.bin")
        )
        XCTAssertEqual(saved.count, 50)
    }

    func testTimedOutNonResumableUploadLeavesNoTemporaryFiles() throws {
        let fixture = try fixture(bodyTimeoutPolicy: Self.shortBodyPolicy)
        defer { fixture.stop() }

        let fd = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 8))
        let head = """
        PUT /s/\(fixture.store.token)/api/upload?name=abandoned.bin HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 40\r
        Connection: close\r
        \r

        """
        socketSend(Data(head.utf8), fd: fd)
        socketSend(Data("0123".utf8), fd: fd)
        usleep(400_000)
        socketSend(Data("4567".utf8), fd: fd)
        let (response, closed) = socketReadUntilClosed(fd: fd)
        close(fd)
        XCTAssertTrue(closed)
        XCTAssertTrue(httpResponseText(response).contains("408"))

        let fm = FileManager.default
        var attempts = 0
        while attempts < 40 {
            let leftovers = ((try? fm.contentsOfDirectory(atPath: fixture.uploadDirectory.path)) ?? [])
                .filter { $0.hasPrefix(".macdro-") && $0.hasSuffix(".part") }
            if leftovers.isEmpty, !(fm.fileExists(atPath: fixture.uploadDirectory.appendingPathComponent("abandoned.bin").path)) {
                break
            }
            attempts += 1
            usleep(50_000)
        }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: fixture.uploadDirectory.path)) ?? [])
            .filter { $0.hasPrefix(".macdro-") && $0.hasSuffix(".part") }
        XCTAssertTrue(leftovers.isEmpty, "timed-out upload must not leak temp files: \(leftovers)")
        XCTAssertFalse(
            fm.fileExists(
                atPath: fixture.uploadDirectory.appendingPathComponent("abandoned.bin").path
            )
        )
    }

    func testBodyCompletingBeforeDeadlineSucceeds() throws {
        let fixture = try fixture(bodyTimeoutPolicy: Self.shortBodyPolicy)
        defer { fixture.stop() }

        var components = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "name", value: "quick.bin")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: 0x41, count: 100)

        let uploadDone = expectation(description: "quick upload completes")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 201 {
                uploadDone.fulfill()
            }
        }.resume()
        wait(for: [uploadDone], timeout: 5)

        let saved = try Data(
            contentsOf: fixture.uploadDirectory.appendingPathComponent("quick.bin")
        )
        XCTAssertEqual(saved.count, 100)
    }

    func testZeroLengthBodyRequestIsNotRejectedByDeadline() throws {
        let fixture = try fixture(bodyTimeoutPolicy: Self.shortBodyPolicy)
        defer { fixture.stop() }

        let fd = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 5))
        defer { close(fd) }
        let head = """
        POST /health HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        socketSend(Data(head.utf8), fd: fd)
        let (response, closed) = socketReadUntilClosed(fd: fd)
        XCTAssertTrue(closed)
        XCTAssertTrue(httpResponseText(response).hasPrefix("HTTP/1.1 200"))
    }

    func testBodyTimeoutPolicyBoundsAndMonotonicity() {
        let policy = BodyTimeoutPolicy(
            minSeconds: 60,
            maxSeconds: 21_600,
            chunkedSeconds: 900,
            minimumThroughputBytesPerSecond: 65_536
        )
        XCTAssertEqual(policy.deadlineSeconds(contentLength: nil), 900)
        XCTAssertEqual(policy.deadlineSeconds(contentLength: 0), 60)
        XCTAssertEqual(policy.deadlineSeconds(contentLength: 1), 60)
        XCTAssertEqual(policy.deadlineSeconds(contentLength: 65_536), 60)
        XCTAssertEqual(policy.deadlineSeconds(contentLength: 16 * 1024 * 1024), 256)
        XCTAssertEqual(policy.deadlineSeconds(contentLength: UInt64.max), 21_600)

        var rng = SplitMix64(seed: 0xB0D_71_5EED)
        var maxLength: UInt64 = 0
        var previous = 0
        for _ in 0..<300 {
            let length: UInt64? = Bool.random(using: &rng)
                ? UInt64.random(in: 0...(1 << 40), using: &rng)
                : nil
            let seconds = policy.deadlineSeconds(contentLength: length)
            XCTAssertGreaterThanOrEqual(seconds, 1)
            XCTAssertLessThanOrEqual(seconds, 21_600)
            if let length, length >= maxLength {
                XCTAssertGreaterThanOrEqual(
                    seconds,
                    previous,
                    "deadline must not shrink as bodies grow (length=\(length))"
                )
                maxLength = length
                previous = seconds
            }
        }
    }

    // MARK: SEC-003 — lease reclamation

    private func leaseFixture(
        idleTimeout: TimeInterval = 900,
        leaseHardTimeout: TimeInterval = 60,
        quota: UInt64? = 1_000_000
    ) throws -> (UploadStore, URL) {
        let directory = root.appendingPathComponent("lease-\(UUID().uuidString)", isDirectory: true)
        let store = UploadStore(
            directory: directory,
            configuration: UploadStore.Configuration(
                idleTimeout: idleTimeout,
                cleanupInterval: 0,
                quotaBytes: quota,
                reservedDiskBytes: 0,
                maxUploadBytes: 10_000_000,
                leaseHardTimeout: leaseHardTimeout
            )
        )
        return (store, directory)
    }

    func testUnleasedExpiredUploadIsStillCleanedUp() throws {
        let (store, directory) = try leaseFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = "unleased-\(UUID().uuidString.prefix(8))"
        let transaction = try store.beginResumable(
            id: id,
            name: "idle.bin",
            expectedSize: 4,
            offset: 0,
            complete: false,
            client: "c1"
        )
        try transaction.append(Data("abcd".utf8))
        store.releaseLease(id: id)

        store.cleanupExpired(now: Date().addingTimeInterval(1_000))
        XCTAssertEqual(store.activeResumableCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
    }

    func testActiveLeaseIsPreservedBeforeHardTimeout() throws {
        let (store, directory) = try leaseFixture(leaseHardTimeout: 60)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = "active-\(UUID().uuidString.prefix(8))"
        let transaction = try store.beginResumable(
            id: id,
            name: "active.bin",
            expectedSize: 4,
            offset: 0,
            complete: false,
            client: "c1"
        )
        store.cleanupExpired(now: Date().addingTimeInterval(59))
        XCTAssertEqual(store.activeResumableCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
    }

    func testLeaseHeldUploadExpiresEvenWhileActivityIsTouched() throws {
        let (store, directory) = try leaseFixture(leaseHardTimeout: 60)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = "drip-\(UUID().uuidString.prefix(8))"
        let transaction = try store.beginResumable(
            id: id,
            name: "drip.bin",
            expectedSize: 4,
            offset: 0,
            complete: false,
            client: "c1"
        )

        for seconds in stride(from: 5, through: 55, by: 5) {
            store.touchResumable(id: id)
            store.cleanupExpired(now: Date().addingTimeInterval(TimeInterval(seconds)))
            XCTAssertEqual(
                store.activeResumableCount,
                1,
                "touching activity must not reap before the hard timeout (t=\(seconds)s)"
            )
        }

        store.cleanupExpired(now: Date().addingTimeInterval(61))
        XCTAssertEqual(
            store.activeResumableCount,
            0,
            "a lease held beyond the hard timeout must be reclaimed"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
    }

    func testReapedLeaseReleasesQuotaForNewUploads() throws {
        let (store, directory) = try leaseFixture(
            idleTimeout: 900,
            leaseHardTimeout: 30,
            quota: 100_000
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = "quota-lease-\(UUID().uuidString.prefix(8))"
        let transaction = try store.beginResumable(
            id: id,
            name: "hold.bin",
            expectedSize: 90_000,
            offset: 0,
            complete: false,
            client: "c1"
        )
        try transaction.append(Data(repeating: 0x42, count: 90_000))

        XCTAssertThrowsError(
            try store.begin(name: "blocked.bin", expectedSize: 90_000, client: "c2")
        ) { error in
            XCTAssertEqual(error as? UploadError, .insufficientStorage)
        }

        store.cleanupExpired(now: Date().addingTimeInterval(31))
        XCTAssertEqual(store.activeResumableCount, 0)
        XCTAssertEqual(store.resumableTemporaryFileCount, 0)

        let next = try store.begin(name: "after.bin", expectedSize: 90_000, client: "c2")
        try next.append(Data(repeating: 0x43, count: 90_000))
        _ = try next.finish()
    }

    // MARK: SEC-002 — authorization before file lookup

    func testBareFileRouteAuthorizesBeforeResolvingExistence() async throws {
        let payload = Data("hello".utf8)
        let fixture = try fixture(files: [("hello.txt", payload)])
        defer { fixture.stop() }

        let knownID = try XCTUnwrap(
            fixture.store.snapshot().files.first?.id.uuidString.lowercased()
        )
        let unknownID = UUID().uuidString.lowercased()
        let invalidID = "not-a-uuid"

        let anonymous = URLSession(configuration: .ephemeral)
        defer { anonymous.invalidateAndCancel() }

        var observed: [String: (status: Int, body: Data)] = [:]
        for (label, id) in [("known", knownID), ("unknown", unknownID), ("invalid", invalidID)] {
            let (data, response) = try await anonymous.data(
                from: URL(string: "http://127.0.0.1:\(fixture.server.port)/f/\(id)")!
            )
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 401, label)
            observed[label] = (http.statusCode, data)
        }
        XCTAssertEqual(observed["known"]?.status, observed["unknown"]?.status)
        XCTAssertEqual(observed["known"]?.body, observed["unknown"]?.body, "401 responses must be identical for known and unknown ids")
        XCTAssertEqual(observed["known"]?.body, Data("Unauthorized\n".utf8))

        let (_, page) = try await anonymous.data(from: fixture.tokenBase)
        XCTAssertEqual((page as? HTTPURLResponse)?.statusCode, 200)

        let (knownData, knownResponse) = try await anonymous.data(
            from: URL(string: "http://127.0.0.1:\(fixture.server.port)/f/\(knownID)")!
        )
        XCTAssertEqual((knownResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(knownData, payload)

        let (unknownData, unknownResponse) = try await anonymous.data(
            from: URL(string: "http://127.0.0.1:\(fixture.server.port)/f/\(unknownID)")!
        )
        XCTAssertEqual((unknownResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(unknownData, Data("Not found\n".utf8))

        var cookieRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(fixture.server.port)/f/\(invalidID)")!
        )
        cookieRequest.setValue(
            "\(SessionStore.cookieName)=\(fixture.store.sessionCookie)",
            forHTTPHeaderField: "Cookie"
        )
        let (invalidData, invalidResponse) = try await anonymous.data(for: cookieRequest)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(invalidData, Data("Not found\n".utf8))
    }

    // MARK: SEC-004 — reserved pattern in every path component

    func testReservedPrefixNeutralizedInEveryPathComponent() {
        XCTAssertEqual(
            UploadStore.requestPath(name: "file.bin", relativePath: ".macdro-evil.part/file.bin"),
            "_.macdro-evil.part/file.bin"
        )
        XCTAssertEqual(
            UploadStore.requestPath(
                name: "file.bin",
                relativePath: "deep/.macdro-a.part/mid/.macdro-b.part/file.bin"
            ),
            "deep/_.macdro-a.part/mid/_.macdro-b.part/file.bin"
        )
        XCTAssertEqual(
            UploadStore.requestPath(name: ".macdro-evil.part", relativePath: nil),
            "_.macdro-evil.part"
        )
        XCTAssertEqual(
            UploadStore.requestPath(name: "file.bin", relativePath: "\\.macdro-c.part\\file.bin"),
            "_.macdro-c.part/file.bin"
        )
    }

    func testReservedPathComponentUploadCreatesNeutralizedDirectory() throws {
        let fixture = try fixture()
        defer { fixture.stop() }

        var components = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: "nested.bin"),
            URLQueryItem(name: "path", value: ".macdro-evil.part/nested.bin")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = Data("payload".utf8)

        let uploadDone = expectation(description: "nested upload completes")
        var receivedStatus = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            receivedStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            uploadDone.fulfill()
        }.resume()
        wait(for: [uploadDone], timeout: 5)
        XCTAssertEqual(receivedStatus, 201)

        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: fixture.uploadDirectory.path)) ?? []
        XCTAssertFalse(entries.contains(".macdro-evil.part"), "reserved directory name must not be created: \(entries)")
        XCTAssertTrue(entries.contains("_.macdro-evil.part"), "neutralized directory expected: \(entries)")
        let saved = try Data(
            contentsOf: fixture.uploadDirectory
                .appendingPathComponent("_.macdro-evil.part/nested.bin")
        )
        XCTAssertEqual(saved, Data("payload".utf8))
    }

    // MARK: BUG-002 — quota reconciliation

    private func quotaFixture(quota: UInt64) throws -> (UploadStore, URL) {
        let directory = root.appendingPathComponent("quota-\(UUID().uuidString)", isDirectory: true)
        let store = UploadStore(
            directory: directory,
            configuration: UploadStore.Configuration(
                idleTimeout: 900,
                cleanupInterval: 0,
                quotaBytes: quota,
                reservedDiskBytes: 0,
                maxUploadBytes: 10_000_000,
                leaseHardTimeout: 60
            )
        )
        return (store, directory)
    }

    func testQuotaRecoversAfterExternalFileDeletion() throws {
        let (store, directory) = try quotaFixture(quota: 1_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.begin(name: "first.bin", expectedSize: 800, client: "c")
        try first.append(Data(repeating: 0x41, count: 800))
        let result = try first.finish()
        XCTAssertEqual(result.size, 800)

        XCTAssertThrowsError(
            try store.begin(name: "second.bin", expectedSize: 300, client: "c")
        ) { error in
            XCTAssertEqual(error as? UploadError, .insufficientStorage)
        }

        try FileManager.default.removeItem(atPath: result.path)

        store.reconcileQuotaNow()

        var second: UploadTransaction?
        for _ in 0..<60 {
            second = try? store.begin(name: "second.bin", expectedSize: 300, client: "c")
            if second != nil { break }
            usleep(50_000)
        }
        let admitted = try XCTUnwrap(
            second,
            "reconciliation must restore quota admission after external deletion"
        )
        try admitted.append(Data(repeating: 0x42, count: 300))
        _ = try admitted.finish()
    }

    func testRepeatedReconciliationDoesNotDoubleDecrement() throws {
        let (store, directory) = try quotaFixture(quota: 100_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.begin(name: "keep.bin", expectedSize: 30_000, client: "c")
        try first.append(Data(repeating: 0x41, count: 30_000))
        let kept = try first.finish()

        store.reconcileQuotaNow()
        store.reconcileQuotaNow()
        store.reconcileQuotaNow()

        let second = try store.begin(name: "next.bin", expectedSize: 55_000, client: "c")
        try second.append(Data(repeating: 0x42, count: 55_000))
        _ = try second.finish()

        store.reconcileQuotaNow()

        XCTAssertThrowsError(
            try store.begin(name: "overflow.bin", expectedSize: 16_000, client: "c")
        ) { error in
            XCTAssertEqual(error as? UploadError, .insufficientStorage)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testReconciliationCountsInFlightTemporaryUploadsExactlyOnce() throws {
        let (store, directory) = try quotaFixture(quota: 300_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let committed = try store.begin(name: "done.bin", expectedSize: 50_000, client: "c")
        try committed.append(Data(repeating: 0x41, count: 50_000))
        _ = try committed.finish()

        let inFlight = try store.begin(name: "pending.bin", expectedSize: 60_000, client: "c")
        try inFlight.append(Data(repeating: 0x42, count: 30_000))

        store.reconcileQuotaNow()

        let next = try store.begin(name: "probe.bin", expectedSize: 150_000, client: "c")
        next.cancel()

        try inFlight.append(Data(repeating: 0x43, count: 30_000))
        _ = try inFlight.finish()

        store.reconcileQuotaNow()
        let final = try store.begin(name: "verify.bin", expectedSize: 100_000, client: "c")
        try final.append(Data(repeating: 0x44, count: 100_000))
        _ = try final.finish()
    }

    func testQuotaRejectionTriggersAutomaticReconciliation() throws {
        let (store, directory) = try quotaFixture(quota: 1_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try store.begin(name: "auto.bin", expectedSize: 800, client: "c")
        try first.append(Data(repeating: 0x41, count: 800))
        let result = try first.finish()

        XCTAssertThrowsError(try store.begin(name: "later.bin", expectedSize: 300, client: "c"))

        try FileManager.default.removeItem(atPath: result.path)

        var admission: UploadTransaction?
        for _ in 0..<60 {
            admission = try? store.begin(name: "later.bin", expectedSize: 300, client: "c")
            if admission != nil { break }
            usleep(50_000)
        }
        XCTAssertNotNil(
            admission,
            "quota rejection must schedule a reconciliation that restores admission"
        )
        admission?.cancel()
    }

    // MARK: Session rotation during uploads

    func testTokenRotationMidUploadRejectsStaleTokenAndResumesWithNewToken() async throws {
        let fixture = try fixture()
        defer { fixture.stop() }

        let id = "rotate-\(UUID().uuidString.prefix(8))"
        let oldToken = fixture.store.token

        var chunk1 = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        chunk1.queryItems = [
            URLQueryItem(name: "uploadId", value: id),
            URLQueryItem(name: "name", value: "rotate.bin"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "15")
        ]
        var request1 = URLRequest(url: chunk1.url!)
        request1.httpMethod = "PUT"
        request1.httpBody = Data("0123456789".utf8)
        let (_, response1) = try await URLSession.shared.data(for: request1)
        XCTAssertEqual((response1 as? HTTPURLResponse)?.statusCode, 200)

        let newToken = fixture.store.rotateToken()

        var stale = URLComponents(
            url: URL(string: "http://127.0.0.1:\(fixture.server.port)/s/\(oldToken)/api/upload")!,
            resolvingAgainstBaseURL: false
        )!
        stale.queryItems = [
            URLQueryItem(name: "uploadId", value: id),
            URLQueryItem(name: "name", value: "rotate.bin"),
            URLQueryItem(name: "offset", value: "10"),
            URLQueryItem(name: "total", value: "15")
        ]
        var staleRequest = URLRequest(url: stale.url!)
        staleRequest.httpMethod = "PUT"
        staleRequest.httpBody = Data("ABCDE".utf8)
        let (staleData, staleResponse) = try await URLSession.shared.data(for: staleRequest)
        XCTAssertEqual((staleResponse as? HTTPURLResponse)?.statusCode, 404, String(decoding: staleData, as: UTF8.self))

        var chunk3 = URLComponents(
            url: URL(string: "http://127.0.0.1:\(fixture.server.port)/s/\(newToken)/api/upload")!,
            resolvingAgainstBaseURL: false
        )!
        chunk3.queryItems = [
            URLQueryItem(name: "uploadId", value: id),
            URLQueryItem(name: "name", value: "rotate.bin"),
            URLQueryItem(name: "offset", value: "10"),
            URLQueryItem(name: "total", value: "15"),
            URLQueryItem(name: "complete", value: "1")
        ]
        var chunk3Request = URLRequest(url: chunk3.url!)
        chunk3Request.httpMethod = "PUT"
        chunk3Request.httpBody = Data("ABCDE".utf8)
        let (_, chunk3Response) = try await URLSession.shared.data(for: chunk3Request)
        XCTAssertEqual((chunk3Response as? HTTPURLResponse)?.statusCode, 201)

        let saved = try Data(
            contentsOf: fixture.uploadDirectory.appendingPathComponent("rotate.bin")
        )
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), "0123456789ABCDE")
    }

    func testTokenRotationClosesActiveEventStream() async throws {
        let fixture = try fixture(files: [("hello.txt", Data("hello".utf8))])
        defer { fixture.stop() }

        let probe = RotationSSEProbe()
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: fixture.tokenBase.appendingPathComponent("api/events"))
        task.resume()
        await fulfillment(of: [probe.firstEvent], timeout: 5)

        fixture.store.rotateToken()
        await fulfillment(of: [probe.finished], timeout: 6)
        XCTAssertTrue(task.state == .completed || task.error != nil)
    }

    func testStaleCookieIsRejectedAfterRotationMidUpload() throws {
        let fixture = try fixture()
        defer { fixture.stop() }

        let originalCookie = fixture.store.sessionCookie
        let fd = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 5))
        let head = """
        PUT /api/upload?name=cookie.bin HTTP/1.1\r
        Host: 127.0.0.1\r
        Cookie: \(SessionStore.cookieName)=\(originalCookie)\r
        Content-Length: 5\r
        Connection: close\r
        \r

        """
        socketSend(Data(head.utf8), fd: fd)
        socketSend(Data("hello".utf8), fd: fd)
        let (firstResponse, _) = socketReadUntilClosed(fd: fd)
        close(fd)
        XCTAssertTrue(
            httpResponseText(firstResponse).hasPrefix("HTTP/1.1 201"),
            String(httpResponseText(firstResponse).prefix(200))
        )

        _ = fixture.store.rotateSessionCookie()

        let fd2 = try XCTUnwrap(socketConnect(port: fixture.server.port, timeout: 5))
        defer { close(fd2) }
        let staleHead = """
        PUT /api/upload?name=cookie2.bin HTTP/1.1\r
        Host: 127.0.0.1\r
        Cookie: \(SessionStore.cookieName)=\(originalCookie)\r
        Content-Length: 5\r
        Connection: close\r
        \r

        """
        socketSend(Data(staleHead.utf8), fd: fd2)
        let (staleResponse, _) = socketReadUntilClosed(fd: fd2)
        XCTAssertTrue(
            httpResponseText(staleResponse).hasPrefix("HTTP/1.1 401"),
            "stale cookie must be rejected after rotation: \(httpResponseText(staleResponse).prefix(200))"
        )
    }

    // MARK: SEC-005 — web client upload IDs

    private var webAppJavaScriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacdroKit/Resources/Web/app.js")
    }

    func testWebClientHasNoInsecureUploadIDRandomness() throws {
        let source = try String(contentsOf: webAppJavaScriptURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("Math.random"),
            "app.js must not fall back to Math.random for any purpose"
        )
        XCTAssertTrue(source.contains("makeUploadID"))
        XCTAssertTrue(source.contains("Secure random IDs are unavailable"))
    }

    private func makeUploadIDSource(from source: String) throws -> String {
        let startMarker = "const makeUploadID = () => {"
        guard let startRange = source.range(of: startMarker) else {
            throw NSError(
                domain: "RemediationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "makeUploadID not found in app.js"]
            )
        }
        guard let endRange = source.range(
            of: "\n    };",
            range: startRange.upperBound..<source.endIndex
        ) else {
            throw NSError(
                domain: "RemediationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "makeUploadID end not found in app.js"]
            )
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private func evaluateMakeUploadID(windowStub: String) throws -> JSValue {
        let source = try String(contentsOf: webAppJavaScriptURL, encoding: .utf8)
        let function = try makeUploadIDSource(from: source)
        let script = """
        var window = \(windowStub);
        \(function)
        result = makeUploadID();
        """
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(String(describing: exception))")
        }
        _ = context.evaluateScript(script)
        return try XCTUnwrap(context.objectForKeyedSubscript("result"))
    }

    func testMakeUploadIDUsesRandomUUIDWhenAvailable() throws {
        let result = try evaluateMakeUploadID(
            windowStub: """
            { crypto: { randomUUID: function () { return "11111111-2222-3333-4444-555555555555"; } } }
            """
        )
        XCTAssertFalse(result.isNull)
        XCTAssertEqual(result.toString(), "11111111222233334444555555555555")
    }

    func testMakeUploadIDUsesSecureGetRandomValuesFallback() throws {
        let result = try evaluateMakeUploadID(
            windowStub: """
            { crypto: { getRandomValues: function (array) {
                for (var i = 0; i < array.length; i += 1) { array[i] = (i * 7 + 3) % 256; }
                return array;
            } } }
            """
        )
        XCTAssertFalse(result.isNull)
        let value = try XCTUnwrap(result.toString())
        XCTAssertEqual(value.count, 32)
        XCTAssertTrue(value.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(value, "030a11181f262d343b424950575e656c")
    }

    func testMakeUploadIDFailsClosedWithoutSecureRandomness() throws {
        let result = try evaluateMakeUploadID(windowStub: "{}")
        XCTAssertTrue(
            result.isNull || result.isUndefined,
            "missing Web Crypto must yield null, not an insecure identifier"
        )
    }

    // MARK: Property-style parser tests

    func testRangeRequestParseFuzzInvariants() {
        var rng = SplitMix64(seed: 0x7A_11_E5)
        let literals = [
            "", "bytes=0-1", "bytes=5-2", "bytes=-0", "bytes=-5",
            "bytes=999999-", "bytes=abc", "items=0-1", "bytes=0-0,2-3",
            "bytes= 0 - 1", "bytes=--1", "bytes=1-2-3",
            "bytes=0-18446744073709551615", "bytes=-18446744073709551615"
        ]
        for _ in 0..<600 {
            let header: String?
            if Bool.random(using: &rng) {
                header = literals.randomElement(using: &rng)
            } else if Bool.random(using: &rng) {
                header = nil
            } else {
                let start = UInt64.random(in: 0..<10_000, using: &rng)
                let end = UInt64.random(in: 0..<10_000, using: &rng)
                let suffix = Bool.random(using: &rng)
                header = suffix
                    ? "bytes=-\(end)"
                    : "bytes=\(start)-\(Bool.random(using: &rng) ? String(end) : "")"
            }
            let size = UInt64.random(in: 0...10_000, using: &rng)
            let result = RangeRequest.parse(header: header, fileSize: size)
            switch result {
            case .full, .unsatisfiable:
                continue
            case .partial(let range):
                XCTAssertLessThanOrEqual(range.start, range.end, "header=\(header ?? "nil") size=\(size)")
                XCTAssertLessThan(range.end, size, "header=\(header ?? "nil") size=\(size)")
                XCTAssertGreaterThan(range.length, 0, "header=\(header ?? "nil") size=\(size)")
            }
        }
    }

    func testUploadPathFuzzInvariants() {
        var generator = SplitMix64(seed: 0xFA11)
        let atoms = [
            "..", ".", "", "a", "file.bin", ".macdro-x.part", ".macdro-",
            "sub", ":", "\\", "in\u{202E}voice", "  ", ".part", "..macdro-y.part",
            String(repeating: "n", count: 300)
        ]
        for _ in 0..<500 {
            let componentCount = Int.random(in: 1...5, using: &generator)
            let components = (0..<componentCount).map { _ in
                atoms.randomElement(using: &generator) ?? "x"
            }
            let name = atoms.randomElement(using: &generator) ?? "f.bin"
            let relativePath = Bool.random(using: &generator)
                ? components.joined(separator: "/") + "/" + name
                : nil
            let path = UploadStore.requestPath(name: name, relativePath: relativePath)

            XCTAssertFalse(path.isEmpty)
            XCTAssertFalse(path.hasPrefix("/"))
            XCTAssertFalse(path.hasSuffix("/"))
            XCTAssertFalse(path.contains("//"))
            for component in path.split(separator: "/") {
                XCTAssertNotEqual(component, ".")
                XCTAssertNotEqual(component, "..")
                XCTAssertFalse(
                    component.hasPrefix(".macdro-") && component.hasSuffix(".part"),
                    "reserved pattern leaked into component \(component) from \(name)/\(relativePath ?? "nil")"
                )
            }
        }
    }
}
