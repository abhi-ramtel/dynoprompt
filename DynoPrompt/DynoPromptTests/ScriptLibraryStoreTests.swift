//
//  ScriptLibraryStoreTests.swift
//  DynoPromptTests
//

import XCTest

final class ScriptLibraryStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ScriptLibraryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptTests-\(UUID().uuidString)", isDirectory: true)
        store = ScriptLibraryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testSaveAndLoadRoundTrip() throws {
        let script = Script(title: "Keynote", pages: ["Hello world", "Second page"])
        try store.save(script)

        let loaded = store.load(id: script.id)
        XCTAssertEqual(loaded?.title, "Keynote")
        XCTAssertEqual(loaded?.pages, ["Hello world", "Second page"])
    }

    func testLoadAllReturnsEveryScriptNewestFirst() throws {
        let older = Script(title: "Older", pages: ["a"])
        try store.save(older)
        // updatedAt is stamped on save, so a second save orders deterministically.
        Thread.sleep(forTimeInterval: 0.01)
        let newer = Script(title: "Newer", pages: ["b"])
        try store.save(newer)

        let all = store.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.title, "Newer")
    }

    func testDeleteRemovesScript() throws {
        let script = Script(title: "Temp", pages: ["x"])
        try store.save(script)
        try store.delete(id: script.id)

        XCTAssertNil(store.load(id: script.id))
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testDeletingMissingScriptIsNotAnError() throws {
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    func testEditPreservesIdentityAndUpdatesTimestamp() throws {
        var script = Script(title: "Draft", pages: ["v1"])
        let saved = try store.save(script)
        Thread.sleep(forTimeInterval: 0.01)

        script = saved
        script.pages = ["v2"]
        let updated = try store.save(script)

        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(store.load(id: saved.id)?.pages, ["v2"])
        XCTAssertGreaterThan(updated.updatedAt, saved.updatedAt)
    }

    func testEmptyTitleIsDerivedFromContent() throws {
        let script = Script(title: "   ", pages: ["\n\nThe opening line\nmore text"])
        let saved = try store.save(script)
        XCTAssertEqual(saved.title, "The opening line")
    }

    // MARK: - Security

    /// A title is user input, and on macOS it can contain slashes and dots.
    /// Filenames are derived from the UUID alone, so a hostile title cannot
    /// escape the library directory.
    func testMaliciousTitleCannotEscapeDirectory() throws {
        let script = Script(
            title: "../../../../../../tmp/dynoprompt-pwned",
            pages: ["payload"]
        )
        try store.save(script)

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first, "\(script.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/dynoprompt-pwned"))
    }

    func testNullBytesAndControlCharactersInTitleAreStoredSafely() throws {
        let script = Script(title: "bad\u{0}title\n\r", pages: ["ok"])
        XCTAssertNoThrow(try store.save(script))
        XCTAssertNotNil(store.load(id: script.id))
    }

    /// Files the app did not write are ignored rather than parsed.
    func testStrayFilesAreIgnored() throws {
        try store.save(Script(title: "Real", pages: ["x"]))
        try "not json".write(
            to: directory.appendingPathComponent("notes.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: directory.appendingPathComponent("00000000-not-a-uuid.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testCorruptScriptFileDoesNotBreakLibrary() throws {
        try store.save(Script(title: "Good", pages: ["x"]))
        let corrupt = UUID()
        try "{ this is not valid json".write(
            to: directory.appendingPathComponent("\(corrupt.uuidString).json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(store.loadAll().count, 1, "one bad file must not hide the rest")
    }

    func testScriptDirectoryIsOwnerOnly() throws {
        try store.save(Script(title: "Private", pages: ["confidential"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o077, 0, "group/other must have no access")
    }

    // MARK: - Derived values

    func testWordCountAndDuration() {
        let script = Script(title: "t", pages: ["one two three", "four five"])
        XCTAssertEqual(script.wordCount, 5)
        XCTAssertEqual(script.estimatedDuration, 2.0, accuracy: 0.001)
    }

    func testDerivedTitleFallsBackWhenEmpty() {
        XCTAssertEqual(Script.derivedTitle(fromPages: ["", "   \n  "]), "Untitled Script")
    }
}
