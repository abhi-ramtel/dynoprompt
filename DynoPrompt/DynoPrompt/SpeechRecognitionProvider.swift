//
//  SpeechRecognitionProvider.swift
//  DynoPrompt
//
//  The abstraction that lets the teleprompter swap speech engines without the
//  synchronization or overlay code knowing which one is running.
//
//      SpeechRecognitionProvider
//          ├── AppleOnDeviceProvider   (default — SFSpeechRecognizer, pinned local)
//          ├── WhisperLocalProvider    (whisper.cpp, optionally OpenWhispr's build)
//          └── future providers
//
//  Every provider must satisfy one non-negotiable contract: `isLocalOnly`
//  reports truthfully whether audio can leave the machine, and the app refuses
//  to start a session with a non-local provider unless the user has explicitly
//  turned that requirement off.
//

import AVFoundation
import Foundation

/// A chunk of microphone audio handed to a provider.
struct SpeechAudioChunk {
    let samples: [Float]
    let sampleRate: Double
}

enum SpeechProviderError: LocalizedError {
    case unavailable(String)
    case modelMissing(String)
    case runtimeMissing(String)
    case sandboxed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):   return detail
        case .modelMissing(let detail):  return detail
        case .runtimeMissing(let detail): return detail
        case .sandboxed(let detail):     return detail
        case .failed(let detail):        return detail
        }
    }
}

/// What a provider reports back. Providers differ in whether they emit a
/// growing transcript (Apple) or an independent window (Whisper); the sync
/// engine handles both because it only ever looks at the recent tail.
struct SpeechProviderResult {
    let text: String
    /// True when the provider considers this text settled rather than a
    /// revisable partial.
    let isFinal: Bool
}

protocol SpeechRecognitionProvider: AnyObject {
    /// Stable identifier matching the user-facing setting.
    var engine: SpeechEngine { get }

    /// Whether audio is guaranteed to stay on this machine. Providers must not
    /// report `true` optimistically.
    var isLocalOnly: Bool { get }

    /// Human-readable description of where processing happens, shown in
    /// Settings so the privacy posture is never a guess.
    var privacyDescription: String { get }

    var onResult: ((SpeechProviderResult) -> Void)? { get set }
    var onError: ((SpeechProviderError) -> Void)? { get set }

    /// Verifies the provider can run before a session starts, so failures
    /// surface in Settings rather than mid-recording.
    func preflight() -> SpeechProviderError?

    /// Begins a session. `contextualHints` are script words that improve
    /// recognition accuracy.
    func start(locale: String, contextualHints: [String]) throws

    /// Feeds captured microphone audio.
    func append(_ chunk: SpeechAudioChunk)

    func stop()
}
