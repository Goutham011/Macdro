import XCTest
@testable import MacdroKit

final class SessionStoreTests: XCTestCase {
    func testTokenIsLongAndUnique() {
        let first = SessionStore.generateToken()
        let second = SessionStore.generateToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
    }

    func testAddAndRetrieveFilesPreservesOrder() {
        let store = SessionStore(token: "test-token")
        let first = SharedFile(sourcePath: "/tmp/a.txt", relativePath: "a.txt", size: 1)
        let second = SharedFile(sourcePath: "/tmp/b.txt", relativePath: "b.txt", size: 2)

        store.add([first, second])

        XCTAssertEqual(store.snapshot().files.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.file(id: second.id)?.relativePath, "b.txt")
    }

    func testRemovingFileUpdatesSnapshot() {
        let store = SessionStore()
        let file = SharedFile(sourcePath: "/tmp/a.txt", relativePath: "a.txt", size: 1)
        store.add([file])
        store.remove(id: file.id)
        XCTAssertTrue(store.snapshot().files.isEmpty)
    }

    func testRotateTokenChangesToken() {
        let store = SessionStore(token: "old")
        let rotated = store.rotateToken()
        XCTAssertNotEqual(rotated, "old")
        XCTAssertEqual(store.token, rotated)
    }
}
