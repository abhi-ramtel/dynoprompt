//
//  WhisperServiceProtocol.swift
//  WhisperService
//
//  The contract between DynoPrompt and its speech-recognition helper.
//
//  Why an XPC service rather than a subprocess or a linked library:
//
//  * **Sandbox.** A sandboxed app may not launch an arbitrary helper binary,
//    but it may launch an XPC service embedded in its own bundle. This is what
//    lets local Whisper work in the App Store build.
//  * **Privacy.** XPC is kernel-mediated IPC. There is no socket, no port and
//    no loopback HTTP, so there is no network surface to misconfigure — the
//    service's own sandbox denies networking outright.
//  * **Stability.** whisper.cpp is C++ doing heavy allocation and GPU work. A
//    crash there takes down the helper, not the prompter mid-recording; the
//    app just reconnects.
//
//  This file is compiled into both the app and the service, so the protocol
//  cannot drift between them.
//

import Foundation

/// Vended by the helper. All methods are asynchronous replies because XPC
/// calls cross a process boundary.
@objc public protocol WhisperServiceProtocol {

    /// Loads a GGML model. Safe to call repeatedly; loading the model that is
    /// already resident is a no-op, which is what keeps a session from paying
    /// the load cost more than once.
    ///
    /// - Parameter modelPath: absolute path to a `ggml-*.bin` file.
    /// - Parameter reply: `nil` on success, otherwise a human-readable reason.
    func loadModel(path modelPath: String, reply: @escaping (String?) -> Void)

    /// Loads a model from an already-open file descriptor.
    ///
    /// This is how a model the *user* downloaded gets loaded. The helper is
    /// sandboxed and can read its own bundle but nothing else, so a path into
    /// Application Support is unreadable to it no matter how ordinary the file
    /// is. The host — which can read it — opens the file and hands the
    /// descriptor across; XPC transfers the open fd itself, and the helper
    /// reads it as `/dev/fd/N`.
    ///
    /// Passing the descriptor rather than the bytes matters: a large model is
    /// 1.5 GB, and copying that through IPC to satisfy a permission check
    /// would be absurd.
    ///
    /// - Parameter identifier: model id, used only to skip a redundant reload.
    func loadModel(
        handle: FileHandle,
        identifier: String,
        reply: @escaping (String?) -> Void
    )

    /// Transcribes one window of audio.
    ///
    /// - Parameter samples: mono 32-bit float PCM at 16 kHz, little-endian.
    /// - Parameter language: ISO-639-1 code, or `auto`.
    /// - Parameter prompt: upcoming script words used to bias decoding.
    /// - Parameter reply: recognized text, or an error string.
    func transcribe(
        samples: Data,
        language: String,
        prompt: String,
        reply: @escaping (String?, String?) -> Void
    )

    /// Releases the model and frees its memory. Called when a session ends.
    func unloadModel(reply: @escaping () -> Void)
}

/// Name of the embedded service, as declared in its Info.plist.
public let whisperServiceName = "dev.fka.dynoprompt.WhisperService"
