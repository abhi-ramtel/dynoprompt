//
//  WhisperIntegrationTests.swift
//  DynoPromptTests
//
//  End-to-end proof that the local speech path actually works, rather than
//  only that its pieces compile.
//
//  The full chain exercised here is:
//
//      synthesized speech (`say`)
//          → WhisperAudio WAV encoding
//          → WhisperRequest multipart body
//          → a real whisper.cpp server on 127.0.0.1
//          → WhisperRequest.clean
//          → ScriptSyncEngine
//          → expected script position
//
//  These tests skip cleanly when no whisper.cpp runtime or GGML model is
//  installed, so CI and contributors without a model still get a green suite.
//

import XCTest

final class WhisperIntegrationTests: XCTestCase {

    private var server: Process?
    private var port: UInt16 = 0

    // MARK: - Environment discovery

    private func locateRuntime() -> URL? {
        OpenWhisprDiscovery.locateRuntime(
            bundledBinary: nil,
            applicationsDirectories: [
                URL(fileURLWithPath: "/Applications"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications"),
            ]
        )?.executableURL
    }

    private func locateModel() -> URL? {
        OpenWhisprDiscovery.availableModels(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        // Smallest model keeps the test quick.
        .min(by: { $0.sizeBytes < $1.sizeBytes })?
        .url
    }

    override func tearDown() {
        server?.terminate()
        server = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Renders text to 16 kHz mono WAV using the system speech synthesizer.
    private func synthesize(_ text: String) throws -> [Float] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynoprompt-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", output.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("`say` is unavailable on this machine.")
        }

        let data = try Data(contentsOf: output)
        guard data.count > 44 else { throw XCTSkip("Synthesized audio was empty.") }

        // Decode the 16-bit PCM payload back to floats, skipping the header.
        let payload = data.dropFirst(44)
        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2)
        payload.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for value in values {
                samples.append(Float(Int16(littleEndian: value)) / Float(Int16.max))
            }
        }
        return samples
    }

    private func startServer(model: URL, runtime: URL) throws {
        port = try Self.freePort()

        let process = Process()
        process.executableURL = runtime
        process.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-l", "en",
            "-t", "4",
            "-nt",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process

        // Wait for the model to load.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if ping() { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        throw XCTSkip("whisper.cpp server did not become ready in time.")
    }

    private func ping() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = response != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return reachable
    }

    /// Sends samples through the real server and returns the cleaned text.
    private func transcribe(_ samples: [Float], prompt: String = "") throws -> String {
        let wav = WhisperAudio.wavData(from: samples)
        let boundary = "dynoprompt-test-\(UUID().uuidString)"

        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            throw XCTSkip("Bad inference URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = WhisperRequest.multipartBody(
            boundary: boundary,
            wav: wav,
            language: "en",
            prompt: prompt
        )

        var result = ""
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = payload["text"] as? String else { return }
            result = WhisperRequest.clean(text)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 130)

        if let failure { throw failure }
        return result
    }

    private static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("No socket available.") }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return UInt16(bigEndian: resolved.sin_port)
    }

    // MARK: - Tests

    /// These run whenever a whisper.cpp runtime and a GGML model are actually
    /// installed, and skip otherwise — so a developer with Whisper set up gets
    /// real end-to-end coverage, while CI (which has neither) stays green and
    /// fast. Set DYNOPROMPT_SKIP_WHISPER_TESTS=1 to opt out locally.
    private func requireWhisperEnvironment() throws -> (runtime: URL, model: URL) {
        if ProcessInfo.processInfo.environment["DYNOPROMPT_SKIP_WHISPER_TESTS"] == "1" {
            throw XCTSkip("Whisper integration tests disabled by environment.")
        }
        guard let runtime = locateRuntime() else {
            throw XCTSkip("No whisper.cpp server binary installed.")
        }
        guard let model = locateModel() else {
            throw XCTSkip("No GGML model installed.")
        }
        return (runtime, model)
    }

    /// The whole local pipeline, ending in a correct script position.
    func testLocalWhisperDrivesScriptPosition() throws {
        let environment = try requireWhisperEnvironment()
        try startServer(model: environment.model, runtime: environment.runtime)

        let script = """
        Today we're going to discuss artificial intelligence and its impact on \
        software engineering.
        """
        // Deliberately *not* the script verbatim — this is the paraphrase case.
        let spoken = "Today we are going to talk about A I and how it changes software engineering"

        let samples = try synthesize(spoken)
        XCTAssertFalse(samples.isEmpty)

        let transcript = try transcribe(samples)
        XCTAssertFalse(transcript.isEmpty, "whisper returned nothing")

        let engine = ScriptSyncEngine()
        engine.load(scriptText: script)
        let update = engine.consume(transcript: transcript)

        XCTAssertEqual(
            update.decision,
            .advanced,
            "transcript was: \(transcript)"
        )
        XCTAssertGreaterThan(
            engine.tokenIndex,
            engine.tokens.count / 2,
            "expected to progress past halfway; transcript was: \(transcript)"
        )
    }

    /// The WAV encoder must produce audio whisper.cpp actually accepts.
    func testGeneratedWavIsAcceptedByWhisper() throws {
        let environment = try requireWhisperEnvironment()
        try startServer(model: environment.model, runtime: environment.runtime)

        let samples = try synthesize("The quick brown fox jumps over the lazy dog")
        let transcript = try transcribe(samples)

        XCTAssertTrue(
            transcript.lowercased().contains("fox"),
            "expected the word 'fox'; got: \(transcript)"
        )
    }
}
