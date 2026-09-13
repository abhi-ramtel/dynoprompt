//
//  PresentationNotesExtractor.swift
//  DynoPrompt
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//

import AppKit
import Foundation

enum PresentationNotesExtractor {

    enum ExtractionError: LocalizedError {
        case unsupportedFormat
        case extractionFailed(String)
        case noNotesFound

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Unsupported file format. Please drop a .pptx or .key file."
            case .extractionFailed(let detail):
                return "Failed to extract notes: \(detail)"
            case .noNotesFound:
                return "No presenter notes found in this presentation."
            }
        }
    }

    static func extractNotes(from url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pptx":
            return try extractPPTXNotes(from: url)
        default:
            throw ExtractionError.unsupportedFormat
        }
    }

    // MARK: - PPTX Extraction

    private static func extractPPTXNotes(from url: URL) throws -> [String] {
        // PPTX is a ZIP archive. Unzip to temp directory and parse XML notes.
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Copy the security-scoped document into DynoPrompt's own temporary
        // directory before handing it to a child process. This keeps PPTX
        // import reliable inside the Mac App Store sandbox.
        let localArchive = tempDir.appendingPathComponent("presentation.pptx")
        do {
            try fileManager.copyItem(at: url, to: localArchive)
        } catch {
            throw ExtractionError.extractionFailed("Could not read PPTX file.")
        }

        // Reject an implausibly large archive before expanding it, so a zip
        // bomb cannot fill the disk during import.
        if let size = try? fileManager.attributesOfItem(atPath: localArchive.path)[.size] as? NSNumber,
           size.int64Value > Self.maxArchiveBytes {
            throw ExtractionError.extractionFailed("That presentation is too large to import.")
        }

        // Unzip using Process.
        //
        // `--` terminates option parsing: the archive path is ours (a UUID in
        // our temp directory) but the terminator keeps that true if the path
        // construction ever changes. Arguments are passed as an array, so no
        // shell is involved and there is nothing to quote or escape.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", "--", localArchive.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed("Could not unzip PPTX file.")
        }

        let notesDir = tempDir.appendingPathComponent("ppt/notesSlides")
        guard fileManager.fileExists(atPath: notesDir.path) else {
            throw ExtractionError.noNotesFound
        }

        let noteFiles = try fileManager.contentsOfDirectory(
            at: notesDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
            .filter { $0.pathExtension == "xml" && $0.lastPathComponent.hasPrefix("notesSlide") }
            .filter { isSafeExtractedFile($0, within: tempDir) }
            .sorted { file1, file2 in
                // Sort by slide number: notesSlide1.xml, notesSlide2.xml, ...
                let n1 = extractNumber(from: file1.lastPathComponent) ?? 0
                let n2 = extractNumber(from: file2.lastPathComponent) ?? 0
                return n1 < n2
            }

        var pages: [String] = []

        for noteFile in noteFiles {
            let data = try Data(contentsOf: noteFile)
            guard data.count <= Self.maxNotePartBytes else { continue }
            let text = parsePPTXNoteXML(data: data)
            pages.append(text)
        }

        // Filter out empty slides and slides that only have the slide number placeholder
        pages = pages.compactMap { page in
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && Int(trimmed) == nil else { return nil }
            return trimmed
        }

        guard !pages.isEmpty else {
            throw ExtractionError.noNotesFound
        }

        return pages
    }

    /// Largest .pptx we will expand.
    private static let maxArchiveBytes: Int64 = 200 * 1024 * 1024
    /// Largest single notes part we will parse.
    private static let maxNotePartBytes = 8 * 1024 * 1024

    /// Guards against a malicious .pptx whose entries are symlinks or escape
    /// the extraction directory. See `ExtractedFileGuard` for the threat.
    private static func isSafeExtractedFile(_ url: URL, within root: URL) -> Bool {
        ExtractedFileGuard.isContainedRegularFile(url, within: root)
    }

    private static func extractNumber(from filename: String) -> Int? {
        let digits = filename.filter { $0.isNumber }
        return Int(digits)
    }

    private static func parsePPTXNoteXML(data: Data) -> String {
        let parser = PPTXNoteXMLParser(data: data)
        return parser.parse()
    }

    // MARK: - Keynote (not supported — handled via UI alerts)
}

// MARK: - PPTX Notes XML Parser

private class PPTXNoteXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentText = ""
    private var insideBody = false
    private var insideTextRun = false
    private var insideParagraph = false
    private var skipPlaceholder = false
    private var currentPlaceholderType: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Defence in depth against XXE. Foundation defaults both of these to
        // the safe value; stating them means a copy of this parser cannot
        // silently inherit an unsafe default.
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.parse()
        return paragraphs.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName.hasSuffix(":sp") || elementName == "sp" {
            skipPlaceholder = false
            currentPlaceholderType = nil
        }

        if elementName.hasSuffix(":ph") || elementName == "ph" {
            let type = attributes["type"] ?? ""
            currentPlaceholderType = type
            if type == "sldNum" || type == "sldImg" || type == "dt" || type == "hdr" || type == "ftr" {
                skipPlaceholder = true
            }
        }

        if elementName.hasSuffix(":txBody") || elementName == "txBody" {
            insideBody = true
        }

        // Start of a paragraph
        if (elementName.hasSuffix(":p") || elementName == "p") && insideBody && !skipPlaceholder {
            insideParagraph = true
            currentParagraph = ""
        }

        if (elementName.hasSuffix(":t") || elementName == "t") && insideParagraph {
            insideTextRun = true
            currentText = ""
        }

        // Handle line breaks within a paragraph
        if (elementName.hasSuffix(":br") || elementName == "br") && insideParagraph {
            currentParagraph += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTextRun {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if (elementName.hasSuffix(":t") || elementName == "t") && insideTextRun {
            insideTextRun = false
            currentParagraph += currentText
        }

        // End of a paragraph — flush it
        if (elementName.hasSuffix(":p") || elementName == "p") && insideParagraph {
            insideParagraph = false
            paragraphs.append(currentParagraph)
        }

        if elementName.hasSuffix(":txBody") || elementName == "txBody" {
            insideBody = false
        }

        if elementName.hasSuffix(":sp") || elementName == "sp" {
            skipPlaceholder = false
            currentPlaceholderType = nil
        }
    }
}
