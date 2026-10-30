import Foundation
import XCTest

final class SnippetStoreTests: XCTestCase {
    private var root: URL?
    override func setUpWithError() throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        root = location
    }
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }
    private func directory(_ name: String) throws -> URL {
        let url = try XCTUnwrap(root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func backup(_ library: SnippetLibrary = TestFixtures.library, version: Int = 1) throws -> URL {
        let file = try XCTUnwrap(root).appendingPathComponent("backup.json")
        try JSONEncoder().encode(SnippetBackup(version: version, library: library)).write(to: file)
        return file
    }
    func testSaveAndReloadUsesActualStore() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let reopened = SnippetStore(root: folder)
        XCTAssertEqual(reopened.library.items, TestFixtures.library.items)
        XCTAssertEqual(reopened.library.groups, TestFixtures.library.groups)
        XCTAssertTrue(reopened.error.isEmpty)
    }
    func testExportAndImportFileRoundTrip() throws {
        let source = SnippetStore(root: try directory("source"))
        XCTAssertTrue(source.save(TestFixtures.library))
        let file = try XCTUnwrap(root).appendingPathComponent("export.json")
        XCTAssertTrue(source.exportBackupFile(to: file))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), ["version", "library"])
        let destination = try directory("destination")
        let target = SnippetStore(root: destination)
        let result = try XCTUnwrap(target.importBackupFile(from: file))
        XCTAssertEqual(result.items, 1)
        XCTAssertEqual(result.groups, 1)
        XCTAssertEqual(SnippetStore(root: destination).library.items, source.library.items)
    }
    func testRepeatedFileImportDoesNotAddDuplicates() throws {
        let store = SnippetStore(root: try directory("destination"))
        let file = try backup()
        XCTAssertEqual(store.importBackupFile(from: file)?.items, 1)
        XCTAssertEqual(store.importBackupFile(from: file)?.items, 0)
        XCTAssertEqual(store.library.items.count, 1)
        XCTAssertEqual(store.library.groups.count, 1)
    }
    func testInvalidVersionPreservesDiskBytesAndMemory() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let history = folder.appendingPathComponent("snippets.json")
        let original = try Data(contentsOf: history)
        XCTAssertNil(store.importBackupFile(from: try backup(version: 9)))
        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertEqual(store.library.items, TestFixtures.library.items)
        XCTAssertFalse(store.error.isEmpty)
    }
    func testPartlyInvalidImportIsRejectedAtomically() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let original = try Data(contentsOf: folder.appendingPathComponent("snippets.json"))
        let incoming = SnippetLibrary(items: [Snippet(id: "valid", title: "正常", text: "不应部分导入"),
                                               Snippet(id: "orphan", groupID: "missing", title: "无效", text: "错误")])
        XCTAssertNil(store.importBackupFile(from: try backup(incoming)))
        XCTAssertEqual(store.library.items, TestFixtures.library.items)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("snippets.json")), original)
    }
    func testCorruptExistingFileIsProtectedFromAllWrites() throws {
        let folder = try directory("corrupt")
        let file = folder.appendingPathComponent("snippets.json"), original = Data("broken JSON".utf8)
        try original.write(to: file)
        let store = SnippetStore(root: folder)
        XCTAssertFalse(store.error.isEmpty)
        XCTAssertFalse(store.save(TestFixtures.library))
        XCTAssertNil(store.importBackupFile(from: try backup()))
        let exported = folder.appendingPathComponent("should-not-exist.json")
        XCTAssertFalse(store.exportBackupFile(to: exported))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testSemanticCorruptionAlsoPreservesExistingFile() throws {
        let folder = try directory("invalid")
        var invalid = TestFixtures.library
        invalid.items.append(invalid.items[0])
        let data = try JSONEncoder().encode(invalid), file = folder.appendingPathComponent("snippets.json")
        try data.write(to: file)
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.library.items.isEmpty)
        XCTAssertFalse(store.error.isEmpty)
        XCTAssertFalse(store.save(TestFixtures.library))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testWriteFailureDoesNotCommitMemory() throws {
        let missing = try XCTUnwrap(root).appendingPathComponent("missing/parent")
        let store = SnippetStore(root: missing)
        XCTAssertFalse(store.save(TestFixtures.library))
        XCTAssertTrue(store.library.items.isEmpty)
        XCTAssertFalse(store.error.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testInvalidSaveDoesNotOverwriteExistingFile() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let original = try Data(contentsOf: folder.appendingPathComponent("snippets.json"))
        var invalid = TestFixtures.library; invalid.items[0].text = String(repeating: "x", count: 65537)
        XCTAssertFalse(store.save(invalid))
        XCTAssertEqual(store.library.items, TestFixtures.library.items)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("snippets.json")), original)
    }
    func testExportWriteFailureLeavesLibraryUntouched() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        XCTAssertFalse(store.exportBackupFile(to: folder.appendingPathComponent("missing/backup.json")))
        XCTAssertEqual(store.library.items, TestFixtures.library.items)
        XCTAssertFalse(store.error.isEmpty)
    }
    func testOversizeFileIsRejectedBeforeDecode() throws {
        let store = SnippetStore(root: try directory("destination"))
        let file = try XCTUnwrap(root).appendingPathComponent("huge.json")
        try Data(repeating: 0x20, count: SnippetBackupCodec.fileLimit + 1).write(to: file)
        XCTAssertNil(store.importBackupFile(from: file))
        XCTAssertTrue(store.library.items.isEmpty)
        XCTAssertFalse(store.error.isEmpty)
    }
    func testSuccessfulImportClearsPriorError() throws {
        let store = SnippetStore(root: try directory("destination"))
        XCTAssertNil(store.importBackupFile(from: try backup(version: 9)))
        XCTAssertFalse(store.error.isEmpty)
        XCTAssertNotNil(store.importBackupFile(from: try backup()))
        XCTAssertTrue(store.error.isEmpty)
    }
    func testExportCannotOverwriteActiveLibrary() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let active = folder.appendingPathComponent("snippets.json")
        let original = try Data(contentsOf: active)
        XCTAssertFalse(store.exportBackupFile(to: active))
        XCTAssertEqual(try Data(contentsOf: active), original)
        XCTAssertEqual(SnippetStore(root: folder).library.items, TestFixtures.library.items)
    }
    func testExportCannotOverwriteActiveLibraryThroughSymbolicLink() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let active = folder.appendingPathComponent("snippets.json")
        let original = try Data(contentsOf: active)
        let alias = folder.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: active)
        XCTAssertFalse(store.exportBackupFile(to: alias))
        XCTAssertEqual(try Data(contentsOf: active), original)
    }
    func testExportCannotOverwriteActiveLibraryThroughHardLink() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let active = folder.appendingPathComponent("snippets.json")
        let original = try Data(contentsOf: active)
        let alias = folder.appendingPathComponent("hard-link.json")
        try FileManager.default.linkItem(at: active, to: alias)
        XCTAssertFalse(store.exportBackupFile(to: alias))
        XCTAssertEqual(try Data(contentsOf: active), original)
        XCTAssertEqual(try Data(contentsOf: alias), original)
    }
    func testExportCanReplaceAnOrdinaryBackupFile() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        let destination = folder.appendingPathComponent("normal-backup.json")
        try Data("old backup".utf8).write(to: destination)
        XCTAssertTrue(store.exportBackupFile(to: destination))
        let decoded = try SnippetBackupCodec.decode(Data(contentsOf: destination))
        XCTAssertEqual(decoded.items, TestFixtures.library.items)
        XCTAssertEqual(SnippetStore(root: folder).library.items, TestFixtures.library.items)
    }
    func testMissingImportFileLeavesExistingLibraryUntouched() throws {
        let folder = try directory("saved")
        let store = SnippetStore(root: folder)
        XCTAssertTrue(store.save(TestFixtures.library))
        XCTAssertNil(store.importBackupFile(from: folder.appendingPathComponent("missing.json")))
        XCTAssertEqual(store.library.items, TestFixtures.library.items)
        XCTAssertFalse(store.error.isEmpty)
    }
}
