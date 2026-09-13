//
//  ExtractedFileGuard.swift
//  DynoPromptCore
//
//  Containment checks for files produced by unpacking an untrusted archive.
//
//  A .pptx is a ZIP, and a ZIP entry can carry the symlink attribute, which
//  `unzip` faithfully recreates. An archive whose `ppt/notesSlides/
//  notesSlide1.xml` entry is a symlink to `~/.ssh/id_rsa` would otherwise make
//  the notes extractor read that file and present it as the user's script —
//  which Remote Connection or Director Mode could then broadcast. The
//  Developer ID build is not sandboxed, so this is a real arbitrary-file-read
//  primitive, not a theoretical one.
//

import Foundation

public enum ExtractedFileGuard {

    /// True when `url` is a regular file that genuinely resides inside `root`.
    ///
    /// Symlinks are rejected outright rather than followed, and both paths are
    /// resolved first so a `..` segment that survived extraction is caught by
    /// the same check.
    public static func isContainedRegularFile(
        _ url: URL,
        within root: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return false }
        if values?.isRegularFile != true { return false }
        return isContainedPath(url, within: root)
    }

    /// Pure path containment, independent of what is on disk. Split out so the
    /// traversal rule can be tested without creating files.
    public static func isContainedPath(_ url: URL, within root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != resolvedRoot else { return false }
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolved.hasPrefix(prefix)
    }
}
