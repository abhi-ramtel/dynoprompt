//
//  SpeechSessionSimulationTests.swift
//  DynoPromptTests
//
//  End-to-end simulation of a recording session.
//
//  A real recognizer delivers a *growing* transcript roughly every 100 ms, and
//  revises what it already emitted. Unit tests that feed one perfect string
//  miss the failure modes that actually bite on camera, so this harness
//  replays realistic streams — with hesitations, corrections, paraphrase and
//  dropouts — and asserts on the whole trajectory rather than a single step.
//

import XCTest

/// Replays a scripted "performance" as a stream of partial transcripts.
private struct SpeechSimulator {
    /// What the speaker actually says, in the order they say it.
    let spokenChunks: [String]
    /// Emit a partial result after every chunk (recognizers stream).
    var cumulative = true

    /// Produces the sequence of transcripts a recognizer would deliver.
    func transcripts() -> [String] {
        guard cumulative else { return spokenChunks }
        var running: [String] = []
        var output: [String] = []
        for chunk in spokenChunks {
            running.append(chunk)
            output.append(running.joined(separator: " "))
        }
        return output
    }
}

private struct SessionTrace {
    var positions: [Int] = []
    var decisions: [ScriptSyncUpdate.Decision] = []
    var confidences: [Double] = []

    var isMonotonic: Bool { positions == positions.sorted() }
    var finalPosition: Int { positions.last ?? 0 }
    var largestSingleJump: Int {
        guard positions.count > 1 else { return 0 }
        return zip(positions, positions.dropFirst()).map { $1 - $0 }.max() ?? 0
    }
}

final class SpeechSessionSimulationTests: XCTestCase {

    private func run(script: String, simulator: SpeechSimulator) -> (ScriptSyncEngine, SessionTrace) {
        let engine = ScriptSyncEngine()
        engine.load(scriptText: script)

        var trace = SessionTrace()
        for transcript in simulator.transcripts() {
            let update = engine.consume(transcript: transcript)
            trace.positions.append(engine.tokenIndex)
            trace.decisions.append(update.decision)
            trace.confidences.append(update.confidence)
        }
        return (engine, trace)
    }

    // MARK: - A clean read

    func testCleanReadReachesTheEndMonotonically() {
        let script = """
        Welcome back to the channel. Today I want to walk through how we rebuilt \
        our deployment pipeline. We cut build times by sixty percent and removed \
        three separate points of failure along the way.
        """
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "Welcome back to the channel",
            "Today I want to walk through",
            "how we rebuilt our deployment pipeline",
            "We cut build times by sixty percent",
            "and removed three separate points of failure along the way",
        ]))

        XCTAssertTrue(trace.isMonotonic, "positions: \(trace.positions)")
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count, "should finish the script")
        XCTAssertFalse(trace.decisions.contains(.noMatch), "a clean read should never miss")
    }

    // MARK: - A realistic, messy read

    func testNaturalDeliveryWithFillersAndParaphraseStillFinishes() {
        let script = """
        Today we're going to discuss artificial intelligence and its impact on \
        software engineering. The tools have changed, but the fundamentals have not.
        """
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "So um today we're going to",
            "talk about AI",
            "and how it's changing software engineering",
            "you know the tools have changed",
            "but uh the fundamentals have not",
        ]))

        XCTAssertTrue(trace.isMonotonic, "positions: \(trace.positions)")
        XCTAssertGreaterThan(
            engine.tokenIndex,
            Int(Double(engine.tokens.count) * 0.8),
            "should be near the end; got \(engine.tokenIndex)/\(engine.tokens.count)"
        )
    }

    func testSpeakerPausesMidSentenceThenResumes() {
        let script = "The second quarter numbers came in ahead of plan across every region."
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "The second quarter numbers",
            "",                                   // silence
            "",                                   // still silent
            "came in ahead of plan",
            "across every region",
        ]))

        XCTAssertTrue(trace.isMonotonic)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    func testSpeakerReadsFasterThanTheRecognizerReports() {
        // Large chunks arrive at once — the engine must keep up rather than
        // trickle forward one word per update.
        let script = (1...60).map { "phrase\($0)" }.joined(separator: " ")
        let (engine, _) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            (1...12).map { "phrase\($0)" }.joined(separator: " "),
            (13...24).map { "phrase\($0)" }.joined(separator: " "),
            (25...36).map { "phrase\($0)" }.joined(separator: " "),
        ]))

        XCTAssertGreaterThanOrEqual(engine.tokenIndex, 30, "fast reading must not lag far behind")
    }

    func testTransientMisrecognitionDoesNotLurch() {
        let script = """
        Our customers told us the onboarding flow was confusing, so we rebuilt it \
        from scratch with a single guided path.
        """
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "Our customers told us the onboarding flow was confusing",
            "XYZZY FROBNICATE QUUX WIDGET SPROCKET",   // a burst of garbage
            "so we rebuilt it from scratch",
            "with a single guided path",
        ]))

        XCTAssertTrue(trace.isMonotonic, "garbage must never rewind: \(trace.positions)")
        XCTAssertLessThanOrEqual(
            trace.largestSingleJump,
            25,
            "no wild leap; jumps were \(trace.positions)"
        )
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count, "recovers and finishes")
    }

    func testSpeakerSkipsAParagraphAndEngineCatchesUp() {
        let script = """
        First we cover the agenda for today. Then we look at last month's metrics \
        in detail with a full regional breakdown. Finally we open the floor for \
        questions from the audience.
        """
        // The speaker jumps straight from the agenda to the Q&A section.
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "First we cover the agenda for today",
            "Finally we open the floor for questions from the audience",
            "Finally we open the floor for questions from the audience",
        ]))

        XCTAssertTrue(trace.isMonotonic)
        XCTAssertGreaterThan(engine.tokenIndex, 20, "should catch up to the skipped-to section")
    }

    func testOffScriptImprovisationHoldsUntilSpeakerReturns() {
        let script = "Let me introduce our new pricing model and what it means for existing customers."
        let (engine, trace) = run(script: script, simulator: SpeechSimulator(spokenChunks: [
            "Let me introduce our new pricing model",
            "oh by the way I should mention we had a great time at the conference last week",
            "and what it means for existing customers",
        ]))

        XCTAssertTrue(trace.isMonotonic)
        // Position should not have run away during the digression.
        XCTAssertLessThanOrEqual(trace.positions[1] - trace.positions[0], 6)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    func testLongScriptStaysAlignedAcrossManyUpdates() {
        // 40 distinct sentences read in order, with light paraphrase noise.
        let sentences = (1..<41).map { index in
            "Section \(index) covers topic alpha\(index) and its relationship to beta\(index)."
        }
        let script = sentences.joined(separator: " ")

        let engine = ScriptSyncEngine()
        engine.load(scriptText: script)

        var positions: [Int] = []
        var spokenSoFar: [String] = []
        for index in 1..<41 {
            // Speaker drops the filler words and shortens slightly.
            spokenSoFar.append("Section \(index) covers topic alpha\(index) and beta\(index)")
            // Recognizers keep a bounded window; mimic that.
            let transcript = spokenSoFar.suffix(3).joined(separator: " ")
            engine.consume(transcript: transcript)
            positions.append(engine.tokenIndex)
        }

        XCTAssertEqual(positions, positions.sorted(), "drifted: \(positions)")
        XCTAssertGreaterThan(
            engine.tokenIndex,
            Int(Double(engine.tokens.count) * 0.85),
            "ended at \(engine.tokenIndex)/\(engine.tokens.count)"
        )
    }

    // MARK: - Manual override during a session

    func testManualOverrideDuringSessionIsRespected() {
        let script = "Alpha bravo charlie delta echo foxtrot golf hotel india juliet."
        let engine = ScriptSyncEngine()
        engine.load(scriptText: script)

        engine.consume(transcript: "alpha bravo charlie delta")
        XCTAssertGreaterThan(engine.tokenIndex, 0)

        // Presenter realises they are in the wrong place and taps back.
        engine.seek(toTokenIndex: 1)
        XCTAssertEqual(engine.tokenIndex, 1)

        // Speech continues from the new anchor rather than snapping forward.
        engine.consume(transcript: "bravo charlie")
        XCTAssertLessThanOrEqual(engine.tokenIndex, 4)
    }

    func testResetReturnsToStartMidSession() {
        let engine = ScriptSyncEngine()
        engine.load(scriptText: "One two three four five six seven eight.")
        engine.consume(transcript: "one two three four five")
        engine.reset()
        XCTAssertEqual(engine.tokenIndex, 0)
        XCTAssertEqual(engine.charOffset, 0)
    }
}
