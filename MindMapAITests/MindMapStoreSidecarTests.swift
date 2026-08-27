import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct MindMapStoreSidecarTests {
    @Test("Draft edits replace only the small preferences sidecar")
    func draftEditsDoNotRewriteTheArchive() throws {
        let archiveURL = temporaryStoreURL("hot-path")
        let store = MindMapStore(storageURL: archiveURL)
        let archiveOnlyMarker = "ARCHIVE_ONLY_NOTE_" + String(repeating: "x", count: 32_000)
        _ = try store.createNote(from: CaptureDraft(body: archiveOnlyMarker))

        let archiveBeforeTyping = try Data(contentsOf: archiveURL)
        let draft = CaptureDraft(
            title: "Quick capture",
            body: "SIDECAR_ONLY_DRAFT 🚆",
            tripTheme: "weekend"
        )
        store.updateCaptureDraft(draft)

        let archiveAfterTyping = try Data(contentsOf: archiveURL)
        let sidecarData = try Data(contentsOf: preferencesURL(for: archiveURL))
        let sidecarText = String(decoding: sidecarData, as: UTF8.self)

        #expect(archiveAfterTyping == archiveBeforeTyping)
        #expect(sidecarText.contains("SIDECAR_ONLY_DRAFT"))
        #expect(!sidecarText.contains("ARCHIVE_ONLY_NOTE"))
        #expect(sidecarData.count < archiveAfterTyping.count)

        let relaunched = MindMapStore(storageURL: archiveURL)
        #expect(relaunched.preferences.captureDraft == draft)
        #expect(relaunched.notes.first?.body == archiveOnlyMarker)
    }

    @Test("A corrupt sidecar resets privacy permissions and salvages safe settings")
    func corruptSidecarFailsPrivacySafe() throws {
        let archiveURL = temporaryStoreURL("corrupt-sidecar")
        let store = MindMapStore(storageURL: archiveURL)
        let captureDraft = CaptureDraft(
            title: "Packing",
            body: "Bring the blue notebook",
            tripTheme: "school trip"
        )
        let askDraft = AskDraft(
            question: "When is the last train?",
            filters: RetrievalFilters(tag: "travel", place: "Chicago")
        )

        store.preferences.aiProcessingConsent = .accepted
        store.preferences.keepLocalHistory = false
        store.preferences.aiModel = "gpt-sidecar-test"
        store.updateCaptureDraft(captureDraft)
        store.updateAskDraft(question: askDraft.question, filters: askDraft.filters)

        let sidecarURL = preferencesURL(for: archiveURL)
        let data = try Data(contentsOf: sidecarURL)
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var values = try #require(root["preferences"] as? [String: Any])
        values["aiProcessingConsent"] = "corrupt-permission-value"
        root["preferences"] = values
        try JSONSerialization.data(withJSONObject: root).write(to: sidecarURL, options: .atomic)

        let recovered = MindMapStore(storageURL: archiveURL)
        #expect(recovered.preferences.aiProcessingConsent == .undecided)
        #expect(recovered.preferences.locationCaptureEnabled == false)
        #expect(recovered.preferences.keepLocalHistory == false)
        #expect(recovered.preferences.aiModel == "gpt-sidecar-test")
        #expect(recovered.preferences.captureDraft == captureDraft)
        #expect(recovered.preferences.askDraft == askDraft)
        #expect(recovered.persistenceMessage?.contains("preferences file") == true)
    }

    @Test("Archive recovery cannot reactivate privacy permissions from a valid sidecar")
    func archiveRecoveryRequiresFreshPrivacyReview() throws {
        let archiveURL = temporaryStoreURL("privacy-recovery")
        let store = MindMapStore(storageURL: archiveURL)
        store.preferences.aiProcessingConsent = .accepted
        store.preferences.locationCaptureEnabled = true

        let firstNote = try store.createNote(from: CaptureDraft(body: "First recovery note"))
        let secondNote = try store.createNote(from: CaptureDraft(body: "Second recovery note"))
        try Data("corrupt archive".utf8).write(to: archiveURL, options: .atomic)

        let recovered = MindMapStore(storageURL: archiveURL)
        #expect(recovered.notes.map(\.id) == [secondNote.id, firstNote.id])
        #expect(recovered.preferences.aiProcessingConsent == .undecided)
        #expect(recovered.preferences.locationCaptureEnabled == false)
        #expect(recovered.persistenceMessage?.contains("reset for review") == true)
    }

    @Test("Delete all resets both persistence files without retaining drafts")
    func deleteAllRemovesPersonalDraftsFromTheSidecar() throws {
        let archiveURL = temporaryStoreURL("delete-all")
        let store = MindMapStore(storageURL: archiveURL)
        let noteMarker = "PERSONAL_NOTE_MUST_BE_REMOVED"
        let captureMarker = "PERSONAL_CAPTURE_DRAFT_MUST_BE_REMOVED"
        let askMarker = "PERSONAL_ASK_DRAFT_MUST_BE_REMOVED"

        _ = try store.createNote(from: CaptureDraft(body: noteMarker))
        store.updateCaptureDraft(CaptureDraft(body: captureMarker))
        store.updateAskDraft(question: askMarker, filters: .init())
        try store.deleteAllLocalData()

        let archiveText = String(decoding: try Data(contentsOf: archiveURL), as: UTF8.self)
        let sidecarText = String(
            decoding: try Data(contentsOf: preferencesURL(for: archiveURL)),
            as: UTF8.self
        )
        for marker in [noteMarker, captureMarker, askMarker] {
            #expect(!archiveText.contains(marker))
            #expect(!sidecarText.contains(marker))
        }

        let relaunched = MindMapStore(storageURL: archiveURL)
        #expect(relaunched.notes.isEmpty)
        #expect(relaunched.preferences.captureDraft.isEmpty)
        #expect(relaunched.preferences.askDraft.question.isEmpty)
    }

    @Test("Cleared drafts never remain in the archive or sanitized backup")
    func clearedDraftDoesNotSurviveOutsideSidecar() throws {
        let archiveURL = temporaryStoreURL("cleared-draft")
        let store = MindMapStore(storageURL: archiveURL)
        let note = try store.createNote(from: CaptureDraft(body: "Ordinary saved note"))
        let marker = "SENSITIVE_DRAFT_MUST_NOT_REMAIN"
        store.updateCaptureDraft(CaptureDraft(body: marker))
        #expect(store.setFavorite(true, noteID: note.id))
        store.clearCaptureDraft()

        let archiveText = String(decoding: try Data(contentsOf: archiveURL), as: UTF8.self)
        let backupURL = archiveURL.deletingPathExtension().appendingPathExtension("backup.json")
        let backupText = String(decoding: try Data(contentsOf: backupURL), as: UTF8.self)
        #expect(!archiveText.contains(marker))
        #expect(!backupText.contains(marker))
        #expect(MindMapStore(storageURL: archiveURL).preferences.captureDraft.isEmpty)
    }

    @Test("A missing sidecar fails consent and location capture closed")
    func missingSidecarFailsClosed() throws {
        let archiveURL = temporaryStoreURL("missing-sidecar")
        let store = MindMapStore(storageURL: archiveURL)
        store.preferences.aiProcessingConsent = .accepted
        store.preferences.locationCaptureEnabled = true
        store.updateCaptureDraft(CaptureDraft(body: "Draft held only in sidecar"))
        _ = try store.createNote(from: CaptureDraft(body: "Saved note"))

        try FileManager.default.removeItem(at: preferencesURL(for: archiveURL))
        let relaunched = MindMapStore(storageURL: archiveURL)
        #expect(relaunched.preferences.aiProcessingConsent == .undecided)
        #expect(relaunched.preferences.locationCaptureEnabled == false)
        #expect(relaunched.preferences.captureDraft.isEmpty)
        #expect(relaunched.persistenceMessage?.contains("preferences file was missing") == true)
    }

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapStoreSidecarTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("archive.json", isDirectory: false)
    }

    private func preferencesURL(for archiveURL: URL) -> URL {
        archiveURL
            .deletingPathExtension()
            .appendingPathExtension("preferences.json")
    }
}
