import Darwin
import Foundation
import MacdroKit
import NIOSSL

@main
struct MacdroAudit {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        setbuf(stdout, nil)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            print("usage: MacdroAudit [test|pre1970|serve <fixtures> <uploads> <port>]")
            exit(2)
        }

        switch mode {
        case "test":
            await runTests()
        case "pre1970":
            await runPre1970()
        case "serve":
            guard args.count == 4, let port = Int(args[3]) else { exit(2) }
            runServer(fixtures: URL(fileURLWithPath: args[1]), uploads: URL(fileURLWithPath: args[2]), port: port)
        default:
            exit(2)
        }
    }

    static func runTests() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacdroAudit-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch { print("FATAL \(error)"); exit(1) }
        defer { try? fm.removeItem(at: root) }

        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        let uploads = root.appendingPathComponent("uploads", isDirectory: true)
        try? fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try? fm.createDirectory(at: uploads, withIntermediateDirectories: true)

        func makeFile(_ name: String, data: Data) -> URL {
            let url = fixtures.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: data)
            return url
        }

        func makeSparse(_ name: String, size: UInt64) -> URL {
            let url = fixtures.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: size)
                try? handle.close()
            }
            return url
        }

        let zero = makeFile("zero.bin", data: Data())
        let normal = makeFile("normal.txt", data: Data("0123456789".utf8))
        let newline = makeFile("header\r\nX-Injected: yes.txt", data: Data("header-test".utf8))
        let sparse = makeSparse("sparse.bin", size: 5 * 1024 * 1024 * 1024)

        func shared(_ url: URL) -> SharedFile {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? Date()
            return SharedFile(sourcePath: url.path, relativePath: url.lastPathComponent, size: size, modifiedAt: modified)
        }

        let zeroFile = shared(zero)
        let normalFile = shared(normal)
        let newlineFile = shared(newline)
        let sparseFile = shared(sparse)

        let store = SessionStore(token: "audit-token")
        store.add([zeroFile, normalFile, newlineFile, sparseFile])
        let identityDirectory = root.appendingPathComponent("identity", isDirectory: true)
        let configuration = MacdroServerConfiguration(identityDirectory: identityDirectory)
        let server = MacdroServer(
            store: store,
            host: "0.0.0.0",
            port: 0,
            uploadDirectory: uploads,
            configuration: configuration
        )
        do { try server.start() } catch { print("FATAL server \(error)"); exit(1) }
        defer { server.stop() }
        let port = server.port
        print("AUDIT server port=\(port) lanport=\(server.lanPort) tls=\(server.tlsFingerprint ?? "none")")
        print("AUDIT lan-error=\(server.lanError.map { String(describing: $0) } ?? "none")")

        if let caAttributes = try? fm.attributesOfItem(atPath: identityDirectory.appendingPathComponent("ca.key").path),
           let permissions = caAttributes[.posixPermissions] as? NSNumber {
            print("AUDIT ca-key-mode=\(String(permissions.intValue, radix: 8))")
        }
        if let leaf = try? NIOSSLCertificate.fromPEMFile(identityDirectory.appendingPathComponent("leaf.crt").path).first,
           let der = try? leaf.toDERBytes()
        {
            print("AUDIT leaf-der-bytes=\(der.count)")
        }

        if server.lanPort > 0 {
            let delegate = AuditTrustDelegate()
            let tlsSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { tlsSession.invalidateAndCancel() }
            do {
                let (data, response) = try await tlsSession.data(
                    from: URL(string: "https://127.0.0.1:\(server.lanPort)/health")!
                )
                print("AUDIT https-health=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                print("AUDIT https-health=ERROR \(error)")
            }

            var plaintext = URLRequest(url: URL(string: "http://127.0.0.1:\(server.lanPort)/health")!)
            plaintext.timeoutInterval = 3
            do {
                _ = try await URLSession.shared.data(for: plaintext)
                print("AUDIT plaintext-on-lan-port=ACCEPTED")
            } catch {
                print("AUDIT plaintext-on-lan-port=rejected")
            }
        }

        if let response = try? raw(port: port, head: "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            print("AUDIT root-status=\(response.statusLine) token-leak=\(response.text.contains("audit-token")) redirect=\(response.headerValue("location") ?? "none")")
        }
        if let response = try? raw(port: port, head: "GET /s/audit-token/api/session HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            print("AUDIT session-status=\(response.statusLine) token-leak=\(response.text.contains("audit-token")) token-field=\(response.text.contains("\"token\""))")
        }
        if let response = try? raw(port: port, head: "GET /api/session HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            print("AUDIT root-session-status=\(response.statusLine)")
        }

        func url(_ file: SharedFile) -> String {
            "http://127.0.0.1:\(port)/s/audit-token/f/\(file.id.uuidString.lowercased())"
        }

        print("--- zero-byte ---")
        if let response = try? raw(port: port, head: "GET /s/audit-token/f/\(zeroFile.id.uuidString.lowercased()) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            let length = response.headerValue("content-length") ?? "?"
            print("GET zero status=\(response.statusLine) content-length=\(length) body=\(response.body.count)")
        } else {
            print("GET zero raw failed (timeout/connection)")
        }
        if let response = try? raw(port: port, head: "HEAD /s/audit-token/f/\(zeroFile.id.uuidString.lowercased()) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            print("HEAD zero status=\(response.statusLine) content-length=\(response.headerValue("content-length") ?? "?")")
        }

        print("--- header injection ---")
        if let response = try? raw(port: port, head: "GET /s/audit-token/f/\(newlineFile.id.uuidString.lowercased()) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") {
            print("newline status=\(response.statusLine)")
            print("content-disposition: \(response.headerValue("content-disposition") ?? "?")")
            print("injected-header-present=\(response.headerText.contains("X-Injected: yes"))")
        } else {
            print("newline request failed (server rejected/closed)")
        }

        print("--- range fuzz ---")
        let rangeHeaders = [
            "bytes=999999-10", "bytes=999999-", "bytes=-0", "bytes=0-0,2-3",
            "bytes=abc", "bytes=0-18446744073709551615", "bytes=5-2",
            "bytes= 0 - 1", "bytes=--1", "bytes=1-2-3", "bytes=", "bytes=0-"
        ]
        for range in rangeHeaders {
            var request = URLRequest(url: URL(string: url(normalFile))!)
            request.setValue(range, forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                print("range \(range) -> \(http?.statusCode ?? -1) bytes=\(data.count) cr=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "-")")
            } catch {
                print("range \(range) -> ERROR \(error)")
            }
        }

        print("--- 4 GiB offset ---")
        do {
            var request = URLRequest(url: URL(string: url(sparseFile))!)
            request.setValue("bytes=4294967296-4294967395", forHTTPHeaderField: "Range")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            print("4G status=\(http?.statusCode ?? -1) bytes=\(data.count) cr=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "-")")
        } catch {
            print("4G ERROR \(error)")
        }

        print("--- concurrent identical upload names ---")
        do {
            var payloads = Set<Data>()
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for index in 0..<MacdroLimits.maxConcurrentUploadsPerClient {
                    group.addTask {
                        let payload = Data("payload-\(index)-\(UUID().uuidString)".utf8)
                        var components = URLComponents(string: "http://127.0.0.1:\(port)/s/audit-token/api/upload")!
                        components.queryItems = [URLQueryItem(name: "name", value: "same.txt")]
                        var request = URLRequest(url: components.url!)
                        request.httpMethod = "PUT"
                        request.httpBody = payload
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return ((response as? HTTPURLResponse)?.statusCode ?? -1, payload)
                    }
                }
                for try await (status, payload) in group {
                    if status != 201 { print("concurrent status \(status)") }
                    payloads.insert(payload)
                }
            }
            let saved = try fm.contentsOfDirectory(atPath: uploads.path).filter { $0.hasPrefix("same") }
            let savedContents = Set(saved.compactMap { try? Data(contentsOf: uploads.appendingPathComponent($0)) })
            print("concurrent files=\(saved.count) uniquePayloads=\(payloads.count) contentsMatch=\(savedContents == payloads)")
        } catch {
            print("concurrent ERROR \(error)")
        }

        print("--- abandoned resumable uploads ---")
        do {
            for index in 0..<(MacdroLimits.maxResumableUploadsPerClient + 4) {
                var components = URLComponents(string: "http://127.0.0.1:\(port)/s/audit-token/api/upload")!
                components.queryItems = [
                    URLQueryItem(name: "uploadId", value: String(format: "leak%06d", index)),
                    URLQueryItem(name: "name", value: "leak-\(index).bin"),
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "total", value: "1")
                ]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "PUT"
                request.httpBody = Data()
                _ = try await URLSession.shared.data(for: request)
            }
            let parts = try fm.contentsOfDirectory(atPath: uploads.path).filter { $0.hasPrefix(".macdro-") && $0.hasSuffix(".part") }
            print("abandoned resumable temp files=\(parts.count) (released leases expire after TTL)")
        } catch {
            print("resumable leak ERROR \(error)")
        }

        print("--- long unicode upload name ---")
        do {
            let name = String(repeating: "😀", count: 300) + ".txt"
            var components = URLComponents(string: "http://127.0.0.1:\(port)/s/audit-token/api/upload")!
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PUT"
            request.httpBody = Data("x".utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            print("long-unicode status=\((response as? HTTPURLResponse)?.statusCode ?? -1) nameBytes=\(name.utf8.count)")
        } catch {
            print("long-unicode ERROR \(error)")
        }

        print("--- large non-upload body ---")
        do {
            let body = Data(repeating: 0x41, count: 32 * 1024 * 1024)
            let head = "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            if let response = try? raw(port: port, head: head, body: body) {
                print("32MiB POST /health status=\(response.statusLine) body=\(response.body.count)")
            } else {
                print("32MiB POST /health failed (timeout/closed)")
            }
        }

        print("AUDIT complete")
    }

    static func runPre1970() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacdroAudit-old-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("old.txt")
        fm.createFile(atPath: fileURL.path, contents: Data("old".utf8))
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: -315_619_200)], ofItemAtPath: fileURL.path)
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        print("mtime=\(attrs?[.modificationDate] ?? "?")")

        let file = SharedFile(sourcePath: fileURL.path, relativePath: "old.txt", size: 3)
        let store = SessionStore(token: "audit-token")
        store.add([file])
        let server = MacdroServer(store: store, host: "127.0.0.1", port: 0, uploadDirectory: root.appendingPathComponent("uploads"))
        do { try server.start() } catch { print("server start failed \(error)"); exit(1) }
        print("PRE1970 server port=\(server.port)")
        let url = URL(string: "http://127.0.0.1:\(server.port)/s/audit-token/f/\(file.id.uuidString.lowercased())")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            print("PRE1970 status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count)")
        } catch {
            print("PRE1970 client error: \(error)")
        }
        server.stop()
    }

    static func runServer(fixtures: URL, uploads: URL, port: Int) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let store = SessionStore(token: "audit-token")
        let shared = files.compactMap { url -> SharedFile? in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { return nil }
            return SharedFile(
                sourcePath: url.path,
                relativePath: url.lastPathComponent,
                size: UInt64(max(0, values?.fileSize ?? 0)),
                modifiedAt: values?.contentModificationDate ?? Date()
            )
        }
        store.add(shared)
        let server = MacdroServer(store: store, host: "127.0.0.1", port: port, uploadDirectory: uploads)
        do { try server.start() } catch { print("FATAL \(error)"); exit(1) }
        print("PORT=\(server.port) TOKEN=audit-token PID=\(getpid()) FILES=\(shared.count)")
        fflush(stdout)
        RunLoop.main.run()
    }

    static func raw(port: Int, head: String, body: Data? = nil) throws -> RawResponse {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AuditError.socket }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw AuditError.connect }
        try writeAll(fd: fd, data: Data(head.utf8))
        if let body { try? writeAll(fd: fd, data: body) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(buffer, count: count)
            } else {
                break
            }
        }
        return RawResponse(raw: response)
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 { throw AuditError.write }
                offset += written
            }
        }
    }
}

private final class AuditTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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

enum AuditError: Error { case socket, connect, write }

struct RawResponse {
    let raw: Data
    var text: String { String(decoding: raw, as: UTF8.self) }
    var statusLine: String { text.components(separatedBy: "\r\n").first ?? "" }
    var headerText: String {
        guard let range = text.range(of: "\r\n\r\n") else { return text }
        return String(text[..<range.lowerBound])
    }
    var body: Data {
        guard let range = raw.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return raw.subdata(in: range.upperBound..<raw.endIndex)
    }
    func headerValue(_ name: String) -> String? {
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
