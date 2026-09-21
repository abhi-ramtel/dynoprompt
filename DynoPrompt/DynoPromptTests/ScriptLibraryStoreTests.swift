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

final class SavedEditorStateStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptEditorStateTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("LastSavedEditorState.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testSavedPagesSurviveStoreRecreation() throws {
        let pages = ["Opening line", "Second page"]
        try SavedEditorStateStore(fileURL: fileURL).save(pages: pages)

        let relaunchedStore = SavedEditorStateStore(fileURL: fileURL)
        XCTAssertEqual(relaunchedStore.load()?.pages, pages)
    }

    func testCorruptStateDoesNotReplaceLaunchContent() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertNil(SavedEditorStateStore(fileURL: fileURL).load())
    }

    // MARK: - Provenance

    /// Restoring the pages alone leaves the editor unable to tell where the
    /// content came from, so Save falls back to asking for a new location and
    /// Save to Library creates a duplicate. The library entry has to survive
    /// the relaunch with the pages.
    func testLibraryProvenanceSurvivesRelaunch() throws {
        let scriptID = UUID()
        try SavedEditorStateStore(fileURL: fileURL).save(
            SavedEditorState(
                pages: ["Opening line"],
                currentPageIndex: 0,
                libraryScriptID: scriptID
            )
        )

        let restored = SavedEditorStateStore(fileURL: fileURL).load()
        XCTAssertEqual(restored?.libraryScriptID, scriptID)
    }

    func testCurrentPageSurvivesRelaunch() throws {
        try SavedEditorStateStore(fileURL: fileURL).save(
            SavedEditorState(pages: ["one", "two", "three"], currentPageIndex: 2)
        )
        XCTAssertEqual(SavedEditorStateStore(fileURL: fileURL).load()?.currentPageIndex, 2)
    }

    /// A page index from a previous launch can point past the end if the
    /// script shrank. Clamping keeps the restored editor on a real page.
    func testOutOfRangePageIndexIsClamped() throws {
        try SavedEditorStateStore(fileURL: fileURL).save(
            SavedEditorState(pages: ["only page"], currentPageIndex: 9)
        )
        XCTAssertEqual(SavedEditorStateStore(fileURL: fileURL).load()?.currentPageIndex, 0)
    }

    /// State written by the previous build stored only `pages`. It must still
    /// load rather than being treated as corrupt and thrown away.
    func testStateWrittenBeforeProvenanceExistedStillLoads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"pages":["Legacy content"]}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        let restored = SavedEditorStateStore(fileURL: fileURL).load()
        XCTAssertEqual(restored?.pages, ["Legacy content"])
        XCTAssertEqual(restored?.currentPageIndex, 0)
        XCTAssertNil(restored?.libraryScriptID)
    }

    func testEmptyPagesAreNotRecorded() throws {
        try SavedEditorStateStore(fileURL: fileURL).save(SavedEditorState(pages: []))
        XCTAssertNil(SavedEditorStateStore(fileURL: fileURL).load())
    }
}

// MARK: - Document bookmarks

/// The document half of provenance. A plain path cannot be written to after a
/// relaunch in the sandboxed build, because the access the save panel granted
/// ends with that launch — only a bookmark carries it forward.
final class SavedDocumentReferenceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testBookmarkRoundTripsToTheSameFile() throws {
        let document = directory.appendingPathComponent("script.dynoprompt")
        try #"["page one"]"#.write(to: document, atomically: true, encoding: .utf8)

        let bookmark = try XCTUnwrap(SavedDocumentReference.bookmark(for: document))
        let resolved = try XCTUnwrap(SavedDocumentReference.resolve(bookmark))

        XCTAssertEqual(
            resolved.url.resolvingSymlinksInPath().standardizedFileURL,
            document.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    /// Holding the scope must not stop ordinary reads and writes from working,
    /// including outside the sandbox where there is no scope to acquire.
    func testWritesSucceedWhileHoldingScope() throws {
        let document = directory.appendingPathComponent("script.dynoprompt")
        try #"["before"]"#.write(to: document, atomically: true, encoding: .utf8)

        let bookmark = try XCTUnwrap(SavedDocumentReference.bookmark(for: document))
        let resolved = try XCTUnwrap(SavedDocumentReference.resolve(bookmark))

        try SavedDocumentReference.withAccess(to: resolved.url) {
            try Data(#"["after"]"#.utf8).write(to: resolved.url, options: .atomic)
        }

        let readBack = try SavedDocumentReference.withAccess(to: resolved.url) {
            try String(contentsOf: resolved.url, encoding: .utf8)
        }
        XCTAssertEqual(readBack, #"["after"]"#)
    }

    /// A deleted document must not resolve to a phantom URL the editor would
    /// then try to save over.
    func testDeletedDocumentDoesNotResolve() throws {
        let document = directory.appendingPathComponent("gone.dynoprompt")
        try #"["page"]"#.write(to: document, atomically: true, encoding: .utf8)
        let bookmark = try XCTUnwrap(SavedDocumentReference.bookmark(for: document))
        try FileManager.default.removeItem(at: document)

        let resolved = SavedDocumentReference.resolve(bookmark)
        if let resolved {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: resolved.url.path),
                "a resolved URL for a deleted file must not appear usable"
            )
        }
    }

    func testGarbageBookmarkIsRejected() {
        XCTAssertNil(SavedDocumentReference.resolve(Data([0x00, 0x01, 0x02, 0x03])))
    }
}
