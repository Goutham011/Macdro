import Darwin
import Foundation

public struct FileIdentity: Hashable, Sendable {
    public let path: String
    public let inode: UInt64
    public let size: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(
        path: String,
        inode: UInt64,
        size: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        changedSeconds: Int64,
        changedNanoseconds: Int64
    ) {
        self.path = path
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }
}

public enum FileMetadata {
    public static func identity(for url: URL) throws -> FileIdentity {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(
            path: url.path,
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    public static func etag(for url: URL) throws -> String {
        let identity = try identity(for: url)
        return "\"\(identity.inode)-\(identity.size)-\(identity.modifiedSeconds).\(identity.modifiedNanoseconds)-"
            + "\(identity.changedSeconds).\(identity.changedNanoseconds)\""
    }

    public static func isNoSpaceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(ENOSPC) || nsError.code == Int(EDQUOT)
        {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isNoSpaceError(underlying)
        {
            return true
        }
        return false
    }
}
