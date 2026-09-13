//
//  ScriptSyncEngineTests.swift
//  DynoPromptTests
//
//  Behavioural tests for the speech→script synchronizer. These are the tests
//  that matter most: the engine decides where the reader's eyes are sent, and
//  a wrong decision on camera is unrecoverable.
//

import XCTest

final class ScriptSyncEngineTests: XCTestCase {

    private func engine(_ script: String, tuning: ScriptSyncTuning = .default) -> ScriptSyncEngine {
        let engine = ScriptSyncEngine(tuning: tuning)
        engine.load(scriptText: script)
        return engine
    }

    // MARK: - Exact speech

    func testExactSpeechAdvancesWithFullConfidence() {
        let engine = engine("Welcome everyone to the quarterly product update.")
        let result = engine.consume(transcript: "Welcome everyone to the quarterly")

        XCTAssertEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, 5)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.001)
    }

    func testProgressiveTranscriptsWalkTheScript() {
        let engine = engine("The first step is to open the editor and paste your script.")
        var positions: [Int] = []
        for transcript in [
            "The first step",
            "The first step is to open",
            "The first step is to open the editor",
            "The first step is to open the editor and paste your script",
        ] {
            engine.consume(transcript: transcript)
            positions.append(engine.tokenIndex)
        }

        XCTAssertEqual(positions, positions.sorted(), "position must be monotonic")
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    // MARK: - Natural speech variation

    /// The scenario named in the brief: different words, same meaning.
    func testParaphraseStillAdvances() {
        let engine = engine(
            "Today we're going to discuss artificial intelligence and its impact on software engineering."
        )
        let result = engine.consume(
            transcript: "Today we're going to talk about AI and how it is changing software engineering."
        )

        XCTAssertEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testInitialismMatchesExpandedPhrase() {
        let engine = engine("Machine learning changed the industry.")
        let result = engine.consume(transcript: "ML changed the industry")
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    func testExpandedPhraseMatchesInitialismInScript() {
        let engine = engine("Our API is the product.")
        let result = engine.consume(transcript: "Our application programming interface is the product")
        XCTAssertEqual(result.decision, .advanced)
    }

    func testFillerWordsAreIgnored() {
        let engine = engine("We need to ship this feature before the deadline.")
        let result = engine.consume(
            transcript: "So um we need to uh you know ship this feature"
        )
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertGreaterThanOrEqual(engine.tokenIndex, 6)
    }

    func testMissingWordsTolerated() {
        let engine = engine("The quick brown fox jumps over the lazy dog today.")
        let result = engine.consume(transcript: "quick fox jumps over lazy dog today")
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertGreaterThanOrEqual(engine.tokenIndex, 9)
    }

    func testExtraImprovisedWordsTolerated() {
        let engine = engine("Let me show you the dashboard.")
        let result = engine.consume(
            transcript: "Okay so let me actually go ahead and show you the new dashboard"
        )
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    func testSentenceRestartRecovers() {
        let engine = engine(
            "Our mission is to make software development accessible to everyone on the planet."
        )
        let result = engine.consume(
            transcript: "Our mission is to, our mission is to make software development accessible"
        )
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertGreaterThanOrEqual(engine.tokenIndex, 8)
    }

    func testRepeatedWordsDoNotOverAdvance() {
        let engine = engine("This is a very very important point.")
        engine.consume(transcript: "This is a very very very important")
        XCTAssertLessThanOrEqual(engine.tokenIndex, engine.tokens.count)
        XCTAssertGreaterThanOrEqual(engine.tokenIndex, 5)
    }

    func testMisrecognizedHomophonesStillMatch() {
        let engine = engine("Their product roadmap is public.")
        let result = engine.consume(transcript: "There product roadmap is public")
        XCTAssertEqual(result.decision, .advanced)
    }

    // MARK: - Stability guarantees

    func testGarbageTranscriptHoldsPosition() {
        let engine = engine("The architecture separates the rendering layer from the data layer.")
        engine.consume(transcript: "The architecture separates")
        let anchor = engine.tokenIndex

        let result = engine.consume(
            transcript: "The architecture separates zzz qqq xylophone banana helicopter"
        )
        XCTAssertNotEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, anchor, "noise must not move the prompter")
    }

    func testNeverRewindsAutomatically() {
        let engine = engine("One two three four five six seven eight nine ten eleven twelve.")
        engine.consume(transcript: "one two three four five six seven eight")
        let anchor = engine.tokenIndex

        engine.consume(transcript: "one two three")
        XCTAssertGreaterThanOrEqual(engine.tokenIndex, anchor)
    }

    func testLargeJumpRequiresCorroboration() {
        let vocabulary = [
            "morning", "harbor", "crystal", "pilot", "ember", "garden", "tunnel",
            "violet", "anchor", "quartz", "meadow", "falcon", "ribbon", "copper",
            "lantern", "summit", "willow", "marble", "cinder", "orbit", "pepper",
            "thicket", "glacier", "cobalt", "saddle", "nimbus", "juniper",
            "lagoon", "pewter", "talon",
        ]
        let engine = engine(vocabulary.joined(separator: " "))

        let first = engine.consume(transcript: "nimbus juniper lagoon pewter talon")
        XCTAssertNotEqual(first.decision, .advanced, "a big leap must not land on one observation")
        XCTAssertEqual(engine.tokenIndex, 0)

        let second = engine.consume(transcript: "nimbus juniper lagoon pewter talon")
        XCTAssertEqual(second.decision, .advanced, "a repeated observation confirms the leap")
        XCTAssertEqual(engine.tokenIndex, vocabulary.count)
    }

    func testDuplicateSentencesPreferTheNearerOccurrence() {
        let engine = engine(
            "Thanks for joining. We will begin shortly. Thanks for joining. We will begin shortly."
        )
        engine.consume(transcript: "Thanks for joining we will begin shortly")
        XCTAssertLessThanOrEqual(engine.tokenIndex, 8, "must not leap to the second copy")
    }

    func testSilenceDoesNotMovePosition() {
        let engine = engine("Some words that will not be spoken yet.")
        let result = engine.consume(transcript: "")
        XCTAssertEqual(result.decision, .noMatch)
        XCTAssertEqual(engine.tokenIndex, 0)
    }

    func testRecoveryWidensWindowAfterRepeatedMisses() {
        // Speaker skips a long passage. Sustained misses widen the search so
        // the engine can re-acquire instead of staying stuck forever.
        let words = (1...140).map { "token\($0)x" }
        let engine = engine(words.joined(separator: " "))

        for _ in 0..<6 {
            engine.consume(transcript: "completely unrelated chatter about nothing")
        }
        for _ in 0..<3 {
            engine.consume(transcript: "token120x token121x token122x token123x token124x")
        }
        XCTAssertGreaterThan(engine.tokenIndex, 100, "should re-acquire far ahead after recovery")
    }

    // MARK: - Annotations

    func testStageDirectionsAreSkipped() {
        let engine = engine("Welcome to the show [pause and smile] let's get started.")
        engine.consume(transcript: "Welcome to the show")
        XCTAssertEqual(engine.tokenIndex, 7, "position lands past the bracketed cue")
        XCTAssertFalse(engine.tokens[engine.tokenIndex].isAnnotation)
    }

    func testAnnotationDoesNotBreakMatchRun() {
        let engine = engine("Start here [beat] and continue to the end.")
        let result = engine.consume(transcript: "Start here and continue to the end")
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    // MARK: - Manual override

    func testManualSeekWinsOverMatcher() {
        let engine = engine("Alpha bravo charlie delta echo foxtrot golf hotel.")
        engine.consume(transcript: "alpha bravo charlie")
        engine.seek(toTokenIndex: 0)
        XCTAssertEqual(engine.tokenIndex, 0)
    }

    func testStepMovesWholeTokens() {
        let engine = engine("Alpha bravo charlie delta echo.")
        engine.step(byTokens: 3)
        XCTAssertEqual(engine.tokenIndex, 3)
        engine.step(byTokens: -2)
        XCTAssertEqual(engine.tokenIndex, 1)
    }

    func testStepClampsAtBoundaries() {
        let engine = engine("Alpha bravo.")
        engine.step(byTokens: -10)
        XCTAssertEqual(engine.tokenIndex, 0)
        engine.step(byTokens: 99)
        XCTAssertEqual(engine.tokenIndex, engine.tokens.count)
    }

    func testSeekByCharacterOffsetRoundTrips() {
        let engine = engine("Alpha bravo charlie delta.")
        engine.seek(toTokenIndex: 2)
        let offset = engine.charOffset
        engine.reset()
        engine.seek(toCharOffset: offset)
        XCTAssertEqual(engine.tokenIndex, 2)
    }

    func testCharOffsetNeverExceedsTotal() {
        let script = "Alpha bravo charlie."
        let engine = engine(script)
        engine.step(byTokens: 99)
        XCTAssertLessThanOrEqual(engine.charOffset, engine.totalCharCount)
        XCTAssertEqual(engine.totalCharCount, script.count)
    }

    // MARK: - Robustness

    func testEmptyScriptIsSafe() {
        let engine = engine("")
        let result = engine.consume(transcript: "anything at all")
        XCTAssertEqual(result.decision, .noMatch)
        XCTAssertEqual(engine.charOffset, 0)
    }

    func testScriptOfOnlyAnnotationsCompletesImmediately() {
        let engine = engine("[intro music] [wave]")
        XCTAssertTrue(engine.isComplete)
        let result = engine.consume(transcript: "hello")
        XCTAssertEqual(result.decision, .noMatch)
    }

    func testUnicodeAndEmojiDoNotCrash() {
        let engine = engine("Café naïve résumé 🎬 Grüße 日本語 test.")
        let result = engine.consume(transcript: "cafe naive resume grusse test")
        // Diacritics are folded, so the ASCII rendering a recognizer emits
        // still matches the accented script.
        XCTAssertEqual(result.decision, .advanced)
        XCTAssertLessThanOrEqual(engine.charOffset, engine.totalCharCount)
    }

    func testVeryLongTranscriptIsBounded() {
        let engine = engine("Short script here.")
        let huge = String(repeating: "word ", count: 20_000)
        let result = engine.consume(transcript: huge)
        XCTAssertLessThanOrEqual(engine.charOffset, engine.totalCharCount)
        XCTAssertLessThanOrEqual(result.tokenIndex, engine.tokens.count)
    }

    // MARK: - Performance

    /// Cost per update must not grow with script length.
    ///
    /// Asserted as a *ratio* between a short and a very long script rather
    /// than a wall-clock budget: a fixed millisecond ceiling measures the
    /// machine, not the algorithm, and is flaky on shared CI hardware. The
    /// property that actually matters is that the windowed alignment keeps
    /// work bounded — so if someone makes it scan the whole script, this
    /// blows up on any hardware.
    func testUpdateCostDoesNotGrowWithScriptLength() {
        func timeUpdates(scriptWords: Int) -> TimeInterval {
            let engine = engine((1...scriptWords).map { "word\($0)" }.joined(separator: " "))
            let start = Date()
            for i in 0..<200 {
                engine.consume(transcript: "word\(i * 3) word\(i * 3 + 1) word\(i * 3 + 2)")
            }
            return Date().timeIntervalSince(start)
        }

        let short = timeUpdates(scriptWords: 200)
        let long = timeUpdates(scriptWords: 8_000)

        // 40× the script for well under 4× the time. A linear scan would be
        // ~40× slower and fail decisively.
        let ratio = long / max(short, 0.0001)
        XCTAssertLessThan(
            ratio, 4.0,
            "cost scaled with script length: \(short)s for 200 words, \(long)s for 8,000"
        )

        // Loose absolute ceiling, purely to catch a catastrophic regression on
        // any machine. Real updates arrive about every 100 ms.
        XCTAssertLessThan(long, 10.0, "200 updates on an 8,000-word script took \(long)s")
    }
}
