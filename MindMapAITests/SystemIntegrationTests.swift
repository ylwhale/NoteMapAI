import CoreSpotlight
import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct SystemIntegrationTests {
    @Test("Share and Shortcut captures queue independently and drain safely")
    func externalCaptureInboxIsAppendOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCaptureInboxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = MindMapSharedCaptureInbox(directoryURL: directory)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let shared = try inbox.enqueue(
            body: "Paris hotel confirmation",
            source: .shareExtension,
            now: timestamp
        )
        let shortcut = try inbox.enqueue(
            title: "Course reminder",
            body: "Review chapter 8 before Thursday",
            source: .shortcut,
            now: timestamp
        )

        let pending = try inbox.pendingCaptures()
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.id)) == Set([shared.id, shortcut.id]))
        #expect(Set(pending.map(\.source)) == Set([.shareExtension, .shortcut]))

        try inbox.remove(shared)
        #expect(try inbox.pendingCaptures().map(\.id) == [shortcut.id])
    }

    @Test("An interrupted inbox import cannot duplicate a saved note")
    func captureSessionMakesImportIdempotent() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCaptureImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let store = MindMapStore(storageURL: storeDirectory.appendingPathComponent("archive.json"))
        let request = MindMapExternalCapture(
            title: "Shared itinerary",
            body: "Train from Paris to London leaves at 09:12.",
            source: .shareExtension
        )
        let draft = CaptureDraft(id: request.id, title: request.title, body: request.body)

        let first = try store.createNote(from: draft, now: request.createdAt)
        let retried = try store.createNote(from: draft, now: request.createdAt)

        #expect(first.id == retried.id)
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.captureSessionID == request.id)
    }

    @Test("Invalid inbox files are quarantined without blocking valid captures")
    func invalidInboxFilesDoNotPoisonQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCapturePoisonTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = MindMapSharedCaptureInbox(directoryURL: directory)
        let valid = try inbox.enqueue(
            body: "Valid capture survives the batch.",
            source: .shareExtension
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("\(UUID().uuidString).json")
        )

        let mismatchedCapture = MindMapExternalCapture(
            body: "This file must not be imported under the wrong name.",
            source: .shortcut
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(mismatchedCapture).write(
            to: directory.appendingPathComponent("\(UUID().uuidString).json")
        )

        let scan = try inbox.scanPendingCaptures()
        #expect(scan.captures.map(\.id) == [valid.id])
        #expect(Set(scan.issues.map(\.kind)) == [.malformedCapture, .mismatchedIdentifier])
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("Quarantine", isDirectory: true),
                includingPropertiesForKeys: nil
            ).count == 2
        )

        try inbox.remove(scan.captures[0])
        #expect(try inbox.pendingCaptures().isEmpty)
    }

    @Test("A schema-valid blank capture is quarantined without blocking valid captures")
    func blankInboxCaptureDoesNotPoisonQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCaptureBlankTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = MindMapSharedCaptureInbox(directoryURL: directory)
        let valid = try inbox.enqueue(
            body: "Keep this valid capture available.",
            source: .shareExtension
        )
        let blank = MindMapExternalCapture(body: "   \n", source: .shortcut)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(blank).write(
            to: directory
                .appendingPathComponent(blank.id.uuidString.lowercased())
                .appendingPathExtension("json")
        )

        let scan = try inbox.scanPendingCaptures()

        #expect(scan.captures.map(\.id) == [valid.id])
        #expect(scan.issues.map(\.kind) == [.emptyCapture])
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("Quarantine", isDirectory: true),
                includingPropertiesForKeys: nil
            ).count == 1
        )
    }

    @Test("Delete Everything removes valid and quarantined shared captures")
    func sharedCaptureInboxDeletionRemovesQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCaptureDeleteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inbox = MindMapSharedCaptureInbox(directoryURL: directory)
        _ = try inbox.enqueue(body: "Private queued text", source: .shareExtension)
        try Data("unreadable private text".utf8).write(
            to: directory.appendingPathComponent("\(UUID().uuidString).json")
        )
        _ = try inbox.scanPendingCaptures()
        #expect(FileManager.default.fileExists(atPath: directory.path))

        try inbox.deleteAllQueuedCaptures()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try inbox.pendingCaptures().isEmpty)
    }

    @Test("Spotlight replacements are serialized and coalesce pending snapshots")
    func spotlightReplacementCoordinatorCoalescesPendingWork() async throws {
        let probe = ReplacementProbe()
        let coordinator = SerializedReplacementCoordinator<[Int]> { snapshot in
            try await probe.record(snapshot)
        }

        let first = Task { try await coordinator.submit([1]) }
        await probe.waitUntilFirstStarts()

        let second = Task { try await coordinator.submit([2]) }
        while await coordinator.submissionCount < 2 {
            await Task.yield()
        }
        let third = Task { try await coordinator.submit([3]) }
        while await coordinator.submissionCount < 3 {
            await Task.yield()
        }

        await probe.releaseFirst()
        try await first.value
        try await second.value
        try await third.value

        #expect(await probe.snapshots == [[1], [3]])
        #expect(await probe.maximumConcurrentOperations == 1)
    }

    @Test("A delayed older Spotlight revision cannot replace newer content")
    func spotlightReplacementCoordinatorRejectsStaleRevision() async throws {
        let probe = ReplacementProbe()
        let coordinator = SerializedReplacementCoordinator<[Int]> { snapshot in
            try await probe.record(snapshot)
        }

        let first = Task { try await coordinator.submit([1], generation: 1) }
        await probe.waitUntilFirstStarts()

        let newest = Task { try await coordinator.submit([3], generation: 3) }
        while await coordinator.submissionCount < 3 {
            await Task.yield()
        }
        try await coordinator.submit([2], generation: 2)

        await probe.releaseFirst()
        try await first.value
        try await newest.value

        #expect(await probe.snapshots == [[1], [3]])
        #expect(await probe.maximumConcurrentOperations == 1)
    }

    @Test("Explicit Spotlight deletion wins over a delayed pre-deletion snapshot")
    func explicitSpotlightDeletionRejectsOlderSnapshot() async throws {
        let probe = SpotlightSnapshotProbe()
        let indexer = MindMapSpotlightIndexer { snapshot in
            await probe.record(
                itemCount: snapshot.items.count,
                deletesLegacyDomain: snapshot.deletesLegacyDomain
            )
        }
        let note = MindNote(title: "Private draft", body: "Remove this from Spotlight.")

        try await indexer.replaceIndex(with: [note])
        let delayedPreDeletionRevision = indexer.reserveRevision()
        try await indexer.deleteAllNoteItems()
        try await indexer.replaceIndex(
            with: [note],
            revision: delayedPreDeletionRevision
        )

        #expect(await probe.itemCounts == [1, 0])
        #expect(await probe.legacyDeletionFlags == [false, true])
    }

    @Test("An outside capture never clears an unfinished Home draft")
    func outsideCapturePreservesHomeDraft() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MindMapCaptureDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let store = MindMapStore(storageURL: storeDirectory.appendingPathComponent("archive.json"))
        let homeDraft = CaptureDraft(
            title: "Unfinished idea",
            body: "Keep this text while an outside capture arrives."
        )
        store.updateCaptureDraft(homeDraft)

        let outsideDraft = CaptureDraft(
            id: UUID(),
            title: "Shared link",
            body: "https://example.com/course"
        )
        _ = try store.createNote(from: outsideDraft, preserveCaptureDraft: true)

        #expect(store.notes.count == 1)
        #expect(store.preferences.captureDraft == homeDraft)

        let reloaded = MindMapStore(storageURL: storeDirectory.appendingPathComponent("archive.json"))
        #expect(reloaded.notes.count == 1)
        #expect(reloaded.preferences.captureDraft == homeDraft)
    }

    @Test("Spotlight note metadata remains useful and on-device searchable")
    func spotlightItemContainsExistingNoteContext() throws {
        let note = MindNote(
            title: "Architecture exam",
            body: "The final covers Gothic cathedrals and Roman arches.",
            place: SavedPlace(
                name: "Paris",
                detail: "Sorbonne University",
                latitude: 48.8462,
                longitude: 2.3449
            ),
            acceptedTags: ["course", "exam"],
            tripTheme: "study abroad"
        )

        let item = MindMapSpotlightIndexer.searchableItem(for: note)
        #expect(item.uniqueIdentifier == note.id.uuidString)
        #expect(item.domainIdentifier == MindMapSystemIntegrationConfiguration.spotlightDomainIdentifier)
        #expect(item.attributeSet.title == "Architecture exam")
        #expect(item.attributeSet.contentDescription?.contains("Gothic cathedrals") == true)
        #expect(item.attributeSet.namedLocation == "Paris")
        #expect(Set(item.attributeSet.keywords ?? []).isSuperset(of: ["course", "exam", "study abroad", "Paris"]))
    }
}

private actor ReplacementProbe {
    private(set) var snapshots: [[Int]] = []
    private(set) var maximumConcurrentOperations = 0
    private var concurrentOperations = 0
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func record(_ snapshot: [Int]) async throws {
        snapshots.append(snapshot)
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
        defer { concurrentOperations -= 1 }

        guard snapshot == [1] else { return }
        firstStarted = true
        firstStartWaiters.forEach { $0.resume() }
        firstStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstRelease = continuation
        }
    }

    func waitUntilFirstStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}

private actor SpotlightSnapshotProbe {
    private(set) var itemCounts: [Int] = []
    private(set) var legacyDeletionFlags: [Bool] = []

    func record(itemCount: Int, deletesLegacyDomain: Bool) {
        itemCounts.append(itemCount)
        legacyDeletionFlags.append(deletesLegacyDomain)
    }
}
