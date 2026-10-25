import Foundation

public final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenValue: String
    private var cookieValue: String
    private var filesByID: [UUID: SharedFile]
    private var orderedIDs: [UUID]
    private let createdAt: Date
    private var authGenerationValue: UInt64 = 0
    private var contentGenerationValue: UInt64 = 0

    public static let cookieName = "macdro_session"

    public init(token: String? = nil, cookie: String? = nil) {
        self.tokenValue = token ?? SessionStore.generateToken()
        self.cookieValue = cookie ?? SessionStore.generateToken()
        self.filesByID = [:]
        self.orderedIDs = []
        self.createdAt = Date()
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var token: String {
        lock.lock()
        defer { lock.unlock() }
        return tokenValue
    }

    public var sessionCookie: String {
        lock.lock()
        defer { lock.unlock() }
        return cookieValue
    }

    public var authGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return authGenerationValue
    }

    public var contentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return contentGenerationValue
    }

    public func rotateSessionCookie() -> String {
        lock.lock()
        defer { lock.unlock() }
        cookieValue = SessionStore.generateToken()
        authGenerationValue &+= 1
        return cookieValue
    }

    public func snapshot() -> SessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let files = orderedIDs.compactMap { filesByID[$0] }
        return SessionSnapshot(token: tokenValue, files: files, createdAt: createdAt)
    }

    public func add(_ files: [SharedFile]) {
        guard !files.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for file in files where filesByID[file.id] == nil {
            filesByID[file.id] = file
            orderedIDs.append(file.id)
            changed = true
        }
        if changed { contentGenerationValue &+= 1 }
    }

    public func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if filesByID.removeValue(forKey: id) != nil {
            orderedIDs.removeAll { $0 == id }
            contentGenerationValue &+= 1
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        if !filesByID.isEmpty { contentGenerationValue &+= 1 }
        filesByID.removeAll()
        orderedIDs.removeAll()
    }

    public func file(id: UUID) -> SharedFile? {
        lock.lock()
        defer { lock.unlock() }
        return filesByID[id]
    }

    @discardableResult
    public func rotateToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        tokenValue = SessionStore.generateToken()
        cookieValue = SessionStore.generateToken()
        authGenerationValue &+= 1
        return tokenValue
    }
}
