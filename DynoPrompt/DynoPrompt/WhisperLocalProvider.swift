//
//  WhisperLocalProvider.swift
//  DynoPrompt
//
//  Local speech recognition backed by whisper.cpp.
//
//  Relationship to OpenWhispr
//  --------------------------
//  DynoPrompt does not drive OpenWhispr and does not depend on it. OpenWhispr is
//  an Electron app with no public API or IPC surface, so automating it would
//  mean binding to private internals.
//
//  What it does ship is whisper.cpp's `server` binary plus standard GGML
//  models in a predictable cache directory. Both are upstream artifacts in
//  documented formats, so when a user already has OpenWhispr installed,
//  DynoPrompt can reuse those files in place rather than making them download
//  another multi-gigabyte model. When OpenWhispr is absent, any whisper.cpp
//  server binary and any GGML model work identically.
//
//  Two backends, in preference order
//  ---------------------------------
//  1. **Embedded XPC service** (default). whisper.cpp is linked into
//     WhisperService.xpc inside the app bundle, along with ggml-base.en. This
//     needs nothing installed, and — because a sandboxed app may launch an
//     XPC service from its own bundle — it is the only backend that works in
//     the App Store build.
//  2. **External whisper.cpp server** (fallback). Used when the app was built
//     without the embedded service. Spawns a `whisper-server` bound to
//     127.0.0.1 on an ephemeral port.
//
//  Privacy
//  -------
//  Neither backend can reach the network. The XPC service is sandboxed with no
//  network entitlement at all, and XPC is kernel-mediated IPC with no socket
//  to misconfigure. The fallback server is bound to loopback and its URLSession
//  has proxies disabled. `isLocalOnly` is therefore enforced by construction,
//  not merely intended.
//

import Foundation

final class WhisperLocalProvider: SpeechRecognitionProvider {

    // MARK: - Configuration

    /// Seconds of audio transcribed per request. Long enough for whisper to
    /// have useful context, short enough to keep the prompter responsive.
    private let windowSeconds: Double = 4.0
    /// How often a new window is submitted. The overlap keeps a word that
    /// straddles a boundary from being lost.
    private let hopSeconds: Double = 1.2
    /// Below this RMS the window is silence and is not worth a request.
    private let silenceThreshold: Float = 0.006

    // MARK: - State

    private var process: Process?
    private var port: UInt16 = 0
    private var session: URLSession
    private var buffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "dev.fka.dynoprompt.whisper.buffer")
    private let inferenceQueue = DispatchQueue(label: "dev.fka.dynoprompt.whisper.inference")
    private var lastSubmission = Date.distantPast
    private var inFlight = false
    private var locale = "en"
    private var initialPrompt = ""
    private var isRunning = false

    /// Non-nil when the embedded XPC service is driving this session.
    private var xpcClient: WhisperXPCClient?

    var onResult: ((SpeechProviderResult) -> Void)?
    var onError: ((SpeechProviderError) -> Void)?

    var engine: SpeechEngine { .whisperLocal }
    var isLocalOnly: Bool { true }

    var privacyDescription: String {
        if WhisperXPCClient.isAvailable {
            return "Built-in whisper.cpp, running in a sandboxed helper with no network access. "
                + "Audio never leaves this Mac."
        }
        switch Self.resolvedRuntime()?.source {
        case .openWhispr:
            return "whisper.cpp from your OpenWhispr install, running on 127.0.0.1. Audio never leaves this Mac."
        case .some:
            return "whisper.cpp running on 127.0.0.1. Audio never leaves this Mac."
        case nil:
            return "No local whisper.cpp runtime found."
        }
    }

    /// True when the bundled, sandbox-safe backend will be used.
    static var usesEmbeddedService: Bool { WhisperXPCClient.isAvailable }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        // The only endpoint is loopback; refuse proxies outright so a system
        // proxy setting can never route audio somewhere else.
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Discovery

    static func resolvedRuntime() -> WhisperRuntimeLocation? {
        let explicit = NotchSettings.shared.whisperBinaryPath
        let additional = explicit.isEmpty ? [] : [URL(fileURLWithPath: explicit)]

        let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-server")
        return OpenWhisprDiscovery.locateRuntime(
            bundledBinary: bundled,
            applicationsDirectories: applicationsDirectories(),
            additionalCandidates: additional
        )
    }

    static func applicationsDirectories() -> [URL] {
        var directories = [URL(fileURLWithPath: "/Applications")]
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            directories.append(home.appendingPathComponent("Applications"))
        }
        return directories
    }

    static func availableModels() -> [WhisperModel] {
        OpenWhisprDiscovery.availableModels(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func resolvedModel() -> WhisperModel? {
        // The user's explicit choice in the model library wins over anything
        // discovered on disk.
        let manager = SpeechModelManager.shared
        if let active = manager.installedModel(withID: manager.activeModelID) {
            return WhisperModel(
                url: active.url,
                displayName: SpeechModelCatalog.model(withID: active.id)?.displayName ?? active.id,
                sizeBytes: active.sizeBytes,
                source: active.isBundled ? .bundled : .userSelected
            )
        }

        let configured = NotchSettings.shared.whisperModelPath
        let models = availableModels()
        if !configured.isEmpty {
            if let match = models.first(where: { $0.url.path == configured }) { return match }
            // A model chosen before still counts if it is still on disk.
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isReadableFile(atPath: url.path) {
                return WhisperModel(
                    url: url,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    sizeBytes: 0,
                    source: .userSelected
                )
            }
        }
        // Prefer the model shipped inside the app: it is guaranteed present,
        // guaranteed readable from the sandboxed helper, and small enough to
        // keep latency low. A teleprompter needs responsiveness far more than
        // it needs transcription polish.
        if let bundled = WhisperXPCClient.bundledModelURL {
            return WhisperModel(
                url: bundled,
                displayName: "base.en (built-in)",
                sizeBytes: 0,
                source: .bundled
            )
        }
        // Otherwise the smallest model found on disk.
        return models.min(by: { $0.sizeBytes < $1.sizeBytes })
    }

    /// True when this build runs inside the App Sandbox, where launching a
    /// helper binary from outside the container is not permitted.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Pre-warming

    /// Loads the model into the helper ahead of the first session.
    ///
    /// Reading a 141 MB model cold takes several seconds; warm it is about a
    /// tenth of one. Without this, the first few seconds of the user's first
    /// recording would go untracked while the model paged in — the worst
    /// possible moment for it.
    static func prewarm() {
        guard WhisperXPCClient.isAvailable,
              NotchSettings.shared.speechEngine == .whisperLocal,
              let model = resolvedModel() else { return }

        let client = WhisperXPCClient()
        client.loadModel(at: model.url) { _ in
            // The connection is deliberately left open: tearing it down would
            // evict the model we just paid to load.
            _ = client
        }
        prewarmClient = client
    }

    /// Holds the pre-warm connection so the loaded model stays resident.
    private static var prewarmClient: WhisperXPCClient?

    // MARK: - Lifecycle

    func preflight() -> SpeechProviderError? {
        // The embedded helper needs no external runtime and is permitted
        // inside the sandbox, so it only needs a readable model.
        if WhisperXPCClient.isAvailable {
            guard let model = Self.resolvedModel() else {
                return .modelMissing(
                    "No speech model found. Rebuild with Scripts/fetch-model.sh, or choose "
                    + "a ggml-*.bin file in Settings."
                )
            }
            guard FileManager.default.isReadableFile(atPath: model.url.path) else {
                return .modelMissing("The model at \(model.url.path) isn't readable.")
            }
            return nil
        }

        if WhisperXPCClient.isStubBuild {
            return .runtimeMissing(
                "This build was compiled without whisper.cpp, so the Whisper engine can't run. "
                + "Install cmake (`brew install cmake`) and rebuild, or use the "
                + "Apple (On-Device) engine, which needs nothing."
            )
        }

        if Self.isSandboxed {
            return .sandboxed(
                "This sandboxed build has no embedded speech helper and can't launch an "
                + "external one. Rebuild with Scripts/vendor-whisper.sh, or use the "
                + "Apple (On-Device) engine."
            )
        }
        guard let runtime = Self.resolvedRuntime() else {
            return .runtimeMissing(
                "No whisper.cpp server binary found. Install OpenWhispr, "
                + "`brew install whisper-cpp`, or choose one in Settings."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: runtime.executableURL.path) else {
            return .runtimeMissing("The whisper.cpp binary at \(runtime.executableURL.path) isn't executable.")
        }
        guard let model = Self.resolvedModel() else {
            return .modelMissing(
                "No GGML model found. Download one in OpenWhispr, or place a "
                + "ggml-*.bin file in ~/Library/Application Support/DynoPrompt/models."
            )
        }
        guard FileManager.default.isReadableFile(atPath: model.url.path) else {
            return .modelMissing("The model at \(model.url.path) isn't readable.")
        }
        return nil
    }

    func start(locale: String, contextualHints: [String]) throws {
        if let error = preflight() { throw error }
        stop()

        self.locale = WhisperRequest.languageCode(from: locale)
        // whisper.cpp accepts an initial prompt that biases decoding. Feeding
        // it upcoming script words measurably improves proper nouns.
        self.initialPrompt = contextualHints.prefix(48).joined(separator: " ")

        guard let model = Self.resolvedModel() else {
            throw SpeechProviderError.modelMissing("The speech model disappeared before start.")
        }

        // Preferred path: the sandboxed helper inside our own bundle.
        if WhisperXPCClient.isAvailable {
            let client = WhisperXPCClient()
            xpcClient = client
            buffer.removeAll()
            lastSubmission = Date()
            isRunning = true

            client.loadModel(at: model.url) { [weak self] error in
                guard let self, let error else { return }
                self.isRunning = false
                DispatchQueue.main.async {
                    self.onError?(.modelMissing(error))
                }
            }
            return
        }

        guard let runtime = Self.resolvedRuntime() else {
            throw SpeechProviderError.runtimeMissing("Whisper runtime disappeared before start.")
        }

        let chosenPort = try Self.reserveEphemeralPort()
        let task = Process()
        task.executableURL = runtime.executableURL
        // Arguments are passed as an array — no shell, so paths containing
        // spaces or metacharacters are inert.
        task.arguments = [
            "-m", model.url.path,
            // Bound to loopback explicitly. This is the guarantee behind
            // `isLocalOnly`, not the binary's default.
            "--host", "127.0.0.1",
            "--port", String(chosenPort),
            "-l", self.locale,
            "-t", String(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))),
            "-nt",              // no timestamps; we only want words
            "--no-fallback",    // keep latency predictable
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            throw SpeechProviderError.failed("Couldn't start whisper.cpp: \(error.localizedDescription)")
        }

        process = task
        port = chosenPort
        buffer.removeAll()
        lastSubmission = Date()
        isRunning = true
    }

    func append(_ chunk: SpeechAudioChunk) {
        guard isRunning else { return }
        let resampled = WhisperAudio.resample(chunk.samples, from: chunk.sampleRate)
        guard !resampled.isEmpty else { return }

        bufferQueue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(contentsOf: resampled)

            let maxSamples = Int(self.windowSeconds * WhisperAudio.targetSampleRate)
            if self.buffer.count > maxSamples {
                self.buffer.removeFirst(self.buffer.count - maxSamples)
            }

            let elapsed = Date().timeIntervalSince(self.lastSubmission)
            guard elapsed >= self.hopSeconds, !self.inFlight else { return }

            // A minimum of one hop of audio keeps the first request from being
            // a near-empty window.
            let minSamples = Int(self.hopSeconds * WhisperAudio.targetSampleRate)
            guard self.buffer.count >= minSamples else { return }

            let window = self.buffer
            guard WhisperAudio.rms(window) >= self.silenceThreshold else {
                // Silence: skip the request entirely rather than burn CPU.
                self.lastSubmission = Date()
                return
            }

            self.inFlight = true
            self.lastSubmission = Date()
            self.inferenceQueue.async { self.transcribe(window) }
        }
    }

    func stop() {
        isRunning = false
        xpcClient?.shutdown()
        xpcClient = nil
        process?.terminate()
        process = nil
        port = 0
        bufferQueue.async { [weak self] in
            self?.buffer.removeAll()
            self?.inFlight = false
        }
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Inference

    private func transcribe(_ samples: [Float]) {
        if let client = xpcClient {
            transcribeOverXPC(samples, using: client)
            return
        }
        transcribeOverLoopback(samples)
    }

    /// Embedded helper: samples cross a kernel-mediated XPC boundary. There is
    /// no socket and no HTTP framing involved.
    private func transcribeOverXPC(_ samples: [Float], using client: WhisperXPCClient) {
        client.transcribe(
            samples: samples,
            language: locale,
            prompt: initialPrompt
        ) { [weak self] text, error in
            guard let self else { return }
            self.bufferQueue.async { self.inFlight = false }

            if let error {
                if self.isRunning {
                    DispatchQueue.main.async { self.onError?(.failed(error)) }
                }
                return
            }
            guard let text else { return }
            let cleaned = WhisperRequest.clean(text)
            guard !cleaned.isEmpty else { return }
            DispatchQueue.main.async {
                self.onResult?(SpeechProviderResult(text: cleaned, isFinal: true))
            }
        }
    }

    private func transcribeOverLoopback(_ samples: [Float]) {
        defer { bufferQueue.async { self.inFlight = false } }
        guard port != 0 else { return }

        let wav = WhisperAudio.wavData(from: samples)
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else { return }

        let boundary = "dynoprompt-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = WhisperRequest.multipartBody(
            boundary: boundary,
            wav: wav,
            language: locale,
            prompt: initialPrompt
        )

        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { [weak self] data, _, error in
            defer { semaphore.signal() }
            guard let self else { return }

            if let error {
                // A transient failure while the model is still loading is
                // normal; only surface it once the session is established.
                if self.isRunning, (error as NSError).code != NSURLErrorCannotConnectToHost {
                    DispatchQueue.main.async {
                        self.onError?(.failed("Whisper request failed: \(error.localizedDescription)"))
                    }
                }
                return
            }

            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = payload["text"] as? String else { return }

            let cleaned = WhisperRequest.clean(text)
            guard !cleaned.isEmpty else { return }

            DispatchQueue.main.async {
                self.onResult?(SpeechProviderResult(text: cleaned, isFinal: true))
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
    }




    /// Asks the kernel for a free TCP port by binding to port 0 on loopback
    /// and reading back the assignment. Avoids the race of guessing a port and
    /// the exposure of a fixed one.
    static func reserveEphemeralPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SpeechProviderError.failed("Couldn't allocate a local port.")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw SpeechProviderError.failed("Couldn't reserve a local port.")
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw SpeechProviderError.failed("Couldn't resolve the local port.")
        }
        return UInt16(bigEndian: resolved.sin_port)
    }
}
