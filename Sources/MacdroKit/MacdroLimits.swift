import Foundation

public enum MacdroLimits {
    public static let maxBufferedBodyBytes = 1 * 1024 * 1024
    public static let maxHeaderFieldSize = 16 * 1024
    public static let maxHeaderListSize = 32 * 1024
    public static let maxHeaderFieldCount = 100
    public static let readTimeoutSeconds = 30
    public static let maxConnections = 128
    public static let maxConnectionsPerIP = 16
    public static let maxRejectedBodyDrainBytes = 8 * 1024 * 1024

    public static let minBodyTimeoutSeconds: TimeInterval = 60
    public static let maxBodyTimeoutSeconds: TimeInterval = 6 * 60 * 60
    public static let chunkedBodyTimeoutSeconds: TimeInterval = 15 * 60
    public static let bodyMinimumThroughputBytesPerSecond = 64 * 1024

    public static let resumableTTLSeconds: TimeInterval = 15 * 60
    public static let resumableCleanupIntervalSeconds: TimeInterval = 60
    public static let leaseHardTimeoutSeconds: TimeInterval = 8 * 60 * 60
    public static let completedUploadTTLSeconds: TimeInterval = 10 * 60
    public static let maxCompletedUploadTombstones = 4_096
    public static let maxResumableUploads = 64
    public static let maxResumableUploadsPerClient = 8
    public static let maxConcurrentUploads = 32
    public static let maxConcurrentUploadsPerClient = 4
    public static let maxPendingUploadBytes = 8 * 1024 * 1024
    public static let uploadCoalesceBytes = 4 * 1024 * 1024
    public static let maxUploadBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let maxTotalUploadBytes: UInt64 = 64 * 1024 * 1024 * 1024

    public static let minReservedDiskBytes: UInt64 = 32 * 1024 * 1024
    public static let maxReservedDiskBytes: UInt64 = 512 * 1024 * 1024
    public static let reservedDiskBytes: UInt64 = 0

    public static let maxClipboardBytes = 1 * 1024 * 1024
    public static let sseHeartbeatSeconds: TimeInterval = 10
    public static let sseMaxLifetimeSeconds: TimeInterval = 60 * 60
    public static let manifestHashConcurrency = 2
    public static let manifestCacheTTLSeconds: TimeInterval = 5 * 60
    public static let manifestCacheMaxBytes = 64 * 1024 * 1024
    public static let zipCacheTTLSeconds: TimeInterval = 5 * 60
    public static let zipBuildConcurrency = 1
    public static let maxArchiveEntries = 100_000
    public static let maxArchiveBytes: UInt64 = 64 * 1024 * 1024 * 1024
    public static let maxArchiveInputBytes: UInt64 = 64 * 1024 * 1024 * 1024
    public static let zipRateLimitPerMinute = 12
    public static let manifestRateLimitPerMinute = 60
    public static let clipboardRateLimitPerMinute = 60
    public static let uploadStartRateLimitPerMinute = 600

    public static func dynamicReservedDiskBytes(volumeCapacity: UInt64) -> UInt64 {
        let tenth = volumeCapacity / 10
        return min(maxReservedDiskBytes, max(minReservedDiskBytes, tenth))
    }
}

/// Size-aware absolute deadline for receiving a single request body.
///
/// The deadline is armed when the request head is accepted and does not reset
/// when bytes arrive, so a client cannot hold a connection open indefinitely by
/// trickling data. Known-length bodies get `contentLength / minimumThroughput`
/// seconds clamped to `[minSeconds, maxSeconds]`; chunked or unknown-length
/// bodies get a fixed `chunkedSeconds` budget. A 16 MiB browser chunk therefore
/// receives roughly 256 s at the default 64 KiB/s floor, while a full 16 GiB
/// single-request upload is bounded by `maxSeconds` (requiring ≈790 KiB/s
/// average throughput to finish in time — well within LAN speeds; the web
/// client always uses resumable 16 MiB chunks, so it is unaffected by the
/// absolute cap).
public struct BodyTimeoutPolicy: Sendable {
    public var minSeconds: TimeInterval
    public var maxSeconds: TimeInterval
    public var chunkedSeconds: TimeInterval
    public var minimumThroughputBytesPerSecond: Int

    public init(
        minSeconds: TimeInterval = MacdroLimits.minBodyTimeoutSeconds,
        maxSeconds: TimeInterval = MacdroLimits.maxBodyTimeoutSeconds,
        chunkedSeconds: TimeInterval = MacdroLimits.chunkedBodyTimeoutSeconds,
        minimumThroughputBytesPerSecond: Int = MacdroLimits.bodyMinimumThroughputBytesPerSecond
    ) {
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.chunkedSeconds = chunkedSeconds
        self.minimumThroughputBytesPerSecond = max(1, minimumThroughputBytesPerSecond)
    }

    public func deadlineSeconds(contentLength: UInt64?) -> Int {
        guard let contentLength else {
            return boundedSeconds(chunkedSeconds)
        }
        let throughput = UInt64(minimumThroughputBytesPerSecond)
        let (quotient, remainder) = contentLength.quotientAndRemainder(dividingBy: throughput)
        let needed = quotient + (remainder == 0 ? 0 : 1)
        let lowerBound = boundedSeconds(minSeconds)
        let upperBound = max(lowerBound, boundedSeconds(maxSeconds))
        guard needed < UInt64(upperBound) else { return upperBound }
        return Int(max(needed, UInt64(lowerBound)))
    }

    private func boundedSeconds(_ interval: TimeInterval) -> Int {
        let clamped = interval.rounded(.up).clamped(to: 1...Double(Int.max))
        return max(1, Int(clamped))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
