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

    public static let resumableTTLSeconds: TimeInterval = 15 * 60
    public static let resumableCleanupIntervalSeconds: TimeInterval = 60
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
