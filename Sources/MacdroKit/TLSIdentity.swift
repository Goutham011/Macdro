import CryptoKit
import Foundation
import NIOSSL

public enum TLSIdentityError: LocalizedError {
    case opensslFailed(String)
    case invalidIdentity
    case missingCertificate

    public var errorDescription: String? {
        switch self {
        case .opensslFailed(let message):
            return "Could not create the Macdro TLS identity: \(message)"
        case .invalidIdentity:
            return "The Macdro TLS identity is incomplete."
        case .missingCertificate:
            return "The Macdro CA certificate is unavailable."
        }
    }
}

public struct TLSIdentity: Sendable {
    public let directory: URL
    public let caCertificateURL: URL
    public let caPrivateKeyURL: URL
    public let certificateURL: URL
    public let privateKeyURL: URL
    public let fingerprint: String
    public let caFingerprint: String
    public let subjectAlternativeNames: [String]

    public func caCertificatePEM() throws -> String {
        guard let pem = try? String(contentsOf: caCertificateURL, encoding: .utf8),
              pem.contains("BEGIN CERTIFICATE")
        else {
            throw TLSIdentityError.missingCertificate
        }
        return pem
    }

    public func caCertificateDER() throws -> Data {
        try TLSIdentityManager.certificateDER(fromPEM: caCertificateURL)
    }

    public func mobileConfiguration() throws -> Data {
        try TLSIdentityManager.mobileConfiguration(
            caCertificateURL: caCertificateURL,
            fingerprint: caFingerprint
        )
    }

    public func makeServerConfiguration() throws -> TLSConfiguration {
        let leaf = try NIOSSLCertificate.fromPEMFile(certificateURL.path)
        let ca = try NIOSSLCertificate.fromPEMFile(caCertificateURL.path)
        let key = try NIOSSLPrivateKey(file: privateKeyURL.path, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: (leaf + ca).map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .none
        return configuration
    }

    public func makeContext() throws -> NIOSSLContext {
        try NIOSSLContext(configuration: makeServerConfiguration())
    }
}

public final class TLSIdentityManager: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var current: TLSIdentity?

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Macdro", isDirectory: true)
            .appendingPathComponent("Identity", isDirectory: true)
    }

    public func identity(for addresses: [String] = []) throws -> TLSIdentity {
        lock.lock()
        defer { lock.unlock() }

        let sans = Self.subjectAlternativeNames(addresses: addresses)
        if let current, current.subjectAlternativeNames == sans {
            return current
        }

        let identity = try loadOrCreate(sans: sans)
        current = identity
        return identity
    }

    public func caCertificatePEM() throws -> String {
        let url = directory.appendingPathComponent("ca.crt")
        guard let pem = try? String(contentsOf: url, encoding: .utf8) else {
            throw TLSIdentityError.missingCertificate
        }
        return pem
    }

    private func loadOrCreate(sans: [String]) throws -> TLSIdentity {
        try prepareDirectory()

        let caCert = directory.appendingPathComponent("ca.crt")
        let caKey = directory.appendingPathComponent("ca.key")
        let leafCert = directory.appendingPathComponent("leaf.crt")
        let leafKey = directory.appendingPathComponent("leaf.key")
        let leafSANs = directory.appendingPathComponent("leaf.sans")

        let caMissing = !FileManager.default.fileExists(atPath: caCert.path)
            || !FileManager.default.fileExists(atPath: caKey.path)
        if caMissing || Self.certificateNeedsRenewal(caCert) {
            try generateCA(certificate: caCert, key: caKey)
            try? FileManager.default.removeItem(at: leafCert)
            try? FileManager.default.removeItem(at: leafKey)
            try? FileManager.default.removeItem(at: leafSANs)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("ca.srl"))
        }

        let storedSANs = (try? String(contentsOf: leafSANs, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init)
        if !FileManager.default.fileExists(atPath: leafCert.path)
            || !FileManager.default.fileExists(atPath: leafKey.path)
            || storedSANs != sans
            || Self.certificateNeedsRenewal(leafCert)
        {
            try generateLeaf(
                certificate: leafCert,
                key: leafKey,
                caCertificate: caCert,
                caKey: caKey,
                sans: sans
            )
            try sans.joined(separator: "\n").write(to: leafSANs, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: leafSANs.path
            )
        }

        let fingerprint = try Self.fingerprint(certificateURL: leafCert)
        let caFingerprint = try Self.fingerprint(certificateURL: caCert)
        return TLSIdentity(
            directory: directory,
            caCertificateURL: caCert,
            caPrivateKeyURL: caKey,
            certificateURL: leafCert,
            privateKeyURL: leafKey,
            fingerprint: fingerprint,
            caFingerprint: caFingerprint,
            subjectAlternativeNames: sans
        )
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(".macdro-tls-") {
            try? fileManager.removeItem(at: url)
        }
    }

    private func generateCA(certificate: URL, key: URL) throws {
        try runOpenSSL(["genrsa", "-out", key.path, "2048"])
        try runOpenSSL([
            "req", "-x509", "-new", "-nodes",
            "-key", key.path,
            "-sha256",
            "-days", "3650",
            "-subj", "/CN=Macdro Local CA",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
            "-out", certificate.path
        ])
        try protect(key)
        try protect(certificate)
    }

    private func generateLeaf(
        certificate: URL,
        key: URL,
        caCertificate: URL,
        caKey: URL,
        sans: [String]
    ) throws {
        let csr = directory.appendingPathComponent(".macdro-tls-\(UUID().uuidString).csr")
        let config = directory.appendingPathComponent(".macdro-tls-\(UUID().uuidString).cnf")
        defer {
            try? FileManager.default.removeItem(at: csr)
            try? FileManager.default.removeItem(at: config)
        }

        let configText = """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Macdro Local Server
        [extensions]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer
        subjectAltName = @alt_names
        [alt_names]
        \(sanLines(sans))
        """

        try configText.write(to: config, atomically: true, encoding: .utf8)
        try protect(config)
        try runOpenSSL(["genrsa", "-out", key.path, "2048"])
        try runOpenSSL([
            "req", "-new",
            "-key", key.path,
            "-config", config.path,
            "-out", csr.path
        ])
        try runOpenSSL([
            "x509", "-req",
            "-in", csr.path,
            "-CA", caCertificate.path,
            "-CAkey", caKey.path,
            "-CAcreateserial",
            "-out", certificate.path,
            "-days", "365",
            "-sha256",
            "-extfile", config.path,
            "-extensions", "extensions"
        ])
        try protect(key)
        try protect(certificate)
    }

    private func sanLines(_ sans: [String]) -> String {
        var dnsNames: [String] = []
        var ipAddresses: [String] = []
        for value in sans {
            if Self.isValidIPv4(value) {
                ipAddresses.append(value)
            } else {
                dnsNames.append(value)
            }
        }
        var lines: [String] = []
        for (index, name) in dnsNames.enumerated() {
            lines.append("DNS.\(index + 1) = \(name)")
        }
        for (index, address) in ipAddresses.enumerated() {
            lines.append("IP.\(index + 1) = \(address)")
        }
        return lines.joined(separator: "\n")
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["OPENSSL_CONF": "/etc/ssl/openssl.cnf"],
            uniquingKeysWith: { _, new in new }
        )
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TLSIdentityError.opensslFailed(message.isEmpty ? "openssl exited with an error" : message)
        }
    }

    private static func subjectAlternativeNames(addresses: [String]) -> [String] {
        var values = ["localhost", "127.0.0.1"]
        var extras = addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { isValidIPv4($0) || isValidDNSName($0) }
        if let mdns = mdnsHostname() {
            extras.append(mdns)
        }
        for value in extras.sorted() where !values.contains(value) {
            values.append(value)
        }
        return values
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), (0...255).contains(number) else { return false }
            return String(number) == part || (part.count > 1 && part.first != "0")
        }
    }

    private static func isValidDNSName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard let tld = labels.last, tld.contains(where: { $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    private static func mdnsHostname() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        var host = String(cString: buffer).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasSuffix(".local") {
            host = String(host.dropLast(6))
        }
        host = String(host.map { character in
            if character.isASCII && (character.isLetter || character.isNumber || character == "-") {
                return character
            }
            return "-"
        })
        while host.hasPrefix("-") { host.removeFirst() }
        while host.hasSuffix("-") { host.removeLast() }
        guard host.count >= 2 else { return nil }
        if host.count > 63 {
            host = String(host.prefix(63))
            while host.hasSuffix("-") { host.removeLast() }
        }
        guard host.count >= 2 else { return nil }
        return host + ".local"
    }

    private static func certificateNeedsRenewal(_ url: URL) -> Bool {
        guard let certificate = try? NIOSSLCertificate.fromPEMFile(url.path).first else {
            return true
        }
        return TimeInterval(certificate.notValidAfter) < Date().timeIntervalSince1970 + 30 * 24 * 60 * 60
    }

    private static func fingerprint(certificateURL: URL) throws -> String {
        fingerprint(der: try certificateDER(fromPEM: certificateURL))
    }

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    public static func certificateDER(fromPEM url: URL) throws -> Data {
        let certificates: [NIOSSLCertificate]
        do {
            certificates = try NIOSSLCertificate.fromPEMFile(url.path)
        } catch {
            throw TLSIdentityError.missingCertificate
        }
        guard let certificate = certificates.first else {
            throw TLSIdentityError.missingCertificate
        }
        return Data(try certificate.toDERBytes())
    }

    public static func mobileConfiguration(caCertificateURL: URL, fingerprint: String) throws -> Data {
        let certificateData = try certificateDER(fromPEM: caCertificateURL)
        guard !certificateData.isEmpty else {
            throw TLSIdentityError.missingCertificate
        }
        let hex = fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        guard hex.count >= 32 else {
            throw TLSIdentityError.invalidIdentity
        }
        let identifier = "local.macdro.root.\(hex.prefix(16))"
        let payloadUUID = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-").uppercased()
        let certificatePayload: [String: Any] = [
            "PayloadCertificateFileName": "Macdro Local CA.crt",
            "PayloadContent": certificateData,
            "PayloadDescription": "Installs the Macdro local certificate authority.",
            "PayloadDisplayName": "Macdro Local CA",
            "PayloadIdentifier": identifier + ".certificate",
            "PayloadType": "com.apple.security.root",
            "PayloadUUID": payloadUUID,
            "PayloadVersion": 1
        ]
        let profile: [String: Any] = [
            "PayloadContent": [certificatePayload],
            "PayloadDescription": "Trusts Macdro on your local network. Verify the fingerprint in Macdro before installing.",
            "PayloadDisplayName": "Macdro Local Network",
            "PayloadIdentifier": identifier,
            "PayloadOrganization": "Macdro",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": payloadUUID,
            "PayloadVersion": 1
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        ), !data.isEmpty else {
            throw TLSIdentityError.invalidIdentity
        }
        return data
    }
}
