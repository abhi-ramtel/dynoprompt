//
//  ScriptLibraryStore.swift
//  DynoPromptCore
//
//  Local, file-backed storage for the user's scripts.
//
//  Scripts never leave the machine: one JSON file per script under
//  Application Support, no index server, no sync, no telemetry. The store is
//  initialised with a directory so tests can point it at a temporary folder.
//

import Foundation

public struct Script: Codable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    /// Pages of script text. A single-page script is the common case; PPTX
    /// imports and multi-section talks use several.
    public var pages: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        pages: [String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, used when the user has not named the script.
    public static func derivedTitle(fromPages pages: [String]) -> String {
        for page in pages {
            for line in page.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(60))
                }
            }
        }
        return "Untitled Script"
    }

    public var wordCount: Int {
        pages.reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
    }

    /// Rough read time at a conversational 150 words per minute.
    public var estimatedDuration: TimeInterval {
        Double(wordCount) / 150.0 * 60.0
    }
}

public enum ScriptLibraryError: LocalizedError {
    case invalidIdentifier
    case storageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "That script identifier isn't valid."
        case .storageUnavailable(let detail):
            return "Couldn't access the script library: \(detail)"
        }
    }
}

public final class ScriptLibraryStore {

    /// ISO-8601 *with* fractional seconds.
    ///
    /// `JSONEncoder.DateEncodingStrategy.iso8601` truncates to whole seconds,
    /// which loses the ordering between two scripts saved in the same second
    /// and makes the library's "most recent first" sort arbitrary.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = timestampFormatter.date(from: raw) { return date }
            // Tolerate files written before fractional seconds were stored.
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised timestamp: \(raw)"
            )
        }
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default location: ~/Library/Application Support/DynoPrompt/Scripts.
    /// Inside the App Sandbox this resolves into the app container, which is
    /// exactly the least-privilege outcome we want.
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("DynoPrompt", isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ScriptLibraryError.storageUnavailable("\(directory.path) is not a directory")
            }
            return
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            // Owner-only: scripts can contain unreleased or confidential
            // material and there is no reason for other users to read them.
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Maps an id to its file. Built from the UUID's canonical string rather
    /// than from any user-supplied text, so a script title can never influence
    /// the path — there is no traversal surface here by construction.
    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    // MARK: - CRUD

    public func loadAll() -> [Script] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = Self.makeDecoder()

        var scripts: [Script] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            // Only read files whose name is a UUID we wrote. A stray file
            // dropped into the folder is ignored rather than parsed.
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            guard let data = try? Data(contentsOf: url),
                  let script = try? decoder.decode(Script.self, from: data) else { continue }
            scripts.append(script)
        }
        return scripts.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func save(_ script: Script) throws -> Script {
        try ensureDirectory()

        var updated = script
        updated.updatedAt = Date()
        if updated.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.title = Script.derivedTitle(fromPages: updated.pages)
        }

        let data = try Self.makeEncoder().encode(updated)

        let url = fileURL(for: updated.id)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return updated
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func load(id: UUID) -> Script? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.makeDecoder().decode(Script.self, from: data)
    }
}
