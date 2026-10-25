import Darwin
import Foundation
import XCTest
@testable import MacdroKit

final class HardeningTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacdroHardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configuration(
        idleTimeout: TimeInterval = 60,
        maxActiveTransactions: Int = MacdroLimits.maxResumableUploads,
        maxTransactionsPerClient: Int = MacdroLimits.maxResumableUploadsPerClient,
        maxConcurrentTransactions: Int = MacdroLimits.maxConcurrentUploads,
        maxConcurrentPerClient: Int = MacdroLimits.maxConcurrentUploadsPerClient,
        quotaBytes: UInt64? = nil
    ) -> UploadStore.Configuration {
        UploadStore.Configuration(
            idleTimeout: idleTimeout,
            cleanupInterval: 0,
            maxActiveTransactions: maxActiveTransactions,
            maxTransactionsPerClient: maxTransactionsPerClient,
            maxConcurrentTransactions: maxConcurrentTransactions,
            maxConcurrentPerClient: maxConcurrentPerClient,
            quotaBytes: quotaBytes
        )
    }

    func testConnectionGateEnforcesPerIPAndGlobalLimits() {
        let gate = ConnectionGate(maxTotal: 3, maxPerIP: 2)
        XCTAssertTrue(gate.acquire(ip: "10.0.0.1"))
        XCTAssertTrue(gate.acquire(ip: "10.0.0.1"))
        XCTAssertFalse(gate.acquire(ip: "10.0.0.1"))
        XCTAssertTrue(gate.acquire(ip: "10.0.0.2"))
        XCTAssertFalse(gate.acquire(ip: "10.0.0.3"))
        gate.release(ip: "10.0.0.1")
        XCTAssertTrue(gate.acquire(ip: "10.0.0.1"))
    }

    func testResumableExpiryClosesHandleRemovesPartAndReleasesName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(
            directory: directory,
            configuration: configuration(idleTimeout: 1)
        )

        let transaction = try store.beginResumable(
            id: "ttl000000",
            name: "ttl.bin",
            expectedSize: 64,
            offset: 0,
            complete: false,
            client: "phone"
        )
        try transaction.append(Data(repeating: 0x41, count: 64))
        XCTAssertTrue(transaction.isOpen)
        XCTAssertEqual(store.resumableTemporaryFileCount, 1)
        store.releaseLease(id: "ttl000000")

        store.cleanupExpired(now: Date().addingTimeInterval(2))
        XCTAssertEqual(store.activeResumableCount, 0)
        XCTAssertEqual(store.resumableTemporaryFileCount, 0)
        XCTAssertFalse(transaction.isOpen)

        let replacement = try store.beginResumable(
            id: "ttl000001",
            name: "ttl.bin",
            expectedSize: 64,
            offset: 0,
            complete: false,
            client: "phone"
        )
        XCTAssertEqual(replacement.relativePath, "ttl.bin")
        replacement.cancel()
    }

    func testStartupRemovesOrphanedPartFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent(".macdro-orphan.part")
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("x".utf8)))

        _ = UploadStore(directory: directory, configuration: configuration())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                $0.hasPrefix(".macdro-") && $0.hasSuffix(".part")
            }.count,
            0
        )
    }

    func testResumableGlobalAndPerClientCaps() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(
            directory: directory,
            configuration: configuration(
                maxActiveTransactions: 2,
                maxTransactionsPerClient: 1,
                maxConcurrentTransactions: 4,
                maxConcurrentPerClient: 2
            )
        )

        let first = try store.beginResumable(
            id: "cap00000a",
            name: "a.bin",
            expectedSize: 1,
            offset: 0,
            complete: false,
            client: "a"
        )
        XCTAssertThrowsError(
            try store.beginResumable(
                id: "cap00000b",
                name: "b.bin",
                expectedSize: 1,
                offset: 0,
                complete: false,
                client: "a"
            )
        ) { XCTAssertEqual($0 as? UploadError, .tooManyUploads) }

        let second = try store.beginResumable(
            id: "cap00000c",
            name: "c.bin",
            expectedSize: 1,
            offset: 0,
            complete: false,
            client: "b"
        )
        XCTAssertThrowsError(
            try store.beginResumable(
                id: "cap00000d",
                name: "d.bin",
                expectedSize: 1,
                offset: 0,
                complete: false,
                client: "c"
            )
        ) { XCTAssertEqual($0 as? UploadError, .tooManyUploads) }

        first.cancel()
        second.cancel()
    }

    func testQuotaRejectsBeforeBodyIsWritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(
            directory: directory,
            configuration: configuration(quotaBytes: 10)
        )
        XCTAssertThrowsError(
            try store.begin(name: "too-big.bin", expectedSize: 11, client: "phone")
        ) { XCTAssertEqual($0 as? UploadError, .insufficientStorage) }
    }

    func testCancelReleasesReservedNameAndHandle() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(directory: directory, configuration: configuration())

        let first = try store.begin(name: "same.txt", expectedSize: 1, client: "phone")
        XCTAssertTrue(first.isOpen)
        first.cancel()
        XCTAssertFalse(first.isOpen)

        let second = try store.begin(name: "same.txt", expectedSize: 1, client: "phone")
        XCTAssertEqual(second.relativePath, "same.txt")
        second.cancel()
    }

    func testLongUnicodeNameFitsFilesystemLimits() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(directory: directory, configuration: configuration())
        let name = String(repeating: "😀", count: 200) + ".txt"
        let transaction = try store.begin(name: name, expectedSize: 1, client: "phone")
        let saved = (transaction.relativePath as NSString).lastPathComponent
        XCTAssertLessThanOrEqual(saved.utf16.count, 240)
        XCTAssertLessThanOrEqual(saved.utf8.count, 240)
        XCTAssertTrue(saved.hasSuffix(".txt"))
        transaction.cancel()
    }

    func testUploadRejectsSymlinkedDirectoryEscape() throws {
        let directory = try makeDirectory()
        let uploads = directory.appendingPathComponent("uploads", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: uploads.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UploadStore(directory: uploads, configuration: configuration())
        XCTAssertThrowsError(
            try store.begin(
                name: "pwn.txt",
                relativePath: "escape/pwn.txt",
                expectedSize: 4,
                client: "phone"
            )
        ) { XCTAssertEqual($0 as? UploadError, .unsafePath) }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwn.txt").path)
        )
    }

    func testFinishRechecksContainmentAfterDirectorySwap() throws {
        let directory = try makeDirectory()
        let uploads = directory.appendingPathComponent("uploads", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UploadStore(directory: uploads, configuration: configuration())
        let transaction = try store.begin(
            name: "swap.txt",
            relativePath: "nested/swap.txt",
            expectedSize: 4,
            client: "phone"
        )
        try transaction.append(Data("evil".utf8))
        try FileManager.default.removeItem(at: uploads.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(
            at: uploads.appendingPathComponent("nested"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try transaction.finish()) {
            XCTAssertEqual($0 as? UploadError, .unsafePath)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("swap.txt").path)
        )
    }

    func testThousandAbandonedUploadsLeaveNoFilesOrQuota() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(
            directory: directory,
            configuration: configuration(quotaBytes: 1_000_000)
        )

        for index in 0..<1_000 {
            let id = String(format: "soak%06d", index)
            let transaction = try store.beginResumable(
                id: id,
                name: "soak-\(index).bin",
                expectedSize: 1,
                offset: 0,
                complete: false,
                client: "soak"
            )
            try transaction.append(Data([0x41]))
            store.removeResumable(id: id)
        }

        XCTAssertEqual(store.activeResumableCount, 0)
        XCTAssertEqual(store.resumableTemporaryFileCount, 0)
        let finalUpload = try store.begin(
            name: "after-soak.bin",
            expectedSize: 999_999,
            client: "soak"
        )
        finalUpload.cancel()
    }

    func testCancelReleasesQuotaAccounting() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(
            directory: directory,
            configuration: configuration(quotaBytes: 64)
        )

        let first = try store.begin(name: "first.bin", expectedSize: 64, client: "phone")
        try first.append(Data(repeating: 0x41, count: 64))
        first.cancel()

        let second = try store.begin(name: "second.bin", expectedSize: 64, client: "phone")
        try second.append(Data(repeating: 0x42, count: 64))
        second.cancel()
    }

    func testLongExtensionIsTruncatedSafely() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UploadStore(directory: directory, configuration: configuration())
        let name = "a." + String(repeating: "b", count: 300)
        let transaction = try store.begin(name: name, expectedSize: 1, client: "phone")
        XCTAssertLessThanOrEqual(
            (transaction.relativePath as NSString).lastPathComponent.utf16.count,
            240
        )
        XCTAssertLessThanOrEqual(
            transaction.relativePath.utf8.count,
            900
        )
        transaction.cancel()
    }
}
