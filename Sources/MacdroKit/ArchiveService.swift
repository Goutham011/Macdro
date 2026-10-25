import CryptoKit
import Foundation

enum ArchiveServiceError: Error {
    case noFiles
    case tooManyEntries
    case archiveTooLarge
    case unavailable
}

final class ArchiveService: @unchecked Sendable {
    private struct CacheEntry {
        let date: Date
        let url: URL
    }

    private let lock = NSLock()
    private let flight = SingleFlight<URL>()
    private let buildGate = DispatchSemaphore(value: MacdroLimits.zipBuildConcurrency)
    private var cache: [String: CacheEntry] = [:]
    private var buildCountValue = 0

    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCountValue
    }

    func archive(for snapshot: SessionSnapshot, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !snapshot.files.isEmpty else {
            completion(.failure(ArchiveServiceError.noFiles))
            return
        }
        guard snapshot.files.count <= MacdroLimits.maxArchiveEntries else {
            completion(.failure(ArchiveServiceError.tooManyEntries))
            return
        }

        let key = Self.key(for: snapshot.files)
        if let url = cachedArchive(for: key) {
            completion(.success(url))
            return
        }

        flight.run(
            key: key,
            work: { [weak self] in
                guard let self else {
                    return .failure(ArchiveServiceError.unavailable)
                }
                let result = self.build(snapshot.files)
                if case .success(let url) = result {
                    self.store(url, for: key)
                }
                return result
            },
            completion: completion
        )
    }

    private func build(_ files: [SharedFile]) -> Result<URL, Error> {
        lock.lock()
        buildCountValue += 1
        lock.unlock()
        var total: UInt64 = 0
        var entries: [ZipEntry] = []
        entries.reserveCapacity(files.count)

        for file in files {
            let identity: FileIdentity
            do {
                identity = try FileMetadata.identity(for: file.sourceURL)
            } catch {
                return .failure(error)
            }
            let (next, overflow) = total.addingReportingOverflow(identity.size)
            guard !overflow, next <= MacdroLimits.maxArchiveInputBytes else {
                return .failure(ArchiveServiceError.archiveTooLarge)
            }
            total = next
            entries.append(
                ZipEntry(
                    url: file.sourceURL,
                    path: Self.safeArchivePath(file.relativePath)
                )
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Macdro-\(UUID().uuidString).zip")
        buildGate.wait()
        defer { buildGate.signal() }
        do {
            try ZipArchive.create(entries: entries, destination: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            guard size <= MacdroLimits.maxArchiveBytes else {
                throw ArchiveServiceError.archiveTooLarge
            }
            return .success(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(error)
        }
    }

    private func cachedArchive(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key],
              Date().timeIntervalSince(entry.date) < MacdroLimits.zipCacheTTLSeconds,
              FileManager.default.fileExists(atPath: entry.url.path)
        else {
            if let entry = cache.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: entry.url)
            }
            return nil
        }
        return entry.url
    }

    private func store(_ url: URL, for key: String) {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-MacdroLimits.zipCacheTTLSeconds)
        var removable = cache.filter { _, entry in entry.date < cutoff }
        let remaining = cache.count - removable.count
        if remaining >= 4 {
            let oldest = cache
                .filter { cacheKey, _ in removable[cacheKey] == nil && cacheKey != key }
                .sorted { $0.value.date < $1.value.date }
                .prefix(max(0, remaining - 3))
            for (cacheKey, entry) in oldest {
                removable[cacheKey] = entry
            }
        }
        for (cacheKey, entry) in removable {
            cache.removeValue(forKey: cacheKey)
            try? FileManager.default.removeItem(at: entry.url)
        }
        if let existing = cache.removeValue(forKey: key), existing.url != url {
            try? FileManager.default.removeItem(at: existing.url)
        }
        cache[key] = CacheEntry(date: Date(), url: url)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let entries = cache.values
        cache.removeAll()
        lock.unlock()
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    deinit {
        removeAll()
    }

    private static func key(for files: [SharedFile]) -> String {
        var hasher = SHA256()
        for file in files {
            let identity = try? FileMetadata.identity(for: file.sourceURL)
            let value = [
                file.id.uuidString,
                file.relativePath,
                String(file.size),
                identity.map { "\($0.inode):\($0.modifiedSeconds).\($0.modifiedNanoseconds):\($0.changedSeconds).\($0.changedNanoseconds)" }
                    ?? "missing"
            ].joined(separator: "\u{1F}")
            hasher.update(data: Data(value.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeArchivePath(_ path: String) -> String {
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return components.isEmpty ? "file" : components.joined(separator: "/")
    }
}
