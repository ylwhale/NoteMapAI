import Foundation

enum RetrievalResolution: String, Codable, Hashable, Sendable {
    case ready
    case needsClarification
    case noEvidence
}

struct RetrievalResult: Codable, Hashable, Sendable {
    var sources: [SourceReference]
    var scannedCount: Int
    var filteredCount: Int
    var resolution: RetrievalResolution
    var statedAssumption: String
    var clarificationQuestion: String

    var relevantTotal: Int { sources.count }
    var needsClarification: Bool { resolution == .needsClarification }
    var hasEvidence: Bool { !sources.isEmpty }
}

/// Deterministic, full-index retrieval for both Library search and Ask.
///
/// The engine deliberately has no storage or network dependencies. It scans every supplied
/// note, applies metadata filters before scoring, and returns every source meeting the configured
/// threshold. Callers can therefore batch the complete result without silently truncating it.
nonisolated struct RetrievalEngine: Sendable {
    struct Configuration: Hashable, Sendable {
        var relevanceThreshold: Double
        var excerptCharacterLimit: Int
        var semanticSimilarityThreshold: Double
        var maximumExcerptPassages: Int

        init(
            relevanceThreshold: Double = 0.44,
            excerptCharacterLimit: Int = 220,
            semanticSimilarityThreshold: Double = 0.68,
            maximumExcerptPassages: Int = 2
        ) {
            self.relevanceThreshold = min(max(relevanceThreshold, 0), 1)
            self.excerptCharacterLimit = max(excerptCharacterLimit, 80)
            self.semanticSimilarityThreshold = min(max(semanticSimilarityThreshold, 0.60), 0.98)
            self.maximumExcerptPassages = min(max(maximumExcerptPassages, 1), 3)
        }
    }

    private struct TokenMatch {
        var strength: Double
        var isExact: Bool
    }

    private struct ScoredNote {
        var note: MindNote
        var score: Double
        var supportType: SourceSupportType
        var matchedTokenCount: Int = 0
        var bestFacetTokenCount: Int = 0
        var bestFacetMatchedTokenCount: Int = 0
        var bestFacetScore: Double = 0
        var matchingTags: [String] = []
        var includesThemeEvidence: Bool = false
        var includesPlaceEvidence: Bool = false
        var contextLabels: Set<String> = []
        var semanticScore: Double = 0
        var semanticPassage: String?
    }

    private struct QueryFacet: Hashable {
        var text: String
        var tokens: [String]
    }

    private struct SemanticPassageRecord {
        var scoredNoteIndex: Int
        var text: String
    }

    private struct ExcerptMatch {
        var range: Range<String.Index>
        var term: String
        var offset: Int
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]
    private static let shortMonthNames = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ]
    private static let queryStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "based", "be", "been", "but", "by",
        "can", "could", "day", "days", "did", "do", "does", "for", "from", "had", "has", "have",
        "how", "i", "in", "into", "is", "it", "know", "me", "my", "note", "notes", "of", "on", "or",
        "our", "past", "plan", "planning", "should", "similar", "that", "the", "their", "then", "these", "this", "to", "us", "was", "we", "were",
        "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your"
    ]

    private static let contextLexicons: [(label: String, keywords: Set<String>)] = [
        (
            "study",
            [
                "assignment", "campus", "chapter", "class", "course", "exam", "faculty", "final", "grade",
                "homework", "lab", "lecture", "paper", "professor", "project", "quiz",
                "research", "review", "school", "semester", "study", "syllabus", "textbook"
            ]
        ),
        (
            "travel",
            [
                "accommodation", "airport", "airbnb", "bus", "flight", "hotel", "hostel", "itinerary", "lodging",
                "luggage", "museum", "neighborhood", "packing", "restaurant", "station",
                "tour", "train", "transit", "travel", "trip", "vacation", "weekend"
            ]
        ),
        (
            "daily life",
            [
                "appointment", "buy", "call", "decision", "doctor", "errand", "groceries",
                "gym", "habit", "laundry", "meeting", "medication", "reminder", "rent",
                "schedule", "todo", "work"
            ]
        )
    ]

    let configuration: Configuration
    private let semanticMatcher: any LocalSemanticMatching

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
        semanticMatcher = AppleNaturalLanguageSemanticMatcher()
    }

    init(relevanceThreshold: Double, excerptCharacterLimit: Int = 220) {
        configuration = .init(
            relevanceThreshold: relevanceThreshold,
            excerptCharacterLimit: excerptCharacterLimit
        )
        semanticMatcher = AppleNaturalLanguageSemanticMatcher()
    }

    init(
        configuration: Configuration = .init(),
        semanticMatcher: any LocalSemanticMatching
    ) {
        self.configuration = configuration
        self.semanticMatcher = semanticMatcher
    }

    /// Ask-oriented retrieval. Single-token prompts are interpreted after filters are applied;
    /// an assumption is stated only when one context clearly dominates.
    func retrieve(
        question: String,
        from notes: [MindNote],
        filters: RetrievalFilters = .init(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> RetrievalResult {
        search(
            query: question,
            in: notes,
            filters: filters,
            now: now,
            calendar: calendar,
            clarifyVagueQuery: true,
            strictAskMatching: true
        )
    }

    /// Full search result, including ambiguity/no-evidence state for Ask.
    func search(
        query: String,
        in notes: [MindNote],
        filters: RetrievalFilters = .init(),
        now: Date = .now,
        calendar: Calendar = .current,
        clarifyVagueQuery: Bool = true,
        strictAskMatching: Bool = false
    ) -> RetrievalResult {
        performSearch(
            query: query,
            notes: notes,
            filters: filters,
            now: now,
            calendar: calendar,
            clarifyVagueQuery: clarifyVagueQuery,
            strictAskMatching: strictAskMatching
        )
    }

    /// Label-compatible convenience for consumers that prefer `notes:query:` ordering.
    func search(
        notes: [MindNote],
        query: String,
        filters: RetrievalFilters = .init(),
        now: Date = .now,
        calendar: Calendar = .current,
        clarifyVagueQuery: Bool = true,
        strictAskMatching: Bool = false
    ) -> RetrievalResult {
        performSearch(
            query: query,
            notes: notes,
            filters: filters,
            now: now,
            calendar: calendar,
            clarifyVagueQuery: clarifyVagueQuery,
            strictAskMatching: strictAskMatching
        )
    }

    /// Library-oriented convenience. It uses the same full-index ranking but never interrupts a
    /// one-word keyword search with Ask's clarification behavior.
    func rankedSources(
        matching query: String,
        in notes: [MindNote],
        filters: RetrievalFilters = .init(),
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SourceReference] {
        search(
            query: query,
            in: notes,
            filters: filters,
            now: now,
            calendar: calendar,
            clarifyVagueQuery: false
        ).sources
    }

    private func performSearch(
        query: String,
        notes: [MindNote],
        filters: RetrievalFilters,
        now: Date,
        calendar: Calendar,
        clarifyVagueQuery: Bool,
        strictAskMatching: Bool
    ) -> RetrievalResult {
        let filteredNotes = notes.filter {
            guard !Task.isCancelled else { return false }
            return matchesFilters($0, filters: filters, now: now, calendar: calendar)
        }
        guard !Task.isCancelled else {
            return cancelledResult(scannedCount: notes.count, filteredCount: filteredNotes.count)
        }
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = Self.uniqueTokens(in: cleanedQuery)
        let queryFacets = Self.explicitQueryFacets(in: cleanedQuery)
        let queryContexts = Self.contextLabels(for: queryTokens)

        if cleanedQuery.isEmpty {
            let sources = filteredNotes
                .map {
                    makeSource(
                        from: .init(
                            note: $0,
                            score: 1,
                            supportType: filters.isActive ? .metadata : .related
                        ),
                        query: "",
                        queryTokens: []
                    )
                }
                .sorted(by: sourceSort)
            return RetrievalResult(
                sources: sources,
                scannedCount: notes.count,
                filteredCount: filteredNotes.count,
                resolution: sources.isEmpty ? .noEvidence : .ready,
                statedAssumption: "",
                clarificationQuestion: ""
            )
        }

        // Punctuation/emoji-only Ask input contains no searchable lexical evidence.
        guard !queryTokens.isEmpty else {
            return RetrievalResult(
                sources: [],
                scannedCount: notes.count,
                filteredCount: filteredNotes.count,
                resolution: .noEvidence,
                statedAssumption: "",
                clarificationQuestion: ""
            )
        }

        let tokenWeights = queryTokenWeights(
            queryTokens,
            in: filteredNotes,
            calendar: calendar,
            strict: strictAskMatching
        )
        guard !Task.isCancelled else {
            return cancelledResult(scannedCount: notes.count, filteredCount: filteredNotes.count)
        }

        var scored: [ScoredNote] = []
        scored.reserveCapacity(filteredNotes.count)
        for note in filteredNotes {
            guard !Task.isCancelled else {
                return cancelledResult(scannedCount: notes.count, filteredCount: filteredNotes.count)
            }
            var candidate = score(
                note: note,
                normalizedQuery: Self.normalized(cleanedQuery),
                queryTokens: queryTokens,
                queryTokenWeights: tokenWeights,
                calendar: calendar,
                strict: strictAskMatching
            )

            if queryFacets.count > 1 {
                let facetScores = queryFacets.map { facet in
                    (
                        facet: facet,
                        result: score(
                        note: note,
                        normalizedQuery: Self.normalized(facet.text),
                        queryTokens: facet.tokens,
                        queryTokenWeights: Dictionary(
                            uniqueKeysWithValues: facet.tokens.map { ($0, tokenWeights[$0] ?? 1) }
                        ),
                        calendar: calendar,
                        strict: strictAskMatching
                        )
                    )
                }
                if let bestFacet = facetScores.max(by: {
                    if abs($0.result.score - $1.result.score) > 0.000_001 {
                        return $0.result.score < $1.result.score
                    }
                    if $0.result.matchedTokenCount != $1.result.matchedTokenCount {
                        return $0.result.matchedTokenCount < $1.result.matchedTokenCount
                    }
                    return $0.facet.text > $1.facet.text
                }) {
                    candidate.bestFacetTokenCount = bestFacet.facet.tokens.count
                    candidate.bestFacetMatchedTokenCount = bestFacet.result.matchedTokenCount
                    candidate.bestFacetScore = bestFacet.result.score
                    candidate.score = max(candidate.score, bestFacet.result.score)
                    if bestFacet.result.supportType == .exactText {
                        candidate.supportType = .exactText
                    }
                    candidate.matchingTags = Array(
                        Set(candidate.matchingTags + bestFacet.result.matchingTags)
                    ).sorted()
                    candidate.includesThemeEvidence = candidate.includesThemeEvidence
                        || bestFacet.result.includesThemeEvidence
                    candidate.includesPlaceEvidence = candidate.includesPlaceEvidence
                        || bestFacet.result.includesPlaceEvidence
                }
            }
            scored.append(candidate)
        }

        var admitted = scored.filter {
            passesLexicalAdmission(
                $0,
                queryTokenCount: queryTokens.count,
                hasExplicitFacets: queryFacets.count > 1,
                strict: strictAskMatching
            )
        }

        let admittedIDs = Set(admitted.map(\.note.id))
        let semanticIndexes = scored.indices.filter { index in
            let candidate = scored[index]
            return !admittedIDs.contains(candidate.note.id)
                && shouldEvaluateSemantic(
                    candidate,
                    queryTokens: queryTokens,
                    queryContexts: queryContexts,
                    filters: filters
                )
        }
        applySemanticMatches(
            to: &scored,
            candidateIndexes: semanticIndexes,
            query: cleanedQuery,
            facets: queryFacets
        )
        guard !Task.isCancelled else {
            return cancelledResult(scannedCount: notes.count, filteredCount: filteredNotes.count)
        }

        admitted.append(contentsOf: semanticIndexes.compactMap { index in
            let candidate = scored[index]
            guard passesSemanticAdmission(
                candidate,
                queryTokens: queryTokens,
                queryContexts: queryContexts,
                filters: filters
            ) else { return nil }
            return candidate
        })

        let sources = admitted
            .map { makeSource(from: $0, query: cleanedQuery, queryTokens: queryTokens) }
            .sorted(by: sourceSort)

        guard !sources.isEmpty else {
            return RetrievalResult(
                sources: [],
                scannedCount: notes.count,
                filteredCount: filteredNotes.count,
                resolution: .noEvidence,
                statedAssumption: "",
                clarificationQuestion: ""
            )
        }

        var resolution = RetrievalResolution.ready
        var assumption = ""
        var clarification = ""

        if clarifyVagueQuery, queryTokens.count == 1 {
            let interpretation = interpretVagueQuery(
                cleanedQuery,
                sources: sources,
                notes: filteredNotes,
                filters: filters
            )
            resolution = interpretation.resolution
            assumption = interpretation.assumption
            clarification = interpretation.clarification
        }

        return RetrievalResult(
            sources: sources,
            scannedCount: notes.count,
            filteredCount: filteredNotes.count,
            resolution: resolution,
            statedAssumption: assumption,
            clarificationQuestion: clarification
        )
    }

    private func matchesFilters(
        _ note: MindNote,
        filters: RetrievalFilters,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if filters.favoritesOnly, !note.isFavorite { return false }

        let tag = Self.normalizedTag(filters.tag)
        if !tag.isEmpty,
           !note.acceptedTags.contains(where: { Self.normalizedTag($0) == tag }) {
            return false
        }

        let place = Self.normalized(filters.place)
        if !place.isEmpty {
            let notePlace = Self.normalized(
                [note.place?.name ?? "", note.place?.detail ?? ""]
                    .joined(separator: " ")
            )
            if !notePlace.contains(place) { return false }
        }

        let theme = Self.normalized(filters.theme)
        if !theme.isEmpty, !Self.normalized(note.tripTheme).contains(theme) { return false }

        let date = note.eventDate ?? note.createdAt
        if !filters.date.includes(date, now: now, calendar: calendar) { return false }

        return true
    }

    private func cancelledResult(scannedCount: Int, filteredCount: Int) -> RetrievalResult {
        RetrievalResult(
            sources: [],
            scannedCount: scannedCount,
            filteredCount: filteredCount,
            resolution: .noEvidence,
            statedAssumption: "",
            clarificationQuestion: ""
        )
    }

    private func passesLexicalAdmission(
        _ candidate: ScoredNote,
        queryTokenCount: Int,
        hasExplicitFacets: Bool,
        strict: Bool
    ) -> Bool {
        guard candidate.score >= configuration.relevanceThreshold else { return false }
        guard strict else { return candidate.matchedTokenCount > 0 }

        // At the network privacy boundary, a multi-concept question normally needs two lexical
        // signals. This prevents one generic or near-prefix word from selecting a sensitive but
        // unrelated note for external processing.
        let requiredMatches = queryTokenCount > 1 ? 2 : 1
        if candidate.matchedTokenCount >= requiredMatches { return true }

        // An explicit clause separator is a user signal that separate notes may answer separate
        // facets (for example, "train and hotel"). Each admitted facet must still meet the normal
        // relevance threshold and carry exact, morphological, or auditable synonym evidence.
        guard hasExplicitFacets, candidate.bestFacetTokenCount > 0 else { return false }
        let requiredFacetMatches = candidate.bestFacetTokenCount > 1 ? 2 : 1
        return candidate.bestFacetMatchedTokenCount >= requiredFacetMatches
            && candidate.bestFacetScore >= configuration.relevanceThreshold
    }

    private func shouldEvaluateSemantic(
        _ candidate: ScoredNote,
        queryTokens: [String],
        queryContexts: Set<String>,
        filters: RetrievalFilters
    ) -> Bool {
        guard !Task.isCancelled, queryTokens.count >= 2 else { return false }
        if filters.isActive || candidate.matchedTokenCount > 0
            || candidate.bestFacetMatchedTokenCount > 0 {
            return true
        }

        guard !queryContexts.isEmpty else { return false }
        return !queryContexts.isDisjoint(with: candidate.contextLabels)
    }

    private func applySemanticMatches(
        to scoredNotes: inout [ScoredNote],
        candidateIndexes: [Int],
        query: String,
        facets: [QueryFacet]
    ) {
        guard !Task.isCancelled, !candidateIndexes.isEmpty else { return }

        var records: [SemanticPassageRecord] = []
        for index in candidateIndexes {
            guard !Task.isCancelled else { return }
            for passage in semanticPassages(for: scoredNotes[index].note) {
                records.append(.init(scoredNoteIndex: index, text: passage))
            }
        }
        guard !records.isEmpty else { return }

        var semanticQueries = [query]
        if facets.count > 1 {
            semanticQueries.append(contentsOf: facets.filter { $0.tokens.count >= 2 }.map(\.text))
        }
        semanticQueries = Self.uniqueNonemptyStrings(semanticQueries)

        let candidateTexts = records.map(\.text)
        for semanticQuery in semanticQueries {
            guard !Task.isCancelled else { return }
            let similarities = semanticMatcher.similarities(
                between: semanticQuery,
                and: candidateTexts
            )
            guard similarities.count == records.count else { continue }

            for (recordIndex, similarity) in similarities.enumerated() {
                guard !Task.isCancelled else { return }
                guard let similarity, similarity.isFinite else { continue }
                let record = records[recordIndex]
                if similarity > scoredNotes[record.scoredNoteIndex].semanticScore + 0.000_001 {
                    scoredNotes[record.scoredNoteIndex].semanticScore = similarity
                    scoredNotes[record.scoredNoteIndex].semanticPassage = record.text
                }
            }
        }

        for index in candidateIndexes {
            let similarity = scoredNotes[index].semanticScore
            guard similarity >= configuration.semanticSimilarityThreshold else { continue }
            // Semantic similarity is a supporting signal, not permission to bypass the configured
            // relevance floor. Its contribution is intentionally discounted below exact text.
            scoredNotes[index].score = max(scoredNotes[index].score, similarity * 0.90)
            if scoredNotes[index].supportType != .metadata {
                scoredNotes[index].supportType = .related
            }
        }
    }

    private func passesSemanticAdmission(
        _ candidate: ScoredNote,
        queryTokens: [String],
        queryContexts: Set<String>,
        filters: RetrievalFilters
    ) -> Bool {
        guard candidate.semanticScore >= configuration.semanticSimilarityThreshold,
              candidate.score >= configuration.relevanceThreshold,
              queryTokens.count >= 2 else { return false }

        let hasLexicalAnchor = candidate.matchedTokenCount > 0
            || candidate.bestFacetMatchedTokenCount > 0
        let hasSharedContext = !queryContexts.isEmpty
            && !queryContexts.isDisjoint(with: candidate.contextLabels)

        // Library search remains local, but uses the same conservative gate so search results do
        // not become noisy. Ask also relies on this gate before an excerpt can cross the external-
        // provider boundary.
        return hasLexicalAnchor || hasSharedContext || filters.isActive
    }

    private func score(
        note: MindNote,
        normalizedQuery: String,
        queryTokens: [String],
        queryTokenWeights: [String: Double],
        calendar: Calendar,
        strict: Bool
    ) -> ScoredNote {
        let title = Self.normalized(note.title)
        let body = Self.normalized(note.body)
        let tags = Self.normalized(note.acceptedTags.joined(separator: " "))
        let theme = Self.normalized(note.tripTheme)
        let place = Self.normalized([note.place?.name ?? "", note.place?.detail ?? ""].joined(separator: " "))
        let date = Self.normalized([
            Self.dateMetadata(for: note.createdAt, calendar: calendar),
            note.eventDate.map { Self.dateMetadata(for: $0, calendar: calendar) } ?? ""
        ].joined(separator: " "))
        let metadata = [tags, theme, place, date].joined(separator: " ")

        let titleTokens = Self.tokens(inNormalizedText: title)
        let bodyTokens = Self.tokens(inNormalizedText: body)
        let tagTokens = Self.tokens(inNormalizedText: tags)
        let themeTokens = Self.tokens(inNormalizedText: theme)
        let placeTokens = Self.tokens(inNormalizedText: place)
        let dateTokens = Self.tokens(inNormalizedText: date)

        var accumulated = 0.0
        var tokenStrengths: [Double] = []
        var textStrength = 0.0
        var metadataStrength = 0.0
        var hasExactTextMatch = false
        var matchedTokenCount = 0
        var matchingTags: Set<String> = []
        var includesThemeEvidence = false
        var includesPlaceEvidence = false
        let totalQueryWeight = queryTokens.reduce(0.0) { $0 + (queryTokenWeights[$1] ?? 1) }
        let maximumQueryWeight = queryTokenWeights.values.max() ?? 1

        for queryToken in queryTokens {
            let titleMatch = Self.bestMatch(for: queryToken, in: titleTokens, strict: strict)
            let bodyMatch = Self.bestMatch(for: queryToken, in: bodyTokens, strict: strict)
            let tagMatch = Self.bestMatch(for: queryToken, in: tagTokens, strict: strict)
            let themeMatch = Self.bestMatch(for: queryToken, in: themeTokens, strict: strict)
            let placeMatch = Self.bestMatch(for: queryToken, in: placeTokens, strict: strict)
            let dateMatch = Self.bestMatch(for: queryToken, in: dateTokens, strict: strict)
            let metadataMatch = [tagMatch, themeMatch, placeMatch, dateMatch]
                .max { $0.strength < $1.strength } ?? .init(strength: 0, isExact: false)
            if tagMatch.strength > 0 {
                for tag in note.acceptedTags {
                    let tokens = Self.tokens(inNormalizedText: Self.normalized(tag))
                    if Self.bestMatch(for: queryToken, in: tokens, strict: strict).strength > 0 {
                        matchingTags.insert(tag)
                    }
                }
            }
            if themeMatch.strength > 0 { includesThemeEvidence = true }
            if placeMatch.strength > 0 { includesPlaceEvidence = true }

            let weightedTitle = titleMatch.strength
            let weightedBody = bodyMatch.strength * 0.94
            let weightedMetadata = metadataMatch.strength * 0.88
            let bestText = max(weightedTitle, weightedBody)

            let strongestForToken = max(bestText, weightedMetadata)
            if strongestForToken > 0 { matchedTokenCount += 1 }
            let tokenWeight = queryTokenWeights[queryToken] ?? 1
            accumulated += strongestForToken * tokenWeight
            tokenStrengths.append(strongestForToken * tokenWeight / maximumQueryWeight)
            textStrength += bestText
            metadataStrength += weightedMetadata
            hasExactTextMatch = hasExactTextMatch
                || titleMatch.isExact
                || bodyMatch.isExact
        }

        // Recall matters more than requiring every word in a natural-language question to appear
        // in a note. Blend the strongest salient match with overall coverage so a representative
        // prompt can retrieve a trip note through "trip" or "Milwaukee" without stopwords and
        // question phrasing diluting the score below the threshold.
        let averageStrength = accumulated / max(totalQueryWeight, 0.000_001)
        let strongestMatch = tokenStrengths.max() ?? 0
        var relevance = strongestMatch * 0.60 + averageStrength * 0.40
        let textPhraseMatch = !normalizedQuery.isEmpty
            && (title.contains(normalizedQuery) || body.contains(normalizedQuery))
        let metadataPhraseMatch = !normalizedQuery.isEmpty && metadata.contains(normalizedQuery)
        if textPhraseMatch {
            relevance += 0.12
            hasExactTextMatch = true
        } else if metadataPhraseMatch {
            relevance += 0.08
        }
        relevance = min(max(relevance, 0), 1)

        let supportType: SourceSupportType
        if hasExactTextMatch {
            supportType = .exactText
        } else if metadataStrength > 0, metadataStrength >= textStrength {
            supportType = .metadata
        } else {
            supportType = .related
        }

        return ScoredNote(
            note: note,
            score: relevance,
            supportType: supportType,
            matchedTokenCount: matchedTokenCount,
            matchingTags: note.acceptedTags.filter { matchingTags.contains($0) },
            includesThemeEvidence: includesThemeEvidence,
            includesPlaceEvidence: includesPlaceEvidence,
            contextLabels: Self.contextLabels(
                for: titleTokens + bodyTokens + tagTokens + themeTokens + placeTokens
            )
        )
    }

    private func queryTokenWeights(
        _ queryTokens: [String],
        in notes: [MindNote],
        calendar: Calendar,
        strict: Bool
    ) -> [String: Double] {
        let documentCount = Double(max(notes.count, 1))
        return Dictionary(uniqueKeysWithValues: queryTokens.map { token in
            let matchingDocuments = notes.reduce(into: 0) { count, note in
                guard !Task.isCancelled else { return }
                let fields = searchableFieldTokens(for: note, calendar: calendar)
                let strength = max(
                    Self.bestMatch(for: token, in: fields.title, strict: strict).strength,
                    Self.bestMatch(for: token, in: fields.body, strict: strict).strength,
                    Self.bestMatch(for: token, in: fields.metadata, strict: strict).strength
                )
                if strength > 0 { count += 1 }
            }
            let inverseDocumentFrequency = log(
                (documentCount + 1) / (Double(matchingDocuments) + 1)
            ) + 1
            return (token, inverseDocumentFrequency)
        })
    }

    private func searchableFieldTokens(
        for note: MindNote,
        calendar: Calendar
    ) -> (title: [String], body: [String], metadata: [String]) {
        let metadata = Self.normalized(
            [
                note.acceptedTags.joined(separator: " "),
                note.tripTheme,
                note.place?.name ?? "",
                note.place?.detail ?? "",
                Self.dateMetadata(for: note.createdAt, calendar: calendar),
                note.eventDate.map { Self.dateMetadata(for: $0, calendar: calendar) } ?? ""
            ].joined(separator: " ")
        )
        return (
            Self.tokens(inNormalizedText: Self.normalized(note.title)),
            Self.tokens(inNormalizedText: Self.normalized(note.body)),
            Self.tokens(inNormalizedText: metadata)
        )
    }

    private func makeSource(
        from scoredNote: ScoredNote,
        query: String,
        queryTokens: [String]
    ) -> SourceReference {
        let note = scoredNote.note
        let displayedExcerpt = contextualizedExcerpt(
            for: note,
            query: query,
            queryTokens: queryTokens,
            semanticPassage: scoredNote.semanticPassage,
            matchingTags: scoredNote.matchingTags,
            includeTheme: scoredNote.includesThemeEvidence,
            includePlace: scoredNote.includesPlaceEvidence
        )
        return SourceReference(
            id: note.id,
            noteID: note.id,
            noteTitle: note.displayTitle,
            noteDate: note.eventDate ?? note.createdAt,
            excerpt: displayedExcerpt,
            score: scoredNote.score,
            supportType: scoredNote.supportType
        )
    }

    private func contextualizedExcerpt(
        for note: MindNote,
        query: String,
        queryTokens: [String],
        semanticPassage: String?,
        matchingTags: [String],
        includeTheme: Bool,
        includePlace: Bool
    ) -> String {
        var context: [String] = [
            "date: \((note.eventDate ?? note.createdAt).formatted(date: .abbreviated, time: .omitted))"
        ]
        if !matchingTags.isEmpty {
            context.append("tags: \(matchingTags.joined(separator: ", "))")
        }
        if includeTheme {
            let theme = note.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !theme.isEmpty { context.append("theme: \(theme)") }
        }
        if includePlace {
            if let place = note.place {
                let name = privacySafeLocationText(place.name, place: place)
                let detail = privacySafeLocationText(place.detail, place: place)
                if !name.isEmpty || !detail.isEmpty {
                    context.append("place: \([name, detail].filter { !$0.isEmpty }.joined(separator: " — "))")
                }
            }
        }

        let limit = configuration.excerptCharacterLimit
        let labels = "Saved context — \nNote excerpt — "
        let minimumBodyBudget = max(30, min(120, limit / 2))
        let contextBudget = max(0, limit - labels.count - minimumBodyBudget)
        var contextText = context.joined(separator: "; ")
        if contextText.count > contextBudget {
            contextText = String(contextText.prefix(max(contextBudget - 1, 0))) + (contextBudget > 0 ? "…" : "")
        }
        let prefix = "Saved context — \(contextText)\nNote excerpt — "
        let bodyBudget = max(0, limit - prefix.count)
        let body = excerpt(
            for: note,
            query: query,
            queryTokens: queryTokens,
            semanticPassage: semanticPassage,
            characterLimit: bodyBudget
        )
        return prefix + body
    }

    /// Place labels remain searchable and visible, but coordinate-like text is deliberately
    /// omitted from the excerpt that can leave the device. Latitude/longitude fields stay local
    /// for map display and note editing.
    private func privacySafeLocationText(_ value: String, place: SavedPlace) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let coordinatePairPattern = #"[-+]?\d{1,3}(?:\.\d+)?\s*[,;/]\s*[-+]?\d{1,3}(?:\.\d+)?"#
        let whitespaceCoordinatePairPattern = #"(?<!\d)[-+]?\d{1,2}\.\d{3,}\s+[-+]?\d{1,3}\.\d{3,}(?!\d)"#
        let labeledCoordinatePattern = #"(?i)\b(?:lat(?:itude)?|lon(?:gitude)?)\b\s*[:=]?\s*[-+]?\d{1,3}(?:\.\d+)?"#
        let containsStoredCoordinatePair = (2...8).first { precision in
            let latitude = String(format: "%.*f", precision, place.latitude)
            let longitude = String(format: "%.*f", precision, place.longitude)
            return cleaned.contains(latitude) && cleaned.contains(longitude)
        } != nil
        guard !containsStoredCoordinatePair,
              cleaned.range(of: coordinatePairPattern, options: .regularExpression) == nil,
              cleaned.range(of: whitespaceCoordinatePairPattern, options: .regularExpression) == nil,
              cleaned.range(of: labeledCoordinatePattern, options: .regularExpression) == nil else {
            return ""
        }
        return cleaned
    }

    private func semanticPassages(for note: MindNote) -> [String] {
        var passages: [String] = []
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { passages.append(title) }
        passages.append(contentsOf: Self.boundedSemanticSegments(in: note.body))

        var seen: Set<String> = []
        let unique = passages.filter {
            let key = Self.normalized($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
        let maximumPassages = 12
        guard unique.count > maximumPassages else { return unique }

        // Sample deterministically across the complete note rather than taking only its beginning.
        // Exact lexical matches still scan the entire body; this cap bounds embedding work for very
        // long notes while giving early, middle, and late passages equal opportunity.
        var sampled: [String] = []
        var sampledIndexes: Set<Int> = []
        for position in 0..<maximumPassages {
            guard !Task.isCancelled else { break }
            let fraction = Double(position) / Double(maximumPassages - 1)
            let index = Int((fraction * Double(unique.count - 1)).rounded())
            if sampledIndexes.insert(index).inserted {
                sampled.append(unique[index])
            }
        }
        return sampled
    }

    private static func boundedSemanticSegments(
        in text: String,
        characterLimit: Int = 360
    ) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var segments: [String] = []
        var start = cleaned.startIndex
        var index = cleaned.startIndex
        var count = 0

        func appendSegment(endingAt end: String.Index) {
            guard start < end else { return }
            let segment = String(cleaned[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append(segment) }
        }

        while index < cleaned.endIndex {
            guard !Task.isCancelled else { break }
            let character = cleaned[index]
            let next = cleaned.index(after: index)
            count += 1
            let isNaturalBoundary = character == "."
                || character == "!"
                || character == "?"
                || character.isNewline
            let reachedLimit = count >= characterLimit
            if isNaturalBoundary || reachedLimit {
                appendSegment(endingAt: next)
                start = next
                count = 0
            }
            index = next
        }
        appendSegment(endingAt: cleaned.endIndex)
        return segments
    }

    private func excerpt(
        for note: MindNote,
        query: String,
        queryTokens: [String],
        semanticPassage: String? = nil,
        characterLimit: Int? = nil
    ) -> String {
        let limit = max(characterLimit ?? configuration.excerptCharacterLimit, 0)
        guard limit > 0 else { return "" }
        let orderedTerms = ([query] + queryTokens.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var matches = excerptMatches(in: note.body, terms: orderedTerms)
        if matches.isEmpty,
           let semanticPassage,
           let range = note.body.range(of: semanticPassage) {
            matches = [
                ExcerptMatch(
                    range: range,
                    term: semanticPassage,
                    offset: note.body.distance(from: note.body.startIndex, to: range.lowerBound)
                )
            ]
        }

        let selectedMatches = selectDiverseMatches(matches, characterLimit: limit)
        if !selectedMatches.isEmpty {
            let separator = "\n…\n"
            let available = max(1, limit - separator.count * (selectedMatches.count - 1))
            let passageLimit = max(1, available / selectedMatches.count)
            let passages = selectedMatches.map {
                excerptWindow(in: note.body, around: $0.range, characterLimit: passageLimit)
            }
            let combined = passages.joined(separator: separator)
            return bounded(combined, characterLimit: limit)
        }

        if let match = excerptMatches(in: note.title, terms: orderedTerms).first {
            return excerptWindow(in: note.title, around: match.range, characterLimit: limit)
        }

        let fallback = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? note.displayTitle
            : note.body
        return excerptWindow(in: fallback, around: nil, characterLimit: limit)
    }

    private func excerptMatches(in text: String, terms: [String]) -> [ExcerptMatch] {
        var matches: [ExcerptMatch] = []
        var seenTerms: Set<String> = []
        for term in terms {
            guard !Task.isCancelled else { break }
            let normalizedTerm = Self.normalized(term)
            guard !normalizedTerm.isEmpty, seenTerms.insert(normalizedTerm).inserted else { continue }
            if let range = text.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Self.posixLocale
            ) {
                matches.append(
                    ExcerptMatch(
                        range: range,
                        term: normalizedTerm,
                        offset: text.distance(from: text.startIndex, to: range.lowerBound)
                    )
                )
            }
        }
        return matches
    }

    private func selectDiverseMatches(
        _ matches: [ExcerptMatch],
        characterLimit: Int
    ) -> [ExcerptMatch] {
        guard let first = matches.first else { return [] }
        guard configuration.maximumExcerptPassages > 1,
              characterLimit >= 100 else { return [first] }

        var selected = [first]
        var selectedTerms: Set<String> = [first.term]
        let minimumDistance = max(40, characterLimit / configuration.maximumExcerptPassages)
        for match in matches.dropFirst() {
            guard !Task.isCancelled else { break }
            guard !selectedTerms.contains(match.term),
                  selected.allSatisfy({ abs($0.offset - match.offset) >= minimumDistance }) else {
                continue
            }
            selected.append(match)
            selectedTerms.insert(match.term)
            if selected.count == configuration.maximumExcerptPassages { break }
        }
        return selected.sorted { $0.offset < $1.offset }
    }

    private func excerptWindow(
        in text: String,
        around match: Range<String.Index>?,
        characterLimit: Int
    ) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard characterLimit > 0 else { return "" }
        guard cleaned.count > characterLimit else { return cleaned }

        let actualMatch = match ?? text.startIndex..<text.startIndex
        let matchOffset = text.distance(from: text.startIndex, to: actualMatch.lowerBound)
        let halfWindow = characterLimit / 2
        let preferredStart = max(0, matchOffset - halfWindow)
        var lower = text.index(text.startIndex, offsetBy: preferredStart)
        var upper = text.index(
            lower,
            offsetBy: characterLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        // Avoid beginning or ending in the middle of a word when a nearby boundary exists.
        if lower != text.startIndex {
            let boundaryLimit = text.index(lower, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
            while lower < boundaryLimit,
                  lower < text.endIndex,
                  !text[lower].isWhitespace {
                lower = text.index(after: lower)
            }
            while lower < text.endIndex, text[lower].isWhitespace {
                lower = text.index(after: lower)
            }
        }
        if upper != text.endIndex {
            let boundaryLimit = text.index(upper, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
            while upper > boundaryLimit,
                  upper > lower,
                  !text[text.index(before: upper)].isWhitespace {
                upper = text.index(before: upper)
            }
        }

        var excerpt = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower != text.startIndex { excerpt = "…" + excerpt }
        if upper != text.endIndex { excerpt += "…" }
        return bounded(excerpt, characterLimit: characterLimit)
    }

    private func bounded(_ value: String, characterLimit: Int) -> String {
        guard characterLimit > 0 else { return "" }
        guard value.count > characterLimit else { return value }
        guard characterLimit > 1 else { return "…" }
        return String(value.prefix(characterLimit - 1)) + "…"
    }

    private func sourceSort(_ lhs: SourceReference, _ rhs: SourceReference) -> Bool {
        if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
        if lhs.noteDate != rhs.noteDate { return lhs.noteDate > rhs.noteDate }
        return lhs.noteID.uuidString < rhs.noteID.uuidString
    }

    private func interpretVagueQuery(
        _ query: String,
        sources: [SourceReference],
        notes: [MindNote],
        filters: RetrievalFilters
    ) -> (resolution: RetrievalResolution, assumption: String, clarification: String) {
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var contextWeights: [String: Double] = [:]
        for source in sources {
            guard let note = notesByID[source.noteID],
                  let context = primaryContext(for: note, excluding: query) else { continue }
            contextWeights[context, default: 0] += max(source.score, 0.1)
        }

        let rankedContexts = contextWeights.sorted {
            if abs($0.value - $1.value) > 0.000_001 { return $0.value > $1.value }
            return $0.key < $1.key
        }
        guard let first = rankedContexts.first else {
            return (
                .needsClarification,
                "",
                "What would you like to know about “\(query)” in these \(sources.count) matching notes?"
            )
        }

        let total = rankedContexts.reduce(0.0) { $0 + $1.value }
        let secondWeight = rankedContexts.dropFirst().first?.value ?? 0
        let clearlyDominant = rankedContexts.count == 1
            || (first.value / max(total, 0.000_001) >= 0.60
                && first.value >= secondWeight * 1.5)

        if clearlyDominant {
            let filterContext = filters.isActive
                ? " among notes matching \(filterDescription(filters))"
                : ""
            return (
                .ready,
                "Assuming you mean “\(query)” in the context of \(first.key)\(filterContext), based on your notes.",
                ""
            )
        }

        let options = rankedContexts.prefix(3).map { $0.key }
        return (
            .needsClarification,
            "",
            clarificationQuestion(for: query, options: options)
        )
    }

    private func filterDescription(_ filters: RetrievalFilters) -> String {
        var parts: [String] = []
        let tag = filters.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = filters.place.trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = filters.theme.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty { parts.append("the “\(tag)” tag") }
        if filters.date != .any { parts.append(filters.date.rawValue.lowercased()) }
        if !place.isEmpty { parts.append("the place “\(place)”") }
        if !theme.isEmpty { parts.append("the theme “\(theme)”") }
        if filters.favoritesOnly { parts.append("favorite notes") }

        guard !parts.isEmpty else { return "your active filters" }
        if parts.count == 1 { return parts[0] }
        if parts.count == 2 { return parts.joined(separator: " and ") }
        return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "the active filters")
    }

    private func primaryContext(for note: MindNote, excluding query: String) -> String? {
        let text = Self.normalized(note.searchableText)
        let noteTokens = Set(Self.tokens(inNormalizedText: text))
        let scoredContexts = Self.contextLexicons.map { lexicon in
            (
                label: lexicon.label,
                score: lexicon.keywords.reduce(0) { count, keyword in
                    count + (noteTokens.contains(keyword) ? 1 : 0)
                }
            )
        }.filter { $0.score > 0 }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.label < $1.label
        }

        if let strongest = scoredContexts.first { return strongest.label }

        let excluded = Self.normalizedTag(query)
        let metadataLabels = note.acceptedTags
            + [note.tripTheme, note.place?.name ?? ""]
        return metadataLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first {
                !$0.isEmpty && Self.normalizedTag($0) != excluded
            }
    }

    private func clarificationQuestion(for query: String, options: [String]) -> String {
        guard !options.isEmpty else {
            return "What would you like to know about “\(query)” in your notes?"
        }
        if options.count == 1 {
            return "What would you like to know about “\(query)” for \(options[0])?"
        }
        if options.count == 2 {
            return "Do you mean “\(query)” for \(options[0]) or \(options[1])?"
        }
        return "Do you mean “\(query)” for \(options[0]), \(options[1]), or \(options[2])?"
    }

    private static func bestMatch(
        for queryToken: String,
        in fieldTokens: [String],
        strict: Bool = false
    ) -> TokenMatch {
        guard !queryToken.isEmpty else { return .init(strength: 0, isExact: false) }
        if fieldTokens.contains(queryToken) { return .init(strength: 1, isExact: true) }

        if strict {
            let queryRoot = morphologyRoot(queryToken)
            if fieldTokens.contains(where: { morphologyRoot($0) == queryRoot }) {
                return .init(strength: 0.93, isExact: false)
            }
            let semanticRoots = semanticRoots(for: queryRoot)
            if !semanticRoots.isEmpty,
               fieldTokens.contains(where: { semanticRoots.contains(morphologyRoot($0)) }) {
                return .init(strength: 0.86, isExact: false)
            }
            return .init(strength: 0, isExact: false)
        }

        guard queryToken.count >= 3 else { return .init(strength: 0, isExact: false) }
        for fieldToken in fieldTokens {
            let shorterCount = min(queryToken.count, fieldToken.count)
            if shorterCount >= 3,
               (fieldToken.hasPrefix(queryToken) || queryToken.hasPrefix(fieldToken)) {
                return .init(strength: 0.78, isExact: false)
            }
        }

        guard queryToken.count >= 4 else { return .init(strength: 0, isExact: false) }
        for fieldToken in fieldTokens where fieldToken.count >= 4 {
            if fieldToken.contains(queryToken) || queryToken.contains(fieldToken) {
                return .init(strength: 0.62, isExact: false)
            }
        }
        return .init(strength: 0, isExact: false)
    }

    private static func morphologyRoot(_ token: String) -> String {
        guard token.count > 3 else { return token }
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("ing"), token.count > 5 {
            var root = String(token.dropLast(3))
            if root.count > 3, root.last == root.dropLast().last {
                root.removeLast()
            }
            return root
        }
        if token.hasSuffix("ed"), token.count > 4 {
            var root = String(token.dropLast(2))
            if root.count > 3, root.last == root.dropLast().last {
                root.removeLast()
            }
            return root
        }
        if token.hasSuffix("es"), token.count > 4 {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    /// Small, auditable on-device concept groups cover common natural-language paraphrases
    /// without embeddings, a network call, or permissive prefix matching at the privacy boundary.
    private static func semanticRoots(for token: String) -> Set<String> {
        for group in semanticConceptGroups {
            let roots = Set(group.map(morphologyRoot))
            if roots.contains(token) { return roots }
        }
        return []
    }

    private static let semanticConceptGroups: [Set<String>] = [
        ["accommodation", "hostel", "hotel", "lodging", "room", "stay"],
        ["affordable", "budget", "cheap", "cost", "expense", "paid", "price"],
        ["airline", "flight", "plane"],
        ["metro", "rail", "subway", "train"],
        ["trip", "travel", "vacation", "weekend"],
        ["dining", "food", "meal", "restaurant"],
        ["exam", "final", "quiz", "test"],
        ["instructor", "professor", "teacher"],
        ["appointment", "visit"],
        ["deadline", "due"],
        ["address", "location", "place"],
        ["book", "booking", "reserv", "reserve", "reservation"],
        ["prepar", "prepare", "review", "study"],
        ["assignment", "essay", "paper", "project"],
        ["depart", "departure", "leave"],
        ["arrive", "arrival", "reach"]
    ]

    private static func explicitQueryFacets(in query: String) -> [QueryFacet] {
        let separators = #"(?i)(?:\s*;\s*|\s*\n+\s*|\b(?:and|also|plus|then|versus|vs\.?)\b)"#
        let separated = query.replacingOccurrences(
            of: separators,
            with: "|",
            options: .regularExpression
        )
        var seen: Set<[String]> = []
        let facets = separated.split(separator: "|").compactMap { raw -> QueryFacet? in
            let text = String(raw).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let tokens = uniqueTokens(in: text)
            guard !tokens.isEmpty, seen.insert(tokens).inserted else { return nil }
            return QueryFacet(text: text, tokens: tokens)
        }
        guard facets.count > 1 else { return [] }
        return Array(facets.prefix(4))
    }

    private static func contextLabels(for tokens: [String]) -> Set<String> {
        let roots = Set(tokens.map(morphologyRoot))
        return Set(contextRootLexicons.compactMap { lexicon in
            roots.isDisjoint(with: lexicon.roots) ? nil : lexicon.label
        })
    }

    private static let contextRootLexicons: [(label: String, roots: Set<String>)] =
        contextLexicons.map { lexicon in
            (lexicon.label, Set(lexicon.keywords.map(morphologyRoot)))
        }

    private static func uniqueNonemptyStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return cleaned
        }
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: posixLocale
        )
        return tokens(inFoldedText: folded).joined(separator: " ")
    }

    private static func normalizedTag(_ value: String) -> String {
        normalized(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func uniqueTokens(in value: String) -> [String] {
        var seen: Set<String> = []
        return tokens(inNormalizedText: normalized(value)).filter {
            !queryStopWords.contains($0) && seen.insert($0).inserted
        }
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

    private static func dateMetadata(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        var parts = [
            String(year),
            String(month),
            String(day),
            String(format: "%04d-%02d-%02d", year, month, day)
        ]
        if (1...12).contains(month) {
            parts.append(monthNames[month - 1])
            parts.append(shortMonthNames[month - 1])
        }
        return parts.joined(separator: " ")
    }
}
