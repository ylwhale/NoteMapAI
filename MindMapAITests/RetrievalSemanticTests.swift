import Foundation
import Testing
@testable import MindMapAI

nonisolated private struct KeywordSemanticMatcher: LocalSemanticMatching {
    var markers: [String]
    var matchingScore: Double = 0.93

    func similarities(between query: String, and candidates: [String]) -> [Double?] {
        candidates.map { candidate in
            markers.contains(where: {
                candidate.localizedCaseInsensitiveContains($0)
            }) ? matchingScore : 0.10
        }
    }
}

nonisolated private struct UnavailableSemanticMatcher: LocalSemanticMatching {
    func similarities(between query: String, and candidates: [String]) -> [Double?] {
        Array(repeating: nil, count: candidates.count)
    }
}

@MainActor
struct RetrievalSemanticTests {
    @Test("High-confidence local semantics recover a related note behind the privacy gate")
    func semanticRecoveryIsConservative() {
        let relevant = MindNote(
            title: "Lecture summary",
            body: "Review chapters four and five before Friday.",
            acceptedTags: ["study"]
        )
        let unrelated = MindNote(
            title: "Health",
            body: "Private cardiology appointment details.",
            acceptedTags: ["health"]
        )
        let engine = RetrievalEngine(
            configuration: .init(semanticSimilarityThreshold: 0.82),
            semanticMatcher: KeywordSemanticMatcher(markers: ["chapters four"])
        )

        let result = engine.retrieve(
            question: "What is my course strategy?",
            from: [unrelated, relevant]
        )

        #expect(result.sources.map(\.noteID) == [relevant.id])
        #expect(result.sources.first?.supportType == .related)
        #expect(result.sources.first?.excerpt.localizedCaseInsensitiveContains("chapters four") == true)
    }

    @Test("The auditable synonym fallback works when an embedding is unavailable")
    func deterministicSynonymFallback() {
        let note = MindNote(body: "Hotel: Hilton. The cost was $148 after fees.")
        let engine = RetrievalEngine(
            semanticMatcher: UnavailableSemanticMatcher()
        )

        let result = engine.retrieve(
            question: "Which lodging was affordable?",
            from: [note]
        )

        #expect(result.sources.map(\.noteID) == [note.id])
    }

    @Test("A single exact-text match does not trigger unnecessary clarification")
    func preciseQuestionUsesExactMatch() {
        let now = Date(timeIntervalSince1970: 1_787_846_400)
        let note = MindNote(
            body: "OrionExam is scheduled in room 204 on Friday.",
            createdAt: now,
            updatedAt: now
        )
        let result = RetrievalEngine(
            semanticMatcher: UnavailableSemanticMatcher()
        ).retrieve(
            question: "Where is OrionExam scheduled?",
            from: [note],
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(result.sources.map(\.noteID) == [note.id])
        #expect(result.resolution == .ready)
        #expect(result.clarificationQuestion.isEmpty)
    }

    @Test("Explicit query facets can retrieve separate notes without weakening unsplit queries")
    func multiTopicDecomposition() {
        let train = MindNote(body: "The train departs from Union Station at 10:40 PM.")
        let hotel = MindNote(body: "The Hilton hotel booking is confirmed.")
        let unrelated = MindNote(body: "Private cardiology appointment details.")
        let engine = RetrievalEngine(semanticMatcher: UnavailableSemanticMatcher())

        let decomposed = engine.retrieve(
            question: "When is the train and which hotel did we reserve?",
            from: [unrelated, hotel, train]
        )
        #expect(Set(decomposed.sources.map(\.noteID)) == Set([train.id, hotel.id]))

        let unsplit = engine.retrieve(
            question: "train hotel",
            from: [train]
        )
        #expect(unsplit.sources.isEmpty)
    }

    @Test("A long note can expose two distant relevant passages inside one strict bound")
    func multipleBoundedExcerpts() throws {
        let filler = String(
            repeating: "This middle section contains unrelated background details. ",
            count: 18
        )
        let note = MindNote(
            body: "The train leaves Union Station at 10:40 PM. \(filler)Hotel check-in begins at 3:00 PM."
        )
        let engine = RetrievalEngine(
            configuration: .init(
                excerptCharacterLimit: 320,
                maximumExcerptPassages: 2
            ),
            semanticMatcher: UnavailableSemanticMatcher()
        )

        let source = try #require(
            engine.retrieve(question: "train and hotel", from: [note]).sources.first
        )
        #expect(source.excerpt.count <= 320)
        #expect(source.excerpt.localizedCaseInsensitiveContains("train leaves"))
        #expect(source.excerpt.localizedCaseInsensitiveContains("hotel check-in"))
        #expect(source.excerpt.contains("\n…\n"))
    }

    @Test("Metadata filters run before semantic scoring and coordinates remain excluded")
    func filterFirstSemanticRetrieval() throws {
        let paris = SavedPlace(
            name: "Paris",
            detail: "48.856600 2.352200",
            latitude: 48.8566,
            longitude: 2.3522
        )
        let chicago = SavedPlace(
            name: "Chicago",
            detail: "41.878100 -87.629800",
            latitude: 41.8781,
            longitude: -87.6298
        )
        let parisNote = MindNote(
            body: "Review the itinerary and prepare the course materials.",
            place: paris
        )
        let chicagoNote = MindNote(
            body: "Review the itinerary and prepare the course materials.",
            place: chicago
        )
        let engine = RetrievalEngine(
            semanticMatcher: KeywordSemanticMatcher(markers: ["course materials"])
        )

        let result = engine.retrieve(
            question: "What is my class strategy?",
            from: [chicagoNote, parisNote],
            filters: RetrievalFilters(place: "Paris")
        )
        let source = try #require(result.sources.first)
        #expect(result.filteredCount == 1)
        #expect(result.sources.map(\.noteID) == [parisNote.id])
        #expect(source.excerpt.contains("48.856600") == false)
        #expect(source.excerpt.contains("2.352200") == false)
    }

    @Test("Semantic ties and pre-cancelled work remain deterministic")
    func deterministicTieAndCancellation() async {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = MindNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "First",
            body: "Review chapter one.",
            createdAt: timestamp,
            updatedAt: timestamp,
            acceptedTags: ["study"]
        )
        let second = MindNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Second",
            body: "Review chapter two.",
            createdAt: timestamp,
            updatedAt: timestamp,
            acceptedTags: ["study"]
        )
        let engine = RetrievalEngine(
            semanticMatcher: KeywordSemanticMatcher(markers: ["Review chapter"])
        )

        let firstRun = engine.retrieve(question: "course strategy", from: [second, first])
        let secondRun = engine.retrieve(question: "course strategy", from: [first, second])
        #expect(firstRun.sources.map(\.noteID) == [first.id, second.id])
        #expect(secondRun.sources.map(\.noteID) == firstRun.sources.map(\.noteID))

        let cancelled = Task { () -> RetrievalResult in
            withUnsafeCurrentTask { task in task?.cancel() }
            return engine.retrieve(question: "course strategy", from: [first, second])
        }
        let cancelledResult = await cancelled.value
        #expect(cancelledResult.sources.isEmpty)
        #expect(cancelledResult.resolution == .noEvidence)
    }
}
