//
//  main.swift
//  WhisperService
//
//  XPC service entry point. Accepts one connection at a time from the host
//  app and vends a `WhisperServiceProtocol` object backed by whisper.cpp.
//

import Foundation

/// Answers XPC requests by delegating to a single shared engine, so the model
/// stays resident across the connections a session makes.
final class WhisperService: NSObject, WhisperServiceProtocol {

    private let engine = WhisperEngine()
    /// Inference is CPU/GPU heavy; keeping it off the XPC delivery queue lets
    /// the connection stay responsive.
    private let queue = DispatchQueue(label: "dev.fka.dynoprompt.whisper.engine", qos: .userInitiated)

    func loadModel(path modelPath: String, reply: @escaping (String?) -> Void) {
        queue.async { [engine] in
            reply(engine.loadModel(path: modelPath))
        }
    }

    func loadModel(
        handle: FileHandle,
        identifier: String,
        reply: @escaping (String?) -> Void
    ) {
        // Keep the handle alive for the whole load: closing it would pull
        // /dev/fd/N out from under whisper.cpp mid-read.
        queue.async { [engine] in
            let result = engine.loadModel(
                descriptor: handle.fileDescriptor,
                identifier: identifier
            )
            withExtendedLifetime(handle) { reply(result) }
        }
    }

    func transcribe(
        samples: Data,
        language: String,
        prompt: String,
        reply: @escaping (String?, String?) -> Void
    ) {
        queue.async { [engine] in
            // The host sends raw little-endian Float32 PCM.
            let floats: [Float] = samples.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
            switch engine.transcribe(samples: floats, language: language, prompt: prompt) {
            case .success(let text):
                reply(text, nil)
            case .failure(let error):
                reply(nil, error.message)
            }
        }
    }

    func unloadModel(reply: @escaping () -> Void) {
        queue.async { [engine] in
            engine.unload()
            reply()
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = WhisperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WhisperServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
