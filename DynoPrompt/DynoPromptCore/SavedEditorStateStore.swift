//
//  SavedEditorStateStore.swift
//  DynoPromptCore
//
//  Restores the last editor content that reached a durable save target.
//
//  Content alone is not enough: the app also has to remember *where* that
//  content came from. Without its provenance, a restored script is an orphan —
//  Save prompts for a new file even though the script came from one, and
//  Save to Library creates a duplicate entry instead of updating the one being
//  edited. So the state carries the library entry or document the pages belong
//  to alongside the pages themselves.
//

import Foundation

public struct SavedEditorState: Codable, Equatable {

    public var pages: [String]
    public var currentPageIndex: Int
    /// Library entry these pages belong to, when the content came from the
    /// script library.
    public var libraryScriptID: UUID?
    /// Security-scoped bookmark to the `.dynoprompt` document these pages
    /// belong to.
    ///
    /// A plain path is not enough. In the sandboxed build the access granted
    /// by the save panel dies with the launch that opened it, so a path
    /// restored on the next launch cannot be written to. A bookmark is the
    /// only thing that carries that permission across a relaunch.
    public var documentBookmark: Data?
    /// Human-readable location of the document, kept only so the UI and logs
    /// can name the file. Never used to gain access.
    public var documentPath: String?

    public init(
        pages: [String],
        currentPageIndex: Int = 0,
        libraryScriptID: UUID? = nil,
        documentBookmark: Data? = nil,
        documentPath: String? = nil
    ) {
        self.pages = pages
        self.currentPageIndex = currentPageIndex
        self.libraryScriptID = libraryScriptID
        self.documentBookmark = documentBookmark
        self.documentPath = documentPath
    }

    // Decoded field by field rather than with the synthesised initialiser so a
    // file written by an earlier build — which stored only `pages` — still
    // loads instead of being discarded as corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pages = try container.decode([String].self, forKey: .pages)
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
        libraryScriptID = try container.decodeIfPresent(UUID.self, forKey: .libraryScriptID)
        documentBookmark = try container.decodeIfPresent(Data.self, forKey: .documentBookmark)
        documentPath = try container.decodeIfPresent(String.self, forKey: .documentPath)
    }
}

// MARK: - Store

public final class SavedEditorStateStore {

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// App-owned state avoids relying on an external document URL after the
    /// App Sandbox revokes the save panel's access at the end of a launch.
    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("DynoPrompt", isDirectory: true)
            .appendingPathComponent("LastSavedEditorState.json", isDirectory: false)
    }

    public func load() -> SavedEditorState? {
        guard let data = try? Data(contentsOf: fileURL),
              var state = try? JSONDecoder().decode(SavedEditorState.self, from: data),
              !state.pages.isEmpty else { return nil }

        // A page index from a previous launch can be out of range if the
        // document shrank; clamp rather than trusting it.
        state.currentPageIndex = min(max(0, state.currentPageIndex), state.pages.count - 1)
        return state
    }

    public func save(_ state: SavedEditorState) throws {
        guard !state.pages.isEmpty else { return }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func save(pages: [String]) throws {
        try save(SavedEditorState(pages: pages))
    }
}

// MARK: - Document references

/// Encodes and resolves the bookmark that lets a `.dynoprompt` document stay
/// writable across relaunches.
///
/// Split out from the store so the bookmark round trip can be tested against a
/// real file without involving the editor.
public enum SavedDocumentReference {

    /// Creates a bookmark for `url`.
    ///
    /// Security scope is requested, which is what survives a relaunch inside
    /// the sandbox. It is also harmless outside one, so both builds take the
    /// same path rather than branching on an entitlement.
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public struct Resolved {
        public let url: URL
        /// True when the bookmark needs rewriting because the file moved.
        public let isStale: Bool
    }

    /// Resolves a bookmark back to a usable URL, or nil if the file is gone.
    public static func resolve(_ bookmark: Data) -> Resolved? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return Resolved(url: url, isStale: isStale)
    }

    /// Runs `body` with the document's security scope held open.
    ///
    /// Outside the sandbox `startAccessingSecurityScopedResource` returns
    /// false and nothing needs releasing, so the work still runs — the scope
    /// is simply unnecessary there.
    @discardableResult
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
