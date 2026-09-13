//
//  LegacyMigration.swift
//  DynoPrompt
//
//  Carries a user's data across the rename from Textream.
//
//  Changing the bundle identifier moves the app to a new `UserDefaults` domain
//  and a new Application Support directory. Without this, an existing user
//  would launch the renamed app to find their settings reset and their script
//  library apparently empty — which looks exactly like data loss.
//
//  Migration runs once, copies rather than moves, and never overwrites
//  anything already present in the new location.
//

import Foundation
import OSLog

enum LegacyMigration {

    private static let legacyBundleID = "dev.fka.textream"
    private static let legacySupportFolder = "Textream"
    private static let completionKey = "migratedFromTextream"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fka.dynoprompt",
        category: "Migration"
    )

    /// Runs both migrations once. Safe to call on every launch.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }
        migrateSettings(into: defaults)
        migrateScriptLibrary()
        defaults.set(true, forKey: completionKey)
        logger.info("Completed migration from the previous app name.")
    }

    // MARK: - Settings

    /// Copies preferences from the old domain, skipping any key the user has
    /// already set here so a fresh choice is never clobbered.
    static func migrateSettings(into defaults: UserDefaults) {
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        let values = legacy.persistentDomain(forName: legacyBundleID) ?? [:]
        guard !values.isEmpty else { return }

        var copied = 0
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        if copied > 0 {
            logger.info("Carried over \(copied, privacy: .public) settings.")
        }
    }

    // MARK: - Script library

    /// Copies saved scripts from the old Application Support folder.
    ///
    /// Files are copied, not moved: if anything goes wrong the originals are
    /// still where the previous version left them.
    static func migrateScriptLibrary(fileManager: FileManager = .default) {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let source = base
            .appendingPathComponent(legacySupportFolder, isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        guard let destination = try? ScriptLibraryStore.defaultDirectory(fileManager: fileManager) else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("Couldn't create the script library: \(error.localizedDescription, privacy: .public)")
            return
        }

        let entries = (try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var copied = 0
        for entry in entries where entry.pathExtension.lowercased() == "json" {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.copyItem(at: entry, to: target)
                copied += 1
            } catch {
                logger.error("Couldn't copy \(entry.lastPathComponent, privacy: .public).")
            }
        }
        if copied > 0 {
            logger.info("Carried over \(copied, privacy: .public) scripts.")
        }
    }
}
