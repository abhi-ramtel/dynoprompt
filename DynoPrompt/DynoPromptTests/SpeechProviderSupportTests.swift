//
//  SpeechProviderSupportTests.swift
//  DynoPromptTests
//
//  Tests for the local-Whisper support layer: audio conversion, runtime and
//  model discovery, and the update-URL guard.
//

import XCTest

// MARK: - Audio

final class WhisperAudioTests: XCTestCase {

    func testResampleProducesTargetRateLength() {
        let input = [Float](repeating: 0.5, count: 48_000)   // 1s at 48 kHz
        let output = WhisperAudio.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 16_000, accuracy: 1)
    }

    func testResampleIsIdentityAtMatchingRate() {
        let input: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(WhisperAudio.resample(input, from: 16_000, to: 16_000), input)
    }

    func testResampleHandlesEmptyAndInvalidInput() {
        XCTAssertTrue(WhisperAudio.resample([], from: 48_000).isEmpty)
        XCTAssertTrue(WhisperAudio.resample([0.1], from: 0).isEmpty)
    }

    func testWavHeaderIsWellFormed() {
        let samples = [Float](repeating: 0, count: 1600)
        let data = WhisperAudio.wavData(from: samples, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        let sampleRate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: sampleRate), 16_000)
    }

    func testWavClampsOutOfRangeSamples() {
        let data = WhisperAudio.wavData(from: [2.0, -2.0], sampleRate: 16_000)
        let first = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        let second = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int16(littleEndian: first), Int16.max)
        XCTAssertEqual(Int16(littleEndian: second), -Int16.max)
    }

    func testRms() {
        XCTAssertEqual(WhisperAudio.rms([]), 0)
        XCTAssertEqual(WhisperAudio.rms([1, 1, 1]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(WhisperAudio.rms([0, 0]), 0, accuracy: 0.0001)
    }
}

// MARK: - Discovery

/// Filesystem stub so discovery can be tested without OpenWhispr installed.
private struct StubProbe: WhisperFileProbing {
    var executables: Set<String> = []
    var directories: [String: [URL]] = [:]
    var sizes: [String: Int64] = [:]

    func isExecutableFile(at url: URL) -> Bool { executables.contains(url.path) }
    func contentsOfDirectory(at url: URL) -> [URL] { directories[url.path] ?? [] }
    func fileSize(at url: URL) -> Int64? { sizes[url.path] }
}

final class OpenWhisprDiscoveryTests: XCTestCase {

    private let applications = [URL(fileURLWithPath: "/Applications")]
    private let home = URL(fileURLWithPath: "/Users/tester")

    func testFindsOpenWhisprBundledServer() {
        let path = "/Applications/OpenWhispr.app/Contents/Resources/bin/whisper-server-darwin-arm64"
        let probe = StubProbe(executables: [path])

        let runtime = OpenWhisprDiscovery.locateRuntime(
            bundledBinary: nil,
            applicationsDirectories: applications,
            probe: probe
        )
        XCTAssertEqual(runtime?.executableURL.path, path)
        XCTAssertEqual(runtime?.source, .openWhispr)
    }

    func testPrefersDynoPromptsOwnBinaryOverOpenWhisprs() {
        let bundled = URL(fileURLWithPath: "/Applications/DynoPrompt.app/Contents/MacOS/whisper-server")
        let openWhispr = "/Applications/OpenWhispr.app/Contents/Resources/bin/whisper-server-darwin-arm64"
        let probe = StubProbe(executables: [bundled.path, openWhispr])

        let runtime = OpenWhisprDiscovery.locateRuntime(
            bundledBinary: bundled,
            applicationsDirectories: applications,
            probe: probe
        )
        XCTAssertEqual(runtime?.source, .bundled)
    }

    func testUserSelectedBinaryWinsOverDiscovery() {
        let chosen = URL(fileURLWithPath: "/opt/custom/whisper-server")
        let openWhispr = "/Applications/OpenWhispr.app/Contents/Resources/bin/whisper-server-darwin-arm64"
        let probe = StubProbe(executables: [chosen.path, openWhispr])

        let runtime = OpenWhisprDiscovery.locateRuntime(
            bundledBinary: nil,
            applicationsDirectories: applications,
            additionalCandidates: [chosen],
            probe: probe
        )
        XCTAssertEqual(runtime?.source, .userSelected)
    }

    func testFindsHomebrewInstall() {
        let probe = StubProbe(executables: ["/opt/homebrew/bin/whisper-server"])
        let runtime = OpenWhisprDiscovery.locateRuntime(
            bundledBinary: nil,
            applicationsDirectories: applications,
            probe: probe
        )
        XCTAssertEqual(runtime?.source, .systemPath)
    }

    func testReturnsNilWhenNothingInstalled() {
        XCTAssertNil(OpenWhisprDiscovery.locateRuntime(
            bundledBinary: nil,
            applicationsDirectories: applications,
            probe: StubProbe()
        ))
    }

    func testListsOpenWhisprModels() {
        let cache = home.appendingPathComponent(".cache/openwhispr/whisper-models")
        let model = cache.appendingPathComponent("ggml-large-v3-turbo.bin")
        let probe = StubProbe(
            directories: [cache.path: [model]],
            sizes: [model.path: 1_624_555_275]
        )

        let models = OpenWhisprDiscovery.availableModels(homeDirectory: home, probe: probe)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.displayName, "large-v3-turbo")
        XCTAssertEqual(models.first?.source, .openWhispr)
    }

    /// The Silero VAD weights live beside the whisper models but are not a
    /// transcription model; offering them would produce a broken session.
    func testIgnoresNonWhisperBinaries() {
        let cache = home.appendingPathComponent(".cache/openwhispr/whisper-models")
        let probe = StubProbe(directories: [cache.path: [
            cache.appendingPathComponent("ggml-silero-v5.1.2.bin"),
            cache.appendingPathComponent("notes.txt"),
            cache.appendingPathComponent("random.bin"),
        ]])

        XCTAssertTrue(OpenWhisprDiscovery.availableModels(homeDirectory: home, probe: probe).isEmpty)
    }

    func testDeduplicatesModelsAcrossDirectories() {
        let cache = home.appendingPathComponent(".cache/openwhispr/whisper-models")
        let model = cache.appendingPathComponent("ggml-base.en.bin")
        let probe = StubProbe(directories: [
            cache.path: [model],
            home.appendingPathComponent("Library/Application Support/DynoPrompt/models").path: [model],
        ])

        XCTAssertEqual(OpenWhisprDiscovery.availableModels(homeDirectory: home, probe: probe).count, 1)
    }
}

// MARK: - Shortcuts

final class PrompterCommandMapTests: XCTestCase {

    func testArrowsMoveByWord() {
        XCTAssertEqual(
            PrompterCommandMap.command(keyCode: PrompterKeyCode.rightArrow, characters: nil, modifiers: []),
            .forwardWord
        )
        XCTAssertEqual(
            PrompterCommandMap.command(keyCode: PrompterKeyCode.leftArrow, characters: nil, modifiers: []),
            .backWord
        )
    }

    func testOptionArrowsMoveBySentence() {
        XCTAssertEqual(
            PrompterCommandMap.command(keyCode: PrompterKeyCode.rightArrow, characters: nil, modifiers: [.option]),
            .forwardSentence
        )
        XCTAssertEqual(
            PrompterCommandMap.command(keyCode: PrompterKeyCode.leftArrow, characters: nil, modifiers: [.option]),
            .backSentence
        )
    }

    func testLetterCommands() {
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 46, characters: "m", modifiers: []), .toggleMicrophone)
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 15, characters: "R", modifiers: []), .reset)
    }

    func testFontAndOpacityKeys() {
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 24, characters: "+", modifiers: []), .increaseFont)
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 27, characters: "-", modifiers: []), .decreaseFont)
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 30, characters: "]", modifiers: []), .increaseOpacity)
        XCTAssertEqual(PrompterCommandMap.command(keyCode: 33, characters: "[", modifiers: []), .decreaseOpacity)
    }

    func testEscapeAndSpace() {
        XCTAssertEqual(PrompterCommandMap.command(keyCode: PrompterKeyCode.escape, characters: nil, modifiers: []), .stop)
        XCTAssertEqual(PrompterCommandMap.command(keyCode: PrompterKeyCode.space, characters: " ", modifiers: []), .togglePause)
    }

    /// ⌘Q must still quit while the overlay is swallowing keys.
    func testSystemShortcutsPassThrough() {
        XCTAssertNil(PrompterCommandMap.command(keyCode: 12, characters: "q", modifiers: [.command]))
        XCTAssertNil(PrompterCommandMap.command(keyCode: PrompterKeyCode.tab, characters: nil, modifiers: [.command]))
        XCTAssertNil(PrompterCommandMap.command(keyCode: 3, characters: "f", modifiers: [.control]))
    }

    func testUnmappedKeysAreIgnored() {
        XCTAssertNil(PrompterCommandMap.command(keyCode: 200, characters: "z", modifiers: []))
    }

    func testEveryCommandHasAShortcutLabel() {
        for command in PrompterCommand.allCases {
            XCTAssertFalse(command.label.isEmpty)
            XCTAssertFalse(command.keyDescription.isEmpty)
        }
    }
}

// MARK: - Update URL

final class ReleaseURLValidatorTests: XCTestCase {

    func testAcceptsGitHubReleaseURLs() {
        XCTAssertNotNil(ReleaseURLValidator.safeReleaseURL("https://github.com/f/textream/releases/tag/v1.7.1"))
        XCTAssertNotNil(ReleaseURLValidator.safeReleaseURL("https://api.github.com/repos/f/dynoprompt"))
    }

    /// The update checker feeds this value straight to the workspace opener,
    /// so anything but an https GitHub link must be refused.
    func testRejectsUnsafeSchemesAndHosts() {
        for candidate in [
            "file:///etc/passwd",
            "http://github.com/f/textream",           // downgraded to plaintext
            "https://evil.example/f/dynoprompt",
            "https://github.com.evil.example/x",      // suffix confusion
            "javascript:alert(1)",
            "dynoprompt://read?text=hi",
            "",
        ] {
            XCTAssertNil(
                ReleaseURLValidator.safeReleaseURL(candidate),
                "\(candidate) must be rejected"
            )
        }
    }
}

// MARK: - Bundled model discovery

/// The bundled model must be preferred over anything found on disk, and the
/// Silero VAD weights that sit beside OpenWhispr's models must never be
/// offered as a transcription model.
final class BundledModelPreferenceTests: XCTestCase {

    private struct StubProbe: WhisperFileProbing {
        var directories: [String: [URL]] = [:]
        var sizes: [String: Int64] = [:]
        func isExecutableFile(at url: URL) -> Bool { false }
        func contentsOfDirectory(at url: URL) -> [URL] { directories[url.path] ?? [] }
        func fileSize(at url: URL) -> Int64? { sizes[url.path] }
    }

    private let home = URL(fileURLWithPath: "/Users/tester")

    func testAppSupportModelsAreDiscovered() {
        let directory = home.appendingPathComponent("Library/Application Support/DynoPrompt/models")
        let model = directory.appendingPathComponent("ggml-base.en.bin")
        let probe = StubProbe(
            directories: [directory.path: [model]],
            sizes: [model.path: 147_964_211]
        )

        let models = OpenWhisprDiscovery.availableModels(homeDirectory: home, probe: probe)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.displayName, "base.en")
        XCTAssertEqual(models.first?.source, .bundled)
    }

    func testSmallestModelIsPreferredWhenSeveralExist() {
        let directory = home.appendingPathComponent(".cache/openwhispr/whisper-models")
        let base = directory.appendingPathComponent("ggml-base.en.bin")
        let large = directory.appendingPathComponent("ggml-large-v3-turbo.bin")
        let probe = StubProbe(
            directories: [directory.path: [large, base]],
            sizes: [base.path: 147_964_211, large.path: 1_624_555_275]
        )

        let models = OpenWhisprDiscovery.availableModels(homeDirectory: home, probe: probe)
        // The provider picks by size; assert the data it relies on is right.
        XCTAssertEqual(models.min(by: { $0.sizeBytes < $1.sizeBytes })?.displayName, "base.en")
    }

    func testDisplayNameStripsGgmlPrefixAndExtension() {
        XCTAssertEqual(OpenWhisprDiscovery.displayName(forFileNamed: "ggml-base.en.bin"), "base.en")
        XCTAssertEqual(OpenWhisprDiscovery.displayName(forFileNamed: "ggml-large-v3-turbo.bin"), "large-v3-turbo")
    }
}

// MARK: - whisper.cpp output cleaning

final class WhisperRequestTests: XCTestCase {

    func testStripsNonSpeechMarkers() {
        XCTAssertEqual(WhisperRequest.clean(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(WhisperRequest.clean("hello [MUSIC] world"), "hello world")
        XCTAssertEqual(WhisperRequest.clean("[ Silence ]"), "")
    }

    func testCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(
            WhisperRequest.clean(" Today we are going\n to talk  about AI.\n"),
            "Today we are going to talk about AI."
        )
    }

    func testLanguageCodeReducesToISO639() {
        XCTAssertEqual(WhisperRequest.languageCode(from: "en-US"), "en")
        XCTAssertEqual(WhisperRequest.languageCode(from: "pt_BR"), "pt")
        XCTAssertEqual(WhisperRequest.languageCode(from: "de"), "de")
    }

    func testMultipartBodyCarriesFileAndFields() {
        let body = WhisperRequest.multipartBody(
            boundary: "BOUND",
            wav: Data([0x52, 0x49, 0x46, 0x46]),
            language: "en",
            prompt: "alpha bravo"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("alpha bravo"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
    }

    func testEmptyPromptIsOmitted() {
        let body = WhisperRequest.multipartBody(
            boundary: "BOUND", wav: Data(), language: "en", prompt: ""
        )
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("name=\"prompt\""))
    }
}
