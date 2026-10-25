import CryptoKit
import Darwin
import Foundation

public enum UploadError: LocalizedError, Equatable {
    case fileCreationFailed
    case alreadyFinished
    case sizeMismatch
    case insufficientStorage
    case tooManyUploads
    case fileNameTooLong
    case unsafePath
    case uploadInProgress(offset: UInt64)
    case offsetMismatch(expected: UInt64)
    case uploadCompleted(offset: UInt64)
    case uploadLimitExceeded
    case capacityUnavailable

    public var errorDescription: String? {
        switch self {
        case .fileCreationFailed:
            return "Could not create the upload file."
        case .alreadyFinished:
            return "The upload has already finished."
        case .sizeMismatch:
            return "The uploaded size did not match the request."
        case .insufficientStorage, .capacityUnavailable:
            return "There is not enough free disk space to save the upload."
        case .tooManyUploads:
            return "Too many uploads are active."
        case .fileNameTooLong:
            return "The requested file path is too long."
        case .unsafePath:
            return "The requested upload path is not allowed."
        case .uploadInProgress:
            return "Another request is writing this upload."
        case .offsetMismatch:
            return "The upload offset does not match."
        case .uploadCompleted:
            return "The upload has already completed."
        case .uploadLimitExceeded:
            return "The file exceeds the upload size limit."
        }
    }
}

public struct UploadResult: Sendable {
    public let name: String
    public let relativePath: String
    public let path: String
    public let size: UInt64
    public let checksum: String

    public init(
        name: String,
        relativePath: String,
        path: String,
        size: UInt64,
        checksum: String
    ) {
        self.name = name
        self.relativePath = relativePath
        self.path = path
        self.size = size
        self.checksum = checksum
    }
}

public final class UploadStore: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var idleTimeout: TimeInterval
        public var cleanupInterval: TimeInterval
        public var maxActiveTransactions: Int
        public var maxTransactionsPerClient: Int
        public var maxConcurrentTransactions: Int
        public var maxConcurrentPerClient: Int
        public var quotaBytes: UInt64?
        public var reservedDiskBytes: UInt64
        public var maxUploadBytes: UInt64

        public init(
            idleTimeout: TimeInterval = MacdroLimits.resumableTTLSeconds,
            cleanupInterval: TimeInterval = MacdroLimits.resumableCleanupIntervalSeconds,
            maxActiveTransactions: Int = MacdroLimits.maxResumableUploads,
            maxTransactionsPerClient: Int = MacdroLimits.maxResumableUploadsPerClient,
            maxConcurrentTransactions: Int = MacdroLimits.maxConcurrentUploads,
            maxConcurrentPerClient: Int = MacdroLimits.maxConcurrentUploadsPerClient,
            quotaBytes: UInt64? = MacdroLimits.maxTotalUploadBytes,
            reservedDiskBytes: UInt64 = MacdroLimits.reservedDiskBytes,
            maxUploadBytes: UInt64 = MacdroLimits.maxUploadBytes
        ) {
            self.idleTimeout = idleTimeout
            self.cleanupInterval = cleanupInterval
            self.maxActiveTransactions = maxActiveTransactions
            self.maxTransactionsPerClient = maxTransactionsPerClient
            self.maxConcurrentTransactions = maxConcurrentTransactions
            self.maxConcurrentPerClient = maxConcurrentPerClient
            self.quotaBytes = quotaBytes
            self.reservedDiskBytes = reservedDiskBytes
            self.maxUploadBytes = maxUploadBytes
        }
    }

    public let directory: URL
    public let configuration: Configuration

    private struct ResumableEntry {
        let transaction: UploadTransaction
        let client: String
        var lastActivity: Date
        var leaseHeld: Bool
        var offset: UInt64
    }

    private let lock = NSLock()
    private var reservedPaths: Set<String> = []
    private var resumableUploads: [String: ResumableEntry] = [:]
    private var nonResumableCount = 0
    private var nonResumableByClient: [String: Int] = [:]
    private var reservedRemaining: UInt64 = 0
    private var committedBytes: UInt64 = 0
    private var completedUploads: [String: (date: Date, offset: UInt64)] = [:]
    private let cleanupQueue = DispatchQueue(label: "macdro.upload.cleanup", qos: .utility)
    private var cleanupTimer: DispatchSourceTimer?

    public init(directory: URL, configuration: Configuration = Configuration()) {
        self.directory = directory
        self.configuration = configuration
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeOrphanedTemporaryFiles(in: directory)
        self.committedBytes = Self.directoryBytes(at: directory)
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.cancel()
    }

    public func begin(
        name: String,
        relativePath: String? = nil,
        expectedSize: UInt64?,
        client: String = "local"
    ) throws -> UploadTransaction {
        lock.lock()
        defer { lock.unlock() }

        guard activeCountLocked() < configuration.maxConcurrentTransactions,
              concurrencyForClientLocked(client) < configuration.maxConcurrentPerClient
        else {
            throw UploadError.tooManyUploads
        }
        if let expectedSize, expectedSize > configuration.maxUploadBytes {
            throw UploadError.uploadLimitExceeded
        }

        let transaction = try beginLocked(
            name: name,
            relativePath: relativePath,
            expectedSize: expectedSize,
            client: client,
            isResumable: false
        )
        nonResumableCount += 1
        nonResumableByClient[client, default: 0] += 1
        return transaction
    }

    public func beginResumable(
        id: String,
        name: String,
        relativePath: String? = nil,
        expectedSize: UInt64?,
        offset: UInt64,
        complete: Bool,
        client: String
    ) throws -> UploadTransaction {
        lock.lock()
        defer { lock.unlock() }

        pruneCompletedLocked()

        if let completed = completedUploads[id] {
            throw UploadError.uploadCompleted(offset: completed.offset)
        }

        let now = Date()
        if var entry = resumableUploads[id] {
            let requestedPath = UploadStore.requestPath(name: name, relativePath: relativePath)
            guard entry.transaction.requestedName == requestedPath else {
                throw UploadError.sizeMismatch
            }
            if let expectedSize, let existingSize = entry.transaction.expectedSize,
               expectedSize != existingSize
            {
                throw UploadError.sizeMismatch
            }
            if let expectedSize, expectedSize > configuration.maxUploadBytes {
                throw UploadError.uploadLimitExceeded
            }
            guard entry.client == client else {
                throw UploadError.uploadInProgress(offset: entry.offset)
            }
            guard !entry.leaseHeld else {
                throw UploadError.uploadInProgress(offset: entry.offset)
            }
            guard offset == entry.offset else {
                throw UploadError.offsetMismatch(expected: entry.offset)
            }
            guard activeCountLocked() < configuration.maxConcurrentTransactions,
                  concurrencyForClientLocked(client) < configuration.maxConcurrentPerClient
            else {
                throw UploadError.tooManyUploads
            }
            entry.leaseHeld = true
            entry.lastActivity = now
            resumableUploads[id] = entry
            entry.transaction.claimLease(id: id)
            return entry.transaction
        }

        let activeResumable = resumableUploads.count
        let clientResumable = resumableUploads.values.reduce(into: 0) { count, entry in
            if entry.client == client { count += 1 }
        }
        guard activeResumable < configuration.maxActiveTransactions,
              clientResumable < configuration.maxTransactionsPerClient,
              activeCountLocked() < configuration.maxConcurrentTransactions,
              concurrencyForClientLocked(client) < configuration.maxConcurrentPerClient
        else {
            throw UploadError.tooManyUploads
        }
        guard offset == 0 else {
            throw UploadError.offsetMismatch(expected: 0)
        }

        let transaction = try beginLocked(
            name: name,
            relativePath: relativePath,
            expectedSize: expectedSize,
            client: client,
            isResumable: true
        )
        transaction.claimLease(id: id)
        resumableUploads[id] = ResumableEntry(
            transaction: transaction,
            client: client,
            lastActivity: now,
            leaseHeld: true,
            offset: 0
        )
        return transaction
    }

    public func releaseLease(id: String) {
        lock.lock()
        if var entry = resumableUploads[id] {
            entry.leaseHeld = false
            entry.lastActivity = Date()
            resumableUploads[id] = entry
        }
        lock.unlock()
    }

    public func resumable(id: String) -> UploadTransaction? {
        lock.lock()
        defer { lock.unlock() }
        return resumableUploads[id]?.transaction
    }

    public func touchResumable(id: String) {
        lock.lock()
        if var entry = resumableUploads[id] {
            entry.lastActivity = Date()
            resumableUploads[id] = entry
        }
        lock.unlock()
    }

    public func removeResumable(id: String) {
        lock.lock()
        let entry = resumableUploads.removeValue(forKey: id)
        lock.unlock()
        entry?.transaction.cancel()
    }

    public func completeResumable(id: String, offset: UInt64) {
        lock.lock()
        resumableUploads.removeValue(forKey: id)
        completedUploads[id] = (Date(), offset)
        pruneCompletedLocked()
        lock.unlock()
    }

    public func failResumable(id: String) {
        lock.lock()
        let entry = resumableUploads.removeValue(forKey: id)
        lock.unlock()
        entry?.transaction.cancel()
    }

    public func cleanupExpired(now: Date = Date()) {
        var expired: [UploadTransaction] = []
        lock.lock()
        for (id, entry) in resumableUploads
        where !entry.leaseHeld && now.timeIntervalSince(entry.lastActivity) >= configuration.idleTimeout {
            resumableUploads.removeValue(forKey: id)
            expired.append(entry.transaction)
        }
        pruneCompletedLocked(now: now)
        lock.unlock()
        for transaction in expired {
            transaction.cancel()
        }
    }

    public var activeResumableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resumableUploads.count
    }

    public var resumableTemporaryFileCount: Int {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasPrefix(".macdro-") && $0.hasSuffix(".part") }.count
    }

    public var availableDiskBytes: UInt64? {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    public static func requestPath(name: String, relativePath: String?) -> String {
        guard let relativePath, !relativePath.isEmpty else {
            return sanitizeName(name)
        }

        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        var components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        _ = components.popLast()

        let directories = components.compactMap { component -> String? in
            guard component != ".", component != ".." else { return nil }
            let safe = sanitizeComponent(component)
            guard !safe.isEmpty else { return nil }
            return safe
        }
        let base = sanitizeName(name)
        return (directories + [base]).joined(separator: "/")
    }

    fileprivate func consumeReservation(
        transaction: UploadTransaction,
        additional: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if transaction.reservedRemaining >= additional {
            return
        }
        try ensureCapacityLocked(additional: additional)
        reservedRemaining &+= additional
        transaction.reservedRemaining += additional
    }

    fileprivate func commitReservation(transaction: UploadTransaction, additional: UInt64) {
        lock.lock()
        let amount = min(additional, transaction.reservedRemaining)
        transaction.reservedRemaining -= amount
        reservedRemaining = reservedRemaining >= amount ? reservedRemaining - amount : 0
        let (next, overflow) = committedBytes.addingReportingOverflow(additional)
        committedBytes = overflow ? UInt64.max : next
        if let leaseID = transaction.leaseUploadID, var entry = resumableUploads[leaseID] {
            entry.offset = entry.offset &+ additional
            resumableUploads[leaseID] = entry
        }
        lock.unlock()
    }

    fileprivate func rollbackReservation(transaction: UploadTransaction, additional: UInt64) {
        lock.lock()
        let amount = min(additional, transaction.reservedRemaining)
        transaction.reservedRemaining -= amount
        reservedRemaining = reservedRemaining >= amount ? reservedRemaining - amount : 0
        lock.unlock()
    }

    fileprivate func settle(_ transaction: UploadTransaction, resumable: Bool, discarded: Bool = false) {
        lock.lock()
        reservedRemaining = reservedRemaining >= transaction.reservedRemaining
            ? reservedRemaining - transaction.reservedRemaining
            : 0
        transaction.reservedRemaining = 0
        if discarded {
            committedBytes = committedBytes >= transaction.written
                ? committedBytes - transaction.written
                : 0
        }
        reservedPaths.remove(transaction.relativePath)
        if !resumable {
            nonResumableCount = max(0, nonResumableCount - 1)
            let next = max(0, nonResumableByClient[transaction.client, default: 0] - 1)
            if next == 0 {
                nonResumableByClient.removeValue(forKey: transaction.client)
            } else {
                nonResumableByClient[transaction.client] = next
            }
        }
        lock.unlock()
    }

    fileprivate func canAppend(_ bytes: UInt64, transaction: UploadTransaction) throws {
        guard bytes <= configuration.maxUploadBytes,
              transaction.written <= configuration.maxUploadBytes - bytes
        else {
            throw UploadError.uploadLimitExceeded
        }
    }

    private func activeCountLocked() -> Int {
        let leased = resumableUploads.values.reduce(into: 0) { count, entry in
            if entry.leaseHeld { count += 1 }
        }
        return nonResumableCount + leased
    }

    private func concurrencyForClientLocked(_ client: String) -> Int {
        let leased = resumableUploads.values.reduce(into: 0) { count, entry in
            if entry.leaseHeld && entry.client == client { count += 1 }
        }
        return nonResumableByClient[client, default: 0] + leased
    }

    private func beginLocked(
        name: String,
        relativePath: String?,
        expectedSize: UInt64?,
        client: String,
        isResumable: Bool
    ) throws -> UploadTransaction {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let requestedPath = Self.requestPath(name: name, relativePath: relativePath)
        guard requestedPath.utf8.count <= 900 else {
            throw UploadError.fileNameTooLong
        }

        if let expectedSize {
            try ensureCapacityLocked(additional: expectedSize)
        }

        let finalRelativePath = Self.uniquePath(
            for: requestedPath,
            directory: directory,
            reserved: reservedPaths
        )
        reservedPaths.insert(finalRelativePath)

        let finalURL = directory.appendingPathComponent(finalRelativePath)
        do {
            try fileManager.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.ensureContained(
                finalURL.deletingLastPathComponent(),
                inside: directory
            )
        } catch {
            reservedPaths.remove(finalRelativePath)
            throw error is UploadError ? error : UploadError.fileCreationFailed
        }

        let temporaryURL = directory.appendingPathComponent(".macdro-\(UUID().uuidString).part")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            reservedPaths.remove(finalRelativePath)
            throw UploadError.insufficientStorage
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            if let expectedSize {
                reservedRemaining &+= expectedSize
            }
            return UploadTransaction(
                store: self,
                name: finalURL.lastPathComponent,
                requestedName: requestedPath,
                relativePath: finalRelativePath,
                temporaryURL: temporaryURL,
                finalURL: finalURL,
                handle: handle,
                expectedSize: expectedSize,
                reservedRemaining: expectedSize ?? 0,
                client: client,
                isResumable: isResumable
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            reservedPaths.remove(finalRelativePath)
            throw UploadError.fileCreationFailed
        }
    }

    private func ensureCapacityLocked(additional: UInt64) throws {
        guard additional <= configuration.maxUploadBytes else {
            throw UploadError.uploadLimitExceeded
        }

        let floor = configuration.reservedDiskBytes > 0
            ? configuration.reservedDiskBytes
            : MacdroLimits.dynamicReservedDiskBytes(volumeCapacity: volumeCapacityBytes() ?? 0)

        if let available = availableDiskBytes {
            let (required, overflow) = additional.addingReportingOverflow(reservedRemaining)
            guard !overflow else { throw UploadError.insufficientStorage }
            let (withFloor, floorOverflow) = required.addingReportingOverflow(floor)
            guard !floorOverflow, available >= withFloor else {
                throw UploadError.insufficientStorage
            }
        }

        if let quota = configuration.quotaBytes {
            let used = committedBytes
            let (committed, overflow) = reservedRemaining.addingReportingOverflow(additional)
            guard !overflow, used <= quota, committed <= quota - used else {
                throw UploadError.insufficientStorage
            }
        }
    }

    private func volumeCapacityBytes() -> UInt64? {
        let values = try? directory.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
    }

    private func pruneCompletedLocked(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-MacdroLimits.completedUploadTTLSeconds)
        completedUploads = completedUploads.filter { $0.value.date >= cutoff }
        let excess = completedUploads.count - MacdroLimits.maxCompletedUploadTombstones
        guard excess > 0 else { return }
        let oldest = completedUploads
            .sorted { $0.value.date < $1.value.date }
            .prefix(excess)
        for (id, _) in oldest {
            completedUploads.removeValue(forKey: id)
        }
    }

    private func startCleanupTimer() {
        guard configuration.cleanupInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: cleanupQueue)
        timer.schedule(
            deadline: .now() + configuration.cleanupInterval,
            repeating: configuration.cleanupInterval
        )
        timer.setEventHandler { [weak self] in
            self?.cleanupExpired()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private static func removeOrphanedTemporaryFiles(in directory: URL) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents
        where url.lastPathComponent.hasPrefix(".macdro-")
            && url.lastPathComponent.hasSuffix(".part")
        {
            try? fileManager.removeItem(at: url)
        }
    }

    fileprivate static func ensureContained(_ url: URL, inside root: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedURL == resolvedRoot || resolvedURL.hasPrefix(resolvedRoot + "/") else {
            throw UploadError.unsafePath
        }
    }

    private static func directoryBytes(at directory: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            let (next, overflow) = total.addingReportingOverflow(UInt64(max(0, size)))
            total = overflow ? UInt64.max : next
        }
        return total
    }

    private static func sanitizeName(_ raw: String) -> String {
        let sanitized = sanitizeComponent(raw)
        let name = sanitized.isEmpty ? "Untitled" : sanitized
        if name.hasPrefix(".macdro-") && name.hasSuffix(".part") {
            return "_" + name
        }
        return name
    }

    private static func sanitizeComponent(_ raw: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{FEFF}"
        ]
        var name = ""
        name.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7F
                || scalar == "/" || dangerous.contains(scalar)
            {
                name.append("_")
            } else {
                name.unicodeScalars.append(scalar)
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: ":", with: "_")
        if name == "." || name == ".." {
            return "_"
        }
        return truncateFilename(name)
    }

    private static func truncateFilename(_ name: String) -> String {
        let maxUnits = 240
        let maxBytes = 240
        guard name.utf16.count > maxUnits || name.utf8.count > maxBytes else {
            return name
        }

        let nsName = name as NSString
        var pathExtension = nsName.pathExtension
        pathExtension = prefixWithin(
            pathExtension,
            maxUnits: maxUnits / 2,
            maxBytes: maxBytes / 2
        )
        let stem = pathExtension.isEmpty ? name : nsName.deletingPathExtension
        let extensionUnits = pathExtension.isEmpty ? 0 : pathExtension.utf16.count + 1
        let extensionBytes = pathExtension.isEmpty ? 0 : pathExtension.utf8.count + 1
        let stemUnits = max(1, maxUnits - extensionUnits)
        let stemBytes = max(1, maxBytes - extensionBytes)

        var trimmed = ""
        var usedUnits = 0
        var usedBytes = 0
        for character in stem {
            let value = String(character)
            let units = value.utf16.count
            let bytes = value.utf8.count
            if usedUnits + units > stemUnits || usedBytes + bytes > stemBytes { break }
            trimmed.append(character)
            usedUnits += units
            usedBytes += bytes
        }
        if trimmed.isEmpty {
            trimmed = "file"
        }
        return pathExtension.isEmpty ? trimmed : "\(trimmed).\(pathExtension)"
    }

    private static func prefixWithin(
        _ string: String,
        maxUnits: Int,
        maxBytes: Int
    ) -> String {
        var result = ""
        var usedUnits = 0
        var usedBytes = 0
        for character in string {
            let value = String(character)
            let units = value.utf16.count
            let bytes = value.utf8.count
            if usedUnits + units > maxUnits || usedBytes + bytes > maxBytes { break }
            result.append(character)
            usedUnits += units
            usedBytes += bytes
        }
        return result
    }

    private static func uniquePath(
        for relativePath: String,
        directory: URL,
        reserved: Set<String>
    ) -> String {
        let fileManager = FileManager.default
        let original = directory.appendingPathComponent(relativePath)
        if !reserved.contains(relativePath), !fileManager.fileExists(atPath: original.path) {
            return relativePath
        }

        let nsPath = relativePath as NSString
        let directoryPart = nsPath.deletingLastPathComponent
        let base = nsPath.lastPathComponent as NSString
        let pathExtension = base.pathExtension
        let stem = pathExtension.isEmpty ? base as String : base.deletingPathExtension
        let prefix = directoryPart == "." ? "" : directoryPart + "/"

        for index in 1...10_000 {
            let candidateName = pathExtension.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(pathExtension)"
            let candidate = prefix + candidateName
            let candidateURL = directory.appendingPathComponent(candidate)
            if !reserved.contains(candidate), !fileManager.fileExists(atPath: candidateURL.path) {
                return candidate
            }
        }

        let suffix = String(UUID().uuidString.prefix(8))
        let fallbackName = pathExtension.isEmpty
            ? "\(stem)-\(suffix)"
            : "\(stem)-\(suffix).\(pathExtension)"
        return prefix + fallbackName
    }
}

public final class UploadTransaction: @unchecked Sendable {
    private let store: UploadStore
    private let handle: FileHandle
    private let lock = NSLock()
    public let name: String
    public let requestedName: String
    public let relativePath: String
    public let temporaryURL: URL
    public let finalURL: URL
    public let expectedSize: UInt64?
    public let client: String
    public let isResumable: Bool
    fileprivate var reservedRemaining: UInt64
    fileprivate var written: UInt64 = 0
    private var isFinished = false
    private var hasher = SHA256()
    private var checksumValue: String?
    fileprivate var leaseUploadID: String?
    private var leaseClaimed = false
    private var handleClosed = false

    public var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    public var checksum: String? {
        lock.lock()
        defer { lock.unlock() }
        return checksumValue
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !handleClosed
    }

    fileprivate init(
        store: UploadStore,
        name: String,
        requestedName: String,
        relativePath: String,
        temporaryURL: URL,
        finalURL: URL,
        handle: FileHandle,
        expectedSize: UInt64?,
        reservedRemaining: UInt64,
        client: String,
        isResumable: Bool
    ) {
        self.store = store
        self.name = name
        self.requestedName = requestedName
        self.relativePath = relativePath
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        self.handle = handle
        self.expectedSize = expectedSize
        self.reservedRemaining = reservedRemaining
        self.client = client
        self.isResumable = isResumable
    }

    fileprivate func claimLease(id: String) {
        lock.lock()
        leaseUploadID = id
        leaseClaimed = true
        lock.unlock()
    }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { throw UploadError.alreadyFinished }
        let count = UInt64(data.count)
        let (nextSize, overflow) = written.addingReportingOverflow(count)
        guard !overflow else { throw UploadError.uploadLimitExceeded }
        if let expectedSize, nextSize > expectedSize {
            throw UploadError.sizeMismatch
        }
        try store.canAppend(count, transaction: self)
        try store.consumeReservation(transaction: self, additional: count)

        do {
            try handle.write(contentsOf: data)
        } catch {
            store.rollbackReservation(transaction: self, additional: count)
            throw Self.mapWriteError(error)
        }
        store.commitReservation(transaction: self, additional: count)
        hasher.update(data: data)
        written = nextSize
    }

    public func finish() throws -> UploadResult {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { throw UploadError.alreadyFinished }
        isFinished = true

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        checksumValue = digest

        do {
            try handle.synchronize()
            try handle.close()
            handleClosed = true
        } catch {
            try? handle.close()
            handleClosed = true
            try? FileManager.default.removeItem(at: temporaryURL)
            store.settle(self, resumable: isResumable, discarded: true)
            throw Self.mapWriteError(error)
        }

        if let expectedSize, written != expectedSize {
            try? FileManager.default.removeItem(at: temporaryURL)
            store.settle(self, resumable: isResumable, discarded: true)
            throw UploadError.sizeMismatch
        }

        do {
            try UploadStore.ensureContained(
                finalURL.deletingLastPathComponent(),
                inside: store.directory
            )
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try UploadStore.ensureContained(
                finalURL.deletingLastPathComponent(),
                inside: store.directory
            )
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            store.settle(self, resumable: isResumable, discarded: true)
            throw Self.mapWriteError(error)
        }

        store.settle(self, resumable: isResumable)
        return UploadResult(
            name: name,
            relativePath: relativePath,
            path: finalURL.path,
            size: written,
            checksum: digest
        )
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return }
        isFinished = true
        try? handle.close()
        handleClosed = true
        try? FileManager.default.removeItem(at: temporaryURL)
        store.settle(self, resumable: isResumable, discarded: true)
    }

    private static func mapWriteError(_ error: Error) -> Error {
        if FileMetadata.isNoSpaceError(error) {
            return UploadError.insufficientStorage
        }
        return error
    }
}
