//
//  WhisperAudio.swift
//  DynoPromptCore
//
//  Audio helpers for the whisper.cpp provider. Pure functions so the encoding
//  and resampling can be tested without a microphone.
//

import Foundation

public enum WhisperAudio {

    /// whisper.cpp models are trained on 16 kHz mono audio.
    public static let targetSampleRate: Double = 16_000

    /// Linear-interpolation resampler. Whisper does its own mel filtering, so
    /// a cheap resample here is adequate and costs far less than pulling in a
    /// DSP dependency for a single conversion.
    public static func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to destinationRate: Double = targetSampleRate
    ) -> [Float] {
        guard sourceRate > 0, destinationRate > 0, !samples.isEmpty else { return [] }
        if abs(sourceRate - destinationRate) < 0.5 { return samples }

        let ratio = sourceRate / destinationRate
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let position = Double(i) * ratio
            let lowerIndex = Int(position)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(position - Double(lowerIndex))
            output[i] = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
        }
        return output
    }

    /// Encodes mono float samples as a 16-bit PCM WAV file.
    ///
    /// whisper.cpp's server accepts a WAV upload, so this is the handoff
    /// format. Writing the 44-byte header by hand avoids an AVFoundation
    /// round-trip through a temporary file.
    public static func wavData(from samples: [Float], sampleRate: Double = targetSampleRate) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let rate = UInt32(sampleRate)
        let byteRate = rate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))

        var data = Data(capacity: 44 + Int(dataSize))

        func appendASCII(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)              // PCM chunk size
        appendUInt16(1)               // PCM format
        appendUInt16(channels)
        appendUInt32(rate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    /// Root-mean-square level of a buffer, used for the waveform and for
    /// deciding whether a chunk contains speech worth transcribing.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Request building

public enum WhisperRequest {

    /// Builds a `multipart/form-data` body for whisper.cpp's `/inference`
    /// endpoint.
    public static func multipartBody(
        boundary: String,
        wav: Data,
        language: String,
        prompt: String
    ) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))

        field("response_format", "json")
        field("language", language)
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// whisper.cpp emits leading spaces, newlines between segments, and
    /// bracketed markers for non-speech audio. None of that should reach the
    /// matcher.
    public static func clean(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\n", with: " ")
        for marker in ["[BLANK_AUDIO]", "[ Silence ]", "(silence)", "[MUSIC]", "[ Pause ]", "[SOUND]"] {
            output = output.replacingOccurrences(of: marker, with: " ", options: .caseInsensitive)
        }
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// whisper.cpp wants a bare ISO-639-1 code, not a full BCP-47 identifier.
    public static func languageCode(from identifier: String) -> String {
        let base = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            ?? identifier
        return base.lowercased()
    }
}
