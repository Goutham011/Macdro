import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacdroKit

private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var buffer = Data()
    private var fulfilled = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        buffer.append(data)
        let ready = buffer.range(of: Data("\n\n".utf8)) != nil && !fulfilled
        if ready { fulfilled = true }
        lock.unlock()
        if ready { expectation.fulfill() }
    }
}

final class RegressionTests: XCTestCase {
    private struct Fixture {
        let server: MacdroServer
        let store: SessionStore
        let directory: URL
        let uploadDirectory: URL

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: uploadDirectory)
        }

        var tokenBase: URL {
            URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/")!
        }
    }

    private func fixture(
        files: [(name: String, data: Data, modifiedAt: Date)],
        maxBufferedBodyBytes: Int = MacdroLimits.maxBufferedBodyBytes,
        readTimeoutSeconds: Int = MacdroLimits.readTimeoutSeconds,
        maxConnections: Int = MacdroLimits.maxConnections,
        maxConnectionsPerIP: Int = MacdroLimits.maxConnectionsPerIP
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroRegression-\(UUID().uuidString)", isDirectory: true)
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
                    modifiedAt: file.modifiedAt
                )
            )
        }

        let store = SessionStore(token: "regression-token")
        store.add(shared)
        let configuration = MacdroServerConfiguration(
            maxBufferedBodyBytes: maxBufferedBodyBytes,
            readTimeoutSeconds: readTimeoutSeconds,
            maxConnections: maxConnections,
            maxConnectionsPerIP: maxConnectionsPerIP
        )
        let server = MacdroServer(
            store: store,
            host: "127.0.0.1",
            port: 0,
            uploadDirectory: uploadDirectory,
            configuration: configuration
        )
        try server.start()
        return Fixture(
            server: server,
            store: store,
            directory: directory,
            uploadDirectory: uploadDirectory
        )
    }

    private func connect(port: Int, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
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

    private func sendAll(_ data: Data, fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    private func readUntilClosed(fd: Int32) -> (Data, Bool) {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(buffer, count: count)
                continue
            }
            if count == 0 {
                return (response, true)
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return (response, false)
            }
            return (response, true)
        }
    }

    private func rawExchange(
        port: Int,
        request: Data,
        timeout: TimeInterval = 3
    ) -> (Data, Bool) {
        guard let fd = connect(port: port, timeout: timeout) else {
            return (Data(), false)
        }
        defer { close(fd) }
        sendAll(request, fd: fd)
        shutdown(fd, SHUT_WR)
        return readUntilClosed(fd: fd)
    }

    private func rawPartialRequest(
        port: Int,
        request: Data,
        timeout: TimeInterval = 4
    ) -> Bool {
        guard let fd = connect(port: port, timeout: timeout) else {
            return false
        }
        defer { close(fd) }
        sendAll(request, fd: fd)
        let (_, closed) = readUntilClosed(fd: fd)
        return closed
    }

    func testDateEpochHandlesNegativeAndFarFutureDates() {
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.timeZone = TimeZone(secondsFromGMT: 0)
            return Calendar(identifier: .gregorian).date(from: components)!
        }

        XCTAssertEqual(DateEpoch.seconds(date(1900, 1, 1)), 0)
        XCTAssertEqual(DateEpoch.seconds(date(1969, 12, 31)), 0)
        XCTAssertEqual(DateEpoch.seconds(date(1970, 1, 1)), 0)
        XCTAssertEqual(DateEpoch.seconds(date(2030, 1, 1)), 1_893_456_000)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: -86_400)), 0)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: 1_700_000_000)), 1_700_000_000)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: .infinity)), 0)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: .nan)), 0)
        XCTAssertEqual(DateEpoch.seconds(Date(timeIntervalSince1970: 1e20)), UInt64.max)
    }

    func testPre1970FileServesEtagWithoutTrapping() async throws {
        let file = SharedFile(
            sourcePath: "/tmp/old.txt",
            relativePath: "old.txt",
            size: 3,
            contentType: "text/plain",
            modifiedAt: Date(timeIntervalSince1970: -1_000)
        )
        XCTAssertEqual(file.etag, "3-0")
    }

    func testZeroByteFileReportsZeroContentLength() async throws {
        let fixture = try fixture(files: [("empty.txt", Data(), Date())])
        defer { fixture.stop() }

        let file = try XCTUnwrap(fixture.store.snapshot().files.first)
        let url = fixture.tokenBase.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "0")
        XCTAssertTrue(data.isEmpty)

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (headData, headResponse) = try await URLSession.shared.data(for: head)
        let headHTTP = try XCTUnwrap(headResponse as? HTTPURLResponse)
        XCTAssertEqual(headHTTP.statusCode, 200)
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Content-Length"), "0")
        XCTAssertTrue(headData.isEmpty)
    }

    func testZeroByteRangeIsUnsatisfiableAndEmpty() async throws {
        let fixture = try fixture(files: [("empty.txt", Data(), Date())])
        defer { fixture.stop() }

        let file = try XCTUnwrap(fixture.store.snapshot().files.first)
        let url = fixture.tokenBase.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        for range in ["bytes=0-", "bytes=0-0", "bytes=-1"] {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 416, range)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes */0", range)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "0", range)
            XCTAssertTrue(data.isEmpty, range)
        }
    }

    func testChunkedBodyOverCapReturns413AndCloses() throws {
        let fixture = try fixture(files: [], maxBufferedBodyBytes: 32)
        defer { fixture.stop() }

        let chunk = String(repeating: "A", count: 64)
        let body = "\(String(chunk.count, radix: 16))\r\n\(chunk)\r\n"
            + "\(String(chunk.count, radix: 16))\r\n\(chunk)\r\n0\r\n\r\n"
        let request = Data(
            ("POST /health HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Connection: close\r\n\r\n"
                + body).utf8
        )
        let (response, closed) = rawExchange(port: fixture.server.port, request: request)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("413 Payload Too Large"), text)
        XCTAssertTrue(closed, "server must close after rejecting a chunked body")
    }

    func testDeclaredOversizedBodyReturns413AndCloses() throws {
        let fixture = try fixture(files: [], maxBufferedBodyBytes: 32)
        defer { fixture.stop() }

        let request = Data(
            ("POST /health HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Content-Length: 128\r\n"
                + "Connection: close\r\n\r\n"
                + String(repeating: "A", count: 128)).utf8
        )
        let (response, closed) = rawExchange(port: fixture.server.port, request: request)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("413 Payload Too Large"))
        XCTAssertTrue(closed, "server must close after rejecting a declared body")
    }

    func testPartialHeaderClosesAtReadTimeout() throws {
        let fixture = try fixture(files: [], readTimeoutSeconds: 1)
        defer { fixture.stop() }

        let request = Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        XCTAssertTrue(
            rawPartialRequest(port: fixture.server.port, request: request),
            "partial headers must be closed by the idle/header timeout"
        )
    }

    func testHundredSlowlorisConnectionsAreBoundedAndClosed() throws {
        let fixture = try fixture(
            files: [],
            readTimeoutSeconds: 1,
            maxConnections: 120,
            maxConnectionsPerIP: 16
        )
        defer { fixture.stop() }

        let request = Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        var sockets: [Int32] = []
        for _ in 0..<100 {
            if let fd = connect(port: fixture.server.port, timeout: 3) {
                sendAll(request, fd: fd)
                sockets.append(fd)
            }
        }
        XCTAssertGreaterThanOrEqual(sockets.count, 90)

        Thread.sleep(forTimeInterval: 2.5)

        var closed = 0
        for fd in sockets {
            let (_, didClose) = readUntilClosed(fd: fd)
            if didClose { closed += 1 }
            close(fd)
        }
        XCTAssertGreaterThanOrEqual(closed, 90)
    }

    func testContentDispositionSanitizesControlsQuotesAndBackslashes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroHeaders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("safe.txt")
        try Data("safe".utf8).write(to: source)
        let names = [
            "header\r\nX-Injected: yes.txt",
            "tab\tquote\"back\\slash.txt",
            "nul\0name.txt"
        ]
        let files = names.map {
            SharedFile(
                sourcePath: source.path,
                relativePath: "safe.txt",
                name: $0,
                size: 4,
                contentType: "text/plain"
            )
        }
        let store = SessionStore(token: "header-token")
        store.add(files)
        let server = MacdroServer(
            store: store,
            host: "127.0.0.1",
            port: 0,
            uploadDirectory: directory.appendingPathComponent("uploads")
        )
        try server.start()
        defer { server.stop() }

        for file in files {
            let url = URL(
                string: "http://127.0.0.1:\(server.port)/s/header-token/f/\(file.id.uuidString.lowercased())"
            )!
            let (data, response) = try await URLSession.shared.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(data, Data("safe".utf8))
            let disposition = try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Disposition"))
            XCTAssertFalse(disposition.contains("\r"))
            XCTAssertFalse(disposition.contains("\n"))
            XCTAssertFalse(disposition.contains("\0"))
            XCTAssertFalse(disposition.contains("\t"))
            XCTAssertNil(http.value(forHTTPHeaderField: "X-Injected"))
            XCTAssertTrue(disposition.contains("filename*=UTF-8''"), disposition)
        }
    }

    func testLongUnicodeUploadNameIsTruncated() async throws {
        let fixture = try fixture(files: [])
        defer { fixture.stop() }

        let original = String(repeating: "😀", count: 300) + ".txt"
        var components = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "name", value: original)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = Data("x".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201, String(decoding: data, as: UTF8.self))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let savedName = try XCTUnwrap(json["name"] as? String)
        XCTAssertLessThanOrEqual(savedName.utf16.count, 240)
        XCTAssertTrue(savedName.hasSuffix(".txt"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.uploadDirectory.appendingPathComponent(savedName).path
            )
        )
    }

    func testUploadQuotaReturns507() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroQuota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(token: "quota-token")
        let configuration = MacdroServerConfiguration(
            upload: UploadStore.Configuration(quotaBytes: 0)
        )
        let server = MacdroServer(
            store: store,
            host: "127.0.0.1",
            port: 0,
            uploadDirectory: directory.appendingPathComponent("uploads"),
            configuration: configuration
        )
        try server.start()
        defer { server.stop() }

        var components = URLComponents(
            url: URL(string: "http://127.0.0.1:\(server.port)/s/quota-token/api/upload")!,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "name", value: "quota.bin")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = Data("x".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 507)
    }

    func testOversizedNonUploadBodyIsRejectedBeforeBuffering() async throws {
        let fixture = try fixture(files: [], maxBufferedBodyBytes: 32)
        defer { fixture.stop() }

        var request = URLRequest(url: fixture.tokenBase.appendingPathComponent("api/clipboard"))
        request.httpMethod = "PUT"
        request.httpBody = Data(repeating: 0x41, count: 128)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    func testCookieIsRequiredForAPIAndIssuedByReceiverPage() async throws {
        let fixture = try fixture(files: [("hello.txt", Data("hello".utf8), Date())])
        defer { fixture.stop() }

        let unauthenticated = URLSession(configuration: .ephemeral)
        let api = URL(string: "http://127.0.0.1:\(fixture.server.port)/api/session")!
        let (_, denied) = try await unauthenticated.data(from: api)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)

        let (_, page) = try await URLSession.shared.data(from: fixture.tokenBase)
        XCTAssertEqual((page as? HTTPURLResponse)?.statusCode, 200)
        let (data, allowed) = try await URLSession.shared.data(from: api)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hello.txt"))
    }

    func testManifestIncludesSHA256() async throws {
        let payload = Data("manifest contents".utf8)
        let fixture = try fixture(files: [("doc.txt", payload, Date())])
        defer { fixture.stop() }

        let url = fixture.tokenBase.appendingPathComponent("api/manifest")
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(files.first?["sha256"] as? String, expected)
    }

    func testEventStreamEmitsInitialSession() async throws {
        let fixture = try fixture(files: [("hello.txt", Data("hello".utf8), Date())])
        defer { fixture.stop() }

        let ready = expectation(description: "SSE session event")
        let delegate = SSEDelegate(expectation: ready)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let url = fixture.tokenBase.appendingPathComponent("api/events")
        let task = session.dataTask(with: url)
        task.resume()

        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        session.invalidateAndCancel()
        XCTAssertTrue(delegate.text.contains("\"files\""))
        XCTAssertTrue(delegate.text.contains("hello.txt"))
    }

    func testZIPDownloadContainsSharedFile() async throws {
        let payload = Data("zip contents\n".utf8)
        let fixture = try fixture(files: [("hello.txt", payload, Date())])
        defer { fixture.stop() }

        let url = fixture.tokenBase.appendingPathComponent("api/zip")
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let zipURL = fixture.directory.appendingPathComponent("download.zip")
        try data.write(to: zipURL)

        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-t", zipURL.path]
        test.standardOutput = FileHandle.nullDevice
        test.standardError = FileHandle.nullDevice
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0)

        let extract = Process()
        let pipe = Pipe()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-p", zipURL.path, "hello.txt"]
        extract.standardOutput = pipe
        try extract.run()
        extract.waitUntilExit()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd() ?? Data(), payload)
    }

    func testFolderUploadPreservesNestedPathAndChecksum() async throws {
        let fixture = try fixture(files: [])
        defer { fixture.stop() }

        let payload = Data("nested".utf8)
        var components = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: "note.txt"),
            URLQueryItem(name: "path", value: "../Docs/Sub/note.txt")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "Docs/Sub/note.txt")
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(json["checksum"] as? String, expected)
        XCTAssertEqual(
            try Data(contentsOf: fixture.uploadDirectory.appendingPathComponent("Docs/Sub/note.txt")),
            payload
        )
    }

    func testLargeUploadUsesCoalescedBodyWritesAndPreservesChecksum() async throws {
        let fixture = try fixture(files: [])
        defer { fixture.stop() }

        let payload = Data(repeating: 0x5A, count: 5 * 1024 * 1024)
        var components = URLComponents(
            url: fixture.tokenBase.appendingPathComponent("api/upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "name", value: "coalesced.bin")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201, String(decoding: data, as: UTF8.self))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(json["checksum"] as? String, expected)
        let savedName = try XCTUnwrap(json["name"] as? String)
        XCTAssertEqual(
            try Data(contentsOf: fixture.uploadDirectory.appendingPathComponent(savedName)),
            payload
        )
    }

    func testThreeParallelUploadsSucceed() async throws {
        let fixture = try fixture(files: [])
        defer { fixture.stop() }

        let base = fixture.tokenBase
        let payloads = (0..<3).map { index in
            Data(repeating: UInt8(index + 1), count: 2 * 1024 * 1024)
        }
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for (index, payload) in payloads.enumerated() {
                group.addTask {
                    var components = URLComponents(
                        url: base.appendingPathComponent("api/upload"),
                        resolvingAgainstBaseURL: false
                    )!
                    components.queryItems = [
                        URLQueryItem(name: "name", value: "parallel-\(index).bin")
                    ]
                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "PUT"
                    request.httpBody = payload
                    let (_, response) = try await URLSession.shared.data(for: request)
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            var values: [Int] = []
            for try await status in group { values.append(status) }
            return values
        }
        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses.allSatisfy { $0 == 201 }, "\(statuses)")
        for index in 0..<3 {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.uploadDirectory.appendingPathComponent("parallel-\(index).bin").path
                )
            )
        }
    }
}
