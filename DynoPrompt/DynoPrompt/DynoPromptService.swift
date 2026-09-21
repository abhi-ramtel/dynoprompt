//
//  DynoPromptService.swift
//  DynoPrompt
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

class DynoPromptService: NSObject, ObservableObject {
    static let shared = DynoPromptService()
    private static let lastDocumentURLDefaultsKey = "lastDocumentURL"
    private static let persistenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fka.dynoprompt",
        category: "EditorPersistence"
    )

    private let savedEditorStateStore: SavedEditorStateStore?
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    @Published var pages: [String] = [""]
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    /// Upper bound on externally supplied script text.
    ///
    /// `dynoprompt://read?text=…` can be triggered by any web page, and the
    /// overlay floats above every other window. An unbounded string would let
    /// a page wedge the UI in text layout while covering the screen; this cap
    /// is far above any real script.
    static let maxExternalTextLength = 200_000

    func readText(_ text: String) {
        let bounded = text.count > Self.maxExternalTextLength
            ? String(text.prefix(Self.maxExternalTextLength))
            : text
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        overlayController.show(text: trimmed, hasNextPage: hasNextPage) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: hasNextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let words = splitTextIntoWords(trimmed)
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let pagePreviews = pages.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.pageCount = pages.count
            content.currentPageIndex = currentPageIndex
            content.pagePreviews = pagePreviews
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?
    @Published var savedPages: [String] = [""]

    /// Library entry the editor is currently working on, when the content came
    /// from the script library.
    ///
    /// The quit flow lives here, so the decision "where does Save go?" has to
    /// be answerable here too. Without this the service only knew about
    /// `.dynoprompt` documents, and quitting while editing a library script
    /// pushed the user into a file save panel for content that already had a
    /// home.
    @Published var activeLibraryScriptID: UUID?

    /// Writes the current pages back to the library entry, returning true on
    /// success. Installed at launch; a closure rather than a direct reference
    /// so the service does not depend on the library UI layer.
    var saveToLibraryHandler: (([String], UUID?) -> UUID?)?

    override init() {
        if let fileURL = try? SavedEditorStateStore.defaultFileURL() {
            savedEditorStateStore = SavedEditorStateStore(fileURL: fileURL)
        } else {
            savedEditorStateStore = nil
        }

        super.init()

        restoreSavedEditorState()
    }

    // MARK: - File Operations

    /// Brings back the last durably saved content *and* where it came from.
    ///
    /// Restoring the pages alone leaves an orphan: the next Save cannot tell
    /// whether it should update a library entry, rewrite a document, or ask
    /// for a new location, so it falls back to asking every time.
    private func restoreSavedEditorState() {
        guard let restored = savedEditorStateStore?.load() else { return }

        pages = restored.pages
        savedPages = restored.pages
        currentPageIndex = min(max(0, restored.currentPageIndex), restored.pages.count - 1)
        activeLibraryScriptID = restored.libraryScriptID

        // A document is only usable again if its bookmark still resolves. The
        // sandbox revoked the original grant when the last launch ended, so a
        // path on its own would produce a URL that cannot be written to.
        if let bookmark = restored.documentBookmark,
           let resolved = SavedDocumentReference.resolve(bookmark),
           FileManager.default.fileExists(atPath: resolved.url.path) {
            currentFileURL = resolved.url
            if resolved.isStale {
                // The file moved; record a fresh bookmark so the next launch
                // does not have to chase it again.
                rememberSavedEditorState()
            }
        } else if restored.documentBookmark != nil {
            Self.persistenceLogger.info(
                "The previously open document could not be reopened; keeping its content unlinked."
            )
        }
    }

    /// Records only content that is already durable (a saved document or
    /// library entry). Unsaved edits deliberately remain outside this file so
    /// choosing Discard on quit cannot resurrect them on the next launch.
    func rememberSavedEditorState() {
        guard let store = savedEditorStateStore else { return }
        do {
            try store.save(
                SavedEditorState(
                    pages: pages,
                    currentPageIndex: currentPageIndex,
                    libraryScriptID: activeLibraryScriptID,
                    documentBookmark: currentFileURL.flatMap { SavedDocumentReference.bookmark(for: $0) },
                    documentPath: currentFileURL?.path
                )
            )
        } catch {
            Self.persistenceLogger.error(
                "Couldn't record the last saved editor state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private var lastDocumentDirectoryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastDocumentURLDefaultsKey),
              !path.isEmpty else { return nil }

        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return directoryURL
    }

    func rememberDocumentURL(_ url: URL) {
        guard url.isFileURL else { return }
        UserDefaults.standard.set(
            url.standardizedFileURL.path,
            forKey: Self.lastDocumentURLDefaultsKey
        )
    }

    /// Where a Save would go, given what the editor is currently holding.
    enum SaveDestination: Equatable {
        /// A `.dynoprompt` document the user already chose.
        case document(URL)
        /// An entry in the script library.
        case library(UUID?)
        /// Nowhere yet — Save has to ask.
        case prompt

        var description: String {
            switch self {
            case .document(let url):  return "document \(url.lastPathComponent)"
            case .library(let id):
                return "library \(id.map { String($0.uuidString.prefix(8)) } ?? "new entry")"
            case .prompt:             return "ask for a location"
            }
        }
    }

    /// Resolved in one place so the menu item, the quit prompt and the
    /// diagnostics cannot disagree about where content belongs.
    ///
    /// Order matters. A document URL wins because the user explicitly chose
    /// that file; otherwise a library entry is used; only content with no home
    /// at all prompts. Before this, everything without a document URL fell
    /// through to a save panel — including library scripts, which already had
    /// somewhere to go.
    var saveDestination: SaveDestination {
        if let url = currentFileURL { return .document(url) }
        // Only content that already belongs to a library entry goes back to
        // the library. Brand-new content still prompts, because Save and
        // Save to Library are separate commands and Save should not quietly
        // invent a library entry the user never asked for.
        if let scriptID = activeLibraryScriptID, saveToLibraryHandler != nil {
            return .library(scriptID)
        }
        return .prompt
    }

    @discardableResult
    func saveFile() -> Bool {
        switch saveDestination {
        case .document(let url):
            return saveToURL(url)
        case .library:
            // Falls through to a panel if the library write fails, so a
            // failure cannot silently look like a successful save.
            return saveToLibrary() || saveFileAs()
        case .prompt:
            return saveFileAs()
        }
    }

    /// Writes the current pages to the script library.
    ///
    /// Returns false when there is no library available, which lets `saveFile`
    /// fall through to a save panel rather than silently doing nothing.
    @discardableResult
    func saveToLibrary() -> Bool {
        guard let handler = saveToLibraryHandler else { return false }
        guard let savedID = handler(pages, activeLibraryScriptID) else {
            Self.persistenceLogger.error("Couldn't write the script to the library.")
            return false
        }
        activeLibraryScriptID = savedID
        savedPages = pages
        rememberSavedEditorState()
        return true
    }

    @discardableResult
    func saveFileAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "dynoprompt")!]
        panel.nameFieldStringValue = "Untitled.dynoprompt"
        panel.canCreateDirectories = true
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return saveToURL(url)
    }

    @discardableResult
    private func saveToURL(_ url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(pages)
            // The scope has to be held for the write itself. A URL restored
            // from a bookmark carries permission that is only active between
            // start and stop; writing outside that window fails in the
            // sandboxed build even though the path is correct.
            try SavedDocumentReference.withAccess(to: url) {
                try data.write(to: url, options: .atomic)
            }
            currentFileURL = url
            savedPages = pages
            rememberDocumentURL(url)
            rememberSavedEditorState()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    var hasUnsavedChanges: Bool {
        pages != savedPages
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "dynoprompt")!,
            // Scripts saved under the app's former name. Identical JSON, so
            // they open directly; saving writes a .dynoprompt file.
            .init(filenameExtension: "textream")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "textream" {
                // Load the content, but forget the path so the next Save
                // prompts for a .dynoprompt file instead of silently
                // rewriting the legacy one.
                self?.openFileAtURL(url)
                self?.currentFileURL = nil
            } else if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.pages = notes
                    // Imported notes have not been saved as a DynoPrompt
                    // document or library entry yet.
                    self?.savedPages = []
                    self?.currentPageIndex = 0
                    self?.readPages.removeAll()
                    self?.currentFileURL = nil
                    self?.activeLibraryScriptID = nil
                    self?.rememberDocumentURL(url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before continuing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return saveFile()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try SavedDocumentReference.withAccess(to: url) {
                try Data(contentsOf: url)
            }
            let loadedPages = try JSONDecoder().decode([String].self, from: data)
            guard !loadedPages.isEmpty else { return }
            pages = loadedPages
            savedPages = loadedPages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = url
            // Opening a document replaces whatever the editor was showing, so
            // it is no longer tied to a library entry.
            activeLibraryScriptID = nil
            rememberDocumentURL(url)
            rememberSavedEditorState()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
        }
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount in
            self?.updateTextFromDirector(text, readCharCount: readCharCount)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Director mode is single page
        pages = [trimmed]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        overlayController.show(text: trimmed, hasNextPage: false) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
        }

        // Feed director server with speech recognizer
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount
        )

        // Also show on external display & browser if configured
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: false
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func updateTextFromDirector(_ text: String, readCharCount: Int) {
        guard directorIsReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pages = [trimmed]

        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count

        // Preserve only the prefix that was both recognized by the Mac and
        // locked in the director's edit snapshot. Recognition can advance
        // while an update is in flight, so trusting either count alone could
        // make newly read text unexpectedly editable or overwriteable.
        let recognizedCharCount = overlayController.speechRecognizer.recognizedCharCount
        let preservedCharCount = min(
            totalCharCount,
            min(recognizedCharCount, max(0, readCharCount))
        )

        // Update overlay content without resetting speech progress
        overlayController.overlayContent.words = words
        overlayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        overlayController.overlayContent.totalCharCount = totalCharCount
        overlayController.overlayContent.hasNextPage = false

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(words: words, totalCharCount: totalCharCount)

        // Update external display & browser
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = totalCharCount
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    func updateKeepAwakeActivity(enabled: Bool) {
        overlayController.updateKeepAwakeActivity(enabled: enabled)
    }

    // macOS Services handler
    @objc func readInDynoPrompt(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    /// Schemes this app answers to. `textream` is the name it shipped under
    /// before the rename; links created then still work.
    static let supportedURLSchemes: Set<String> = ["dynoprompt", "textream"]

    // URL scheme handler: dynoprompt://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              Self.supportedURLSchemes.contains(scheme) else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}
