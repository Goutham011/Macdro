import Foundation
import XCTest
@testable import MacdroKit

final class HTTPIntegrationTests: XCTestCase {
    private var server: MacdroServer!
    private var store: SessionStore!
    private var tempDirectory: URL!
    private var file: SharedFile!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let fileURL = tempDirectory.appendingPathComponent("hello.txt")
        try Data("abcdefghij".utf8).write(to: fileURL)

        store = SessionStore(token: "integration-token")
        file = SharedFile(
            sourcePath: fileURL.path,
            relativePath: "hello.txt",
            size: 10,
            contentType: "text/plain"
        )
        store.add([file])

        server = MacdroServer(store: store, host: "127.0.0.1", port: 0)
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(server.port)/s/\(store.token)/")!
    }

    func testHealthEndpoint() async throws {
        let url = URL(string: "http://127.0.0.1:\(server.port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok\n")
    }

    func testReceiverPageLoads() async throws {
        let (data, response) = try await URLSession.shared.data(from: baseURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("Macdro"))
        XCTAssertTrue(html.contains("app.js"))
    }

    func testSessionJSONListsFile() async throws {
        let url = baseURL.appendingPathComponent("api/session")
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = json?["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(files?.first?["name"] as? String, "hello.txt")
        XCTAssertEqual(files?.first?["size"] as? Int, 10)
    }

    func testFullDownload() async throws {
        let url = baseURL.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(data, Data("abcdefghij".utf8))
    }

    func testRangeDownload() async throws {
        let url = baseURL.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        var request = URLRequest(url: url)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 206)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(data, Data("cdef".utf8))
    }

    func testHeadRequestHasNoBody() async throws {
        let url = baseURL.appendingPathComponent("f/\(file.id.uuidString.lowercased())")
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Length"), "10")
        XCTAssertTrue(data.isEmpty)
    }

    func testWrongTokenReturnsNotFound() async throws {
        let url = URL(string: "http://127.0.0.1:\(server.port)/s/wrong-token/api/session")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }
}
