import Foundation
import UniformTypeIdentifiers

public struct SharedFile: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let sourcePath: String
    public let relativePath: String
    public let name: String
    public let size: UInt64
    public let contentType: String
    public let modifiedAt: Date

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        relativePath: String,
        name: String? = nil,
        size: UInt64,
        contentType: String? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.name = name ?? URL(fileURLWithPath: sourcePath).lastPathComponent
        self.size = size
        self.contentType = contentType
            ?? UTType(filenameExtension: URL(fileURLWithPath: sourcePath).pathExtension)?
                .preferredMIMEType
            ?? "application/octet-stream"
        self.modifiedAt = modifiedAt
    }

    public var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    public var etag: String {
        "\(size)-\(DateEpoch.seconds(modifiedAt))"
    }
}

public struct SessionSnapshot: Sendable {
    public let token: String
    public let files: [SharedFile]
    public let createdAt: Date

    public init(token: String, files: [SharedFile], createdAt: Date) {
        self.token = token
        self.files = files
        self.createdAt = createdAt
    }

    public var totalBytes: UInt64 {
        files.reduce(0) { $0 + $1.size }
    }
}

public enum FileFormatting {
    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
