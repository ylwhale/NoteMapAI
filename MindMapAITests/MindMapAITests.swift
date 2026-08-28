import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct MindMapAITests {
    @Test("Capture drafts persist and one capture session cannot save twice")
    func durableDraftAndIdempotentSave() throws {
        let url = temporaryStoreURL("draft")
        let draft = CaptureDraft(
            id: UUID(),
            title: "",
            body: "Remember the last train leaves at 10:40 PM 🚆",
            eventDate: nil,
            tripTheme: "weekend trip"
        )

        let firstStore = MindMapStore(storageURL: url)
        firstStore.updateCaptureDraft(draft)

        let restoredDraftStore = MindMapStore(storageURL: url)
        #expect(restoredDraftStore.preferences.captureDraft == draft)

        let firstSave = try restoredDraftStore.createNote(from: draft)
        let duplicateSave = try restoredDraftStore.createNote(from: draft)
        #expect(firstSave.id == duplicateSave.id)
        #expect(restoredDraftStore.notes.count == 1)
        #expect(restoredDraftStore.preferences.captureDraft.isEmpty)

        let relaunchedStore = MindMapStore(storageURL: url)
        #expect(relaunchedStore.notes.map(\.id) == [firstSave.id])
        #expect(relaunchedStore.notes.first?.body.contains("🚆") == true)
    }

    @Test("A deleted note leaves no live retrieval, plan, or checklist reference")
    func deletionCascade() throws {
        let url = temporaryStoreURL("cascade")
        let store = MindMapStore(storageURL: url)
        let privateQuote = "Pack a rain shell for Milwaukee."
        let note = try store.createNote(from: CaptureDraft(body: privateQuote))
        let sourceLink = PlanSourceLink(
            noteID: note.id,
            titleAtSave: note.displayTitle,
            noteDate: note.createdAt,
            updatedAtSave: note.updatedAt
        )
        var plan = MindPlan(
            title: "Milwaukee weekend",
            conclusion: "Bring rain gear.",
            answerParts: [
                PlanAnswerPart(
                    text: "Bring rain gear.",
                    origin: .generatedGuidance,
                    citations: [
                        PlanAnswerCitation(sourceLinkID: sourceLink.id, quote: privateQuote)
                    ]
                )
            ],
            checklist: [
                PlanChecklistItem(
                    text: "Pack rain shell",
                    sourceNoteIDs: [note.id],
                    origin: .generatedGuidance,
                    citations: [
                        PlanStepCitation(sourceLinkID: sourceLink.id, quote: privateQuote)
                    ]
                )
            ],
            date: nil,
            place: "Milwaukee",
            sources: [sourceLink]
        )
        plan.updatedAt = .now
        try store.upsertPlan(plan)
        store.recordQuery(
            question: "What should I pack?",
            conclusion: GroundedConclusion(
                directAnswer: "Pack a rain shell.",
                answerEvidence: [ClaimEvidence(sourceNoteID: note.id, quote: "Pack a rain shell")],
                claims: [],
                conflicts: [],
                missingInformation: [],
                suggestedChecklist: [],
                statedAssumption: ""
            ),
            sourceCount: 1
        )
        #expect(store.queryHistory.count == 1)

        store.deleteNote(note.id)

        #expect(store.note(withID: note.id) == nil)
        #expect(store.locatedNotes.isEmpty)
        #expect(store.plans.first?.sources.first?.noteID == nil)
        #expect(store.plans.first?.checklist.first?.sourceNoteIDs.isEmpty == true)
        #expect(store.plans.first?.answerParts?.first?.citations.isEmpty == true)
        #expect(store.plans.first?.checklist.first?.citations == nil)
        #expect(store.queryHistory.isEmpty)
        let export = String(decoding: try store.exportData(), as: UTF8.self)
        #expect(!export.contains(privateQuote))
        let savedPlan = try #require(store.plans.first)
        #expect(!savedPlan.sharePreview().contains(privateQuote))
        let rawArchive = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!rawArchive.contains(privateQuote))
        #expect(store.plans.first?.sources.first?.titleAtSave == "Deleted source")
    }

    @Test("Saved plan answer parts and steps preserve provenance while legacy data still decodes")
    func planStepProvenancePersistsBackwardCompatibly() throws {
        let url = temporaryStoreURL("plan-step-provenance")
        let store = MindMapStore(storageURL: url)
        let note = try store.createNote(
            from: CaptureDraft(body: "Review chapter 4 before Friday.")
        )
        let evidence = ClaimEvidence(
            sourceNoteID: note.id,
            quote: "Review chapter 4 before Friday."
        )
        let conclusion = GroundedConclusion(
            directAnswer: "Review chapter 4 before Friday, then create a practice session.",
            answerEvidence: [evidence],
            claims: [],
            conflicts: [],
            missingInformation: [],
            suggestedChecklist: [
                SuggestedPlanItem(
                    text: "Review chapter 4 before Friday.",
                    sourceNoteIDs: [note.id],
                    origin: .sourceBacked,
                    evidence: [evidence]
                ),
                SuggestedPlanItem(
                    text: "Create a practice session.",
                    sourceNoteIDs: [note.id],
                    origin: .generatedGuidance,
                    evidence: [evidence]
                )
            ],
            statedAssumption: "",
            answerParts: [
                GroundedAnswerPart(
                    text: "Review chapter 4 before Friday.",
                    origin: .sourceBacked,
                    evidence: [evidence]
                ),
                GroundedAnswerPart(
                    text: "Then create a practice session.",
                    origin: .generatedGuidance,
                    evidence: [evidence]
                )
            ]
        )
        let plan = store.makePlan(from: conclusion, question: "How should I study?")

        #expect(plan.answerParts?.map(\.origin) == [.sourceBacked, .generatedGuidance])
        #expect(plan.answerParts?.flatMap(\.citations).map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])
        #expect(plan.answerParts?.flatMap(\.citations).allSatisfy { citation in
            plan.sources.contains { $0.id == citation.sourceLinkID }
        } == true)
        #expect(plan.checklist.map(\.origin) == [.sourceBacked, .generatedGuidance])
        #expect(plan.checklist.flatMap { $0.citations ?? [] }.map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])
        #expect(plan.checklist.flatMap { $0.citations ?? [] }.allSatisfy { citation in
            plan.sources.contains { $0.id == citation.sourceLinkID }
        } == true)
        try store.upsertPlan(plan)
        let relaunched = MindMapStore(storageURL: url)
        #expect(relaunched.plans.first?.answerParts?.map(\.origin) == [
            .sourceBacked,
            .generatedGuidance
        ])
        #expect(relaunched.plans.first?.answerParts?.flatMap(\.citations).map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])
        #expect(relaunched.plans.first?.checklist.map(\.origin) == [
            .sourceBacked,
            .generatedGuidance
        ])
        #expect(relaunched.plans.first?.checklist.flatMap { $0.citations ?? [] }.map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])

        let savedPlan = try #require(relaunched.plans.first)
        let reusedPlan = savedPlan.reusableCopy(now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(reusedPlan.checklist.flatMap { $0.citations ?? [] }.map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])
        #expect(reusedPlan.checklist.flatMap { $0.citations ?? [] }.allSatisfy { citation in
            reusedPlan.sources.contains { $0.id == citation.sourceLinkID }
                && !savedPlan.sources.contains { $0.id == citation.sourceLinkID }
        } == true)
        try relaunched.upsertPlan(reusedPlan)
        let relaunchedAfterReuse = MindMapStore(storageURL: url)
        let persistedReuse = try #require(
            relaunchedAfterReuse.plans.first(where: { $0.id == reusedPlan.id })
        )
        #expect(persistedReuse.checklist.flatMap { $0.citations ?? [] }.map(\.quote) == [
            "Review chapter 4 before Friday.",
            "Review chapter 4 before Friday."
        ])

        let legacyStep = try JSONDecoder().decode(
            PlanChecklistItem.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","text":"Legacy step","isComplete":false,"sourceNoteIDs":[]}"#.utf8)
        )
        #expect(legacyStep.origin == nil)
        #expect(legacyStep.citations == nil)

        let encodedPlan = try JSONEncoder().encode(plan)
        var legacyPlanObject = try #require(
            JSONSerialization.jsonObject(with: encodedPlan) as? [String: Any]
        )
        legacyPlanObject.removeValue(forKey: "answerParts")
        let legacyPlanData = try JSONSerialization.data(withJSONObject: legacyPlanObject)
        let legacyPlan = try JSONDecoder().decode(MindPlan.self, from: legacyPlanData)
        #expect(legacyPlan.answerParts == nil)
    }

    @Test("Plan sources remain stale after a same-second edit and relaunch")
    func fractionalRevisionSurvivesRelaunch() throws {
        let url = temporaryStoreURL("fractional-revision")
        let store = MindMapStore(storageURL: url)
        let base = Date(timeIntervalSince1970: 1_800_000_000.100_000)
        let note = try store.createNote(from: CaptureDraft(body: "Hotel cost was $148."), now: base)
        let source = PlanSourceLink(
            noteID: note.id,
            titleAtSave: note.displayTitle,
            noteDate: note.createdAt,
            updatedAtSave: note.updatedAt
        )
        let plan = MindPlan(
            title: "Hotel plan",
            conclusion: "Hotel cost was $148.",
            checklist: [],
            date: nil,
            place: "",
            sources: [source]
        )
        try store.upsertPlan(plan)

        var edited = note
        edited.body = "Hotel cost was $158."
        try store.updateNote(edited, now: base.addingTimeInterval(0.000_500))

        let relaunched = MindMapStore(storageURL: url)
        let savedSource = try #require(relaunched.plans.first?.sources.first)
        guard case .changed = relaunched.planSourceState(savedSource) else {
            Issue.record("A sub-second note revision was incorrectly reported as current.")
            return
        }
    }

    @Test("A corrupt primary archive restores the last known-good local backup")
    func archiveBackupRecovery() throws {
        let url = temporaryStoreURL("backup-recovery")
        let store = MindMapStore(storageURL: url)
        let first = try store.createNote(from: CaptureDraft(body: "First durable note"))
        let second = try store.createNote(from: CaptureDraft(body: "Second durable note"))

        try Data("not valid JSON".utf8).write(to: url, options: .atomic)
        let recovered = MindMapStore(storageURL: url)

        #expect(recovered.notes.map(\.id) == [second.id, first.id])
        #expect(recovered.persistenceMessage?.contains("last known-good backup") == true)

        let firstSaveURL = temporaryStoreURL("first-save-recovery")
        let firstSaveStore = MindMapStore(storageURL: firstSaveURL)
        let onlyNote = try firstSaveStore.createNote(from: CaptureDraft(body: "Only durable note"))
        try Data("corrupt first archive".utf8).write(to: firstSaveURL, options: .atomic)
        #expect(MindMapStore(storageURL: firstSaveURL).notes.map(\.id) == [onlyNote.id])

        let sanitizedURL = temporaryStoreURL("sanitized-recovery")
        let sanitizedStore = MindMapStore(storageURL: sanitizedURL)
        let privateMarker = "PRIVATE_NOTE_THAT_WAS_DELETED"
        let deleted = try sanitizedStore.createNote(from: CaptureDraft(body: privateMarker))
        let kept = try sanitizedStore.createNote(from: CaptureDraft(body: "Keep this note"))
        #expect(sanitizedStore.deleteNote(deleted.id))
        try Data("corrupt sanitized archive".utf8).write(to: sanitizedURL, options: .atomic)
        let sanitizedRecovery = MindMapStore(storageURL: sanitizedURL)
        #expect(sanitizedRecovery.notes.map(\.id) == [kept.id])
        #expect(!String(decoding: try sanitizedRecovery.exportData(), as: UTF8.self).contains(privateMarker))

        try recovered.deleteAllLocalData()
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { $0.contains("backup") || $0.contains("recovery-") })
    }

    @Test("Privacy preferences roll back when durable storage fails")
    func privacyPreferenceRollback() {
        let impossibleURL = URL(fileURLWithPath: "/dev/null/MindMapAI/archive.json")
        let store = MindMapStore(storageURL: impossibleURL)

        store.preferences.aiProcessingConsent = .accepted
        #expect(store.preferences.aiProcessingConsent == .undecided)

        store.preferences.locationCaptureEnabled = false
        #expect(store.preferences.locationCaptureEnabled == true)
        #expect(store.persistenceMessage != nil)
    }

    @Test("Retrieval scans the complete index and supports partial memory and metadata")
    func fullIndexRetrieval() {
        let chicago = SavedPlace(name: "Chicago Union Station", detail: "Chicago, Illinois", latitude: 41.8786, longitude: -87.6405)
        let notes = [
            MindNote(body: "The last train home leaves at 10:40 PM.", place: chicago, acceptedTags: ["travel"]),
            MindNote(body: "Hotel cost was $148 after fees.", place: chicago, acceptedTags: ["budget"]),
            MindNote(body: "Professor moved office hours to Thursday.", acceptedTags: ["study"])
        ]
        let engine = RetrievalEngine(relevanceThreshold: 0.40)
        let result = engine.retrieve(question: "Chicago train hotel cost", from: notes)

        #expect(result.scannedCount == 3)
        #expect(result.sources.contains { $0.excerpt.localizedCaseInsensitiveContains("train") })
        #expect(result.sources.contains { $0.excerpt.localizedCaseInsensitiveContains("hotel") })
        #expect(result.sources.allSatisfy { notes.map(\.id).contains($0.noteID) })

        let filtered = engine.search(
            query: "Union",
            in: notes,
            filters: RetrievalFilters(place: "Chicago")
        )
        #expect(filtered.filteredCount == 2)
        #expect(filtered.sources.allSatisfy { $0.noteID != notes[2].id })

        let naturalQuestion = engine.retrieve(
            question: "Based on my past travel notes, what should I plan for a similar weekend trip?",
            from: notes
        )
        #expect(naturalQuestion.sources.contains { $0.noteID == notes[0].id })

        let coordinateOnlyPlace = SavedPlace(
            name: "Chicago",
            detail: "41.878123 -87.629456",
            latitude: 41.878123,
            longitude: -87.629456
        )
        let metadataNote = MindNote(body: "Bring a jacket.", place: coordinateOnlyPlace)
        let metadataResult = engine.retrieve(question: "Chicago", from: [metadataNote])
        #expect(metadataResult.sources.first?.excerpt.contains("Chicago") == true)
        #expect(metadataResult.sources.first?.excerpt.contains("41.878") == false)
        #expect(metadataResult.sources.first?.excerpt.contains("-87.629") == false)

        let whitespaceCoordinatePlace = SavedPlace(
            name: "Chicago",
            detail: "meet at 40.7128 -74.0060",
            latitude: 41.88,
            longitude: -87.63
        )
        let whitespaceCoordinateNote = MindNote(body: "Train platform note.", place: whitespaceCoordinatePlace)
        let whitespaceCoordinateResult = engine.retrieve(
            question: "Chicago train",
            from: [whitespaceCoordinateNote]
        )
        #expect(whitespaceCoordinateResult.sources.first?.excerpt.contains("40.7128") == false)
        #expect(whitespaceCoordinateResult.sources.first?.excerpt.contains("-74.0060") == false)

        let longMatchingTag = "travel " + String(repeating: "context ", count: 30)
        let longMetadataNote = MindNote(
            body: "The train leaves from platform seven at noon.",
            acceptedTags: [longMatchingTag, "private-medical-detail"]
        )
        let longMetadataResult = engine.retrieve(
            question: "travel train",
            from: [longMetadataNote]
        )
        let longMetadataExcerpt = longMetadataResult.sources.first?.excerpt ?? ""
        #expect(longMetadataExcerpt.localizedCaseInsensitiveContains("train leaves"))
        #expect(!longMetadataExcerpt.contains("private-medical-detail"))

        let vehicleNote = MindNote(body: "Car maintenance is due next Tuesday.")
        let sensitiveNearPrefix = MindNote(body: "Private cardiology appointment next Tuesday.")
        let privacyBounded = engine.retrieve(
            question: "car maintenance",
            from: [sensitiveNearPrefix, vehicleNote]
        )
        #expect(privacyBounded.sources.map(\.noteID) == [vehicleNote.id])

        let oneSignalOnly = MindNote(body: "Train museum membership renewal.")
        let multiConcept = engine.retrieve(
            question: "train hotel",
            from: [oneSignalOnly]
        )
        #expect(multiConcept.sources.isEmpty)

        let paraphraseNote = MindNote(body: "Hotel: Hilton. The cost was $148.")
        let paraphrase = engine.retrieve(
            question: "Which lodging was affordable?",
            from: [paraphraseNote]
        )
        #expect(paraphrase.sources.map(\.noteID) == [paraphraseNote.id])

        let stayQuestion = engine.retrieve(
            question: "Where did we stay?",
            from: [paraphraseNote]
        )
        #expect(stayQuestion.sources.map(\.noteID) == [paraphraseNote.id])
    }

    @Test("No evidence returns an explicit no-answer state")
    func noEvidence() {
        let result = RetrievalEngine().retrieve(
            question: "Which hostel had free parking?",
            from: [MindNote(body: "Review chapters 4 and 5 before Friday.")]
        )
        #expect(result.resolution == .noEvidence)
        #expect(result.sources.isEmpty)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!DateFilter.sevenDays.includes(now.addingTimeInterval(86_400), now: now))
        #expect(!DateFilter.thirtyDays.includes(now.addingTimeInterval(86_400), now: now))
    }

    @Test("Retrieved sources preserve note time, event date, place, and matched tags")
    func retrievalPreservesContextForEvidenceAndAI() {
        let calendar = Calendar(identifier: .gregorian)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let eventDate = Date(timeIntervalSince1970: 1_800_086_340)
        let place = SavedPlace(
            name: "North Hall",
            detail: "Chicago",
            latitude: 41.8781,
            longitude: -87.6295
        )
        let note = MindNote(
            title: "Quiz reminder",
            body: "Professor Rivera said to complete the online quiz.",
            createdAt: capturedAt,
            updatedAt: capturedAt,
            eventDate: eventDate,
            place: place,
            acceptedTags: ["quiz", "course"]
        )

        let source = RetrievalEngine().retrieve(
            question: "quiz",
            from: [note],
            now: capturedAt,
            calendar: calendar
        ).sources.first

        #expect(source?.context?.referenceAt == capturedAt)
        #expect(source?.context?.capturedAt == capturedAt)
        #expect(source?.context?.eventDate == eventDate)
        #expect(source?.context?.locationLabel == "North Hall — Chicago")
        #expect(source?.context?.tags == ["quiz"])
        #expect(source?.excerpt.contains("event date:") == true)
        #expect(source?.excerpt.contains("captured:") == true)
        #expect(source?.excerpt.contains("North Hall") == true)
        #expect(source?.excerpt.contains("quiz") == true)
    }

    @Test("Time-of-day context can answer local retrieval questions")
    func retrievalUsesCaptureTimeContext() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2027, month: 1, day: 15, hour: 9)
        )!
        let morningNote = MindNote(
            body: "Review the quiz rubric.",
            createdAt: calendar.date(
                from: DateComponents(year: 2027, month: 1, day: 15, hour: 10)
            )!,
            updatedAt: calendar.date(
                from: DateComponents(year: 2027, month: 1, day: 15, hour: 10)
            )!
        )
        let eveningNote = MindNote(
            body: "Review the quiz rubric.",
            createdAt: calendar.date(
                from: DateComponents(year: 2027, month: 1, day: 15, hour: 20)
            )!,
            updatedAt: calendar.date(
                from: DateComponents(year: 2027, month: 1, day: 15, hour: 20)
            )!
        )

        let result = RetrievalEngine().retrieve(
            question: "morning",
            from: [eveningNote, morningNote],
            now: now,
            calendar: calendar
        )

        #expect(result.sources.map(\.noteID) == [morningNote.id])
    }

    @Test("Ask temporal intent excludes the opposite timeframe and ranks by date")
    func retrievalUsesUpcomingAndCompletedTimeframes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2027, month: 1, day: 15, hour: 12)
        )!
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(
                from: DateComponents(year: 2027, month: 1, day: day, hour: hour)
            )!
        }
        func quizNote(_ title: String, day: Int, hour: Int) -> MindNote {
            let eventDate = date(day, hour)
            return MindNote(
                title: title,
                body: "Online quiz",
                createdAt: eventDate.addingTimeInterval(-86_400),
                updatedAt: eventDate.addingTimeInterval(-86_400),
                eventDate: eventDate,
                acceptedTags: ["quiz"]
            )
        }

        let olderCompleted = quizNote("Older quiz", day: 5, hour: 10)
        let recentCompleted = quizNote("Recent quiz", day: 12, hour: 10)
        let soonUpcoming = quizNote("Soon quiz", day: 16, hour: 10)
        let laterUpcoming = quizNote("Later quiz", day: 20, hour: 10)
        let notes = [laterUpcoming, olderCompleted, soonUpcoming, recentCompleted]
        let engine = RetrievalEngine()

        let upcoming = engine.retrieve(
            question: "Which quiz am I going to take?",
            from: notes,
            now: now,
            calendar: calendar
        )
        #expect(upcoming.sources.map(\.noteID) == [soonUpcoming.id, laterUpcoming.id])

        let completed = engine.retrieve(
            question: "Which quiz have I taken?",
            from: notes,
            now: now,
            calendar: calendar
        )
        #expect(completed.sources.map(\.noteID) == [recentCompleted.id, olderCompleted.id])
    }

    @Test("Ask derives relative weekday dates and keeps all upcoming evidence")
    func retrievalInfersRelativeWeekdayEventDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 14, minute: 32)
        )!
        let capturedAt = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 1, minute: 33)
        )!
        let saturday = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29)
        )!
        let deadline = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 15, hour: 23, minute: 59)
        )!
        let pastNote = MindNote(
            body: "Professor said we needed to take the online quiz before Tuesday.",
            createdAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 23, hour: 12)
            )!,
            updatedAt: capturedAt,
            acceptedTags: ["quiz"]
        )
        let relativeNote = MindNote(
            body: "Professor said we need to take an online quiz on Saturday.",
            createdAt: capturedAt,
            updatedAt: capturedAt,
            acceptedTags: ["quiz"]
        )
        let deadlineNote = MindNote(
            title: "[MMTEST] Online quiz deadline",
            body: "Professor Rivera said the online quiz must be completed by Tuesday, September 15 at 11:59 PM.",
            createdAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 21, hour: 13, minute: 5)
            )!,
            updatedAt: capturedAt,
            eventDate: deadline,
            acceptedTags: ["quiz"]
        )

        let result = RetrievalEngine().retrieve(
            question: "When do I need to take an online quiz?",
            from: [pastNote, deadlineNote, relativeNote],
            now: now,
            calendar: calendar
        )

        #expect(result.sources.map(\.noteID) == [relativeNote.id, deadlineNote.id])
        let relativeSource = result.sources.first { $0.noteID == relativeNote.id }
        #expect(relativeSource?.noteDate == saturday)
        #expect(relativeSource?.context?.eventDate == nil)
        #expect(relativeSource?.context?.inferredEventDate == saturday)
        #expect(relativeSource?.excerpt.contains("mentioned event date:") == true)

        let completed = RetrievalEngine().retrieve(
            question: "Which online quiz have I taken?",
            from: [pastNote, deadlineNote, relativeNote],
            now: now,
            calendar: calendar
        )
        #expect(completed.sources.map(\.noteID) == [pastNote.id])
    }

    @Test("Tag suggestions stay bounded and prefer an existing matching label")
    func tagsPreferExistingLabels() {
        let note = MindNote(body: "Weekend trip: check the last train and hotel cost.")
        let tags = TagSuggestionEngine().suggestTags(
            for: note,
            existingTags: ["Weekend Trip", "Study", "Budget"]
        )

        #expect((1...3).contains(tags.count))
        #expect(tags.contains("Weekend Trip"))
        #expect(Set(tags.map { $0.lowercased() }).count == tags.count)
    }

    @Test("Grounding validation removes unknown sources and non-verbatim evidence")
    func groundingValidation() throws {
        let noteID = UUID()
        let source = SourceReference(
            noteID: noteID,
            noteTitle: "Train detail",
            noteDate: .now,
            excerpt: "The last train leaves at 10:40 PM.",
            score: 0.92,
            supportType: .exactText
        )
        let unknownID = UUID()
        let json = """
        {
          "answer": "Plan to leave before the 10:40 PM train.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"last train leaves at 10:40 PM"}],
          "claims": [
            {"text":"The train leaves at 10:40 PM.","evidence":[{"source_id":"\(noteID.uuidString)","quote":"The last train leaves at 10:40 PM."}]},
            {"text":"The station has free parking.","evidence":[{"source_id":"\(noteID.uuidString)","quote":"The last train leaves at 10:40 PM."}]},
            {"text":"The station has free parking.","evidence":[{"source_id":"\(unknownID.uuidString)","quote":"free parking"}]}
          ],
          "conflicts": [],
          "missing_information": ["Return fare"],
          "checklist": [
            {"text":"Confirm the train","source_ids":["\(noteID.uuidString)"]},
            {"text":"Reserve free parking","source_ids":["\(unknownID.uuidString)"]}
          ],
          "assumption": ""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(json.utf8),
            sources: [source]
        )

        #expect(conclusion.claims.count == 1)
        #expect(conclusion.claims.first?.text.contains("10:40") == true)
        #expect(conclusion.suggestedChecklist.isEmpty)
        #expect(conclusion.allReferencedNoteIDs == [noteID])

        let contradiction = """
        {
          "answer": "The last train does not leave at 10:40 PM.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"The last train leaves at 10:40 PM."}],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [],
          "assumption": ""
        }
        """
        do {
            _ = try GroundingValidator.validatedConclusion(
                from: Data(contradiction.utf8),
                sources: [source]
            )
            Issue.record("A negated claim must not pass through with unrelated verbatim evidence.")
        } catch let error as AIProviderError {
            #expect(error == .invalidGrounding)
        }

        let swappedEntity = """
        {
          "answer": "Alice booked Marriott.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"Alice booked Hilton. Bob booked Marriott."}],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [],
          "assumption": ""
        }
        """
        let associationSource = SourceReference(
            noteID: noteID,
            noteTitle: "Bookings",
            noteDate: .now,
            excerpt: "Alice booked Hilton. Bob booked Marriott.",
            score: 1,
            supportType: .exactText
        )
        do {
            _ = try GroundingValidator.validatedConclusion(
                from: Data(swappedEntity.utf8),
                sources: [associationSource]
            )
            Issue.record("Evidence from separate facts must not be recombined into a new association.")
        } catch let error as AIProviderError {
            #expect(error == .invalidGrounding)
        }

        let temporalContradiction = """
        {
          "answer": "The last train leaves before 10:40 PM.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"The last train leaves at 10:40 PM."}],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [],
          "assumption": ""
        }
        """
        do {
            _ = try GroundingValidator.validatedConclusion(
                from: Data(temporalContradiction.utf8),
                sources: [source]
            )
            Issue.record("A before/at substitution must not pass grounding validation.")
        } catch let error as AIProviderError {
            #expect(error == .invalidGrounding)
        }

        let uncertainSource = SourceReference(
            noteID: noteID,
            noteTitle: "Hotel estimate",
            noteDate: .now,
            excerpt: "The hotel may cost $200.",
            score: 1,
            supportType: .exactText
        )
        let certaintySubstitution = """
        {
          "answer": "The hotel costs $200.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"The hotel may cost $200."}],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [],
          "assumption": ""
        }
        """
        do {
            _ = try GroundingValidator.validatedConclusion(
                from: Data(certaintySubstitution.utf8),
                sources: [uncertainSource]
            )
            Issue.record("An uncertain source must not be displayed as a certain claim.")
        } catch let error as AIProviderError {
            #expect(error == .invalidGrounding)
        }

        let hotelSource = SourceReference(
            noteID: noteID,
            noteTitle: "Hotel price",
            noteDate: .now,
            excerpt: "Hotel price was $148.",
            score: 1,
            supportType: .exactText
        )
        let answeredAndMissing = """
        {
          "answer": "Hotel price was $148.",
          "answer_evidence": [{"source_id":"\(noteID.uuidString)","quote":"Hotel price was $148."}],
          "claims": [],
          "conflicts": [],
          "missing_information": ["Hotel price was not provided."],
          "checklist": [],
          "assumption": ""
        }
        """
        let reconciled = try GroundingValidator.validatedConclusion(
            from: Data(answeredAndMissing.utf8),
            sources: [hotelSource],
            question: "What was the hotel price?"
        )
        #expect(reconciled.missingInformation.isEmpty)
    }

    @Test("A provider no-answer preserves specific missing information")
    func providerNoAnswerIsValid() throws {
        let source = SourceReference(
            noteID: UUID(),
            noteTitle: "Trip fragment",
            noteDate: .now,
            excerpt: "Saved context — date: Aug 22, 2026\nNote excerpt — Train time unknown.",
            score: 0.8,
            supportType: .related
        )
        let payload = """
        {
          "answer": "",
          "answer_evidence": [],
          "claims": [],
          "conflicts": [],
          "missing_information": [
            "The return train time is not recorded.",
            "Paris is the capital of France."
          ],
          "checklist": [],
          "assumption": "Paris is the capital of France."
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source],
            question: "What is the return train time?"
        )
        #expect(conclusion.directAnswer.isEmpty)
        #expect(conclusion.missingInformation == ["The return train time is not recorded."])
        #expect(conclusion.statedAssumption.isEmpty)
    }

    @Test("Share preview includes only selected plan content and selected source metadata")
    func privacySafeSharePreview() {
        let source = PlanSourceLink(
            noteID: UUID(),
            titleAtSave: "Train note",
            noteDate: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAtSave: .now
        )
        let plan = MindPlan(
            title: "Weekend plan",
            conclusion: "Take the earlier train.",
            checklist: [PlanChecklistItem(text: "Buy ticket")],
            date: nil,
            place: "Milwaukee",
            sources: [source]
        )

        let withoutSources = plan.sharePreview()
        #expect(!withoutSources.contains("Train note"))
        #expect(withoutSources.contains("Provenance: AI-generated"))

        let withSelectedSource = plan.sharePreview(including: [source.id])
        #expect(withSelectedSource.contains("Train note"))
        #expect(withSelectedSource.contains("Take the earlier train"))
    }

    @Test("Representative local capture, retrieval, and tag operations stay within MVP budgets")
    func representativeLocalPerformanceGates() throws {
        let clock = ContinuousClock()
        let notes = (0..<1_000).map { index in
            MindNote(
                title: index.isMultiple(of: 5) ? "Midwest trip \(index)" : "Course item \(index)",
                body: index.isMultiple(of: 5)
                    ? "Milwaukee weekend train leaves at 10:40 PM and the hotel cost was $148."
                    : "Lecture fragment \(index) about the project rubric and Thursday office hours.",
                acceptedTags: [index.isMultiple(of: 5) ? "travel" : "study"]
            )
        }

        let searchStartedAt = clock.now
        let searchResult = RetrievalEngine().retrieve(
            question: "Milwaukee weekend train hotel cost",
            from: notes
        )
        let searchElapsed = searchStartedAt.duration(to: clock.now)
        #expect(searchElapsed < .seconds(1))
        #expect(searchResult.sources.count == 200)

        let tagStartedAt = clock.now
        let tags = TagSuggestionEngine().suggestTags(
            for: notes[0],
            existingTags: ["travel", "study", "budget"]
        )
        let tagElapsed = tagStartedAt.duration(to: clock.now)
        #expect(tagElapsed < .seconds(5))
        #expect((1...3).contains(tags.count))

        let store = MindMapStore(storageURL: temporaryStoreURL("performance"))
        let saveStartedAt = clock.now
        _ = try store.createNote(from: CaptureDraft(body: "One-tap local capture 🚆"))
        let saveElapsed = saveStartedAt.duration(to: clock.now)
        #expect(saveElapsed < .milliseconds(300))
    }

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapAITests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("archive.json", isDirectory: false)
    }
}
