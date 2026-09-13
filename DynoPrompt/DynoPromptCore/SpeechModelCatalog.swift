//
//  SpeechModelCatalog.swift
//  DynoPromptCore
//
//  The curated list of speech models a user may install.
//
//  Every entry is pinned: an exact URL on an allowlisted host, an exact size,
//  and an exact SHA-256. Nothing is discovered from a remote index, because a
//  remote index is a remote instruction — it would let whoever controls it
//  point the app at a file of their choosing. Adding a model is a code change
//  that goes through review.
//
//  Hashes and sizes were taken from the upstream repository's own metadata and
//  independently re-verified against a local download.
//

import Foundation

// MARK: - Descriptor

public struct SpeechModelDescriptor: Identifiable, Equatable, Hashable {

    /// Rough transcription quality, used to order and describe the catalog.
    public enum Tier: Int, Comparable {
        case tiny, base, small, medium, large

        public static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var label: String {
            switch self {
            case .tiny:   return "Tiny"
            case .base:   return "Base"
            case .small:  return "Small"
            case .medium: return "Medium"
            case .large:  return "Large"
            }
        }
    }

    public enum LanguageSupport: Equatable, Hashable {
        case englishOnly
        /// Whisper's multilingual models cover 99 languages.
        case multilingual

        public var label: String {
            switch self {
            case .englishOnly:  return "English only"
            case .multilingual: return "99 languages"
            }
        }
    }

    /// Stable identifier. Also the on-disk filename stem, so it is constrained
    /// to a conservative character set — see `isValidIdentifier`.
    public let id: String
    public let displayName: String
    public let tier: Tier
    public let languages: LanguageSupport
    /// Upstream release this file belongs to.
    public let version: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the file.
    public let sha256: String
    /// Approximate resident memory while loaded, from upstream's published
    /// figures. Used to warn before a model that will not fit.
    public let approximateMemoryBytes: Int64
    /// Speed relative to the largest model: 16 means roughly 16× faster.
    public let relativeSpeed: Int

    public init(
        id: String,
        displayName: String,
        tier: Tier,
        languages: LanguageSupport,
        version: String,
        downloadURL: URL,
        sizeBytes: Int64,
        sha256: String,
        approximateMemoryBytes: Int64,
        relativeSpeed: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.languages = languages
        self.version = version
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.approximateMemoryBytes = approximateMemoryBytes
        self.relativeSpeed = relativeSpeed
    }

    /// Filename this model installs as. Derived from `id` alone — never from
    /// anything the server sends — so a hostile `Content-Disposition` or
    /// redirect target cannot influence where bytes land.
    public var fileName: String { "\(id).bin" }

    /// One-line summary for the model list.
    public var summary: String {
        "\(languages.label) · \(ByteFormat.short(sizeBytes)) · ~\(relativeSpeed)× faster than Large"
    }

    /// Guidance shown before a download starts.
    public var resourceWarning: String {
        "Uses about \(ByteFormat.short(approximateMemoryBytes)) of memory while active, "
            + "and \(ByteFormat.short(sizeBytes)) of disk."
    }
}

// MARK: - Byte formatting

public enum ByteFormat {
    /// Compact, human-readable size. Deliberately not `ByteCountFormatter`:
    /// this is used inside test assertions and must be locale-stable.
    public static func short(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes.rounded())
    }
}

// MARK: - Catalog

public enum SpeechModelCatalog {

    /// Hosts a model may be fetched from.
    ///
    /// An allowlist rather than "any HTTPS URL": TLS proves you are talking to
    /// whoever the certificate names, not that they should be trusted with the
    /// contents of this app's model directory.
    ///
    /// The redirect targets matter as much as the entry points. A request to
    /// `huggingface.co` is answered with a 302 to regional storage — currently
    /// `us.aws.cdn.hf.co` under their Xet backend — and the download follows
    /// it, so those hosts have to be here too or the transfer dies at the
    /// redirect.
    ///
    /// This list bounds *where bytes may come from*. It is not what makes them
    /// trustworthy: the pinned SHA-256 is. A file that hashes correctly is the
    /// file we intended regardless of which mirror served it, and a file that
    /// does not is discarded no matter how reputable the host.
    public static let allowedHosts: Set<String> = [
        "huggingface.co",
        // LFS and Xet storage backends.
        "cdn-lfs.huggingface.co",
        "cdn-lfs-us-1.huggingface.co",
        "cdn.hf.co",
        "xethub.hf.co",
    ]

    private static func upstream(_ file: String) -> URL {
        // Force-unwrapped against a compile-time constant prefix; a malformed
        // entry here is a build-time mistake, not a runtime condition.
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }

    /// Every model the app offers, fastest first.
    public static let all: [SpeechModelDescriptor] = [
        SpeechModelDescriptor(
            id: "ggml-tiny.en",
            displayName: "Tiny (English)",
            tier: .tiny,
            languages: .englishOnly,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-tiny.en.bin"),
            sizeBytes: 77_704_715,
            sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
            approximateMemoryBytes: 390 * 1_048_576,
            relativeSpeed: 32
        ),
        SpeechModelDescriptor(
            id: "ggml-tiny",
            displayName: "Tiny",
            tier: .tiny,
            languages: .multilingual,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-tiny.bin"),
            sizeBytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            approximateMemoryBytes: 390 * 1_048_576,
            relativeSpeed: 32
        ),
        SpeechModelDescriptor(
            id: "ggml-base.en",
            displayName: "Base (English)",
            tier: .base,
            languages: .englishOnly,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-base.en.bin"),
            sizeBytes: 147_964_211,
            sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
            approximateMemoryBytes: 500 * 1_048_576,
            relativeSpeed: 16
        ),
        SpeechModelDescriptor(
            id: "ggml-base",
            displayName: "Base",
            tier: .base,
            languages: .multilingual,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-base.bin"),
            sizeBytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            approximateMemoryBytes: 500 * 1_048_576,
            relativeSpeed: 16
        ),
        SpeechModelDescriptor(
            id: "ggml-small.en",
            displayName: "Small (English)",
            tier: .small,
            languages: .englishOnly,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-small.en.bin"),
            sizeBytes: 487_614_201,
            sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
            approximateMemoryBytes: 1_000 * 1_048_576,
            relativeSpeed: 6
        ),
        SpeechModelDescriptor(
            id: "ggml-small",
            displayName: "Small",
            tier: .small,
            languages: .multilingual,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-small.bin"),
            sizeBytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            approximateMemoryBytes: 1_000 * 1_048_576,
            relativeSpeed: 6
        ),
        SpeechModelDescriptor(
            id: "ggml-medium.en",
            displayName: "Medium (English)",
            tier: .medium,
            languages: .englishOnly,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-medium.en.bin"),
            sizeBytes: 1_533_774_781,
            sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
            approximateMemoryBytes: 2_600 * 1_048_576,
            relativeSpeed: 2
        ),
        SpeechModelDescriptor(
            id: "ggml-medium",
            displayName: "Medium",
            tier: .medium,
            languages: .multilingual,
            version: "whisper.cpp ggml",
            downloadURL: upstream("ggml-medium.bin"),
            sizeBytes: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            approximateMemoryBytes: 2_600 * 1_048_576,
            relativeSpeed: 2
        ),
        SpeechModelDescriptor(
            id: "ggml-large-v3-turbo",
            displayName: "Large v3 Turbo",
            tier: .large,
            languages: .multilingual,
            version: "large-v3-turbo",
            downloadURL: upstream("ggml-large-v3-turbo.bin"),
            sizeBytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            approximateMemoryBytes: 1_800 * 1_048_576,
            relativeSpeed: 4
        ),
    ]

    public static func model(withID id: String) -> SpeechModelDescriptor? {
        all.first { $0.id == id }
    }

    /// The model shipped inside the app.
    public static let bundledModelID = "ggml-base.en"

    // MARK: - Validation

    /// Identifiers are used to build filenames, so they are restricted to a
    /// conservative set with no separators, no dots at the edges, and no
    /// relative-path constructs.
    public static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        guard id != ".", id != ".." else { return false }
        guard !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Whether a URL is acceptable to download a model from.
    ///
    /// Requires HTTPS and an allowlisted host. Applied both to catalog entries
    /// (at startup, as a self-check) and to every redirect the download
    /// follows, so a redirect cannot walk the request off the allowlist or
    /// downgrade it to plaintext.
    public static func isAllowedSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        if allowedHosts.contains(host) { return true }
        // Accept subdomains of allowlisted hosts (HuggingFace serves LFS
        // objects from rotating CDN names), but never a host that merely ends
        // with the same text — "evil-huggingface.co" must not match.
        return allowedHosts.contains { host.hasSuffix(".\($0)") }
    }

    /// A 64-character lowercase hex digest.
    public static func isValidDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        }
    }

    /// Self-check that every shipped entry satisfies the rules above. Called
    /// by tests so a bad entry cannot be merged.
    public static func validateCatalog() -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for model in all {
            if !isValidIdentifier(model.id) {
                problems.append("\(model.id): invalid identifier")
            }
            if !seen.insert(model.id).inserted {
                problems.append("\(model.id): duplicate identifier")
            }
            if !isAllowedSource(model.downloadURL) {
                problems.append("\(model.id): source not allowlisted — \(model.downloadURL)")
            }
            if !isValidDigest(model.sha256) {
                problems.append("\(model.id): malformed SHA-256")
            }
            if model.sizeBytes <= 0 {
                problems.append("\(model.id): non-positive size")
            }
        }
        return problems
    }
}
