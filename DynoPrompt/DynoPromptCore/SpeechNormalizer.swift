//
//  SpeechNormalizer.swift
//  DynoPromptCore
//
//  Turns raw script text and raw speech transcripts into a comparable token
//  stream. Everything here is pure, synchronous and dependency-free so the
//  synchronization engine can be unit tested without audio, UI or network.
//

import Foundation

/// A single comparable unit of the script or of a spoken transcript.
public struct SpeechToken: Equatable {
    /// Canonical, comparison-ready form (lowercased, punctuation stripped,
    /// equivalences applied). Never empty.
    public let key: String
    /// Character offset of the end of this token within the *collapsed* source
    /// string (words joined by single spaces), including the token itself but
    /// not the following separator. Used to map token positions back to the
    /// character offsets the overlay renders with.
    public let charEnd: Int
    /// Bracketed stage directions like `[pause]` and emoji-only words. These
    /// are never spoken, so the engine skips over them automatically.
    public let isAnnotation: Bool

    public init(key: String, charEnd: Int, isAnnotation: Bool) {
        self.key = key
        self.charEnd = charEnd
        self.isAnnotation = isAnnotation
    }
}

public enum SpeechNormalizer {

    // MARK: - Filler words

    /// Discourse markers a speaker emits that will never appear in a script.
    /// Dropping them from the *spoken* side keeps them from consuming the
    /// alignment's mismatch budget. They are deliberately NOT dropped from the
    /// script side: if the author wrote "like", it is meant to be read.
    public static let fillerWords: Set<String> = [
        "um", "uh", "uhm", "erm", "er", "ah", "eh", "hmm", "hm", "mm",
        "mhm", "huh", "oh", "okay", "ok", "yeah", "yep",
        "like", "basically", "actually", "literally", "honestly",
        "sorta", "kinda", "anyway", "anyways", "right",
    ]

    /// Multi-word filler phrases, matched greedily before single-word fillers.
    static let fillerPhrases: [[String]] = [
        ["you", "know"],
        ["i", "mean"],
        ["sort", "of"],
        ["kind", "of"],
        ["so", "yeah"],
    ]

    // MARK: - Equivalences

    /// Phrases that a speaker commonly contracts to an initialism (or expands
    /// from one). Both sides are rewritten to the same canonical key, so
    /// "artificial intelligence" and "AI" align at zero cost.
    ///
    /// Keyed by the *expanded* token sequence; the value is the canonical key.
    static let phraseEquivalents: [[String]: String] = [
        ["artificial", "intelligence"]: "ai",
        ["machine", "learning"]: "ml",
        ["large", "language", "model"]: "llm",
        ["large", "language", "models"]: "llm",
        ["natural", "language", "processing"]: "nlp",
        ["user", "interface"]: "ui",
        ["user", "experience"]: "ux",
        ["application", "programming", "interface"]: "api",
        ["operating", "system"]: "os",
        ["software", "development", "kit"]: "sdk",
        ["continuous", "integration"]: "ci",
        ["return", "on", "investment"]: "roi",
        ["for", "example"]: "eg",
        ["that", "is"]: "ie",
    ]

    /// Single tokens that map onto a canonical key shared with a phrase above,
    /// plus common spoken/written spelling splits.
    static let wordEquivalents: [String: String] = [
        "ai": "ai", "ml": "ml", "llm": "llm", "llms": "llm", "nlp": "nlp",
        "ui": "ui", "ux": "ux", "api": "api", "apis": "api", "os": "os",
        "sdk": "sdk", "ci": "ci", "roi": "roi", "eg": "eg", "ie": "ie",
        // Spoken numbers → digits, so "five" aligns with "5".
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16",
        "seventeen": "17", "eighteen": "18", "nineteen": "19",
        "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
        "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000",
        "percent": "%", "and": "and",
        // Contractions that speech recognition renders inconsistently.
        "cannot": "cant", "wont": "wont", "dont": "dont", "its": "its",
        "im": "im", "ive": "ive", "id": "id", "ill": "ill",
        "were": "were", "weve": "weve", "were_": "were",
        "gonna": "goingto", "going": "going", "wanna": "wantto",
    ]

    // MARK: - Character normalization

    /// Lowercases, folds diacritics, and strips everything that is not a
    /// letter, a digit or an internal separator. Apostrophes are removed
    /// entirely so "don't" and "dont" collapse to the same key.
    public static func normalizeWord(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US")
        ).lowercased()

        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                out.append(scalar)
            }
            // Everything else (punctuation, apostrophes, symbols, emoji) is
            // dropped: it carries no signal for alignment.
        }
        return String(out)
    }

    /// True when a word is a stage direction or carries no alphanumerics at
    /// all (pure emoji or punctuation).
    static func isAnnotationWord(_ word: String, insideBrackets: Bool) -> Bool {
        if insideBrackets { return true }
        return normalizeWord(word).isEmpty
    }

    // MARK: - Script tokenization

    /// Tokenizes the *script*. Preserves character offsets into the collapsed
    /// text so the engine can report a position the renderer understands.
    ///
    /// - Parameter collapsedWords: the script already split into display words
    ///   (the same split the overlay uses), which are joined by single spaces
    ///   to form the collapsed source string.
    public static func scriptTokens(collapsedWords words: [String]) -> [SpeechToken] {
        var tokens: [SpeechToken] = []
        var charOffset = 0
        var insideBrackets = false

        // Pre-pass: a "[" only opens an annotation when a "]" follows it.
        var closingAtOrAfter = [Bool](repeating: false, count: words.count)
        var seenClosing = false
        for i in words.indices.reversed() {
            if words[i].contains("]") { seenClosing = true }
            closingAtOrAfter[i] = seenClosing
        }

        // First pass produces one raw token per word, carrying its char end.
        var raw: [(key: String, charEnd: Int, isAnnotation: Bool)] = []
        for (i, word) in words.enumerated() {
            let opens = word.hasPrefix("[") && closingAtOrAfter[i]
            if opens { insideBrackets = true }

            let end = charOffset + word.count
            let annotation = isAnnotationWord(word, insideBrackets: insideBrackets)
            let key = normalizeWord(word)
            raw.append((key: key, charEnd: end, isAnnotation: annotation))

            if insideBrackets && word.contains("]") { insideBrackets = false }
            charOffset = end + 1 // the joining space
        }

        // Second pass collapses known multi-word phrases into one canonical
        // token, so a script saying "artificial intelligence" and a speaker
        // saying "AI" produce the same key.
        var i = 0
        while i < raw.count {
            if !raw[i].isAnnotation,
               let (canonical, length) = matchPhrase(in: raw, at: i) {
                tokens.append(SpeechToken(
                    key: canonical,
                    charEnd: raw[i + length - 1].charEnd,
                    isAnnotation: false
                ))
                i += length
                continue
            }

            let entry = raw[i]
            // Annotations are kept (with an empty-safe key) so the engine can
            // skip them while still advancing the character offset past them.
            let key = entry.isAnnotation ? "" : canonicalKey(entry.key)
            tokens.append(SpeechToken(
                key: key,
                charEnd: entry.charEnd,
                isAnnotation: entry.isAnnotation || key.isEmpty
            ))
            i += 1
        }

        return tokens
    }

    private static func matchPhrase(
        in raw: [(key: String, charEnd: Int, isAnnotation: Bool)],
        at index: Int
    ) -> (canonical: String, length: Int)? {
        // Longest phrase first so "large language model" wins over shorter
        // overlapping entries.
        for (phrase, canonical) in phraseEquivalents.sorted(by: { $0.key.count > $1.key.count }) {
            guard index + phrase.count <= raw.count else { continue }
            var matched = true
            for (offset, expected) in phrase.enumerated() {
                let entry = raw[index + offset]
                if entry.isAnnotation || entry.key != expected {
                    matched = false
                    break
                }
            }
            if matched { return (canonical, phrase.count) }
        }
        return nil
    }

    static func canonicalKey(_ normalized: String) -> String {
        wordEquivalents[normalized] ?? normalized
    }

    // MARK: - Spoken tokenization

    /// Tokenizes a *spoken* transcript: drops filler words, applies the same
    /// equivalences, and collapses the same phrases. Character offsets are
    /// meaningless here, so `charEnd` is the token index.
    public static func spokenKeys(_ transcript: String) -> [String] {
        let rawWords = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalizeWord(String($0)) }
            .filter { !$0.isEmpty }

        // Drop multi-word filler phrases first (greedy, left to right).
        var deFilled: [String] = []
        var i = 0
        outer: while i < rawWords.count {
            for phrase in fillerPhrases where i + phrase.count <= rawWords.count {
                if Array(rawWords[i..<(i + phrase.count)]) == phrase {
                    i += phrase.count
                    continue outer
                }
            }
            deFilled.append(rawWords[i])
            i += 1
        }

        // Collapse equivalence phrases ("artificial intelligence" → "ai").
        var collapsed: [String] = []
        i = 0
        outer2: while i < deFilled.count {
            for (phrase, canonical) in phraseEquivalents.sorted(by: { $0.key.count > $1.key.count })
            where i + phrase.count <= deFilled.count {
                if Array(deFilled[i..<(i + phrase.count)]) == phrase {
                    collapsed.append(canonical)
                    i += phrase.count
                    continue outer2
                }
            }
            collapsed.append(canonicalKey(deFilled[i]))
            i += 1
        }

        // Finally drop single-word fillers. This happens last so a filler that
        // is part of an equivalence phrase is preserved.
        return collapsed.filter { !fillerWords.contains($0) }
    }

    // MARK: - Fuzzy comparison

    /// Similarity in 0...1 between two canonical keys. 1.0 is an exact match.
    /// Deliberately cheap: bounded edit distance on short strings only.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let shorter = min(a.count, b.count)
        let longer = max(a.count, b.count)

        // A long shared prefix is a strong signal for stemming differences
        // ("change" / "changing", "build" / "building").
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        if shorter >= 4 && shared >= shorter - 1 && longer - shorter <= 4 {
            return 0.9
        }

        // Very short words must match exactly; edit distance is too permissive
        // at that length ("or" vs "of" vs "on").
        if shorter <= 3 { return 0 }

        let distance = editDistance(Array(a), Array(b))
        guard distance <= 2 else { return 0 }
        let score = 1.0 - Double(distance) / Double(longer)
        return score >= 0.6 ? score * 0.9 : 0
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : min(prev, dp[j], dp[j - 1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }
}
