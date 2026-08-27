import Foundation
import Combine

enum MindMapStoreError: LocalizedError {
    case emptyBody
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "Write something you want to remember before saving."
        case .persistenceFailed(let message):
            return "MindMap AI could not save your changes. \(message)"
        }
    }
}

private enum MindMapArchiveLoadError: Error {
    case unsupportedSchema(Int)
}

private enum MindMapPreferencesSidecarLoadError: Error {
    case unsupportedSchema(Int)
}

private struct MindMapPreferencesSidecar: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var preferences: MindMapPreferences

    init(preferences: MindMapPreferences) {
        schemaVersion = Self.currentSchemaVersion
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        preferences = try container.decode(MindMapPreferences.self, forKey: .preferences)
    }
}

private enum MindMapFileSnapshot {
    case missing
    case data(Data)
}

private struct MindMapDecodableFragment<Value: Decodable>: Decodable {
    let value: Value
}

@MainActor
final class MindMapStore: ObservableObject {
    @Published private(set) var notes: [MindNote]
    @Published private(set) var tagSuggestions: [TagSuggestion]
    @Published private(set) var plans: [MindPlan]
    @Published private(set) var queryHistory: [QueryHistoryItem]
    @Published private(set) var persistenceMessage: String?
    @Published var preferences: MindMapPreferences {
        didSet {
            guard !isRestoringState else { return }
            do {
                try persistPreferences(preferences)
                persistenceMessage = nil
            } catch {
                let previousPreferences = oldValue
                restore {
                    preferences = previousPreferences
                }
                persistenceMessage = error.localizedDescription
            }
        }
    }

    let storageURL: URL

    private let fileManager: FileManager
    private var isRestoringState = false

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)

        let archiveExists = fileManager.fileExists(atPath: self.storageURL.path)
        let loaded = Self.loadArchive(from: self.storageURL, fileManager: fileManager)
        let loadedPreferences = Self.loadPreferences(
            for: self.storageURL,
            archivePreferences: loaded.archive.preferences,
            requiresPrivacyReview: loaded.requiresPrivacyReview,
            archiveExists: archiveExists,
            fileManager: fileManager
        )
        notes = loaded.archive.notes.sorted { $0.createdAt > $1.createdAt }
        tagSuggestions = loaded.archive.tagSuggestions
        plans = loaded.archive.plans.sorted { $0.updatedAt > $1.updatedAt }
        queryHistory = loaded.archive.queryHistory.sorted { $0.createdAt > $1.createdAt }
        preferences = loadedPreferences.preferences
        persistenceMessage = Self.joinedMessages(loaded.message, loadedPreferences.message)
    }

    var acceptedTags: [String] {
        let tags = notes.flatMap(\.acceptedTags)
        return Array(Set(tags.map(Self.normalizedTag).filter { !$0.isEmpty })).sorted()
    }

    var locatedNotes: [MindNote] {
        notes.filter { $0.place != nil }
    }

    var pendingTagSuggestion: TagSuggestion? {
        tagSuggestions
            .filter { $0.decision == .pending }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    func updateCaptureDraft(_ draft: CaptureDraft) {
        preferences.captureDraft = draft
    }

    func clearCaptureDraft() {
        preferences.captureDraft = .init()
    }

    func updateAskDraft(question: String, filters: RetrievalFilters) {
        preferences.askDraft = AskDraft(question: question, filters: filters)
    }

    @discardableResult
    func createNote(
        from draft: CaptureDraft,
        place: SavedPlace? = nil,
        now: Date = .now,
        preserveCaptureDraft: Bool = false
    ) throws -> MindNote {
        if let existing = notes.first(where: { $0.captureSessionID == draft.id }) {
            return existing
        }

        let cleanedBody = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBody.isEmpty else { throw MindMapStoreError.emptyBody }

        let note = MindNote(
            captureSessionID: draft.id,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: cleanedBody,
            createdAt: now,
            updatedAt: now,
            eventDate: draft.eventDate,
            place: place,
            tripTheme: draft.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let oldNotes = notes
        let oldPreferences = preferences
        notes.insert(note, at: 0)
        if !preserveCaptureDraft {
            restore {
                preferences.captureDraft = .init()
            }
        }

        do {
            try persist()
            persistenceMessage = nil
            return note
        } catch {
            restore {
                notes = oldNotes
                preferences = oldPreferences
            }
            throw error
        }
    }

    func updateNote(_ note: MindNote, now: Date = .now) throws {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let oldNotes = notes
        var updated = note
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.body = updated.body.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tripTheme = updated.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.acceptedTags = Self.cleanedTags(updated.acceptedTags)
        guard !updated.body.isEmpty else { throw MindMapStoreError.emptyBody }
        updated.updatedAt = now
        notes[index] = updated
        notes.sort { $0.createdAt > $1.createdAt }

        do {
            // Edits can redact note text or remove a precise place. Never retain the pre-edit
            // private content in an automatic recovery archive.
            try persist()
        } catch {
            notes = oldNotes
            throw error
        }
        do {
            try removeRecoveryArtifacts()
            persistenceMessage = nil
        } catch {
            let wrapped = MindMapStoreError.persistenceFailed(
                "The edited note was saved, but a stale recovery file could not be removed. \(error.localizedDescription)"
            )
            persistenceMessage = wrapped.localizedDescription
            throw wrapped
        }
    }

    func attachLocation(_ place: SavedPlace, to noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), notes[index].place == nil else { return }
        let previousArchive = makeArchive()
        notes[index].place = place
        notes[index].updatedAt = .now
        persistBestEffort(restoring: previousArchive)
    }

    @discardableResult
    func setFavorite(_ isFavorite: Bool, noteID: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        let previousArchive = makeArchive()
        notes[index].isFavorite = isFavorite
        notes[index].updatedAt = .now
        return persistBestEffort(restoring: previousArchive)
    }

    @discardableResult
    func deleteNote(_ noteID: UUID) -> Bool {
        let previousArchive = makeArchive()
        notes.removeAll { $0.id == noteID }
        tagSuggestions.removeAll { $0.noteID == noteID }
        // A stored answer summary can retain facts derived from a deleted note. Remove the
        // complete history entry rather than keeping an unverifiable derived fragment. Legacy
        // entries without source IDs are conservatively cleared on note deletion.
        queryHistory.removeAll { historyItem in
            guard let sourceNoteIDs = historyItem.sourceNoteIDs else { return true }
            return sourceNoteIDs.contains(noteID)
        }

        for planIndex in plans.indices {
            var planChanged = false
            let deletedSourceLinkIDs = Set(
                plans[planIndex].sources.compactMap { source in
                    source.noteID == noteID ? source.id : nil
                }
            )
            for sourceIndex in plans[planIndex].sources.indices where plans[planIndex].sources[sourceIndex].noteID == noteID {
                plans[planIndex].sources[sourceIndex].noteID = nil
                plans[planIndex].sources[sourceIndex].titleAtSave = "Deleted source"
                plans[planIndex].sources[sourceIndex].noteDate = Date(timeIntervalSince1970: 0)
                planChanged = true
            }
            if var answerParts = plans[planIndex].answerParts {
                for partIndex in answerParts.indices {
                    let previousCount = answerParts[partIndex].citations.count
                    answerParts[partIndex].citations.removeAll {
                        deletedSourceLinkIDs.contains($0.sourceLinkID)
                    }
                    if answerParts[partIndex].citations.count != previousCount {
                        planChanged = true
                    }
                }
                plans[planIndex].answerParts = answerParts
            }
            for itemIndex in plans[planIndex].checklist.indices {
                let previousCount = plans[planIndex].checklist[itemIndex].sourceNoteIDs.count
                plans[planIndex].checklist[itemIndex].sourceNoteIDs.removeAll { $0 == noteID }
                if plans[planIndex].checklist[itemIndex].sourceNoteIDs.count != previousCount {
                    planChanged = true
                }
                if var citations = plans[planIndex].checklist[itemIndex].citations {
                    let previousCitationCount = citations.count
                    citations.removeAll { deletedSourceLinkIDs.contains($0.sourceLinkID) }
                    if citations.count != previousCitationCount {
                        plans[planIndex].checklist[itemIndex].citations = citations.isEmpty ? nil : citations
                        planChanged = true
                    }
                }
            }
            if planChanged {
                plans[planIndex].updatedAt = .now
            }
        }
        plans.sort { $0.updatedAt > $1.updatedAt }
        let didPersist = persistBestEffort(restoring: previousArchive)
        guard didPersist else { return false }
        return removeRecoveryArtifactsReportingFailure()
    }

    func addTagSuggestion(_ suggestion: TagSuggestion) {
        guard notes.contains(where: { $0.id == suggestion.noteID }) else { return }
        let previousArchive = makeArchive()
        tagSuggestions.removeAll { $0.noteID == suggestion.noteID && $0.decision == .pending }
        tagSuggestions.append(suggestion)
        persistBestEffort(restoring: previousArchive)
    }

    func decideTagSuggestion(_ suggestionID: UUID, decision: TagSuggestionDecision, editedTags: [String] = []) {
        guard let suggestionIndex = tagSuggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        let previousArchive = makeArchive()
        let suggestion = tagSuggestions[suggestionIndex]
        tagSuggestions[suggestionIndex].decision = decision

        if decision == .accepted, let noteIndex = notes.firstIndex(where: { $0.id == suggestion.noteID }) {
            let accepted = editedTags.isEmpty ? suggestion.tags : editedTags
            notes[noteIndex].acceptedTags = Self.cleanedTags(notes[noteIndex].acceptedTags + accepted)
            notes[noteIndex].updatedAt = .now
        }
        persistBestEffort(restoring: previousArchive)
    }

    func upsertPlan(_ plan: MindPlan) throws {
        let oldPlans = plans
        var cleaned = plan
        cleaned.title = cleaned.title.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.conclusion = cleaned.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.place = cleaned.place.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.checklist = cleaned.checklist.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        cleaned.updatedAt = .now

        if let index = plans.firstIndex(where: { $0.id == cleaned.id }) {
            plans[index] = cleaned
        } else {
            plans.append(cleaned)
        }
        plans.sort { $0.updatedAt > $1.updatedAt }

        do {
            // Plan edits may remove sourced personal details; do not preserve the previous plan
            // body or links in a recovery copy.
            try persist()
        } catch {
            plans = oldPlans
            throw error
        }
        do {
            try removeRecoveryArtifacts()
            persistenceMessage = nil
        } catch {
            let wrapped = MindMapStoreError.persistenceFailed(
                "The edited plan was saved, but a stale recovery file could not be removed. \(error.localizedDescription)"
            )
            persistenceMessage = wrapped.localizedDescription
            throw wrapped
        }
    }

    @discardableResult
    func deletePlan(_ planID: UUID) -> Bool {
        let previousArchive = makeArchive()
        plans.removeAll { $0.id == planID }
        let didPersist = persistBestEffort(restoring: previousArchive)
        guard didPersist else { return false }
        return removeRecoveryArtifactsReportingFailure()
    }

    func planSourceState(_ source: PlanSourceLink) -> PlanSourceState {
        guard let noteID = source.noteID,
              let note = notes.first(where: { $0.id == noteID }) else {
            return .deleted
        }
        return note.updatedAt == source.updatedAtSave ? .current : .changed
    }

    func recordQuery(question: String, conclusion: GroundedConclusion, sourceCount: Int) {
        guard preferences.keepLocalHistory else { return }
        let previousArchive = makeArchive()
        queryHistory.insert(
            QueryHistoryItem(
                question: question,
                answerSummary: conclusion.directAnswer,
                sourceCount: sourceCount,
                sourceNoteIDs: conclusion.allReferencedNoteIDs
            ),
            at: 0
        )
        if queryHistory.count > 50 {
            queryHistory.removeLast(queryHistory.count - 50)
        }
        persistBestEffort(restoring: previousArchive)
    }

    @discardableResult
    func clearQueryHistory() -> Bool {
        let previousArchive = makeArchive()
        queryHistory.removeAll()
        let didPersist = persistBestEffort(restoring: previousArchive)
        guard didPersist else { return false }
        return removeRecoveryArtifactsReportingFailure()
    }

    func deleteAllLocalData() throws {
        let oldArchive = makeArchive()
        restore {
            notes = []
            tagSuggestions = []
            plans = []
            queryHistory = []
            preferences = .init()
        }

        do {
            try persist(createBackup: false)
        } catch {
            apply(oldArchive)
            throw error
        }
        do {
            try removeRecoveryArtifacts(removeBackup: true)
            persistenceMessage = nil
        } catch {
            // The primary archive and draft sidecar are already empty. Never restore private
            // data merely because a stale recovery artifact could not be removed; report the
            // incomplete cleanup so the UI cannot claim full deletion.
            let wrapped = MindMapStoreError.persistenceFailed(
                "The active library was cleared, but a local recovery file could not be removed. \(error.localizedDescription)"
            )
            persistenceMessage = wrapped.localizedDescription
            throw wrapped
        }
    }

    func exportData() throws -> Data {
        let encoder = Self.makeEncoder(prettyPrinted: true)
        do {
            return try encoder.encode(makeArchive())
        } catch {
            throw MindMapStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    func note(withID id: UUID) -> MindNote? {
        notes.first { $0.id == id }
    }

    func makePlan(
        from conclusion: GroundedConclusion,
        question: String,
        retrievalAssumption: String = ""
    ) -> MindPlan {
        let referencedIDs = conclusion.allReferencedNoteIDs
        let sourceLinks = referencedIDs.compactMap { id -> PlanSourceLink? in
            guard let note = note(withID: id) else { return nil }
            return PlanSourceLink(
                noteID: note.id,
                titleAtSave: note.displayTitle,
                noteDate: note.eventDate ?? note.createdAt,
                updatedAtSave: note.updatedAt
            )
        }
        let liveSourceIDs = Set(sourceLinks.compactMap(\.noteID))
        let sourceLinkIDByNoteID: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: sourceLinks.compactMap { source -> (UUID, UUID)? in
                guard let noteID = source.noteID else { return nil }
                return (noteID, source.id)
            }
        )
        let answerParts: [PlanAnswerPart] = conclusion.resolvedAnswerParts.map { part in
            let citations = part.evidence.compactMap { evidence -> PlanAnswerCitation? in
                guard let sourceLinkID = sourceLinkIDByNoteID[evidence.sourceNoteID] else {
                    return nil
                }
                return PlanAnswerCitation(
                    sourceLinkID: sourceLinkID,
                    quote: evidence.quote
                )
            }
            return PlanAnswerPart(
                text: part.text,
                origin: part.origin,
                citations: citations
            )
        }
        var seenAssumptions: Set<String> = []
        let assumptions = [retrievalAssumption, conclusion.statedAssumption].compactMap { value -> String? in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let key = cleaned.lowercased()
            guard seenAssumptions.insert(key).inserted else { return nil }
            return cleaned
        }
        let planConclusion = assumptions.isEmpty
            ? conclusion.directAnswer
            : "\(conclusion.directAnswer)\n\nAssumption: \(assumptions.joined(separator: " "))"

        return MindPlan(
            title: question.trimmingCharacters(in: .whitespacesAndNewlines),
            conclusion: planConclusion,
            answerParts: answerParts.isEmpty ? nil : answerParts,
            checklist: conclusion.suggestedChecklist.map {
                PlanChecklistItem(
                    text: $0.text,
                    sourceNoteIDs: $0.sourceNoteIDs.filter { liveSourceIDs.contains($0) },
                    origin: $0.origin,
                    citations: $0.evidence?.compactMap { evidence in
                        guard let sourceLinkID = sourceLinkIDByNoteID[evidence.sourceNoteID] else {
                            return nil
                        }
                        return PlanStepCitation(
                            sourceLinkID: sourceLinkID,
                            quote: evidence.quote
                        )
                    }
                )
            },
            date: nil,
            place: "",
            sources: sourceLinks,
            isAIGenerated: true
        )
    }

    private func makeArchive() -> MindMapArchive {
        MindMapArchive(
            notes: notes,
            tagSuggestions: tagSuggestions,
            plans: plans,
            queryHistory: queryHistory,
            preferences: preferences
        )
    }

    private func makePersistenceArchive() -> MindMapArchive {
        var fallbackPreferences = preferences
        // The sidecar is the sole durable source for live drafts and permissions. Keeping these
        // fields out of the main archive prevents cleared drafts or stale consent from returning
        // when the sidecar is missing or unreadable.
        fallbackPreferences.captureDraft = .init()
        fallbackPreferences.askDraft = .init()
        Self.resetPrivacyPermissions(in: &fallbackPreferences)
        return MindMapArchive(
            notes: notes,
            tagSuggestions: tagSuggestions,
            plans: plans,
            queryHistory: queryHistory,
            preferences: fallbackPreferences
        )
    }

    private func apply(_ archive: MindMapArchive) {
        restore {
            notes = archive.notes.sorted { $0.createdAt > $1.createdAt }
            tagSuggestions = archive.tagSuggestions
            plans = archive.plans.sorted { $0.updatedAt > $1.updatedAt }
            queryHistory = archive.queryHistory.sorted { $0.createdAt > $1.createdAt }
            preferences = archive.preferences
        }
    }

    private func restore(_ changes: () -> Void) {
        isRestoringState = true
        changes()
        isRestoringState = false
    }

    @discardableResult
    private func persistBestEffort(
        restoring previousArchive: MindMapArchive? = nil,
        createBackup: Bool = true
    ) -> Bool {
        do {
            try persist(createBackup: createBackup)
            persistenceMessage = nil
            return true
        } catch {
            if let previousArchive {
                apply(previousArchive)
            }
            persistenceMessage = error.localizedDescription
            return false
        }
    }

    private func persist(createBackup: Bool = true) throws {
        var archiveSnapshot: MindMapFileSnapshot?
        var preferencesSnapshot: MindMapFileSnapshot?
        var backupSnapshot: MindMapFileSnapshot?

        do {
            let directory = storageURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let preferencesURL = Self.preferencesURL(for: storageURL)
            let archiveData = try Self.makeEncoder(prettyPrinted: false).encode(makePersistenceArchive())
            let preferencesData = try Self.makeEncoder(prettyPrinted: false).encode(
                MindMapPreferencesSidecar(preferences: preferences)
            )
            archiveSnapshot = try Self.snapshot(of: storageURL, fileManager: fileManager)
            preferencesSnapshot = try Self.snapshot(of: preferencesURL, fileManager: fileManager)
            let backupURL = Self.backupURL(for: storageURL)
            backupSnapshot = try Self.snapshot(of: backupURL, fileManager: fileManager)
            try archiveData.write(to: storageURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try preferencesData.write(
                to: preferencesURL,
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            if createBackup {
                // Recovery always mirrors the newly committed, sanitized state. It never keeps
                // a pre-redaction/pre-deletion archive that could resurrect removed private data.
                try archiveData.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } else if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
        } catch {
            // A full save spans two independently atomic files. If the second replacement
            // fails, restore both pre-transaction snapshots before rolling back memory.
            if let archiveSnapshot {
                try? Self.restore(archiveSnapshot, to: storageURL, fileManager: fileManager)
            }
            if let preferencesSnapshot {
                try? Self.restore(
                    preferencesSnapshot,
                    to: Self.preferencesURL(for: storageURL),
                    fileManager: fileManager
                )
            }
            if let backupSnapshot {
                try? Self.restore(
                    backupSnapshot,
                    to: Self.backupURL(for: storageURL),
                    fileManager: fileManager
                )
            }
            let wrapped = MindMapStoreError.persistenceFailed(error.localizedDescription)
            persistenceMessage = wrapped.localizedDescription
            throw wrapped
        }
    }

    private func persistPreferences(_ preferences: MindMapPreferences) throws {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.makeEncoder(prettyPrinted: false).encode(
                MindMapPreferencesSidecar(preferences: preferences)
            )
            try data.write(
                to: Self.preferencesURL(for: storageURL),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        } catch {
            throw MindMapStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("MindMapAI", isDirectory: true)
            .appendingPathComponent("mindmap-ai.json", isDirectory: false)
    }

    private static func loadArchive(
        from url: URL,
        fileManager: FileManager
    ) -> (archive: MindMapArchive, message: String?, requiresPrivacyReview: Bool) {
        guard fileManager.fileExists(atPath: url.path) else { return (.init(), nil, false) }

        do {
            let data = try Data(contentsOf: url)
            return (try decodeArchive(from: data), nil, false)
        } catch {
            let formatter = ISO8601DateFormatter()
            let recoveryURL = url
                .deletingPathExtension()
                .appendingPathExtension("recovery-\(formatter.string(from: .now)).json")
            try? fileManager.copyItem(at: url, to: recoveryURL)

            let backupURL = backupURL(for: url)
            if let backupData = try? Data(contentsOf: backupURL),
               var backupArchive = try? decodeArchive(from: backupData) {
                // Recovery must never silently resurrect a more permissive privacy choice.
                // Require fresh AI disclosure and keep future location capture off until the
                // user reviews Settings again.
                backupArchive.preferences.aiProcessingConsent = .undecided
                backupArchive.preferences.locationCaptureEnabled = false
                return (
                    backupArchive,
                    "The newest local archive could not be opened. MindMap AI restored the last known-good backup and preserved the unreadable file as \(recoveryURL.lastPathComponent).",
                    true
                )
            }
            return (
                .init(),
                "The local library could not be opened. The unreadable file was preserved as \(recoveryURL.lastPathComponent); export or keep that recovery file before adding new data.",
                true
            )
        }
    }

    private static func loadPreferences(
        for storageURL: URL,
        archivePreferences: MindMapPreferences,
        requiresPrivacyReview: Bool,
        archiveExists: Bool,
        fileManager: FileManager
    ) -> (preferences: MindMapPreferences, message: String?) {
        let url = preferencesURL(for: storageURL)
        let privacyReviewMessage = requiresPrivacyReview
            ? "AI processing consent and automatic location capture were reset for review."
            : nil

        guard fileManager.fileExists(atPath: url.path) else {
            var preferences = archivePreferences
            if archiveExists {
                resetPrivacyPermissions(in: &preferences)
                preferences.captureDraft = .init()
                preferences.askDraft = .init()
            }
            let missingMessage = archiveExists
                ? "The local preferences file was missing. AI processing consent and automatic location capture were reset, and drafts were not restored from the library archive."
                : nil
            return (preferences, joinedMessages(privacyReviewMessage, missingMessage))
        }

        do {
            let data = try Data(contentsOf: url)
            var preferences = try decodePreferencesSidecar(from: data).preferences
            if requiresPrivacyReview {
                resetPrivacyPermissions(in: &preferences)
            }
            return (preferences, privacyReviewMessage)
        } catch {
            let data = try? Data(contentsOf: url)
            var fallback = archivePreferences
            fallback.captureDraft = .init()
            fallback.askDraft = .init()
            resetPrivacyPermissions(in: &fallback)
            var preferences = salvagedNonPrivacyPreferences(
                from: data,
                fallingBackTo: fallback
            )
            resetPrivacyPermissions(in: &preferences)
            return (
                preferences,
                "The local preferences file could not be opened. AI processing consent and automatic location capture were reset; other settings were preserved where possible."
            )
        }
    }

    private static func salvagedNonPrivacyPreferences(
        from data: Data?,
        fallingBackTo fallback: MindMapPreferences
    ) -> MindMapPreferences {
        var result = fallback
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["preferences"] as? [String: Any] else {
            return result
        }

        if let keepLocalHistory: Bool = decodedFragment(Bool.self, from: values["keepLocalHistory"]) {
            result.keepLocalHistory = keepLocalHistory
        }
        if let aiModel: String = decodedFragment(String.self, from: values["aiModel"]) {
            result.aiModel = aiModel
        }
        if let captureDraft: CaptureDraft = decodedFragment(CaptureDraft.self, from: values["captureDraft"]) {
            result.captureDraft = captureDraft
        }
        if let askDraft: AskDraft = decodedFragment(AskDraft.self, from: values["askDraft"]) {
            result.askDraft = askDraft
        }
        return result
    }

    private static func decodedFragment<Value: Decodable>(
        _ type: Value.Type,
        from value: Any?
    ) -> Value? {
        guard let value,
              JSONSerialization.isValidJSONObject(["value": value]),
              let wrappedData = try? JSONSerialization.data(withJSONObject: ["value": value]) else {
            return nil
        }

        return try? makeDecoder()
            .decode(MindMapDecodableFragment<Value>.self, from: wrappedData)
            .value
    }

    private static func resetPrivacyPermissions(in preferences: inout MindMapPreferences) {
        preferences.aiProcessingConsent = .undecided
        preferences.locationCaptureEnabled = false
    }

    private static func joinedMessages(_ messages: String?...) -> String? {
        let messages: [String] = messages.compactMap { message in
            guard let message else { return nil }
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private static func backupURL(for storageURL: URL) -> URL {
        storageURL
            .deletingPathExtension()
            .appendingPathExtension("backup.json")
    }

    private static func preferencesURL(for storageURL: URL) -> URL {
        storageURL
            .deletingPathExtension()
            .appendingPathExtension("preferences.json")
    }

    private static func snapshot(of url: URL, fileManager: FileManager) throws -> MindMapFileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        return .data(try Data(contentsOf: url))
    }

    private static func restore(
        _ snapshot: MindMapFileSnapshot,
        to url: URL,
        fileManager: FileManager
    ) throws {
        switch snapshot {
        case .missing:
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        case .data(let data):
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    private func removeRecoveryArtifactsReportingFailure() -> Bool {
        do {
            try removeRecoveryArtifacts()
            persistenceMessage = nil
            return true
        } catch {
            let wrapped = MindMapStoreError.persistenceFailed(
                "The change was saved, but a stale recovery file could not be removed. \(error.localizedDescription)"
            )
            persistenceMessage = wrapped.localizedDescription
            return false
        }
    }

    private func removeRecoveryArtifacts(removeBackup: Bool = false) throws {
        let directory = storageURL.deletingLastPathComponent()
        let stem = storageURL.deletingPathExtension().lastPathComponent
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var targets = contents.filter { $0.lastPathComponent.hasPrefix("\(stem).recovery-") }
        if removeBackup {
            let backupURL = Self.backupURL(for: storageURL)
            if fileManager.fileExists(atPath: backupURL.path) { targets.append(backupURL) }
        }
        for url in targets {
            try fileManager.removeItem(at: url)
            if fileManager.fileExists(atPath: url.path) {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func decodeArchive(from data: Data) throws -> MindMapArchive {
        let archive = try makeDecoder().decode(MindMapArchive.self, from: data)
        guard archive.schemaVersion <= MindMapArchive.currentSchemaVersion else {
            throw MindMapArchiveLoadError.unsupportedSchema(archive.schemaVersion)
        }
        return archive
    }

    private static func decodePreferencesSidecar(from data: Data) throws -> MindMapPreferencesSidecar {
        let sidecar = try makeDecoder().decode(MindMapPreferencesSidecar.self, from: data)
        guard sidecar.schemaVersion > 0,
              sidecar.schemaVersion <= MindMapPreferencesSidecar.currentSchemaVersion else {
            throw MindMapPreferencesSidecarLoadError.unsupportedSchema(sidecar.schemaVersion)
        }
        return sidecar
    }

    private static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        // JSONEncoder's built-in ISO-8601 strategy drops sub-second precision. Note revisions
        // and saved plan-source revisions can legitimately occur within the same second, so new
        // archives store the full floating-point timestamp. The decoder below still accepts all
        // legacy ISO-8601 strings.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            if let date = legacy.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MindMap AI date value."
            )
        }
        return decoder
    }

    private static func normalizedTag(_ tag: String) -> String {
        tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
    }

    private static func cleanedTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let cleaned = normalizedTag(tag)
            guard !cleaned.isEmpty, !result.contains(cleaned) else { continue }
            result.append(cleaned)
        }
        return Array(result.prefix(12))
    }
}

enum PlanSourceState {
    case current
    case changed
    case deleted
}
