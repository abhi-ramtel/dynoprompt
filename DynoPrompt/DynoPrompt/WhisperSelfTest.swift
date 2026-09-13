//
//  WhisperSelfTest.swift
//  DynoPrompt
//
//  Diagnostic for the bundled speech stack, run with:
//
//      DynoPrompt.app/Contents/MacOS/DynoPrompt --whisper-selftest [audio.wav]
//
//  It exists because the embedded XPC service cannot be exercised from
//  outside the app: an `Application`-type service is only launchable by its
//  containing bundle, which is precisely the property that makes it safe. The
//  only way to verify the real path — bundle → XPC → whisper.cpp → text — is
//  from inside the app, so the app carries the check.
//
//  Used by Scripts/verify-whisper.sh and available to any user diagnosing a
//  local install.
//

import AppKit
import Foundation

enum WhisperSelfTest {

    static let launchArgument = "--whisper-selftest"
    /// Adds a live download of the smallest catalog model, exercising the real
    /// network → verify → install path.
    static let modelArgument = "--model-selftest"

    static var isRequested: Bool {
        CommandLine.arguments.contains(launchArgument)
            || CommandLine.arguments.contains(modelArgument)
    }

    private static var includesModelDownload: Bool {
        CommandLine.arguments.contains(modelArgument)
    }

    /// Runs the diagnostic and terminates the process with 0 on success.
    static func run() -> Never {
        var failures = 0

        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            let mark = passed ? "PASS" : "FAIL"
            let suffix = detail.isEmpty ? "" : "  — \(detail)"
            print("\(mark)  \(name)\(suffix)")
            if !passed { failures += 1 }
        }

        print("DynoPrompt whisper self-test")
        print("----------------------------")

        // --- Catalog integrity -------------------------------------------
        let catalogProblems = SpeechModelCatalog.validateCatalog()
        check("model catalog valid", catalogProblems.isEmpty, catalogProblems.joined(separator: "; "))

        let manager = SpeechModelManager.shared
        check(
            "model storage resolved",
            manager.storageDirectory.path.contains("DynoPrompt"),
            manager.storageDirectory.path
        )
        check(
            "installed models listed",
            !manager.installed.isEmpty,
            manager.installed.map(\.id).joined(separator: ", ")
        )

        // --- Effective layout ---------------------------------------------
        // Reports the values actually in use, which is also how a user can
        // confirm a stored preference was brought back into range.
        let layout = NotchSettings.shared
        let savedWidth = layout.notchWidth
        let savedHeight = layout.textAreaHeight
        let savedFontSize = layout.fontSize
        let savedSpacing = layout.lineSpacingMultiplier
        check(
            "overlay size in range",
            (PrompterLayoutLimits.minWidth...PrompterLayoutLimits.maxWidth).contains(layout.notchWidth)
                && (PrompterLayoutLimits.minHeight...PrompterLayoutLimits.maxHeight)
                    .contains(layout.textAreaHeight),
            "\(Int(layout.notchWidth))×\(Int(layout.textAreaHeight))px"
        )
        check(
            "text size in range",
            (PrompterLayoutLimits.minFontSize...PrompterLayoutLimits.maxFontSize)
                .contains(layout.fontSize)
                && (PrompterLayoutLimits.minLineSpacing...PrompterLayoutLimits.maxLineSpacing)
                    .contains(layout.lineSpacingMultiplier),
            String(format: "%.0fpt, %.2f× spacing", layout.fontSize, layout.lineSpacingMultiplier)
        )

        // --- Settings writes don't recurse --------------------------------
        // Drives every clamped property the way a Settings slider does:
        // in-range, above the maximum, below the minimum, and a repeat of the
        // same value. Clamping these inside `didSet` used to recurse under
        // @Observable and blow the stack the moment Settings was opened, so
        // reaching the end of this block at all is the assertion.
        for _ in 0..<3 {
            layout.notchWidth = 800
            layout.notchWidth = 99_999
            layout.notchWidth = -1
            layout.notchWidth = 99_999
            layout.textAreaHeight = 400
            layout.textAreaHeight = 99_999
            layout.textAreaHeight = -1
            layout.fontSize = 32
            layout.fontSize = 5_000
            layout.fontSize = 0
            layout.fontSize = 5_000
            layout.lineSpacingMultiplier = 2.0
            layout.lineSpacingMultiplier = 500
            layout.lineSpacingMultiplier = 0
            layout.fontSizePreset = .xs
            layout.fontSizePreset = .xl
        }
        check(
            "settings writes clamp without recursing",
            layout.notchWidth == PrompterLayoutLimits.maxWidth
                && layout.fontSize == FontSizePreset.xl.pointSize
                && layout.lineSpacingMultiplier == PrompterLayoutLimits.minLineSpacing,
            "\(Int(layout.notchWidth))px, \(Int(layout.fontSize))pt"
        )

        // Restore, so a diagnostic run doesn't leave the user's overlay resized.
        layout.notchWidth = savedWidth
        layout.textAreaHeight = savedHeight
        layout.fontSize = savedFontSize
        layout.lineSpacingMultiplier = savedSpacing

        check("embedded XPC service present", WhisperXPCClient.isAvailable)
        guard WhisperXPCClient.isAvailable else {
            if WhisperXPCClient.isStubBuild {
                print("")
                print("whisper.cpp was not compiled into this build, so a placeholder")
                print("was linked in its place. This happens when cmake is missing or")
                print("the source could not be fetched.")
                print("")
                print("  Fix:  brew install cmake  &&  Scripts/vendor-whisper.sh")
                print("")
                print("DynoPrompt itself is fine: the Apple (On-Device) engine is the")
                print("default and needs none of this. Only the Whisper engine is")
                print("unavailable.")
            } else {
                print("")
                print("The app was built without the embedded helper.")
                print("Run Scripts/vendor-whisper.sh and rebuild.")
            }
            exit(1)
        }

        let model = WhisperLocalProvider.resolvedModel()
        check("model resolved", model != nil, model?.url.lastPathComponent ?? "none")
        guard let model else { exit(1) }
        check(
            "model readable",
            FileManager.default.isReadableFile(atPath: model.url.path),
            model.url.path
        )

        let client = WhisperXPCClient()

        // --- Load ---------------------------------------------------------
        let loadStart = Date()
        var loadError: String?
        let loaded = DispatchSemaphore(value: 0)
        client.loadModel(at: model.url) { error in
            loadError = error
            loaded.signal()
        }
        let loadFinished = loaded.wait(timeout: .now() + 180) == .success
        check("model loaded", loadFinished && loadError == nil,
              loadError ?? String(format: "%.2fs", Date().timeIntervalSince(loadStart)))
        guard loadFinished, loadError == nil else { exit(1) }

        // --- Transcribe ---------------------------------------------------
        let samples = loadAudio()
        let duration = Double(samples.count) / 16_000

        // Below this there is nothing to recognize. `say` needs an installed
        // voice, and a headless machine has none — it produces a fraction of a
        // second of near-silence, which whisper turns into a stray word. That
        // is a missing test fixture, not a broken prompter, so say so rather
        // than reporting a failure that means nothing.
        let hasUsableAudio = duration >= 1.0
        check("audio available", hasUsableAudio, String(format: "%.1fs", duration))
        if !hasUsableAudio {
            print("      No usable speech to test with. Pass a WAV path, or run")
            print("      Scripts/verify-whisper.sh, which uses the committed fixture.")
            failures -= 1   // not a product failure
        }

        if hasUsableAudio {
            var transcript: String?
            var failure: String?
            let inferenceStart = Date()
            let done = DispatchSemaphore(value: 0)
            client.transcribe(samples: samples, language: "en", prompt: "") { text, error in
                transcript = text
                failure = error
                done.signal()
            }
            let finished = done.wait(timeout: .now() + 180) == .success
            let elapsed = Date().timeIntervalSince(inferenceStart)

            check("transcription returned", finished && failure == nil, failure ?? "")
            let cleaned = WhisperRequest.clean(transcript ?? "")
            check("transcript non-empty", !cleaned.isEmpty, cleaned)
            print(String(format: "      inference: %.2fs for %.1fs of audio",
                         elapsed, Double(samples.count) / 16_000))

            // --- Drives the synchroniser ----------------------------------
            // The point of the whole stack: real recognized speech moving a
            // real script forward.
            if !cleaned.isEmpty {
                let engine = ScriptSyncEngine()
                engine.load(scriptText:
                    "Today we're going to discuss artificial intelligence and its "
                    + "impact on software engineering.")
                let update = engine.consume(transcript: cleaned)
                check(
                    "synchroniser advanced",
                    update.decision == .advanced,
                    "position \(engine.tokenIndex)/\(engine.tokens.count), "
                    + String(format: "confidence %.2f", update.confidence)
                )
            }
        }

        // --- A downloaded model loads through the sandbox -----------------
        // Regression guard: the helper is sandboxed and cannot open a path in
        // Application Support, so a model the user downloaded is only usable
        // because the host passes an open file descriptor across XPC. Before
        // that, every downloaded model failed to load in a signed build while
        // working fine in an unsigned one.
        if let external = manager.installed.first(where: { !$0.isBundled }) {
            let externalClient = WhisperXPCClient()
            var externalError: String?
            let done = DispatchSemaphore(value: 0)
            externalClient.loadModel(at: external.url) { error in
                externalError = error
                done.signal()
            }
            let finished = done.wait(timeout: .now() + 180) == .success
            check(
                "downloaded model loads through the sandboxed helper",
                finished && externalError == nil,
                externalError ?? external.url.lastPathComponent
            )
            externalClient.shutdown()
        }

        // --- The bundled model's bytes match the pinned digest ------------
        // Verifies the real integrity path against a real 141 MB file, rather
        // than trusting that it works.
        if let bundled = WhisperXPCClient.bundledModelURL,
           let expected = SpeechModelCatalog.model(withID: SpeechModelCatalog.bundledModelID) {
            let start = Date()
            let digest = SpeechModelManager.sha256(ofFileAt: bundled)
            check(
                "bundled model digest matches catalog",
                digest == expected.sha256,
                String(format: "hashed in %.2fs", Date().timeIntervalSince(start))
            )
        }

        if includesModelDownload {
            runDownloadCheck(check)
        }

        client.shutdown()

        print("----------------------------")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Downloads the smallest catalog model for real, exercising HTTPS
    /// transfer, SHA-256 verification and atomic install.
    private static func runDownloadCheck(_ check: (String, Bool, String) -> Void) {
        let manager = SpeechModelManager.shared
        guard let model = SpeechModelCatalog.all.min(by: { $0.sizeBytes < $1.sizeBytes }) else {
            return
        }

        if manager.isInstalled(model) {
            manager.remove(model)
        }

        print("      downloading \(model.displayName) (\(ByteFormat.short(model.sizeBytes)))…")
        let start = Date()
        manager.download(model)

        // The manager posts progress on the main queue, so the run loop has to
        // turn for this to make progress.
        let deadline = Date().addingTimeInterval(600)
        var lastPercent = -1
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            switch manager.state(for: model) {
            case .downloading(let fraction, _, _):
                let percent = Int(fraction * 100)
                if percent / 20 != lastPercent / 20 {
                    lastPercent = percent
                    print("      \(percent)%")
                }
            case .failed(let message):
                check("model download", false, message)
                return
            case .idle where manager.isInstalled(model):
                check(
                    "model downloaded, verified and installed",
                    true,
                    String(format: "%.1fs", Date().timeIntervalSince(start))
                )
                check(
                    "installed file is in the model directory",
                    manager.installedModel(withID: model.id)?.url
                        .deletingLastPathComponent().path == manager.storageDirectory.path,
                    manager.installedModel(withID: model.id)?.url.path ?? "missing"
                )
                // Re-hash the installed file: the manager verified the staged
                // copy, so this confirms the atomic install preserved it.
                let digest = manager.installedModel(withID: model.id)
                    .flatMap { SpeechModelManager.sha256(ofFileAt: $0.url) }
                check("installed file digest matches catalog", digest == model.sha256, "")
                return
            default:
                break
            }
        }
        check("model download", false, "timed out")
    }

    /// Uses a WAV path supplied after the flag, or synthesizes one so the test
    /// works with no fixtures.
    private static func loadAudio() -> [Float] {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(where: { $0 == launchArgument || $0 == modelArgument }),
           index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("-") {
            return samples(fromWAVAt: URL(fileURLWithPath: arguments[index + 1]))
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynoprompt-selftest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", output.path,
            "--data-format=LEI16@16000",
            "Today we are going to talk about artificial intelligence "
            + "and its impact on software engineering.",
        ]
        do {
            try say.run()
            say.waitUntilExit()
        } catch {
            return []
        }
        return samples(fromWAVAt: output)
    }

    /// Reads the payload of a 16 kHz mono 16-bit WAV.
    private static func samples(fromWAVAt url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return [] }
        let payload = data.dropFirst(44)
        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                samples.append(Float(Int16(littleEndian: value)) / 32_768.0)
            }
        }
        return samples
    }
}
