//
//  WhisperEngine.swift
//  WhisperService
//
//  Thin Swift wrapper over whisper.cpp's C API.
//
//  The model is loaded once and held for the life of the session: loading
//  ggml-base.en takes roughly a second, and a teleprompter transcribes a new
//  window every ~1.2 s, so reloading per request would dominate the latency
//  budget.
//

import Foundation
import CWhisper

/// Serialises access to the whisper context. `whisper_full` is not reentrant,
/// and XPC may deliver concurrent requests.
final class WhisperEngine {

    private var context: OpaquePointer?
    private var loadedModelPath: String?
    private let lock = NSLock()

    /// Threads used for inference. Leaves headroom so the prompter's UI and
    /// audio capture in the host process stay smooth.
    private let threadCount: Int32 = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return Int32(max(2, min(8, cores - 2)))
    }()

    deinit {
        if let context { whisper_free(context) }
    }

    // MARK: - Model lifecycle

    /// Loads from an open descriptor the host passed across.
    ///
    /// `/dev/fd/N` names a descriptor this process already owns, so the
    /// sandbox has nothing to deny — the access check happened in the host
    /// when it opened the file.
    func loadModel(descriptor: Int32, identifier: String) -> String? {
        lock.lock()
        if loadedModelPath == identifier, context != nil {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let path = "/dev/fd/\(descriptor)"
        let result = loadModel(path: path, cacheKey: identifier)
        return result
    }

    func loadModel(path: String) -> String? {
        loadModel(path: path, cacheKey: path)
    }

    private func loadModel(path: String, cacheKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if loadedModelPath == cacheKey, context != nil {
            return nil
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            return "The model file isn't readable: \(path)"
        }

        if let context {
            whisper_free(context)
            self.context = nil
            loadedModelPath = nil
        }

        var params = whisper_context_default_params()
        // Metal gives a large speedup on Apple silicon and degrades to CPU
        // automatically where it is unavailable.
        params.use_gpu = true

        guard let newContext = path.withCString({ cPath in
            whisper_init_from_file_with_params(cPath, params)
        }) else {
            return "whisper.cpp couldn't load the model at \(path)"
        }

        context = newContext
        loadedModelPath = cacheKey
        return nil
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let context { whisper_free(context) }
        context = nil
        loadedModelPath = nil
    }

    // MARK: - Inference

    /// Transcribes 16 kHz mono float samples.
    func transcribe(
        samples: [Float],
        language: String,
        prompt: String
    ) -> Result<String, WhisperEngineError> {
        lock.lock()
        defer { lock.unlock() }

        guard let context else {
            return .failure(.notLoaded)
        }
        guard !samples.isEmpty else {
            return .success("")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.single_segment = false
        params.translate = false
        params.n_threads = threadCount
        // Temperature fallback re-runs decoding on low confidence, which is
        // unpredictable latency. A prompter would rather have a slightly worse
        // transcript on time than a better one late.
        params.temperature_inc = 0
        params.suppress_nst = true

        // These C strings must outlive the `whisper_full` call, so they are
        // held in scope for the whole duration rather than passed inline.
        let languageBuffer = strdup(language.isEmpty ? "en" : language)
        let promptBuffer: UnsafeMutablePointer<CChar>? = prompt.isEmpty ? nil : strdup(prompt)
        defer {
            free(languageBuffer)
            if let promptBuffer { free(promptBuffer) }
        }
        params.language = UnsafePointer(languageBuffer)
        if let promptBuffer {
            params.initial_prompt = UnsafePointer(promptBuffer)
        }

        let status = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else {
            return .failure(.inferenceFailed(Int(status)))
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        return .success(text)
    }
}

enum WhisperEngineError: Error {
    case notLoaded
    case inferenceFailed(Int)

    var message: String {
        switch self {
        case .notLoaded:
            return "No model is loaded."
        case .inferenceFailed(let code):
            return "whisper.cpp inference failed (code \(code))."
        }
    }
}
