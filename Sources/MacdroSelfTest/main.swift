import Darwin
import Foundation
import MacdroKit

@main
struct MacdroSelfTest {
    static func main() async {
        var failures = 0

        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)")
            }
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacdroSelfTest-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            print("FAIL  could not create temp directory: \(error)")
            exit(1)
        }

        defer { try? fileManager.removeItem(at: tempDirectory) }

        let fileURL = tempDirectory.appendingPathComponent("hello world.txt")
        let contents = Data("abcdefghij".utf8)
        let emptyURL = tempDirectory.appendingPathComponent("empty.txt")
        let oldURL = tempDirectory.appendingPathComponent("old.txt")
        let headerSourceURL = tempDirectory.appendingPathComponent("header-source.txt")
        do {
            try contents.write(to: fileURL)
            try Data().write(to: emptyURL)
            try Data("old".utf8).write(to: oldURL)
            try Data("header".utf8).write(to: headerSourceURL)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: -2_208_988_800)],
                ofItemAtPath: oldURL.path
            )
        } catch {
            print("FAIL  could not create test files: \(error)")
            exit(1)
        }

        let uploadsDirectory = tempDirectory.appendingPathComponent("Uploads", isDirectory: true)
        let store = SessionStore(token: "selftest-token")
        let sharedFile = SharedFile(
            sourcePath: fileURL.path,
            relativePath: "hello world.txt",
            size: UInt64(contents.count),
            contentType: "text/plain"
        )
        let emptyFile = SharedFile(
            sourcePath: emptyURL.path,
            relativePath: "empty.txt",
            size: 0,
            contentType: "text/plain"
        )
        let oldFile = SharedFile(
            sourcePath: oldURL.path,
            relativePath: "old.txt",
            size: 3,
            contentType: "text/plain",
            modifiedAt: Date(timeIntervalSince1970: -2_208_988_800)
        )
        let headerFile = SharedFile(
            sourcePath: headerSourceURL.path,
            relativePath: "header-source.txt",
            name: "header\r\nX-Injected: yes.txt",
            size: 6,
            contentType: "text/plain"
        )
        store.add([sharedFile, emptyFile, oldFile, headerFile])

        let server = MacdroServer(
            store: store,
            host: "127.0.0.1",
            port: 0,
            uploadDirectory: uploadsDirectory
        )
        do {
            try server.start()
        } catch {
            print("FAIL  server did not start: \(error)")
            exit(1)
        }
        defer { server.stop() }

        let root = URL(string: "http://127.0.0.1:\(server.port)")!
        let base = root.appendingPathComponent("s/\(store.token)")
        print("Testing receiver at \(base.absoluteString)/ (port \(server.port))")

        do {
            let (healthData, healthResponse) = try await URLSession.shared.data(
                from: root.appendingPathComponent("health")
            )
            check((healthResponse as? HTTPURLResponse)?.statusCode == 200, "health returns 200")
            check(String(decoding: healthData, as: UTF8.self) == "ok\n", "health body is ok")
        } catch {
            failures += 1
            print("FAIL  health request: \(error)")
        }

        do {
            let (htmlData, htmlResponse) = try await URLSession.shared.data(from: base)
            let html = String(decoding: htmlData, as: UTF8.self)
            check((htmlResponse as? HTTPURLResponse)?.statusCode == 200, "receiver page returns 200")
            check(html.contains("Macdro"), "receiver page contains brand")
            check(html.contains("app.js"), "receiver page loads app.js")
            check(html.contains("upload-input"), "receiver page exposes uploads")
            check((htmlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff", "receiver page sets nosniff")
            check((htmlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer", "receiver page hides referrer")
        } catch {
            failures += 1
            print("FAIL  receiver page request: \(error)")
        }

        do {
            let (rootData, rootResponse) = try await URLSession.shared.data(from: root)
            let body = String(decoding: rootData, as: UTF8.self)
            check((rootResponse as? HTTPURLResponse)?.statusCode == 200, "root landing page returns 200")
            check((rootResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") == nil, "root does not redirect with token")
            check(!body.contains(store.token), "root does not expose token")
        } catch {
            failures += 1
            print("FAIL  root landing request: \(error)")
        }

        do {
            let (jsonData, jsonResponse) = try await URLSession.shared.data(
                from: base.appendingPathComponent("api/session")
            )
            let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            let files = json?["files"] as? [[String: Any]]
            check((jsonResponse as? HTTPURLResponse)?.statusCode == 200, "session API returns 200")
            check(files?.count == 4, "session API lists shared files")
            check(files?.first?["name"] as? String == "hello world.txt", "session API preserves file name")
            check(json?["token"] == nil, "session API does not expose token")
            check(!String(decoding: jsonData, as: UTF8.self).contains(store.token), "session JSON does not contain token")
        } catch {
            failures += 1
            print("FAIL  session API request: \(error)")
        }

        let fileEndpoint = base.appendingPathComponent("f/\(sharedFile.id.uuidString.lowercased())")

        do {
            let (data, response) = try await URLSession.shared.data(from: fileEndpoint)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200, "full download returns 200")
            check(data == contents, "full download body matches")
            check(http?.value(forHTTPHeaderField: "Accept-Ranges") == "bytes", "download advertises ranges")
            check(
                http?.value(forHTTPHeaderField: "Content-Disposition")?.contains("filename*=UTF-8''hello%20world.txt") == true,
                "download sets UTF-8 content disposition"
            )
        } catch {
            failures += 1
            print("FAIL  full download: \(error)")
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: fileEndpoint)
            let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            check(etag != nil, "download exposes ETag")
            let originalDate = ((try? fileManager.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date) ?? Date()
            try Data("ABCDEFGHIJ".utf8).write(to: fileURL)
            try fileManager.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
            var conditional = URLRequest(url: fileEndpoint)
            conditional.setValue(etag, forHTTPHeaderField: "If-None-Match")
            let (changedData, changedResponse) = try await URLSession.shared.data(for: conditional)
            check((changedResponse as? HTTPURLResponse)?.statusCode == 200, "ETag changes for same-size rewrite")
            check(changedData == Data("ABCDEFGHIJ".utf8), "changed body is served")
            try contents.write(to: fileURL)
            try fileManager.setAttributes([.modificationDate: originalDate], ofItemAtPath: fileURL.path)
        } catch {
            failures += 1
            print("FAIL  ETag request: \(error)")
        }

        do {
            var request = URLRequest(url: fileEndpoint)
            request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 206, "range download returns 206")
            check(data == Data("cdef".utf8), "range download body matches")
            check(http?.value(forHTTPHeaderField: "Content-Range") == "bytes 2-5/10", "range header matches")
        } catch {
            failures += 1
            print("FAIL  range download: \(error)")
        }

        do {
            var request = URLRequest(url: fileEndpoint)
            request.httpMethod = "HEAD"
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200, "HEAD returns 200")
            check(data.isEmpty, "HEAD has no body")
            check(http?.value(forHTTPHeaderField: "Content-Length") == "10", "HEAD exposes content length")
        } catch {
            failures += 1
            print("FAIL  HEAD request: \(error)")
        }

        do {
            let zeroEndpoint = base.appendingPathComponent("f/\(emptyFile.id.uuidString.lowercased())")
            let (data, response) = try await URLSession.shared.data(from: zeroEndpoint)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200, "zero-byte GET returns 200")
            check(http?.value(forHTTPHeaderField: "Content-Length") == "0", "zero-byte GET reports length 0")
            check(data.isEmpty, "zero-byte GET has empty body")

            var head = URLRequest(url: zeroEndpoint)
            head.httpMethod = "HEAD"
            let (headData, headResponse) = try await URLSession.shared.data(for: head)
            check(
                (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "0",
                "zero-byte HEAD reports length 0"
            )
            check(headData.isEmpty, "zero-byte HEAD has empty body")

            var range = URLRequest(url: zeroEndpoint)
            range.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let (rangeData, rangeResponse) = try await URLSession.shared.data(for: range)
            let rangeHTTP = rangeResponse as? HTTPURLResponse
            check(rangeHTTP?.statusCode == 416, "zero-byte range returns 416")
            check(rangeHTTP?.value(forHTTPHeaderField: "Content-Range") == "bytes */0", "zero-byte range reports size 0")
            check(rangeHTTP?.value(forHTTPHeaderField: "Content-Length") == "0", "zero-byte range has length 0")
            check(rangeData.isEmpty, "zero-byte range has empty body")
        } catch {
            failures += 1
            print("FAIL  zero-byte checks: \(error)")
        }

        do {
            let oldEndpoint = base.appendingPathComponent("f/\(oldFile.id.uuidString.lowercased())")
            let (data, response) = try await URLSession.shared.data(from: oldEndpoint)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200, "pre-1970 file returns 200")
            check(data == Data("old".utf8), "pre-1970 file body matches")
            check(http?.value(forHTTPHeaderField: "ETag") != nil, "pre-1970 file exposes ETag")
        } catch {
            failures += 1
            print("FAIL  pre-1970 file: \(error)")
        }

        do {
            let headerEndpoint = base.appendingPathComponent("f/\(headerFile.id.uuidString.lowercased())")
            let (data, response) = try await URLSession.shared.data(from: headerEndpoint)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 200, "CRLF filename download returns 200")
            check(data == Data("header".utf8), "CRLF filename body matches")
            check(
                http?.value(forHTTPHeaderField: "Content-Disposition")?.contains("\r") != true
                    && http?.value(forHTTPHeaderField: "Content-Disposition")?.contains("\n") != true,
                "CRLF filename is sanitized"
            )
            check(http?.value(forHTTPHeaderField: "X-Injected") == nil, "CRLF filename cannot inject headers")
        } catch {
            failures += 1
            print("FAIL  CRLF filename: \(error)")
        }

        do {
            let declared = MacdroLimits.maxBufferedBodyBytes + 1
            let head = "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(declared)\r\nConnection: close\r\n\r\n"
            let response = Self.rawRequest(port: server.port, head: head)
            check(
                response.map { String(decoding: $0, as: UTF8.self).contains("413 Payload Too Large") } == true,
                "oversized non-upload body returns 413"
            )
        }

        do {
            let uploadContents = Data("uploaded from phone\n".utf8)
            var components = URLComponents(
                url: base.appendingPathComponent("api/upload"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "name", value: "from phone.txt")]

            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = uploadContents

            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let savedURL = uploadsDirectory.appendingPathComponent("from phone.txt")

            check(http?.statusCode == 201, "upload returns 201")
            check(json?["name"] as? String == "from phone.txt", "upload preserves file name")
            check(json?["size"] as? Int == uploadContents.count, "upload reports size")
            check(fileManager.fileExists(atPath: savedURL.path), "upload saves file")
            check((try? Data(contentsOf: savedURL)) == uploadContents, "upload contents match")
        } catch {
            failures += 1
            print("FAIL  upload request: \(error)")
        }

        do {
            var components = URLComponents(
                url: base.appendingPathComponent("api/upload"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "name", value: "../escape.txt")]

            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.httpBody = Data("safe".utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            check(http?.statusCode == 201, "upload accepts traversal-shaped names")
            check(json?["name"] as? String == ".._escape.txt", "upload sanitizes path separators")
            check(
                fileManager.fileExists(
                    atPath: uploadsDirectory.appendingPathComponent(".._escape.txt").path
                ),
                "sanitized upload stays inside destination"
            )
        } catch {
            failures += 1
            print("FAIL  traversal upload request: \(error)")
        }

        do {
            let payload = Data((0..<1000).map { UInt8($0 % 251) })
            let uploadID = "resume" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let resumedName = "resumed-upload.bin"

            func resumableURL(offset: Int, complete: Bool) -> URL {
                var components = URLComponents(
                    url: base.appendingPathComponent("api/upload"),
                    resolvingAgainstBaseURL: false
                )!
                var items = [
                    URLQueryItem(name: "uploadId", value: uploadID),
                    URLQueryItem(name: "name", value: resumedName),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "total", value: String(payload.count))
                ]
                if complete {
                    items.append(URLQueryItem(name: "complete", value: "1"))
                }
                components.queryItems = items
                return components.url!
            }

            var firstRequest = URLRequest(url: resumableURL(offset: 0, complete: false))
            firstRequest.httpMethod = "PUT"
            firstRequest.httpBody = Data(payload.prefix(400))
            let (firstData, firstResponse) = try await URLSession.shared.data(for: firstRequest)
            let firstHTTP = firstResponse as? HTTPURLResponse
            let firstJSON = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
            check(firstHTTP?.statusCode == 200, "resumable upload accepts first chunk")
            check(firstJSON?["offset"] as? Int == 400, "resumable upload reports offset")
            check(firstHTTP?.value(forHTTPHeaderField: "X-Upload-Offset") == "400", "resumable upload exposes offset header")

            var secondRequest = URLRequest(url: resumableURL(offset: 400, complete: true))
            secondRequest.httpMethod = "PUT"
            secondRequest.httpBody = Data(payload.dropFirst(400))
            let (secondData, secondResponse) = try await URLSession.shared.data(for: secondRequest)
            let secondHTTP = secondResponse as? HTTPURLResponse
            let secondJSON = try JSONSerialization.jsonObject(with: secondData) as? [String: Any]
            let resumedURL = uploadsDirectory.appendingPathComponent(resumedName)
            check(secondHTTP?.statusCode == 201, "resumable upload completes")
            check(secondJSON?["complete"] as? Bool == true, "resumable upload marks completion")
            check((try? Data(contentsOf: resumedURL)) == payload, "resumable upload contents match")

            var duplicateRequest = URLRequest(url: resumableURL(offset: payload.count, complete: true))
            duplicateRequest.httpMethod = "PUT"
            duplicateRequest.httpBody = Data()
            let (_, duplicateResponse) = try await URLSession.shared.data(for: duplicateRequest)
            check((duplicateResponse as? HTTPURLResponse)?.statusCode == 409, "duplicate completion returns 409")
            check((duplicateResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Upload-Offset") == "\(payload.count)", "duplicate completion reports final offset")
        } catch {
            failures += 1
            print("FAIL  resumable upload: \(error)")
        }

        do {
            let payload = Data("offset-check-payload".utf8)
            let uploadID = "offset" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

            func chunkURL(offset: Int) -> URL {
                var components = URLComponents(
                    url: base.appendingPathComponent("api/upload"),
                    resolvingAgainstBaseURL: false
                )!
                components.queryItems = [
                    URLQueryItem(name: "uploadId", value: uploadID),
                    URLQueryItem(name: "name", value: "offset-check.txt"),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "total", value: String(payload.count))
                ]
                return components.url!
            }

            var firstRequest = URLRequest(url: chunkURL(offset: 0))
            firstRequest.httpMethod = "PUT"
            firstRequest.httpBody = Data(payload.prefix(6))
            _ = try await URLSession.shared.data(for: firstRequest)

            var wrongRequest = URLRequest(url: chunkURL(offset: 2))
            wrongRequest.httpMethod = "PUT"
            wrongRequest.httpBody = Data(payload.dropFirst(2))
            let (_, wrongResponse) = try await URLSession.shared.data(for: wrongRequest)
            let wrongHTTP = wrongResponse as? HTTPURLResponse
            check(wrongHTTP?.statusCode == 409, "resumable upload rejects wrong offset")
            check(wrongHTTP?.value(forHTTPHeaderField: "X-Upload-Offset") == "6", "wrong offset returns current offset")

            var finishRequest = URLRequest(url: chunkURL(offset: 6))
            finishRequest.httpMethod = "PUT"
            finishRequest.httpBody = Data(payload.dropFirst(6))
            let (_, finishResponse) = try await URLSession.shared.data(for: finishRequest)
            check((finishResponse as? HTTPURLResponse)?.statusCode == 200, "resumable upload continues after mismatch")

            var completeURL = chunkURL(offset: payload.count)
            completeURL = URL(string: completeURL.absoluteString + "&complete=1")!
            var completeRequest = URLRequest(url: completeURL)
            completeRequest.httpMethod = "PUT"
            completeRequest.httpBody = Data()
            let (_, completeResponse) = try await URLSession.shared.data(for: completeRequest)
            check((completeResponse as? HTTPURLResponse)?.statusCode == 201, "resumable upload finishes after mismatch")
            check(
                (try? Data(contentsOf: uploadsDirectory.appendingPathComponent("offset-check.txt"))) == payload,
                "resumable upload recovers full contents"
            )
        } catch {
            failures += 1
            print("FAIL  resumable offset handling: \(error)")
        }

        do {
            var components = URLComponents(
                url: base.appendingPathComponent("api/upload"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "uploadId", value: "missing" + UUID().uuidString.replacingOccurrences(of: "-", with: "")),
                URLQueryItem(name: "name", value: "missing.txt"),
                URLQueryItem(name: "offset", value: "10"),
                URLQueryItem(name: "total", value: "20")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.httpBody = Data("0123456789".utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            check(http?.statusCode == 409, "unknown resumable upload returns 409")
            check(http?.value(forHTTPHeaderField: "X-Upload-Offset") == "0", "unknown resumable upload resets offset")
        } catch {
            failures += 1
            print("FAIL  unknown resumable upload: \(error)")
        }

        do {
            let declared = MacdroLimits.maxClipboardBytes + 1
            let head = "PUT /s/\(store.token)/api/clipboard HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(declared)\r\nConnection: close\r\n\r\n"
            let response = Self.rawRequest(port: server.port, head: head)
            check(
                response.map { String(decoding: $0, as: UTF8.self).contains("413 Payload Too Large") } == true,
                "oversized clipboard write returns 413"
            )
        }

        do {
            let wrong = root.appendingPathComponent("s/wrong-token/api/session")
            let (_, response) = try await URLSession.shared.data(from: wrong)
            check((response as? HTTPURLResponse)?.statusCode == 404, "wrong token returns 404")
        } catch {
            failures += 1
            print("FAIL  wrong-token request: \(error)")
        }

        if failures == 0 {
            print("All checks passed.")
            exit(0)
        } else {
            print("\(failures) check(s) failed.")
            exit(1)
        }
    }

    static func rawRequest(port: Int, head: String, timeout: TimeInterval = 3) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
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
        guard connected == 0 else { return nil }
        let request = Data(head.utf8)
        request.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.send(fd, base, request.count, 0)
        }
        shutdown(fd, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            response.append(buffer, count: count)
        }
        return response
    }
}
