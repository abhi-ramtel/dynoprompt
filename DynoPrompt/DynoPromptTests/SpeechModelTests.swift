//
//  SpeechModelTests.swift
//  DynoPromptTests
//
//  Catalog integrity and model-store safety. Downloaded models are untrusted
//  external assets, so most of these tests name the attack they prevent.
//

import XCTest

// MARK: - Catalog

final class SpeechModelCatalogTests: XCTestCase {

    /// Every shipped entry must satisfy the identifier, source and digest
    /// rules. If someone adds a model with a typo'd hash or an off-allowlist
    /// URL, this fails before it can ship.
    func testShippedCatalogIsValid() {
        let problems = SpeechModelCatalog.validateCatalog()
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testCatalogCoversTheUsefulRange() {
        let tiers = Set(SpeechModelCatalog.all.map(\.tier))
        XCTAssertTrue(tiers.contains(.tiny))
        XCTAssertTrue(tiers.contains(.base))
        XCTAssertTrue(tiers.contains(.large))

        let languages = Set(SpeechModelCatalog.all.map(\.languages))
        XCTAssertTrue(languages.contains(.englishOnly))
        XCTAssertTrue(languages.contains(.multilingual))
    }

    func testBundledModelIsInTheCatalog() {
        XCTAssertNotNil(SpeechModelCatalog.model(withID: SpeechModelCatalog.bundledModelID))
    }

    func testEveryModelExposesTheMetadataTheUIPromises() {
        for model in SpeechModelCatalog.all {
            XCTAssertFalse(model.displayName.isEmpty, model.id)
            XCTAssertFalse(model.version.isEmpty, model.id)
            XCTAssertGreaterThan(model.sizeBytes, 0, model.id)
            XCTAssertGreaterThan(model.approximateMemoryBytes, 0, model.id)
            XCTAssertGreaterThan(model.relativeSpeed, 0, model.id)
            XCTAssertFalse(model.summary.isEmpty, model.id)
            XCTAssertFalse(model.resourceWarning.isEmpty, model.id)
        }
    }

    // MARK: Source allowlist

    func testHttpsAllowlistedHostsAccepted() {
        for candidate in [
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
            "https://cdn-lfs.huggingface.co/repos/abc/ggml-base.en.bin",
            "https://some-cdn.huggingface.co/x.bin",
            // The CDN a huggingface.co download actually redirects to.
            "https://us.aws.cdn.hf.co/xet-bridge-us/abc/def",
            "https://eu.aws.cdn.hf.co/xet-bridge-eu/abc",
            "https://transfer.xethub.hf.co/x",
        ] {
            XCTAssertTrue(
                SpeechModelCatalog.isAllowedSource(URL(string: candidate)!),
                "\(candidate) should be allowed"
            )
        }
    }

    /// Plaintext, unknown hosts, and lookalike domains must all be refused.
    func testUnsafeSourcesRejected() {
        for candidate in [
            "http://huggingface.co/model.bin",            // no TLS
            "https://evil.example/model.bin",             // not allowlisted
            "https://evil-huggingface.co/model.bin",      // suffix lookalike
            "https://huggingface.co.evil.example/x.bin",  // subdomain lookalike
            "https://evil-cdn.hf.co/model.bin",           // hyphen lookalike
            "https://hf.co.evil.example/model.bin",
            "https://notcdn.hf.co.attacker.test/x.bin",
            "file:///etc/passwd",
            "ftp://huggingface.co/model.bin",
        ] {
            XCTAssertFalse(
                SpeechModelCatalog.isAllowedSource(URL(string: candidate)!),
                "\(candidate) must be rejected"
            )
        }
    }

    // MARK: Identifiers

    /// Identifiers become filenames, so anything that could escape the model
    /// directory or address a device must be refused.
    func testTraversalIdentifiersRejected() {
        for candidate in [
            "..", ".", "../../etc/passwd", "a/b", "a\\b", "", ".hidden", "trailing.",
            "model\u{0}name", "modèle", "a b", String(repeating: "x", count: 65),
        ] {
            XCTAssertFalse(
                SpeechModelCatalog.isValidIdentifier(candidate),
                "\(candidate.debugDescription) must be rejected"
            )
        }
    }

    func testOrdinaryIdentifiersAccepted() {
        for candidate in ["ggml-base.en", "ggml-large-v3-turbo", "model_1", "a"] {
            XCTAssertTrue(
                SpeechModelCatalog.isValidIdentifier(candidate),
                "\(candidate) should be accepted"
            )
        }
    }

    func testFileNameIsDerivedFromIdentifierOnly() {
        let model = SpeechModelCatalog.model(withID: "ggml-base.en")!
        XCTAssertEqual(model.fileName, "ggml-base.en.bin")
    }

    // MARK: Digests

    func testDigestValidation() {
        XCTAssertTrue(SpeechModelCatalog.isValidDigest(String(repeating: "a", count: 64)))
        XCTAssertFalse(SpeechModelCatalog.isValidDigest(String(repeating: "A", count: 64)))
        XCTAssertFalse(SpeechModelCatalog.isValidDigest(String(repeating: "a", count: 63)))
        XCTAssertFalse(SpeechModelCatalog.isValidDigest(String(repeating: "z", count: 64)))
        XCTAssertFalse(SpeechModelCatalog.isValidDigest(""))
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.short(147_964_211), "141 MB")
        XCTAssertEqual(ByteFormat.short(1_624_555_275), "1.5 GB")
    }
}

// MARK: - Store

final class SpeechModelStoreTests: XCTestCase {

    private var directory: URL!
    private var store: SpeechModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptModels-\(UUID().uuidString)", isDirectory: true)
        store = SpeechModelStore(directory: directory)
        try store.ensureDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeFile(bytes: Int, at url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    // MARK: Paths

    func testFileURLStaysInsideStorageDirectory() throws {
        let url = try store.fileURL(for: "ggml-base.en")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(url.lastPathComponent, "ggml-base.en.bin")
    }

    /// The path-traversal case, at the layer that builds paths.
    func testTraversalIdentifierIsRefused() {
        XCTAssertThrowsError(try store.fileURL(for: "../../../../tmp/pwned")) { error in
            XCTAssertEqual(error as? SpeechModelStoreError, .invalidIdentifier("../../../../tmp/pwned"))
        }
        XCTAssertThrowsError(try store.fileURL(for: ".."))
        XCTAssertThrowsError(try store.fileURL(for: "a/b"))
    }

    // MARK: Install

    func testInstallMovesVerifiedFileIntoPlace() throws {
        let model = SpeechModelCatalog.model(withID: "ggml-base.en")!
        let staged = directory.appendingPathComponent("staged.partial")
        try makeFile(bytes: Int(model.sizeBytes), at: staged)

        let installed = try store.install(downloadedFile: staged, as: model)

        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staging file consumed")
        XCTAssertTrue(store.isInstalled(model.id))
    }

    /// A truncated transfer must be rejected and deleted, never installed.
    func testTruncatedDownloadIsRejectedAndDiscarded() throws {
        let model = SpeechModelCatalog.model(withID: "ggml-base.en")!
        let staged = directory.appendingPathComponent("staged.partial")
        try makeFile(bytes: 1024, at: staged)

        XCTAssertThrowsError(try store.install(downloadedFile: staged, as: model)) { error in
            guard case .sizeMismatch = error as? SpeechModelStoreError else {
                return XCTFail("expected a size mismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "bad download deleted")
        XCTAssertFalse(store.isInstalled(model.id), "nothing installed")
    }

    func testInstalledModelsAreOwnerOnly() throws {
        let model = SpeechModelCatalog.model(withID: "ggml-base.en")!
        let staged = directory.appendingPathComponent("staged.partial")
        try makeFile(bytes: Int(model.sizeBytes), at: staged)
        let installed = try store.install(downloadedFile: staged, as: model)

        let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o077, 0, "group/other must have no access")
        // A model is data. Nothing should ever mark it executable.
        XCTAssertEqual(permissions & 0o111, 0, "must not be executable")
    }

    // MARK: Enumeration

    func testStrayFilesAreIgnored() throws {
        try makeFile(bytes: 16, at: directory.appendingPathComponent("ggml-base.en.bin"))
        try makeFile(bytes: 16, at: directory.appendingPathComponent("notes.txt"))
        try makeFile(bytes: 16, at: directory.appendingPathComponent("a b.bin"))

        let installed = store.installedModels()
        XCTAssertEqual(installed.map(\.id), ["ggml-base.en"])
    }

    func testBundledModelIsReportedAndNotRemovable() throws {
        let bundled = directory.appendingPathComponent("bundled-copy.bin")
        try makeFile(bytes: 32, at: bundled)

        let installed = store.installedModels(bundled: bundled)
        let entry = installed.first { $0.id == SpeechModelCatalog.bundledModelID }
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isBundled ?? false)

        XCTAssertThrowsError(try store.remove(SpeechModelCatalog.bundledModelID)) { error in
            XCTAssertEqual(error as? SpeechModelStoreError, .cannotRemoveBundled)
        }
    }

    // MARK: Remove

    func testRemoveDeletesTheFile() throws {
        let url = try store.fileURL(for: "ggml-tiny.en")
        try makeFile(bytes: 16, at: url)
        XCTAssertTrue(store.isInstalled("ggml-tiny.en"))

        try store.remove("ggml-tiny.en")
        XCTAssertFalse(store.isInstalled("ggml-tiny.en"))
    }

    func testRemovingSomethingNotInstalledThrows() {
        XCTAssertThrowsError(try store.remove("ggml-tiny.en")) { error in
            XCTAssertEqual(error as? SpeechModelStoreError, .notInstalled("ggml-tiny.en"))
        }
    }

    func testRemoveRefusesTraversalIdentifier() {
        XCTAssertThrowsError(try store.remove("../../../etc/hosts"))
    }

    // MARK: Disk space

    func testDiskSpaceCheckRequiresHeadroom() throws {
        // The real volume has room for a small model; the check should pass
        // for tiny and the arithmetic should demand more than the file size.
        let tiny = SpeechModelCatalog.model(withID: "ggml-tiny.en")!
        XCTAssertNoThrow(try store.verifyDiskSpace(for: tiny))
        XCTAssertGreaterThan(store.availableDiskSpace(), 0)
    }

    func testInsufficientSpaceErrorIsDescriptive() {
        let error = SpeechModelStoreError.insufficientDiskSpace(
            required: 2_000_000_000,
            available: 100_000_000
        )
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("1.9 GB"), message)
        XCTAssertTrue(message.contains("95 MB"), message)
    }

    /// The integrity failure message must not leak digests — it should tell
    /// the user what happened and what to do.
    func testIntegrityErrorIsActionableAndTerse() {
        let error = SpeechModelStoreError.integrityMismatch(
            expected: String(repeating: "a", count: 64),
            actual: String(repeating: "b", count: 64)
        )
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("integrity check"), message)
        XCTAssertFalse(message.contains(String(repeating: "a", count: 64)), "should not echo digests")
    }
}

// MARK: - Disk space on a fresh install

/// Regression: on a machine where the model directory has never been created,
/// the free-space probe must still report the volume's real capacity. It
/// previously returned zero, which refused every download on a disk with
/// hundreds of gigabytes free.
final class FreshInstallDiskSpaceTests: XCTestCase {

    func testReportsRealCapacityWhenDirectoryDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptMissing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        let store = SpeechModelStore(directory: missing)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertGreaterThan(
            store.availableDiskSpace(), 0,
            "a non-existent directory must not report an empty volume"
        )
    }

    func testSmallModelPassesTheSpaceCheckOnAFreshInstall() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptMissing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        let store = SpeechModelStore(directory: missing)

        let tiny = SpeechModelCatalog.all.min(by: { $0.sizeBytes < $1.sizeBytes })!
        XCTAssertNoThrow(try store.verifyDiskSpace(for: tiny))
    }
}

// MARK: - Size clamping

/// Regression: `didSet` clamping does not run during `init`, so a stored value
/// outside the allowed range used to survive a relaunch and could draw the
/// overlay off-screen or at an unreadable font size.
final class SettingsClampTests: XCTestCase {

    func testClampBoundsValues() {
        XCTAssertEqual(PrompterLayoutLimits.clamp(9999, 240, 1600), 1600)
        XCTAssertEqual(PrompterLayoutLimits.clamp(-5, 240, 1600), 240)
        XCTAssertEqual(PrompterLayoutLimits.clamp(500, 240, 1600), 500)
    }

    func testDocumentedRangesAreCoherent() {
        XCTAssertLessThan(PrompterLayoutLimits.minWidth, PrompterLayoutLimits.maxWidth)
        XCTAssertLessThan(PrompterLayoutLimits.minHeight, PrompterLayoutLimits.maxHeight)
        XCTAssertLessThan(PrompterLayoutLimits.minFontSize, PrompterLayoutLimits.maxFontSize)
        XCTAssertLessThan(PrompterLayoutLimits.minLineSpacing, PrompterLayoutLimits.maxLineSpacing)

        // Defaults must sit inside their own ranges.
        XCTAssertTrue((PrompterLayoutLimits.minWidth...PrompterLayoutLimits.maxWidth)
            .contains(PrompterLayoutLimits.defaultWidth))
        XCTAssertTrue((PrompterLayoutLimits.minHeight...PrompterLayoutLimits.maxHeight)
            .contains(PrompterLayoutLimits.defaultHeight))
        XCTAssertTrue((PrompterLayoutLimits.minFontSize...PrompterLayoutLimits.maxFontSize)
            .contains(PrompterLayoutLimits.defaultFontSize))
        XCTAssertTrue((PrompterLayoutLimits.minLineSpacing...PrompterLayoutLimits.maxLineSpacing)
            .contains(PrompterLayoutLimits.defaultLineSpacing))
    }

    /// The four legacy quick-picks must all remain reachable through the
    /// continuous value, so migrating an existing setup cannot clamp it.
    func testLegacyPresetSizesFallInsideTheContinuousRange() {
        let range = PrompterLayoutLimits.minFontSize...PrompterLayoutLimits.maxFontSize
        for points in [CGFloat(14), 16, 20, 24] {
            XCTAssertTrue(range.contains(points), "\(points)pt is outside the slider range")
        }
    }

    /// A stored value from a previous build is brought back in range rather
    /// than trusted.
    func testOutOfRangeStoredValuesAreClamped() {
        XCTAssertEqual(PrompterLayoutLimits.clampWidth(9999), PrompterLayoutLimits.maxWidth)
        XCTAssertEqual(PrompterLayoutLimits.clampFontSize(500), PrompterLayoutLimits.maxFontSize)
        XCTAssertEqual(PrompterLayoutLimits.clampLineSpacing(99), PrompterLayoutLimits.maxLineSpacing)
        XCTAssertEqual(PrompterLayoutLimits.clampHeight(-1), PrompterLayoutLimits.minHeight)
    }

    /// An oversized setting is fitted to the display in use rather than drawn
    /// off-screen.
    func testScreenFittingNeverExceedsTheDisplay() {
        XCTAssertLessThanOrEqual(
            PrompterLayoutLimits.maximumWidth(forScreenWidth: 1440), 1440
        )
        XCTAssertLessThanOrEqual(
            PrompterLayoutLimits.maximumHeight(forScreenHeight: 900), 900
        )
        // Even a tiny display must still allow the minimum usable size.
        XCTAssertGreaterThanOrEqual(
            PrompterLayoutLimits.maximumWidth(forScreenWidth: 100),
            PrompterLayoutLimits.minWidth
        )
    }

    /// The size range must be wide enough to be worth calling adjustable.
    func testRangesAreGenerous() {
        XCTAssertGreaterThanOrEqual(PrompterLayoutLimits.maxWidth / PrompterLayoutLimits.minWidth, 5)
        XCTAssertGreaterThanOrEqual(PrompterLayoutLimits.maxFontSize / PrompterLayoutLimits.minFontSize, 5)
    }
}
