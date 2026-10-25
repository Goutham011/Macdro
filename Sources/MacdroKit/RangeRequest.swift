import Foundation

public enum RangeRequest {
    public struct ByteRange: Equatable, Sendable {
        public let start: UInt64
        public let end: UInt64

        public init(start: UInt64, end: UInt64) {
            self.start = start
            self.end = end
        }

        public var length: UInt64 {
            end >= start ? end - start + 1 : 0
        }
    }

    public enum Result: Equatable, Sendable {
        case full
        case partial(ByteRange)
        case unsatisfiable
    }

    public static func parse(header: String?, fileSize: UInt64) -> Result {
        guard let header, !header.isEmpty else { return .full }
        guard header.hasPrefix("bytes=") else { return .full }
        if fileSize == 0 { return .unsatisfiable }

        let spec = String(header.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return .full }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }

        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffixLength = UInt64(endText), suffixLength > 0 else {
                return .unsatisfiable
            }
            let length = min(suffixLength, fileSize)
            return .partial(ByteRange(start: fileSize - length, end: fileSize - 1))
        }

        guard let start = UInt64(startText), start < fileSize else {
            return .unsatisfiable
        }

        if endText.isEmpty {
            return .partial(ByteRange(start: start, end: fileSize - 1))
        }

        guard let requestedEnd = UInt64(endText), requestedEnd >= start else {
            return .unsatisfiable
        }

        return .partial(ByteRange(start: start, end: min(requestedEnd, fileSize - 1)))
    }
}
