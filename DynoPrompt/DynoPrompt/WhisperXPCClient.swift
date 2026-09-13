//
//  WhisperXPCClient.swift
//  DynoPrompt
//
//  Host-side connection to the embedded WhisperService.
//
//  The service is bundled inside the app, so this path needs nothing
//  installed on the user's machine and works inside the App Sandbox — unlike
//  driving an external whisper.cpp binary, which the sandbox forbids.
//

import Foundation

final class WhisperXPCClient {

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    /// True when the app was built with the embedded service present.
    ///
    /// A placeholder build counts as unavailable: the service exists but
    /// cannot transcribe, and claiming otherwise would make the app blame the
    /// user's model file for a missing dependency.
    static var isAvailable: Bool { serviceURL != nil && !isStubBuild }

    /// True when whisper.cpp could not be vendored and a placeholder was built
    /// in its place — see Scripts/vendor-whisper.sh.
    static var isStubBuild: Bool {
        guard let service = serviceURL else { return false }
        let marker = service.appendingPathComponent("Contents/Resources/.whisper-stub")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Location of the embedded XPC service, if present.
    private static var serviceURL: URL? {
        guard let services = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent()
            .appendingPathComponent("XPCServices") else { return nil }
        let candidate = services.appendingPathComponent("WhisperService.xpc")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The model shipped with the app.
    ///
    /// It lives inside `WhisperService.xpc`, not in the app's own Resources.
    /// A sandboxed XPC service may read its own bundle but *not* the
    /// containing app's Resources — verified by running the self-test against
    /// a genuinely sandboxed build, where the host could read the model and
    /// the helper could not. Shipping it inside the helper is what makes the
    /// built-in engine work under the App Sandbox.
    static var bundledModelURL: URL? {
        guard let service = serviceURL else { return nil }
        let url = service
            .appendingPathComponent("Contents/Resources/models/ggml-base.en.bin")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Connection

    private func proxy(
        onError: @escaping (String) -> Void
    ) -> WhisperServiceProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if connection == nil {
            let newConnection = NSXPCConnection(serviceName: whisperServiceName)
            newConnection.remoteObjectInterface = NSXPCInterface(with: WhisperServiceProtocol.self)
            // whisper.cpp is heavy C++; if it ever crashes, drop the stale
            // connection so the next request transparently relaunches it
            // rather than failing forever.
            let reset: () -> Void = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.connection = nil
                self.lock.unlock()
            }
            newConnection.invalidationHandler = reset
            newConnection.interruptionHandler = reset
            newConnection.resume()
            connection = newConnection
        }

        return connection?.remoteObjectProxyWithErrorHandler { error in
            onError(error.localizedDescription)
        } as? WhisperServiceProtocol
    }

    // MARK: - API

    func loadModel(at url: URL, completion: @escaping (String?) -> Void) {
        guard let service = proxy(onError: { completion($0) }) else {
            completion("Couldn't reach the speech recognition helper.")
            return
        }

        // A model inside the helper's own bundle is readable by it directly.
        if isInsideServiceBundle(url) {
            service.loadModel(path: url.path, reply: completion)
            return
        }

        // Anything else — a model the user downloaded into Application
        // Support, or picked themselves — is invisible to the sandboxed
        // helper. This process can read it, so it opens the file and hands the
        // descriptor over; XPC transfers the open fd and the helper reads it
        // as /dev/fd/N. Sending the descriptor rather than the bytes keeps a
        // 1.5 GB model out of the IPC path entirely.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            completion("Couldn't open the model at \(url.path).")
            return
        }
        let identifier = url.deletingPathExtension().lastPathComponent
        service.loadModel(handle: handle, identifier: identifier) { error in
            // Hold the handle until the helper is done with it.
            withExtendedLifetime(handle) {
                try? handle.close()
                completion(error)
            }
        }
    }

    /// True when the file lives inside the embedded service, which the helper
    /// can open without help.
    private func isInsideServiceBundle(_ url: URL) -> Bool {
        guard let service = Self.serviceURL else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(service.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    /// Transcribes 16 kHz mono float samples.
    func transcribe(
        samples: [Float],
        language: String,
        prompt: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        guard let service = proxy(onError: { completion(nil, $0) }) else {
            completion(nil, "Couldn't reach the speech recognition helper.")
            return
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        service.transcribe(
            samples: data,
            language: language,
            prompt: prompt,
            reply: completion
        )
    }

    func shutdown() {
        lock.lock()
        let existing = connection
        connection = nil
        lock.unlock()

        guard let existing else { return }
        // Ask the helper to free the model before tearing the link down, so a
        // few hundred megabytes are not left resident until it exits.
        let service = existing.remoteObjectProxyWithErrorHandler { _ in
            existing.invalidate()
        } as? WhisperServiceProtocol
        if let service {
            service.unloadModel { existing.invalidate() }
        } else {
            existing.invalidate()
        }
    }

    deinit {
        connection?.invalidate()
    }
}
