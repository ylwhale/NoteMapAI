import Foundation

/// Local, deterministic tag suggestions. The engine never mutates a note and never requires the
/// network, so it can safely run after a durable save or in a unit test.
struct TagSuggestionEngine: Sendable {
    struct Configuration: Hashable, Sendable {
        var maximumSuggestions: Int
        var minimumKeywordLength: Int

        init(maximumSuggestions: Int = 3, minimumKeywordLength: Int = 4) {
            self.maximumSuggestions = min(max(maximumSuggestions, 1), 3)
            self.minimumKeywordLength = max(minimumKeywordLength, 3)
        }
    }

    private struct Category: Sendable {
        var label: String
        var aliases: Set<String>
        var keywords: Set<String>
        var baseScore: Double

        var acceptedKeys: Set<String> { aliases.union([label]) }
    }

    private struct Candidate {
        var key: String
        var label: String
        var score: Double
        var insertionOrder: Int
        var usesExistingLabel: Bool
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static let categories: [Category] = [
        Category(
            label: "study",
            aliases: ["academic", "academics", "class", "classes", "college", "school"],
            keywords: [
                "assignment", "campus", "class", "course", "exam", "faculty", "grade",
                "homework", "lab", "lecture", "office hours", "paper", "professor", "project",
                "quiz", "research", "semester", "study", "syllabus", "textbook"
            ],
            baseScore: 126
        ),
        Category(
            label: "travel",
            aliases: ["trip", "trips", "vacation"],
            keywords: [
                "airport", "airbnb", "bus", "flight", "hotel", "hostel", "itinerary",
                "luggage", "museum", "neighborhood", "packing", "reservation", "restaurant",
                "station", "tour", "train", "transit", "travel", "trip", "vacation", "weekend"
            ],
            baseScore: 126
        ),
        Category(
            label: "daily",
            aliases: ["daily life", "life admin", "personal"],
            keywords: [
                "appointment", "buy", "call", "decision", "doctor", "errand", "groceries",
                "gym", "habit", "laundry", "meeting", "medication", "reminder", "rent",
                "schedule", "todo", "work"
            ],
            baseScore: 116
        ),
        Category(
            label: "transportation",
            aliases: ["commute", "transit", "transport"],
            keywords: [
                "airport", "bus", "commute", "fare", "flight", "last train", "metro", "parking",
                "route", "station", "subway", "taxi", "train", "transit", "transport", "uber"
            ],
            baseScore: 108
        ),
        Category(
            label: "food",
            aliases: ["dining", "restaurant", "restaurants"],
            keywords: [
                "breakfast", "cafe", "coffee", "dinner", "dish", "eat", "food", "lunch",
                "meal", "menu", "restaurant", "snack"
            ],
            baseScore: 106
        ),
        Category(
            label: "budget",
            aliases: ["cost", "costs", "expense", "expenses", "money"],
            keywords: [
                "afford", "budget", "cheap", "cost", "deal", "discount", "dollar", "expensive",
                "fee", "price", "save money", "spent"
            ],
            baseScore: 104
        ),
        Category(
            label: "activities",
            aliases: ["activity", "things to do"],
            keywords: [
                "activity", "concert", "event", "festival", "hike", "museum", "park", "show",
                "tour", "trail", "visit"
            ],
            baseScore: 102
        ),
        Category(
            label: "lessons",
            aliases: ["lesson", "lessons learned", "reflection", "reflections"],
            keywords: [
                "avoid", "better next time", "forgot", "learned", "lesson", "mistake", "next time",
                "remember", "reflection"
            ],
            baseScore: 102
        )
    ]

    private static let notablePhrases: [(phrase: String, score: Double)] = [
        ("weekend trip", 124),
        ("office hours", 118),
        ("study guide", 118),
        ("packing list", 116),
        ("class notes", 114),
        ("project decision", 112),
        ("lesson learned", 112)
    ]

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "another", "because", "been", "before", "being",
        "between", "both", "could", "did", "does", "doing", "during", "each", "from", "have",
        "having", "here", "into", "just", "later", "more", "most", "need", "notes", "other",
        "over", "really", "should", "some", "than", "that", "their", "them", "then", "there",
        "these", "they", "thing", "things", "this", "those", "through", "today", "under", "very",
        "want", "what", "when", "where", "which", "while", "with", "would", "your"
    ]

    let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    init(maximumSuggestions: Int) {
        configuration = .init(maximumSuggestions: maximumSuggestions)
    }

    /// Returns one to three normalized, unique labels when the note contains enough information.
    /// Existing labels keep their original capitalization and receive priority over new synonyms.
    func suggestTags(for note: MindNote, existingTags: [String] = []) -> [String] {
        let acceptedKeys = Set(note.acceptedTags.map { Self.normalizedTag($0) }.filter { !$0.isEmpty })
        let existing = Self.uniqueLabels(existingTags)
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map {
            (Self.normalizedTag($0), $0)
        })
        let normalizedContent = Self.normalized(
            [
                note.title,
                note.body,
                note.tripTheme,
                note.place?.name ?? "",
                note.place?.detail ?? ""
            ].joined(separator: " ")
        )
        let contentTokens = Self.tokens(inNormalizedText: normalizedContent)

        var candidates: [String: Candidate] = [:]
        var insertionOrder = 0

        func addCandidate(_ rawLabel: String, score: Double, prefersExisting: Bool = true) {
            let proposedKey = Self.normalizedTag(rawLabel)
            guard !proposedKey.isEmpty, !acceptedKeys.contains(proposedKey) else { return }

            let existingLabel = prefersExisting ? existingByKey[proposedKey] : nil
            let label = existingLabel ?? Self.cleanedNewLabel(rawLabel)
            let key = Self.normalizedTag(label)
            guard !key.isEmpty, !acceptedKeys.contains(key) else { return }

            let candidate = Candidate(
                key: key,
                label: label,
                score: score + (existingLabel == nil ? 0 : 8),
                insertionOrder: insertionOrder,
                usesExistingLabel: existingLabel != nil
            )
            insertionOrder += 1

            if let current = candidates[key] {
                if candidate.score > current.score {
                    var replacement = candidate
                    replacement.insertionOrder = current.insertionOrder
                    candidates[key] = replacement
                }
            } else {
                candidates[key] = candidate
            }
        }

        // A user's established label is the strongest candidate when its full token sequence is
        // already present in the note.
        for label in existing {
            let key = Self.normalizedTag(label)
            guard !key.isEmpty,
                  !acceptedKeys.contains(key),
                  Self.containsPhrase(key, in: normalizedContent) else { continue }
            addCandidate(label, score: 142 + Double(Self.tokens(inNormalizedText: key).count))
        }

        // Preserve explicit structured context before deriving broader categories.
        let theme = note.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if !theme.isEmpty {
            addCandidate(Self.preferredExactLabel(for: theme, existingByKey: existingByKey), score: 132)
        }
        if let place = note.place?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !place.isEmpty {
            addCandidate(Self.preferredExactLabel(for: place, existingByKey: existingByKey), score: 120)
        }

        for phrase in Self.notablePhrases where Self.containsPhrase(phrase.phrase, in: normalizedContent) {
            addCandidate(
                Self.preferredExactLabel(for: phrase.phrase, existingByKey: existingByKey),
                score: phrase.score
            )
        }

        for category in Self.categories {
            let hitCount = category.keywords.reduce(0) { partial, keyword in
                partial + (Self.containsPhrase(keyword, in: normalizedContent) ? 1 : 0)
            }
            guard hitCount > 0,
                  acceptedKeys.isDisjoint(with: category.acceptedKeys) else { continue }

            let preferred = Self.preferredCategoryLabel(
                category,
                existingLabels: existing,
                existingByKey: existingByKey
            )
            addCandidate(
                preferred,
                score: category.baseScore + Double(min(hitCount, 5) * 2)
            )
        }

        // Deterministic keyword fallback gives short but meaningful notes a useful tag without
        // requiring a model call. Repetition is a signal, but first appearance breaks ties.
        var frequencies: [String: Int] = [:]
        var firstPositions: [String: Int] = [:]
        for (index, token) in contentTokens.enumerated() {
            guard Self.isKeywordCandidate(
                token,
                minimumLength: configuration.minimumKeywordLength
            ) else { continue }
            frequencies[token, default: 0] += 1
            if firstPositions[token] == nil { firstPositions[token] = index }
        }

        let keywordCandidates = frequencies.keys.sorted {
            let leftFrequency = frequencies[$0] ?? 0
            let rightFrequency = frequencies[$1] ?? 0
            if leftFrequency != rightFrequency { return leftFrequency > rightFrequency }
            let leftPosition = firstPositions[$0] ?? .max
            let rightPosition = firstPositions[$1] ?? .max
            if leftPosition != rightPosition { return leftPosition < rightPosition }
            return $0 < $1
        }
        for token in keywordCandidates.prefix(6) where !acceptedKeys.contains(token) {
            let label = existingByKey[token] ?? token
            addCandidate(
                label,
                score: 44 + Double(min(frequencies[token] ?? 1, 4) * 2)
            )
        }

        // A body containing only emoji or very short words still represents daily-life context.
        if candidates.isEmpty,
           !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !acceptedKeys.contains("daily") {
            let fallback = Self.preferredCategoryLabel(
                Self.categories.first { $0.label == "daily" }!,
                existingLabels: existing,
                existingByKey: existingByKey
            )
            addCandidate(fallback, score: 1)
        }

        return candidates.values
            .sorted {
                if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
                if $0.usesExistingLabel != $1.usesExistingLabel {
                    return $0.usesExistingLabel && !$1.usesExistingLabel
                }
                if $0.insertionOrder != $1.insertionOrder {
                    return $0.insertionOrder < $1.insertionOrder
                }
                return $0.key < $1.key
            }
            .prefix(configuration.maximumSuggestions)
            .map { $0.label }
    }

    func suggestions(for note: MindNote, existingTags: [String] = []) -> [String] {
        suggestTags(for: note, existingTags: existingTags)
    }

    func suggestTags(for note: MindNote, existingNotes: [MindNote]) -> [String] {
        suggestTags(for: note, existingTags: Self.existingTags(in: existingNotes))
    }

    /// Builds the existing model without introducing hidden time/UUID dependencies. Callers pass
    /// those values, making repeated tests byte-for-byte deterministic.
    func makeSuggestion(
        for note: MindNote,
        existingTags: [String] = [],
        id: UUID,
        createdAt: Date
    ) -> TagSuggestion? {
        let tags = suggestTags(for: note, existingTags: existingTags)
        guard !tags.isEmpty else { return nil }
        return TagSuggestion(
            id: id,
            noteID: note.id,
            tags: tags,
            createdAt: createdAt,
            decision: .pending
        )
    }

    static func existingTags(in notes: [MindNote]) -> [String] {
        uniqueLabels(notes.flatMap { $0.acceptedTags })
    }

    /// Canonical key used for deduplication and matching. Display spelling is preserved separately
    /// when the value came from the user's existing tag vocabulary.
    static func normalizedTag(_ value: String) -> String {
        normalized(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func preferredExactLabel(
        for proposed: String,
        existingByKey: [String: String]
    ) -> String {
        existingByKey[normalizedTag(proposed)] ?? cleanedNewLabel(proposed)
    }

    private static func preferredCategoryLabel(
        _ category: Category,
        existingLabels: [String],
        existingByKey: [String: String]
    ) -> String {
        let possibleKeys = category.acceptedKeys
        if let existing = existingLabels.first(where: {
            possibleKeys.contains(normalizedTag($0))
        }) {
            return existing
        }
        return existingByKey[category.label] ?? category.label
    }

    private static func uniqueLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for rawLabel in labels {
            let label = cleanedExistingLabel(rawLabel)
            let key = normalizedTag(label)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            output.append(label)
        }
        return output
    }

    private static func cleanedExistingLabel(_ value: String) -> String {
        var label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while label.hasPrefix("#") { label.removeFirst() }
        return label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func cleanedNewLabel(_ value: String) -> String {
        normalizedTag(cleanedExistingLabel(value))
    }

    private static func isKeywordCandidate(_ token: String, minimumLength: Int) -> Bool {
        guard token.count >= minimumLength,
              !stopWords.contains(token),
              token.rangeOfCharacter(from: .letters) != nil,
              token.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        return true
    }

    private static func containsPhrase(_ rawPhrase: String, in normalizedContent: String) -> Bool {
        let phrase = normalized(rawPhrase)
        guard !phrase.isEmpty else { return false }
        return (" " + normalizedContent + " ").contains(" " + phrase + " ")
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: posixLocale
        )
        return tokens(inFoldedText: folded).joined(separator: " ")
    }

    private static func tokens(inNormalizedText value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }

    private static func tokens(inFoldedText value: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        let allowed = CharacterSet.alphanumerics

        func finishToken() {
            guard !current.isEmpty else { return }
            result.append(String(current))
            current.removeAll(keepingCapacity: true)
        }

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                current.append(scalar)
            } else {
                finishToken()
            }
        }
        finishToken()
        return result
    }
}
