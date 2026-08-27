import CoreLocation
import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct MindMapServicePrivacyTests {
    @Test("OpenAI request sends only the question and selected excerpts with storage disabled")
    func openAIRequestIsPrivacyBoundedAndStructured() async throws {
        let endpoint = uniqueEndpoint("privacy")
        let recorder = CapturedRequestBox()
        let apiKey = "sk-test-private-key-never-in-body"
        let place = SavedPlace(
            name: "Private dorm room",
            detail: "Exact room and floor must stay local",
            latitude: 41.878_123,
            longitude: -87.629_456
        )
        let relevantNote = MindNote(
            title: "Train home",
            body: "The last train leaves at 10:40 PM.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            place: place,
            acceptedTags: ["travel"]
        )
        let unrelatedPrivateText = "UNRELATED_PRIVATE_MEDICAL_NOTE_take_medication_at_7"
        let unrelatedNote = MindNote(body: unrelatedPrivateText, acceptedTags: ["health"])
        let retrieval = RetrievalEngine(relevanceThreshold: 0.40).retrieve(
            question: "last train",
            from: [relevantNote, unrelatedNote]
        )
        #expect(retrieval.sources.map(\.noteID) == [relevantNote.id])

        let providerData = try successfulProviderEnvelope(
            answer: "The last train leaves at 10:40 PM.",
            sourceID: relevantNote.id,
            quote: "last train leaves at 10:40 PM"
        )
        MockResponsesURLProtocol.register(endpoint) { request in
            recorder.record(request)
            return (
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                providerData
            )
        }
        defer { MockResponsesURLProtocol.unregister(endpoint) }

        let service = OpenAIConclusionService(
            endpoint: endpoint,
            session: mockSession()
        )
        let question = "When should I leave for the last train?"
        let conclusion = try await service.generateConclusion(
            question: question,
            sources: retrieval.sources,
            apiKey: apiKey,
            model: "gpt-test"
        )
        #expect(conclusion.directAnswer == "The last train leaves at 10:40 PM.")

        guard let request = recorder.request,
              let body = recorder.body,
              let requestJSON = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("The mock did not receive a JSON request.")
            return
        }

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requestJSON["store"] as? Bool == false)
        #expect(requestJSON["model"] as? String == "gpt-test")

        let input = requestJSON["input"] as? String ?? ""
        #expect(input.contains(question))
        #expect(input.contains("The last train leaves at 10:40 PM."))
        #expect(input.contains(relevantNote.id.uuidString))
        #expect(!input.contains(unrelatedPrivateText))
        #expect(!input.contains(place.name))
        #expect(!input.contains(place.detail))
        #expect(!input.contains("41.878123"))
        #expect(!input.contains("41.8781"))
        #expect(!input.contains("-87.629456"))
        #expect(!input.contains("-87.6295"))

        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(!bodyText.contains(apiKey))
        #expect(request.url?.absoluteString.contains(apiKey) == false)
        let headersContainingKey = request.allHTTPHeaderFields?
            .filter { $0.value.contains(apiKey) }
            .map { $0.key.lowercased() } ?? []
        #expect(headersContainingKey == ["authorization"])

        guard let text = requestJSON["text"] as? [String: Any],
              let format = text["format"] as? [String: Any],
              let schema = format["schema"] as? [String: Any] else {
            Issue.record("The request did not contain the required structured-output schema.")
            return
        }
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "mindmap_grounded_conclusion")
        #expect(format["strict"] as? Bool == true)
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        let required = Set(schema["required"] as? [String] ?? [])
        #expect(required == Set([
            "answer_parts",
            "claims",
            "conflicts",
            "missing_information",
            "checklist",
            "assumption"
        ]))

        let properties = schema["properties"] as? [String: Any]
        let answerParts = properties?["answer_parts"] as? [String: Any]
        let answerPartItems = answerParts?["items"] as? [String: Any]
        let answerPartProperties = answerPartItems?["properties"] as? [String: Any]
        let answerKind = answerPartProperties?["kind"] as? [String: Any]
        #expect(Set(answerKind?["enum"] as? [String] ?? []) == Set([
            "source_fact",
            "generated_guidance"
        ]))

        let checklist = properties?["checklist"] as? [String: Any]
        let checklistItems = checklist?["items"] as? [String: Any]
        let checklistProperties = checklistItems?["properties"] as? [String: Any]
        let checklistKind = checklistProperties?["kind"] as? [String: Any]
        #expect(Set(checklistKind?["enum"] as? [String] ?? []) == Set([
            "source_action",
            "generated_guidance"
        ]))
        #expect(Set(checklistItems?["required"] as? [String] ?? []) == Set([
            "kind",
            "text",
            "source_ids",
            "evidence"
        ]))
        let checklistEvidence = checklistProperties?["evidence"] as? [String: Any]
        let checklistEvidenceItems = checklistEvidence?["items"] as? [String: Any]
        #expect(Set(checklistEvidenceItems?["required"] as? [String] ?? []) == Set([
            "source_id",
            "quote"
        ]))

        let instructions = requestJSON["instructions"] as? String ?? ""
        #expect(instructions.contains("Generated guidance may synthesize and add useful next steps"))
        #expect(instructions.contains("must not state or imply a new fact"))
        #expect(instructions.contains("Every checklist item must cite at least one exact evidence quote"))
    }

    @Test("Only explicitly selected excerpts cross the AI request boundary")
    func selectedExcerptBoundaryPreservesOrderAndSupportsEmptySelection() {
        let first = makeSource()
        let second = SourceReference(
            noteID: UUID(),
            noteTitle: "Exam note",
            noteDate: .now,
            excerpt: "The final exam is in room 204.",
            score: 0.85,
            supportType: .exactText
        )
        let third = SourceReference(
            noteID: UUID(),
            noteTitle: "Travel note",
            noteDate: .now,
            excerpt: "The Paris train leaves from Gare du Nord.",
            score: 0.75,
            supportType: .related
        )

        let selected = AskView.sourcesSelectedForRequest(
            [first, second, third],
            selectedSourceIDs: [third.id, first.id]
        )

        #expect(selected.map(\.id) == [first.id, third.id])
        #expect(!selected.contains(where: { $0.excerpt == second.excerpt }))
        #expect(AskView.sourcesSelectedForRequest(
            [first, second, third],
            selectedSourceIDs: []
        ).isEmpty)
    }

    @Test("Provider rejection and URL timeout map to explicit provider errors")
    func providerErrorsAreMapped() async throws {
        let source = makeSource()

        let rejectionEndpoint = uniqueEndpoint("rejected")
        MockResponsesURLProtocol.register(rejectionEndpoint) { _ in
            let body = Data(#"{"error":{"message":"Rate limited for test"}}"#.utf8)
            return (
                HTTPURLResponse(
                    url: rejectionEndpoint,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }
        defer { MockResponsesURLProtocol.unregister(rejectionEndpoint) }

        let rejectedService = OpenAIConclusionService(
            endpoint: rejectionEndpoint,
            session: mockSession()
        )
        do {
            _ = try await rejectedService.generateConclusion(
                question: "When is the train?",
                sources: [source],
                apiKey: "test-key",
                model: "gpt-test"
            )
            Issue.record("Expected the provider rejection to throw.")
        } catch let error as AIProviderError {
            #expect(error == .providerRejected("Rate limited for test"))
        } catch {
            Issue.record("Unexpected rejection error: \(error)")
        }

        let timeoutEndpoint = uniqueEndpoint("timeout")
        MockResponsesURLProtocol.register(timeoutEndpoint) { _ in
            throw URLError(.timedOut)
        }
        defer { MockResponsesURLProtocol.unregister(timeoutEndpoint) }

        let timeoutService = OpenAIConclusionService(
            endpoint: timeoutEndpoint,
            session: mockSession()
        )
        do {
            _ = try await timeoutService.generateConclusion(
                question: "When is the train?",
                sources: [source],
                apiKey: "test-key",
                model: "gpt-test"
            )
            Issue.record("Expected the URL timeout to throw.")
        } catch let error as AIProviderError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected timeout error: \(error)")
        }
    }

    @Test("Revoking AI consent during a batch prevents every later provider request")
    func revokingConsentStopsLaterBatches() async {
        let provider = DelayedBatchProvider()
        let consent = TestConsentState()
        let firstSource = makeSource()
        let secondSource = SourceReference(
            noteID: UUID(),
            noteTitle: "Hotel note",
            noteDate: Date(timeIntervalSince1970: 1_700_000_100),
            excerpt: "The hotel cost was $148.",
            score: 0.90,
            supportType: .exactText
        )

        let operation = Task {
            try await AskView.generateAuthorizedBatches(
                provider: provider,
                question: "What should I know?",
                sourceBatches: [[firstSource], [secondSource]],
                apiKey: "test-key",
                model: "gpt-test",
                overallTimeout: .seconds(2),
                authorization: { consent.isAccepted },
                progress: { _ in }
            )
        }

        await provider.waitUntilFirstRequestStarts()
        consent.isAccepted = false

        do {
            _ = try await operation.value
            Issue.record("Expected consent revocation to stop batch generation.")
        } catch let error as AIRequestBoundaryError {
            #expect(error == .consentRevoked)
        } catch {
            Issue.record("Unexpected consent-revocation error: \(error)")
        }
        #expect(await provider.requestCount == 1)
    }

    @Test("A location failure cannot roll back an already durable note save")
    func locationFailureDoesNotAffectDurableSave() async throws {
        let storageURL = temporaryStoreURL("location-failure")
        let store = MindMapStore(storageURL: storageURL)
        let note = try store.createNote(
            from: CaptureDraft(body: "Remember this even if location fails."),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(store.note(withID: note.id) != nil)

        let manager = FailingLocationManager()
        let locationService = MindMapLocationService(locationManager: manager)
        let place = await locationService.captureCurrentPlace(timeout: 0.25)

        #expect(place == nil)
        #expect(locationService.lastFailure == .unavailable)
        #expect(store.note(withID: note.id)?.place == nil)

        let relaunchedStore = MindMapStore(storageURL: storageURL)
        #expect(relaunchedStore.notes.map(\.id) == [note.id])
        #expect(relaunchedStore.notes.first?.body == "Remember this even if location fails.")
    }

    @Test("Plan source state reports current, changed, and deleted notes")
    func planSourceLifecycleState() throws {
        let store = MindMapStore(storageURL: temporaryStoreURL("plan-source-state"))
        let note = try store.createNote(
            from: CaptureDraft(body: "The train leaves at 10:40 PM."),
            now: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let source = PlanSourceLink(
            noteID: note.id,
            titleAtSave: note.displayTitle,
            noteDate: note.createdAt,
            updatedAtSave: note.updatedAt
        )
        let plan = MindPlan(
            title: "Train plan",
            conclusion: "Leave before 10:40 PM.",
            checklist: [PlanChecklistItem(text: "Check the schedule", sourceNoteIDs: [note.id])],
            date: nil,
            place: "",
            sources: [source]
        )
        try store.upsertPlan(plan)

        guard case .current = store.planSourceState(source) else {
            Issue.record("A source should be current immediately after it is saved.")
            return
        }

        var editedNote = note
        editedNote.body = "The updated train leaves at 10:15 PM."
        try store.updateNote(editedNote)
        guard case .changed = store.planSourceState(source) else {
            Issue.record("Editing the source note should mark the saved source link as changed.")
            return
        }

        store.deleteNote(note.id)
        guard let deletedLink = store.plans.first?.sources.first else {
            Issue.record("The plan should retain a tombstoned source entry.")
            return
        }
        #expect(deletedLink.noteID == nil)
        guard case .deleted = store.planSourceState(deletedLink) else {
            Issue.record("A removed source should be reported as deleted.")
            return
        }
        #expect(store.plans.first?.checklist.first?.sourceNoteIDs.isEmpty == true)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        return URLSession(configuration: configuration)
    }

    private func uniqueEndpoint(_ suffix: String) -> URL {
        URL(string: "https://mindmap.test/\(suffix)/\(UUID().uuidString)")!
    }

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapServicePrivacyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("archive.json", isDirectory: false)
    }

    private func makeSource() -> SourceReference {
        SourceReference(
            noteID: UUID(),
            noteTitle: "Train note",
            noteDate: Date(timeIntervalSince1970: 1_700_000_000),
            excerpt: "The last train leaves at 10:40 PM.",
            score: 0.95,
            supportType: .exactText
        )
    }

    private func successfulProviderEnvelope(
        answer: String,
        sourceID: UUID,
        quote: String
    ) throws -> Data {
        let conclusion: [String: Any] = [
            "answer_parts": [[
                "kind": "source_fact",
                "text": answer,
                "evidence": [["source_id": sourceID.uuidString, "quote": quote]]
            ]],
            "claims": [],
            "conflicts": [],
            "missing_information": [],
            "checklist": [],
            "assumption": ""
        ]
        let conclusionData = try JSONSerialization.data(withJSONObject: conclusion)
        let conclusionText = String(decoding: conclusionData, as: UTF8.self)
        let envelope: [String: Any] = [
            "output": [[
                "content": [[
                    "type": "output_text",
                    "text": conclusionText
                ]]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}

@MainActor
private final class TestConsentState {
    var isAccepted = true
}

private actor DelayedBatchProvider: GroundedConclusionProviding {
    private(set) var requestCount = 0
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFirstRequestStarts() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func generateConclusion(
        question: String,
        sources: [SourceReference],
        apiKey: String,
        model: String
    ) async throws -> GroundedConclusion {
        requestCount += 1
        if requestCount == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        try await Task.sleep(for: .milliseconds(120))
        let source = sources[0]
        return GroundedConclusion(
            directAnswer: source.excerpt,
            answerEvidence: [ClaimEvidence(sourceNoteID: source.noteID, quote: source.excerpt)],
            claims: [],
            conflicts: [],
            missingInformation: [],
            suggestedChecklist: [],
            statedAssumption: ""
        )
    }
}

nonisolated private final class CapturedRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        lock.lock()
        storedRequest = request
        storedBody = body
        lock.unlock()
    }

    private static func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

nonisolated private final class MockResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ url: URL, handler: @escaping Handler) {
        lock.lock()
        handlers[url.absoluteString] = handler
        lock.unlock()
    }

    static func unregister(_ url: URL) {
        lock.lock()
        handlers.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let key = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[key] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let key = request.url?.absoluteString else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let handler: Handler?
        Self.lock.lock()
        handler = Self.handlers[key]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

@MainActor
private final class FailingLocationManager: MindMapLocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters

    private let callbackManager = CLLocationManager()

    func requestWhenInUseAuthorization() { }

    func requestLocation() {
        delegate?.locationManager?(
            callbackManager,
            didFailWithError: CLError(.locationUnknown)
        )
    }

    func stopUpdatingLocation() { }
}
