import Foundation

enum MindMapTab: Hashable {
    case home
    case library
    case ask
    case plans
    case settings
}

nonisolated struct SavedPlace: Codable, Hashable, Sendable {
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double

    var coordinateDescription: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

nonisolated struct MindNote: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var captureSessionID: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var eventDate: Date?
    var place: SavedPlace?
    var acceptedTags: [String]
    var tripTheme: String
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        captureSessionID: UUID = UUID(),
        title: String = "",
        body: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        eventDate: Date? = nil,
        place: SavedPlace? = nil,
        acceptedTags: [String] = [],
        tripTheme: String = "",
        isFavorite: Bool = false
    ) {
        self.id = id
        self.captureSessionID = captureSessionID
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.eventDate = eventDate
        self.place = place
        self.acceptedTags = acceptedTags
        self.tripTheme = tripTheme
        self.isFavorite = isFavorite
    }

    var displayTitle: String {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty { return cleanedTitle }

        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.count <= 54 { return firstLine.isEmpty ? "Untitled note" : firstLine }
        return String(firstLine.prefix(51)) + "..."
    }

    var searchableText: String {
        [title, body, acceptedTags.joined(separator: " "), tripTheme, place?.name ?? "", place?.detail ?? ""]
            .joined(separator: " ")
    }
}

enum TagSuggestionDecision: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case ignored
}

struct TagSuggestion: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var noteID: UUID
    var tags: [String]
    var createdAt: Date = .now
    var decision: TagSuggestionDecision = .pending
}

nonisolated enum DateFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case any = "Any time"
    case today = "Today"
    case sevenDays = "Past 7 days"
    case thirtyDays = "Past 30 days"

    var id: String { rawValue }

    func includes(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            return date <= now
                && date >= (calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast)
        case .thirtyDays:
            return date <= now
                && date >= (calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast)
        }
    }
}

nonisolated struct RetrievalFilters: Codable, Hashable, Sendable {
    var tag: String = ""
    var date: DateFilter = .any
    var place: String = ""
    var theme: String = ""
    var favoritesOnly: Bool = false

    var isActive: Bool {
        !tag.isEmpty || date != .any || !place.isEmpty || !theme.isEmpty || favoritesOnly
    }
}

nonisolated enum SourceSupportType: String, Codable, Sendable {
    case exactText = "Exact text"
    case metadata = "Context match"
    case related = "Related note"
}

nonisolated struct SourceReference: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var noteID: UUID
    var noteTitle: String
    var noteDate: Date
    var excerpt: String
    var score: Double
    var supportType: SourceSupportType
}

nonisolated struct ClaimEvidence: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sourceNoteID: UUID
    var quote: String
}

/// Distinguishes content copied from a user's notes from guidance proposed by the AI.
/// Raw values are stable because the origin is persisted with saved plan steps.
nonisolated enum AIContentOrigin: String, Codable, Hashable, Sendable {
    case sourceBacked = "source_backed"
    case generatedGuidance = "generated_guidance"
}

nonisolated struct GroundedAnswerPart: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var origin: AIContentOrigin
    var evidence: [ClaimEvidence]
}

nonisolated struct GroundedClaim: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var evidence: [ClaimEvidence]
}

nonisolated struct GroundedConflict: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var sourceNoteIDs: [UUID]
}

nonisolated struct SuggestedPlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var sourceNoteIDs: [UUID]
    /// Optional so conclusions encoded before step-level provenance continue to decode.
    var origin: AIContentOrigin? = nil
    /// Exact, validator-approved excerpts that explain this step. `nil` represents a legacy
    /// conclusion; newly generated steps always carry at least one item.
    var evidence: [ClaimEvidence]? = nil
}

nonisolated struct GroundedConclusion: Codable, Hashable, Sendable {
    var directAnswer: String
    var answerEvidence: [ClaimEvidence]
    var claims: [GroundedClaim]
    var conflicts: [GroundedConflict]
    var missingInformation: [String]
    var suggestedChecklist: [SuggestedPlanItem]
    var statedAssumption: String
    /// Optional so previously encoded conclusions remain readable. New provider results always
    /// preserve their validated, ordered parts here instead of flattening provenance away.
    var answerParts: [GroundedAnswerPart]? = nil

    var resolvedAnswerParts: [GroundedAnswerPart] {
        if let answerParts, !answerParts.isEmpty {
            return answerParts
        }

        let cleaned = directAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return [
            GroundedAnswerPart(
                text: cleaned,
                origin: .sourceBacked,
                evidence: answerEvidence
            )
        ]
    }

    var allReferencedNoteIDs: [UUID] {
        var ordered: [UUID] = []
        let directAnswerIDs: [UUID] = answerEvidence.map(\.sourceNoteID)
        let answerPartIDs: [UUID] = (answerParts ?? []).flatMap { part in
            part.evidence.map(\.sourceNoteID)
        }
        let claimIDs: [UUID] = claims.flatMap { claim in
            claim.evidence.map(\.sourceNoteID)
        }
        let conflictIDs: [UUID] = conflicts.flatMap(\.sourceNoteIDs)
        let checklistIDs: [UUID] = suggestedChecklist.flatMap(\.sourceNoteIDs)
        let checklistEvidenceIDs: [UUID] = suggestedChecklist.flatMap { item in
            (item.evidence ?? []).map(\.sourceNoteID)
        }
        let candidates = directAnswerIDs
            + answerPartIDs
            + claimIDs
            + conflictIDs
            + checklistIDs
            + checklistEvidenceIDs
        for id in candidates where !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }
}

enum AskPhase: String, Codable, Sendable {
    case idle
    case searching
    case batching
    case awaitingConsent
    case generating
    case complete
    case needsClarification
    case noEvidence
    case offline
    case providerUnavailable
    case failed
    case cancelled

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .searching: return "Searching your library"
        case .batching: return "Checking every relevant note"
        case .awaitingConsent: return "Review AI processing"
        case .generating: return "Building a grounded conclusion"
        case .complete: return "Conclusion ready"
        case .needsClarification: return "One detail needed"
        case .noEvidence: return "Not enough evidence"
        case .offline: return "Offline"
        case .providerUnavailable: return "AI provider unavailable"
        case .failed: return "Could not finish"
        case .cancelled: return "Cancelled"
        }
    }
}

struct AskSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var question: String
    var filters: RetrievalFilters
    var phase: AskPhase = .idle
    var sources: [SourceReference] = []
    var relevantTotal: Int = 0
    var processedTotal: Int = 0
    var processingLimitMessage: String = ""
    var retrievalAssumption: String = ""
    var clarificationQuestion: String = ""
    var errorMessage: String = ""
    var conclusion: GroundedConclusion?
}

struct CaptureDraft: Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var eventDate: Date?
    var tripTheme: String = ""

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tripTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && eventDate == nil
    }
}

struct AskDraft: Codable, Hashable, Sendable {
    var question: String = ""
    var filters: RetrievalFilters = .init()
}

enum AIProcessingConsent: String, Codable, Sendable {
    case undecided
    case accepted
    case declined
}

struct MindMapPreferences: Codable, Hashable, Sendable {
    var aiProcessingConsent: AIProcessingConsent = .undecided
    var locationCaptureEnabled: Bool = true
    var keepLocalHistory: Bool = true
    var aiModel: String = "gpt-5.6-luna"
    var captureDraft: CaptureDraft = .init()
    var askDraft: AskDraft = .init()
}

struct PlanChecklistItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var isComplete: Bool = false
    var sourceNoteIDs: [UUID] = []
    /// `nil` represents a legacy or user-added step. New AI-created steps persist their exact
    /// validated origin without changing the decoding of existing archives.
    var origin: AIContentOrigin? = nil
    /// `nil` represents a legacy or user-added step. New AI-created steps keep exact quotes
    /// keyed to the plan's durable source links.
    var citations: [PlanStepCitation]? = nil
}

struct PlanSourceLink: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var noteID: UUID?
    var titleAtSave: String
    var noteDate: Date
    var updatedAtSave: Date
}

/// An exact excerpt retained with a saved answer. It points at the plan's durable source link;
/// deleting the linked note scrubs the quote while leaving a content-free source tombstone.
struct PlanAnswerCitation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sourceLinkID: UUID
    var quote: String
}

struct PlanStepCitation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sourceLinkID: UUID
    var quote: String
}

struct PlanAnswerPart: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var text: String
    var origin: AIContentOrigin
    var citations: [PlanAnswerCitation]
}

struct MindPlan: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var conclusion: String
    /// Optional so plan archives written before sentence-level provenance continue to decode.
    var answerParts: [PlanAnswerPart]? = nil
    var checklist: [PlanChecklistItem]
    var date: Date?
    var place: String
    var sources: [PlanSourceLink]
    var createdAt: Date = .now
    var updatedAt: Date = .now
    /// `isAIGenerated` records immutable origin. This optional edit flag preserves decoding of
    /// archives created before origin and edit state were separated.
    var isAIGenerated: Bool = true
    var hasUserEdits: Bool? = nil

    var hasBeenUserEdited: Bool {
        hasUserEdits ?? !isAIGenerated
    }

    var provenanceLabel: String {
        if isAIGenerated {
            return hasBeenUserEdited ? "AI-generated · user edited" : "AI-generated draft"
        }
        return hasBeenUserEdited ? "User-edited plan" : "User-created plan"
    }

    func sharePreview(including sourceIDs: Set<UUID> = []) -> String {
        var sections: [String] = [title.trimmingCharacters(in: .whitespacesAndNewlines)]
        if isAIGenerated {
            sections.append("Provenance: \(provenanceLabel)")
        }

        let cleanedConclusion = conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedConclusion.isEmpty { sections.append(cleanedConclusion) }

        let checklistLines = checklist
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.isComplete ? "[x] " : "[ ] ") + $0.text }
        if !checklistLines.isEmpty {
            sections.append("Checklist\n" + checklistLines.joined(separator: "\n"))
        }

        var metadata: [String] = []
        if let date { metadata.append(date.formatted(date: .abbreviated, time: .omitted)) }
        let cleanedPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedPlace.isEmpty { metadata.append(cleanedPlace) }
        if !metadata.isEmpty { sections.append(metadata.joined(separator: " - ")) }

        let selectedSources = sources.filter { $0.noteID != nil && sourceIDs.contains($0.id) }
        if !selectedSources.isEmpty {
            let lines = selectedSources.map {
                "- \($0.titleAtSave) (\($0.noteDate.formatted(date: .abbreviated, time: .omitted)))"
            }
            sections.append("Sources\n" + lines.joined(separator: "\n"))
        }

        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct QueryHistoryItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var question: String
    var answerSummary: String
    var sourceCount: Int
    /// Optional for backward-compatible decoding of archives created before source-aware deletion.
    var sourceNoteIDs: [UUID]? = nil
    var createdAt: Date = .now
}

struct MindMapArchive: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var notes: [MindNote] = []
    var tagSuggestions: [TagSuggestion] = []
    var plans: [MindPlan] = []
    var queryHistory: [QueryHistoryItem] = []
    var preferences: MindMapPreferences = .init()

    init(
        schemaVersion: Int = currentSchemaVersion,
        notes: [MindNote] = [],
        tagSuggestions: [TagSuggestion] = [],
        plans: [MindPlan] = [],
        queryHistory: [QueryHistoryItem] = [],
        preferences: MindMapPreferences = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.tagSuggestions = tagSuggestions
        self.plans = plans
        self.queryHistory = queryHistory
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case notes
        case tagSuggestions
        case plans
        case queryHistory
        case preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        notes = try container.decodeIfPresent([MindNote].self, forKey: .notes) ?? []
        tagSuggestions = try container.decodeIfPresent([TagSuggestion].self, forKey: .tagSuggestions) ?? []
        plans = try container.decodeIfPresent([MindPlan].self, forKey: .plans) ?? []
        queryHistory = try container.decodeIfPresent([QueryHistoryItem].self, forKey: .queryHistory) ?? []
        preferences = try container.decodeIfPresent(MindMapPreferences.self, forKey: .preferences) ?? .init()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(notes, forKey: .notes)
        try container.encode(tagSuggestions, forKey: .tagSuggestions)
        try container.encode(plans, forKey: .plans)
        try container.encode(queryHistory, forKey: .queryHistory)
        try container.encode(preferences, forKey: .preferences)
    }
}
