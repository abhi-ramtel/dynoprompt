//
//  OpenWhisprDiscovery.swift
//  DynoPromptCore
//
//  Locates a local whisper.cpp runtime and GGML model files.
//
//  DynoPrompt does NOT talk to OpenWhispr. OpenWhispr is an Electron app with no
//  public API, no IPC surface and no documented protocol, so driving it would
//  mean depending on private internals that can change without notice.
//
//  What OpenWhispr *does* provide is the same underlying technology: it ships
//  whisper.cpp's `server` binary and downloads standard GGML models to a
//  predictable cache directory. Those artifacts are plain files in documented
//  upstream formats, so DynoPrompt can reuse them in place — no duplicate
//  multi-gigabyte download — while remaining fully functional when OpenWhispr
//  is absent.
//
//  Discovery is pure path resolution against an injectable filesystem view so
//  it can be unit tested without either app installed.
//

import Foundation

public struct WhisperRuntimeLocation: Equatable {
    public enum Source: String, Equatable {
        /// Shipped inside DynoPrompt itself.
        case bundled
        /// Reused from an OpenWhispr installation on this machine.
        case openWhispr
        /// Found on PATH or in a Homebrew prefix.
        case systemPath
        /// Explicitly chosen by the user.
        case userSelected
    }

    public let executableURL: URL
    public let source: Source

    public init(executableURL: URL, source: Source) {
        self.executableURL = executableURL
        self.source = source
    }
}

public struct WhisperModel: Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let displayName: String
    public let sizeBytes: Int64
    public let source: WhisperRuntimeLocation.Source

    public init(url: URL, displayName: String, sizeBytes: Int64, source: WhisperRuntimeLocation.Source) {
        self.url = url
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.source = source
    }
}

/// The filesystem operations discovery needs, so tests can supply a fake.
public protocol WhisperFileProbing {
    func isExecutableFile(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) -> [URL]
    func fileSize(at url: URL) -> Int64?
}

public struct DefaultWhisperFileProbe: WhisperFileProbing {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isExecutableFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    public func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

public enum OpenWhisprDiscovery {

    /// Locations OpenWhispr is known to install its whisper.cpp server into.
    /// Verified against OpenWhispr 1.x on macOS.
    public static func openWhisprBinaryCandidates(
        applicationsDirectories: [URL]
    ) -> [URL] {
        let relativePaths = [
            "OpenWhispr.app/Contents/Resources/bin/whisper-server-darwin-arm64",
            "OpenWhispr.app/Contents/Resources/bin/whisper-server-darwin-x64",
            "OpenWhispr.app/Contents/Resources/bin/whisper-server",
        ]
        return applicationsDirectories.flatMap { base in
            relativePaths.map { base.appendingPathComponent($0) }
        }
    }

    /// Directories that hold GGML `.bin` models, in preference order.
    public static func modelDirectories(homeDirectory: URL) -> [(URL, WhisperRuntimeLocation.Source)] {
        [
            (homeDirectory.appendingPathComponent("Library/Application Support/DynoPrompt/models"), .bundled),
            (homeDirectory.appendingPathComponent(".cache/openwhispr/whisper-models"), .openWhispr),
            (homeDirectory.appendingPathComponent("Library/Application Support/open-whispr/models"), .openWhispr),
            (homeDirectory.appendingPathComponent(".cache/whisper"), .systemPath),
            (homeDirectory.appendingPathComponent("Library/Application Support/natively/whisper-models"), .systemPath),
        ]
    }

    /// Finds a usable whisper.cpp server binary, preferring one DynoPrompt ships
    /// over one borrowed from another app.
    public static func locateRuntime(
        bundledBinary: URL?,
        applicationsDirectories: [URL],
        additionalCandidates: [URL] = [],
        probe: WhisperFileProbing = DefaultWhisperFileProbe()
    ) -> WhisperRuntimeLocation? {
        if let bundledBinary, probe.isExecutableFile(at: bundledBinary) {
            return WhisperRuntimeLocation(executableURL: bundledBinary, source: .bundled)
        }
        for candidate in additionalCandidates where probe.isExecutableFile(at: candidate) {
            return WhisperRuntimeLocation(executableURL: candidate, source: .userSelected)
        }
        for candidate in openWhisprBinaryCandidates(applicationsDirectories: applicationsDirectories)
        where probe.isExecutableFile(at: candidate) {
            return WhisperRuntimeLocation(executableURL: candidate, source: .openWhispr)
        }
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for name in ["whisper-server", "whisper-cpp-server"] {
                let candidate = URL(fileURLWithPath: prefix).appendingPathComponent(name)
                if probe.isExecutableFile(at: candidate) {
                    return WhisperRuntimeLocation(executableURL: candidate, source: .systemPath)
                }
            }
        }
        return nil
    }

    /// Lists every GGML model DynoPrompt can load, newest-looking first.
    public static func availableModels(
        homeDirectory: URL,
        probe: WhisperFileProbing = DefaultWhisperFileProbe()
    ) -> [WhisperModel] {
        var seen = Set<String>()
        var models: [WhisperModel] = []

        for (directory, source) in modelDirectories(homeDirectory: homeDirectory) {
            for url in probe.contentsOfDirectory(at: directory) {
                guard url.pathExtension.lowercased() == "bin" else { continue }
                // GGML whisper models are all named ggml-*.bin upstream. The
                // prefix check keeps unrelated .bin files (e.g. the Silero VAD
                // weights sitting in the same folder) out of the picker.
                let name = url.lastPathComponent
                guard name.hasPrefix("ggml-") else { continue }
                guard !name.contains("silero") else { continue }
                guard seen.insert(url.path).inserted else { continue }

                models.append(WhisperModel(
                    url: url,
                    displayName: displayName(forFileNamed: name),
                    sizeBytes: probe.fileSize(at: url) ?? 0,
                    source: source
                ))
            }
        }
        return models
    }

    static func displayName(forFileNamed name: String) -> String {
        var trimmed = name
        if trimmed.hasPrefix("ggml-") { trimmed.removeFirst("ggml-".count) }
        if trimmed.hasSuffix(".bin") { trimmed.removeLast(".bin".count) }
        return trimmed
    }
}
