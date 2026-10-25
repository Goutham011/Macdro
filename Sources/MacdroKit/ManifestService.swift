import CryptoKit
import Foundation

public struct ManifestFile: Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let size: UInt64
    public let sha256: String?

    public init(id: String, name: String, path: String, size: UInt64, sha256: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public struct ManifestPayload: Codable, Sendable {
    public let files: [ManifestFile]

    public init(files: [ManifestFile]) {
        self.files = files
    }
}

final class ManifestService: @unchecked Sendable {
    private struct CacheEntry {
        let date: Date
        let data: Data
    }

    private let lock = NSLock()
    private let flight = SingleFlight<Data>()
    private let hashGate = DispatchSemaphore(value: MacdroLimits.manifestHashConcurrency)
    private var cache: [String: CacheEntry] = [:]
    private var cacheBytes = 0
    private var buildCountValue = 0

    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCountValue
    }

    func data(for snapshot: SessionSnapshot, completion: @escaping (Result<Data, Error>) -> Void) {
        let key = Self.key(for: snapshot.files)
        if let cached = cachedData(for: key) {
            completion(.success(cached))
            return
        }

        flight.run(
            key: key,
            work: { [weak self] in
                guard let self else {
                    return .failure(ManifestError.unavailable)
                }
                let result = self.build(snapshot.files)
                if case .success(let data) = result {
                    self.store(data, for: key)
                }
                return result
            },
            completion: completion
        )
    }

    private func build(_ files: [SharedFile]) -> Result<Data, Error> {
        lock.lock()
        buildCountValue += 1
        lock.unlock()
        var entries: [ManifestFile] = []
        entries.reserveCapacity(files.count)

        for file in files {
            hashGate.wait()
            defer { hashGate.signal() }
            entries.append(
                ManifestFile(
                    id: file.id.uuidString.lowercased(),
                    name: file.name,
                    path: file.relativePath,
                    size: file.size,
                    sha256: try? Checksums.sha256(fileURL: file.sourceURL)
                )
            )
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(ManifestPayload(files: entries))
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    private func cachedData(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key],
              Date().timeIntervalSince(entry.date) < MacdroLimits.manifestCacheTTLSeconds
        else {
            removeLocked(key)
            return nil
        }
        return entry.data
    }

    private func store(_ data: Data, for key: String) {
        guard data.count <= MacdroLimits.manifestCacheMaxBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        removeLocked(key)
        cache[key] = CacheEntry(date: Date(), data: data)
        cacheBytes += data.count
        let cutoff = Date().addingTimeInterval(-MacdroLimits.manifestCacheTTLSeconds)
        let expired = cache.filter { $0.key != key && $0.value.date < cutoff }.map(\.key)
        for cacheKey in expired {
            removeLocked(cacheKey)
        }
        while cache.count > 8 || cacheBytes > MacdroLimits.manifestCacheMaxBytes {
            let oldest = cache
                .filter { $0.key != key }
                .min { $0.value.date < $1.value.date }
            guard let oldest else { break }
            removeLocked(oldest.key)
        }
    }

    private func removeLocked(_ key: String) {
        guard let entry = cache.removeValue(forKey: key) else { return }
        cacheBytes = max(0, cacheBytes - entry.data.count)
    }

    private static func key(for files: [SharedFile]) -> String {
        var hasher = SHA256()
        for file in files {
            let identity = try? FileMetadata.identity(for: file.sourceURL)
            let value = [
                file.id.uuidString,
                file.relativePath,
                String(file.size),
                identity.map { "\($0.inode):\($0.modifiedSeconds).\($0.modifiedNanoseconds):\($0.changedNanoseconds)" }
                    ?? "missing"
            ].joined(separator: "\u{1F}")
            hasher.update(data: Data(value.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ManifestError: Error {
    case unavailable
    case tooManyEntries
}
