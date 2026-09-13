//
//  SpeechModelStore.swift
//  DynoPromptCore
//
//  On-disk management of installed speech models: where they live, which are
//  present, installing one atomically, and removing one.
//
//  Downloaded models are treated as untrusted input. Nothing here derives a
//  path from server-supplied data, installation is atomic so a failed download
//  can never leave a half-written file that looks installed, and every write
//  is confined to one directory that is re-verified on each operation.
//

import Foundation

public enum SpeechModelStoreError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case integrityMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case escapesStorageDirectory(String)
    case storageUnavailable(String)
    case notInstalled(String)
    case cannotRemoveBundled

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "“\(id)” isn't a valid model identifier."
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space. This model needs \(ByteFormat.short(required)); "
                + "\(ByteFormat.short(available)) is free."
        case .integrityMismatch:
            // Deliberately does not echo the digests: the actionable fact is
            // that the file was rejected and deleted.
            return "The downloaded model failed its integrity check and was discarded. "
                + "This usually means the download was corrupted — try again."
        case .sizeMismatch(let expected, let actual):
            return "The download was \(ByteFormat.short(actual)); "
                + "\(ByteFormat.short(expected)) was expected. It was discarded."
        case .escapesStorageDirectory:
            return "That model path is outside the model folder and was refused."
        case .storageUnavailable(let detail):
            return "Couldn't access the model folder: \(detail)"
        case .notInstalled(let id):
            return "“\(id)” isn't installed."
        case .cannotRemoveBundled:
            return "The built-in model ships with the app and can't be removed."
        }
    }
}

// MARK: - Installed model

public struct InstalledSpeechModel: Identifiable, Equatable {
    public let id: String
    public let url: URL
    public let sizeBytes: Int64
    public let installedAt: Date
    /// True for the model that ships inside the app bundle.
    public let isBundled: Bool

    public init(id: String, url: URL, sizeBytes: Int64, installedAt: Date, isBundled: Bool) {
        self.id = id
        self.url = url
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.isBundled = isBundled
    }
}

// MARK: - Store

public final class SpeechModelStore {

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Where downloaded models live. Inside the App Sandbox this resolves into
    /// the app container, which is the least-privilege outcome.
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("DynoPrompt", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Shown in the UI so the user always knows where their models are.
    public var storageDirectory: URL { directory }

    // MARK: - Paths

    /// Resolves the install path for a model id.
    ///
    /// Identifiers are validated first, then the resolved path is re-checked
    /// against the storage directory. Belt and braces: the validation alone is
    /// sufficient, but the containment check means a future change to the
    /// identifier rules cannot silently open a traversal.
    public func fileURL(for id: String) throws -> URL {
        guard SpeechModelCatalog.isValidIdentifier(id) else {
            throw SpeechModelStoreError.invalidIdentifier(id)
        }
        let url = directory.appendingPathComponent("\(id).bin", isDirectory: false)
        guard ExtractedFileGuard.isContainedPath(url, within: directory) else {
            throw SpeechModelStoreError.escapesStorageDirectory(id)
        }
        return url
    }

    public func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SpeechModelStoreError.storageUnavailable("\(directory.path) is not a directory")
            }
            return
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SpeechModelStoreError.storageUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Queries

    public func isInstalled(_ id: String) -> Bool {
        guard let url = try? fileURL(for: id) else { return false }
        return fileManager.isReadableFile(atPath: url.path)
    }

    /// Every model present on disk, plus the bundled one if supplied.
    public func installedModels(bundled: URL? = nil) -> [InstalledSpeechModel] {
        var results: [InstalledSpeechModel] = []

        if let bundled, fileManager.isReadableFile(atPath: bundled.path) {
            results.append(InstalledSpeechModel(
                id: SpeechModelCatalog.bundledModelID,
                url: bundled,
                sizeBytes: fileSize(at: bundled) ?? 0,
                installedAt: creationDate(at: bundled) ?? Date(),
                isBundled: true
            ))
        }

        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in entries where url.pathExtension.lowercased() == "bin" {
            let id = url.deletingPathExtension().lastPathComponent
            // Only surface files this app could have written. A stray file is
            // ignored rather than offered as a model.
            guard SpeechModelCatalog.isValidIdentifier(id) else { continue }
            guard !results.contains(where: { $0.id == id }) else { continue }
            results.append(InstalledSpeechModel(
                id: id,
                url: url,
                sizeBytes: fileSize(at: url) ?? 0,
                installedAt: creationDate(at: url) ?? Date(),
                isBundled: false
            ))
        }
        return results.sorted { $0.id < $1.id }
    }

    /// Free space on the volume holding the model directory.
    ///
    /// Walks up to the first ancestor that exists: on a fresh install neither
    /// the model directory nor its parent has been created yet, and querying a
    /// path that does not exist reports zero free space — which would refuse
    /// every download on a machine with plenty of room.
    public func availableDiskSpace() -> Int64 {
        var probe = directory
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            // Stop at the root rather than looping forever.
            guard parent.path != probe.path, parent.path != "/" else {
                probe = URL(fileURLWithPath: NSHomeDirectory())
                break
            }
            probe = parent
        }
        guard let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return capacity
    }

    /// Checks there is room for a download, keeping headroom so a install does
    /// not fill the volume. The temporary file and the final file coexist
    /// briefly, so twice the size is required.
    public func verifyDiskSpace(for model: SpeechModelDescriptor) throws {
        let required = model.sizeBytes * 2 + 256 * 1_048_576
        let available = availableDiskSpace()
        guard available >= required else {
            throw SpeechModelStoreError.insufficientDiskSpace(
                required: required,
                available: available
            )
        }
    }

    // MARK: - Install / remove

    /// Moves a verified download into place atomically.
    ///
    /// The caller must already have verified the digest. The move is the last
    /// step and is atomic within a volume, so a model file either exists
    /// complete and verified, or does not exist at all — there is no state in
    /// which a partial file looks installed.
    public func install(
        downloadedFile temporaryURL: URL,
        as model: SpeechModelDescriptor
    ) throws -> URL {
        try ensureDirectory()
        let destination = try fileURL(for: model.id)

        // Size is cheap to check and catches a truncated transfer before the
        // more expensive digest comparison is trusted.
        let actualSize = fileSize(at: temporaryURL) ?? -1
        guard actualSize == model.sizeBytes else {
            try? fileManager.removeItem(at: temporaryURL)
            throw SpeechModelStoreError.sizeMismatch(
                expected: model.sizeBytes,
                actual: max(0, actualSize)
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try? fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }

        // Models are read-only data; nothing should ever execute them, and the
        // permissions say so.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func remove(_ id: String) throws {
        guard id != SpeechModelCatalog.bundledModelID || !isBundledOnly(id) else {
            throw SpeechModelStoreError.cannotRemoveBundled
        }
        let url = try fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SpeechModelStoreError.notInstalled(id)
        }
        try fileManager.removeItem(at: url)
    }

    /// True when the only copy of this id is the one inside the app bundle.
    private func isBundledOnly(_ id: String) -> Bool {
        guard let url = try? fileURL(for: id) else { return true }
        return !fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func creationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
