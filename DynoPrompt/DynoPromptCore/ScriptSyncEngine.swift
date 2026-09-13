//
//  ScriptSyncEngine.swift
//  DynoPromptCore
//
//  Maps what the speaker actually said onto where they are in the script.
//
//  Design constraints (in priority order):
//    1. Local and deterministic — no network, no model inference, no LLM.
//    2. Low latency — bounded work per update regardless of script length.
//    3. Stable — a bad transcript must hold position, never lurch.
//
//  The engine is a pure state machine: feed it transcripts, read back a
//  character offset. It owns no audio, no timers and no UI, which is what
//  makes the whole thing unit testable.
//

import Foundation

// MARK: - Tuning

public struct ScriptSyncTuning: Equatable {
    /// How many script tokens ahead of the anchor are considered. Bounds the
    /// per-update cost and caps how far a single update can skip.
    public var lookAheadTokens: Int
    /// How many tokens behind the anchor are considered, so a speaker who
    /// repeats or restarts a sentence still aligns.
    public var lookBehindTokens: Int
    /// Most recent spoken tokens used for alignment.
    public var spokenWindowTokens: Int
    /// Minimum confidence required to move at all.
    public var minConfidence: Double
    /// Confidence required to accept a jump larger than `maxRoutineJumpTokens`.
    public var highConfidence: Double
    /// Forward moves larger than this need `highConfidence` *and* corroboration.
    public var maxRoutineJumpTokens: Int
    /// Consecutive consistent observations required before a large jump lands.
    public var largeJumpCorroborations: Int
    /// Consecutive low-confidence updates before the search window widens to
    /// recover from a desync.
    public var recoveryAfterMisses: Int
    /// Window multiplier applied while recovering.
    public var recoveryWindowMultiplier: Int

    public static let `default` = ScriptSyncTuning(
        lookAheadTokens: 60,
        lookBehindTokens: 12,
        spokenWindowTokens: 24,
        minConfidence: 0.45,
        highConfidence: 0.72,
        maxRoutineJumpTokens: 18,
        largeJumpCorroborations: 2,
        recoveryAfterMisses: 4,
        recoveryWindowMultiplier: 3
    )

    public init(
        lookAheadTokens: Int,
        lookBehindTokens: Int,
        spokenWindowTokens: Int,
        minConfidence: Double,
        highConfidence: Double,
        maxRoutineJumpTokens: Int,
        largeJumpCorroborations: Int,
        recoveryAfterMisses: Int,
        recoveryWindowMultiplier: Int
    ) {
        self.lookAheadTokens = lookAheadTokens
        self.lookBehindTokens = lookBehindTokens
        self.spokenWindowTokens = spokenWindowTokens
        self.minConfidence = minConfidence
        self.highConfidence = highConfidence
        self.maxRoutineJumpTokens = maxRoutineJumpTokens
        self.largeJumpCorroborations = largeJumpCorroborations
        self.recoveryAfterMisses = recoveryAfterMisses
        self.recoveryWindowMultiplier = recoveryWindowMultiplier
    }
}

// MARK: - Result

public struct ScriptSyncUpdate: Equatable {
    public enum Decision: String, Equatable {
        /// Position moved forward.
        case advanced
        /// A match was found but gating rejected it; position unchanged.
        case held
        /// Nothing credible matched; position unchanged.
        case noMatch
    }

    public let decision: Decision
    /// Character offset into the collapsed script text.
    public let charOffset: Int
    /// Token index of the next token expected to be spoken.
    public let tokenIndex: Int
    public let confidence: Double

    public init(decision: Decision, charOffset: Int, tokenIndex: Int, confidence: Double) {
        self.decision = decision
        self.charOffset = charOffset
        self.tokenIndex = tokenIndex
        self.confidence = confidence
    }
}

// MARK: - Engine

public final class ScriptSyncEngine {

    public private(set) var tokens: [SpeechToken] = []
    public private(set) var totalCharCount: Int = 0
    /// Index of the next token the speaker is expected to say.
    public private(set) var tokenIndex: Int = 0
    public private(set) var lastConfidence: Double = 0

    private var tuning: ScriptSyncTuning
    private var consecutiveMisses = 0
    /// Pending large jump awaiting corroboration: (target, times seen).
    private var pendingJump: (target: Int, count: Int)?

    public init(tuning: ScriptSyncTuning = .default) {
        self.tuning = tuning
    }

    // MARK: Script loading

    public func load(scriptWords words: [String]) {
        tokens = SpeechNormalizer.scriptTokens(collapsedWords: words)
        totalCharCount = words.joined(separator: " ").count
        tokenIndex = 0
        lastConfidence = 0
        consecutiveMisses = 0
        pendingJump = nil
        skipAnnotations()
    }

    public func load(scriptText text: String) {
        load(scriptWords: text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init))
    }

    public func updateTuning(_ newTuning: ScriptSyncTuning) {
        tuning = newTuning
    }

    // MARK: Position

    /// Character offset of the current position, suitable for the renderer.
    public var charOffset: Int {
        guard tokenIndex > 0 else { return 0 }
        let index = min(tokenIndex, tokens.count) - 1
        return min(tokens[index].charEnd, totalCharCount)
    }

    public var isComplete: Bool { tokenIndex >= tokens.count }

    /// Manual override. Always wins over the matcher — the speaker is the
    /// authority on where they are.
    public func seek(toTokenIndex index: Int) {
        tokenIndex = max(0, min(index, tokens.count))
        consecutiveMisses = 0
        pendingJump = nil
        lastConfidence = 0
        skipAnnotations()
    }

    /// Manual override by character offset (what the overlay's tap-to-jump and
    /// the keyboard shortcuts speak in).
    public func seek(toCharOffset offset: Int) {
        let clamped = max(0, min(offset, totalCharCount))
        var index = 0
        while index < tokens.count && tokens[index].charEnd <= clamped {
            index += 1
        }
        seek(toTokenIndex: index)
    }

    public func reset() { seek(toTokenIndex: 0) }

    /// Steps whole tokens, skipping annotations. Used by the ⌥←/⌥→ shortcuts.
    public func step(byTokens delta: Int) {
        guard delta != 0 else { return }
        var index = tokenIndex
        var remaining = abs(delta)
        let forward = delta > 0
        while remaining > 0 {
            if forward {
                guard index < tokens.count else { break }
                index += 1
            } else {
                guard index > 0 else { break }
                index -= 1
            }
            if index < tokens.count && tokens[index].isAnnotation { continue }
            remaining -= 1
        }
        seek(toTokenIndex: index)
    }

    // MARK: Matching

    /// Feeds a transcript (the recognizer's view of everything said since the
    /// last reset/jump) and returns the resulting decision.
    @discardableResult
    public func consume(transcript: String) -> ScriptSyncUpdate {
        let spoken = SpeechNormalizer.spokenKeys(transcript)
        return consume(spokenKeys: spoken)
    }

    @discardableResult
    public func consume(spokenKeys: [String]) -> ScriptSyncUpdate {
        guard !tokens.isEmpty, !spokenKeys.isEmpty, !isComplete else {
            return ScriptSyncUpdate(
                decision: .noMatch,
                charOffset: charOffset,
                tokenIndex: tokenIndex,
                confidence: 0
            )
        }

        let window = Array(spokenKeys.suffix(tuning.spokenWindowTokens))
        let widen = consecutiveMisses >= tuning.recoveryAfterMisses
            ? tuning.recoveryWindowMultiplier : 1

        let lowerBound = max(0, tokenIndex - tuning.lookBehindTokens * widen)
        let upperBound = min(tokens.count, tokenIndex + tuning.lookAheadTokens * widen)
        guard lowerBound < upperBound else {
            return miss()
        }

        guard let best = align(
            spoken: window,
            scriptRange: lowerBound..<upperBound
        ) else {
            return miss()
        }

        lastConfidence = best.confidence

        // --- Gating -------------------------------------------------------

        // Never rewind automatically. A speaker repeating themselves must not
        // drag the prompter backwards; only manual seek goes back.
        guard best.endIndex > tokenIndex else {
            consecutiveMisses = 0
            pendingJump = nil
            return ScriptSyncUpdate(
                decision: .held,
                charOffset: charOffset,
                tokenIndex: tokenIndex,
                confidence: best.confidence
            )
        }

        guard best.confidence >= tuning.minConfidence else {
            return miss(confidence: best.confidence)
        }

        let jump = best.endIndex - tokenIndex
        if jump > tuning.maxRoutineJumpTokens {
            // A big leap is either the speaker skipping a paragraph or the
            // recognizer hallucinating. Require both high confidence and the
            // same landing spot on consecutive updates before committing.
            guard best.confidence >= tuning.highConfidence else {
                return hold(confidence: best.confidence)
            }
            if var pending = pendingJump, abs(pending.target - best.endIndex) <= 2 {
                pending.count += 1
                pending.target = best.endIndex
                pendingJump = pending
                if pending.count < tuning.largeJumpCorroborations {
                    return hold(confidence: best.confidence)
                }
            } else {
                pendingJump = (target: best.endIndex, count: 1)
                if tuning.largeJumpCorroborations > 1 {
                    return hold(confidence: best.confidence)
                }
            }
        }

        // --- Commit -------------------------------------------------------
        pendingJump = nil
        consecutiveMisses = 0
        tokenIndex = min(best.endIndex, tokens.count)
        skipAnnotations()

        return ScriptSyncUpdate(
            decision: .advanced,
            charOffset: charOffset,
            tokenIndex: tokenIndex,
            confidence: best.confidence
        )
    }

    // MARK: Helpers

    private func miss(confidence: Double = 0) -> ScriptSyncUpdate {
        consecutiveMisses += 1
        pendingJump = nil
        lastConfidence = confidence
        return ScriptSyncUpdate(
            decision: .noMatch,
            charOffset: charOffset,
            tokenIndex: tokenIndex,
            confidence: confidence
        )
    }

    private func hold(confidence: Double) -> ScriptSyncUpdate {
        ScriptSyncUpdate(
            decision: .held,
            charOffset: charOffset,
            tokenIndex: tokenIndex,
            confidence: confidence
        )
    }

    /// Annotations (`[pause]`, emoji) are never spoken, so the position slides
    /// past them as soon as it lands on one.
    private func skipAnnotations() {
        while tokenIndex < tokens.count && tokens[tokenIndex].isAnnotation {
            tokenIndex += 1
        }
    }

    // MARK: - Alignment

    struct Alignment {
        /// Script token index just past the last matched token.
        let endIndex: Int
        let confidence: Double
    }

    /// Local sequence alignment of the spoken window against a bounded slice of
    /// the script.
    ///
    /// This is a Smith-Waterman style dynamic program over *tokens*, which is
    /// what makes it tolerant of the things people actually do: swapped
    /// synonyms (mismatch, small penalty), dropped words (gap in spoken),
    /// improvised extra words (gap in script), and restarts (the local — not
    /// global — maximum simply lands later).
    ///
    /// Cost is `spokenWindow × scriptWindow`, both fixed, so it is O(1) in
    /// script length and runs in microseconds.
    func align(spoken: [String], scriptRange: Range<Int>) -> Alignment? {
        let script = Array(tokens[scriptRange])
        guard !script.isEmpty, !spoken.isEmpty else { return nil }

        let rows = spoken.count
        let cols = script.count

        let matchScore = 2.0
        let mismatchPenalty = -1.0
        let gapPenalty = -1.0

        /// One dynamic-programming cell. Alongside the Smith-Waterman score we
        /// carry where this local alignment began and how many script tokens
        /// it actually matched, so confidence can be computed without a
        /// traceback pass.
        struct Cell {
            var score: Double = 0
            var matches: Int = 0
            var startRow: Int = 0
            var startCol: Int = 0
        }

        var previous = [Cell](repeating: Cell(), count: cols + 1)
        var current = [Cell](repeating: Cell(), count: cols + 1)

        var best = Cell()
        var bestCol = -1
        var bestRow = -1

        /// Ranks candidate cells. Score dominates. On a tie we prefer the
        /// alignment that explains *more of what was said*: when a speaker
        /// paraphrases the middle of a sentence, stopping at the mismatched
        /// middle and running on to the matching tail can score identically,
        /// and the tail is the truthful reading. Only when score and spoken
        /// coverage both tie do we keep the *earlier* script position, which
        /// stops a script containing the same sentence twice from leaping to
        /// the second copy.
        func isBetter(_ cell: Cell, row: Int) -> Bool {
            if cell.score > best.score + 1e-9 { return true }
            if cell.score < best.score - 1e-9 { return false }
            return row > bestRow
        }

        for i in 1...rows {
            current[0] = Cell()
            for j in 1...cols {
                let scriptToken = script[j - 1]
                var cell = Cell()

                if scriptToken.isAnnotation {
                    // Stage directions are never spoken. Sliding over one is
                    // free, so it cannot break a run of real matches.
                    let fromLeft = current[j - 1]
                    let fromAbove = previous[j]
                    cell = fromLeft.score >= fromAbove.score ? fromLeft : fromAbove
                } else {
                    let similarity = SpeechNormalizer.similarity(spoken[i - 1], scriptToken.key)
                    let diagonalSource = previous[j - 1]
                    let isFresh = diagonalSource.score <= 0

                    var diagonal = diagonalSource
                    if similarity > 0 {
                        diagonal.score = diagonalSource.score + matchScore * similarity
                        diagonal.matches = diagonalSource.matches + 1
                    } else {
                        diagonal.score = diagonalSource.score + mismatchPenalty
                    }
                    if isFresh {
                        // Starting a new local alignment here.
                        diagonal.startRow = i - 1
                        diagonal.startCol = j - 1
                    }

                    var up = previous[j]          // spoken token unmatched
                    up.score = up.score + gapPenalty
                    var left = current[j - 1]     // script token unmatched
                    left.score = left.score + gapPenalty

                    cell = diagonal
                    if up.score > cell.score { cell = up }
                    if left.score > cell.score { cell = left }

                    if cell.score <= 0 {
                        cell = Cell(score: 0, matches: 0, startRow: i, startCol: j)
                    }
                }

                current[j] = cell
                if cell.score > 0, cell.matches > 0, isBetter(cell, row: i) {
                    best = cell
                    bestCol = j
                    bestRow = i
                }
            }
            swap(&previous, &current)
        }

        guard bestCol > 0, bestRow > 0, best.matches > 0 else { return nil }

        // Confidence balances two questions that matter independently:
        //   precision — how much of the script region was actually spoken?
        //   recall    — how much of the speech is explained by the script?
        // Their harmonic mean (F1) rejects the dangerous case of a couple of
        // accidental word hits buried in a long off-script ramble, while still
        // accepting an honest paraphrase where only half the words survive.
        let spokenUsed = max(1, bestRow - best.startRow)
        let scriptUsed = max(1, bestCol - best.startCol)
        let precision = Double(best.matches) / Double(scriptUsed)
        let recall = Double(best.matches) / Double(spokenUsed)
        let confidence = (precision + recall) > 0
            ? 2 * precision * recall / (precision + recall)
            : 0

        return Alignment(
            endIndex: scriptRange.lowerBound + bestCol,
            confidence: min(1.0, confidence)
        )
    }
}
