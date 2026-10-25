import Foundation
import zlib

public enum ZipArchiveError: Error {
    case couldNotCreateArchive
    case couldNotReadEntry
    case tooManyEntries
    case archiveTooLarge
    case invalidEntryName
    case fileChanged
}

public struct ZipEntry: Sendable {
    public let url: URL
    public let path: String

    public init(url: URL, path: String) {
        self.url = url
        self.path = path
    }
}

public enum ZipArchive {
    public static func create(entries: [ZipEntry], destination: URL) throws {
        guard entries.count <= MacdroLimits.maxArchiveEntries else {
            throw ZipArchiveError.tooManyEntries
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination)
        else {
            throw ZipArchiveError.couldNotCreateArchive
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        defer { try? output.close() }

        struct CentralRecord {
            let pathData: Data
            let crc: UInt32
            let size: UInt64
            let offset: UInt64
            let dosTime: UInt16
            let dosDate: UInt16
            let needsZip64: Bool
        }

        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)
        var offset: UInt64 = 0
        var totalBytes: UInt64 = 0
        var usedPaths: Set<String> = []

        for entry in entries {
            let identity: FileIdentity
            do {
                identity = try FileMetadata.identity(for: entry.url)
            } catch {
                throw ZipArchiveError.couldNotReadEntry
            }
            let fileSize = identity.size
            let (nextTotal, totalOverflow) = totalBytes.addingReportingOverflow(fileSize)
            guard !totalOverflow, nextTotal <= MacdroLimits.maxArchiveInputBytes else {
                throw ZipArchiveError.archiveTooLarge
            }
            totalBytes = nextTotal

            let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            let (dosTime, dosDate) = dosDateTime(modified)
            let path = uniquePath(entry.path, used: &usedPaths)
            let nameData = Data(path.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw ZipArchiveError.invalidEntryName
            }
            let needsZip64 = fileSize >= 0xFFFF_FFFF || offset >= 0xFFFF_FFFF
            let version: UInt16 = needsZip64 ? 45 : 20

            var localExtra = Data()
            if needsZip64 {
                localExtra.appendLE(UInt16(0x0001))
                localExtra.appendLE(UInt16(16))
                localExtra.appendLE(fileSize)
                localExtra.appendLE(fileSize)
            }

            var header = Data()
            header.appendLE(UInt32(0x0403_4B50))
            header.appendLE(version)
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(dosTime)
            header.appendLE(dosDate)
            header.appendLE(UInt32(0))
            header.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(fileSize))
            header.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(fileSize))
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(localExtra.count))
            header.append(nameData)
            header.append(localExtra)

            let headerOffset = offset
            try output.write(contentsOf: header)
            offset += UInt64(header.count)

            let crc = try writeFileContents(entry.url, identity: identity, to: output)
            offset += fileSize

            let crcOffset = headerOffset + 14
            try output.seek(toOffset: crcOffset)
            var crcData = Data()
            crcData.appendLE(crc)
            try output.write(contentsOf: crcData)
            _ = try output.seekToEnd()
            guard output.offsetInFile <= MacdroLimits.maxArchiveBytes else {
                throw ZipArchiveError.archiveTooLarge
            }

            centralRecords.append(
                CentralRecord(
                    pathData: nameData,
                    crc: crc,
                    size: fileSize,
                    offset: headerOffset,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    needsZip64: needsZip64
                )
            )
        }

        let centralOffset = offset
        var centralSize: UInt64 = 0
        for record in centralRecords {
            let needsOffsetZip64 = record.offset >= 0xFFFF_FFFF
            let needsZip64 = record.needsZip64 || needsOffsetZip64
            let version: UInt16 = needsZip64 ? 45 : 20
            var extra = Data()
            if needsZip64 {
                extra.appendLE(UInt16(0x0001))
                let extraLength = record.needsZip64 ? (needsOffsetZip64 ? 24 : 16) : 8
                extra.appendLE(UInt16(extraLength))
                if record.needsZip64 {
                    extra.appendLE(record.size)
                    extra.appendLE(record.size)
                }
                if needsOffsetZip64 {
                    extra.appendLE(record.offset)
                }
            }

            var central = Data()
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(version)
            central.appendLE(version)
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(record.dosTime)
            central.appendLE(record.dosDate)
            central.appendLE(record.crc)
            central.appendLE(record.needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(record.size))
            central.appendLE(record.needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(record.size))
            central.appendLE(UInt16(record.pathData.count))
            central.appendLE(UInt16(extra.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(needsOffsetZip64 ? UInt32(0xFFFF_FFFF) : UInt32(record.offset))
            central.append(record.pathData)
            central.append(extra)
            try output.write(contentsOf: central)
            centralSize += UInt64(central.count)
            guard output.offsetInFile <= MacdroLimits.maxArchiveBytes else {
                throw ZipArchiveError.archiveTooLarge
            }
        }

        let needsZip64End = centralRecords.count >= 0xFFFF
            || centralSize >= 0xFFFF_FFFF
            || centralOffset >= 0xFFFF_FFFF
            || centralRecords.contains { $0.needsZip64 }

        if needsZip64End {
            let zip64Offset = centralOffset + centralSize
            var zip64 = Data()
            zip64.appendLE(UInt32(0x0606_4B50))
            zip64.appendLE(UInt64(44))
            zip64.appendLE(UInt16(45))
            zip64.appendLE(UInt16(45))
            zip64.appendLE(UInt32(0))
            zip64.appendLE(UInt32(0))
            zip64.appendLE(UInt64(centralRecords.count))
            zip64.appendLE(UInt64(centralRecords.count))
            zip64.appendLE(centralSize)
            zip64.appendLE(centralOffset)
            try output.write(contentsOf: zip64)

            var locator = Data()
            locator.appendLE(UInt32(0x0706_4B50))
            locator.appendLE(UInt32(0))
            locator.appendLE(zip64Offset)
            locator.appendLE(UInt32(1))
            try output.write(contentsOf: locator)

            var end = Data()
            end.appendLE(UInt32(0x0605_4B50))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(0xFFFF))
            end.appendLE(UInt16(0xFFFF))
            end.appendLE(UInt32(0xFFFF_FFFF))
            end.appendLE(UInt32(0xFFFF_FFFF))
            end.appendLE(UInt16(0))
            try output.write(contentsOf: end)
        } else {
            var end = Data()
            end.appendLE(UInt32(0x0605_4B50))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(0))
            end.appendLE(UInt16(centralRecords.count))
            end.appendLE(UInt16(centralRecords.count))
            end.appendLE(UInt32(centralSize))
            end.appendLE(UInt32(centralOffset))
            end.appendLE(UInt16(0))
            try output.write(contentsOf: end)
        }

        guard output.offsetInFile <= MacdroLimits.maxArchiveBytes else {
            throw ZipArchiveError.archiveTooLarge
        }
        try output.synchronize()
    }

    private static func writeFileContents(
        _ url: URL,
        identity: FileIdentity,
        to output: FileHandle
    ) throws -> UInt32 {
        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.couldNotReadEntry
        }
        defer { try? input.close() }

        var crc: uLong = 0
        var written: UInt64 = 0
        while true {
            let data = try autoreleasepool {
                try input.read(upToCount: 1024 * 1024) ?? Data()
            }
            if data.isEmpty { break }
            let (next, overflow) = written.addingReportingOverflow(UInt64(data.count))
            guard !overflow, next <= identity.size else {
                throw ZipArchiveError.fileChanged
            }
            written = next
            try output.write(contentsOf: data)
            crc = data.withUnsafeBytes { bytes in
                zlib.crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
            }
        }

        guard written == identity.size else {
            throw ZipArchiveError.fileChanged
        }
        guard let current = try? FileMetadata.identity(for: url), current == identity else {
            throw ZipArchiveError.fileChanged
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    private static func uniquePath(_ raw: String, used: inout Set<String>) -> String {
        var path = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
        if path.isEmpty {
            path = "file"
        }
        guard used.contains(path) else {
            used.insert(path)
            return path
        }

        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent as NSString
        let ext = filename.pathExtension
        let stem = ext.isEmpty ? filename as String : filename.deletingPathExtension
        let prefix = directory == "." ? "" : directory + "/"
        for index in 2...100_000 {
            let candidate = ext.isEmpty
                ? "\(prefix)\(stem) (\(index))"
                : "\(prefix)\(stem) (\(index)).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
        }
        let fallback = "\(prefix)\(stem)-\(UUID().uuidString.prefix(8))"
        used.insert(fallback)
        return fallback
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let month = max(1, min(12, parts.month ?? 1))
        let day = max(1, min(31, parts.day ?? 1))
        let hour = max(0, min(23, parts.hour ?? 0))
        let minute = max(0, min(59, parts.minute ?? 0))
        let second = max(0, min(59, parts.second ?? 0))

        let dateValue = UInt16(((year - 1980) << 9) | ((month & 0xF) << 5) | (day & 0x1F))
        let timeValue = UInt16(((hour & 0x1F) << 11) | ((minute & 0x3F) << 5) | ((second / 2) & 0x1F))
        return (timeValue, dateValue)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
