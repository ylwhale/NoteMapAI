import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

nonisolated enum MindMapSystemIntegrationConfiguration {
    static let appGroupIdentifier = "group.com.jyhuang28.MindMapAI"
    static let captureURLScheme = "mindmapai"
    static let spotlightDomainIdentifier = "com.jyhuang28.MindMapAI.notes"
    static let spotlightIndexName = "com.jyhuang28.MindMapAI.private-notes"
}

nonisolated struct MindMapExternalCapture: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case shareExtension
        case shortcut
    }

    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var source: Source
    /// The exact inbox file this value was decoded from. It is deliberately
    /// excluded from Codable so it can never be supplied by another process.
    fileprivate(set) var sourceFileURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case createdAt
        case source
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String,
        createdAt: Date = .now,
        source: Source
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.source = source
        sourceFileURL = nil
    }
}

nonisolated struct MindMapSharedCaptureInboxIssue: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case malformedCapture
        case mismatchedIdentifier
        case emptyCapture
        case quarantineFailed
    }

    var kind: Kind
    var fileName: String
    var description: String
}

nonisolated struct MindMapSharedCaptureInboxScan: Sendable {
    var captures: [MindMapExternalCapture]
    var issues: [MindMapSharedCaptureInboxIssue]
}

nonisolated enum MindMapSharedCaptureError: LocalizedError {
    case appGroupUnavailable
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The shared MindMap AI capture area is unavailable. Check the app's signing and App Group capability."
        case .emptyCapture:
            return "Add some note text before saving."
        }
    }
}

/// A cross-process, append-only inbox shared by the app, Share Extension, and
/// App Intents. Each request has its own file, so simultaneous captures cannot
/// overwrite one another. The main app removes a request only after its normal
/// transactional note save succeeds.
nonisolated struct MindMapSharedCaptureInbox: Sendable {
    private let injectedDirectoryURL: URL?

    init(directoryURL: URL? = nil) {
        injectedDirectoryURL = directoryURL
    }

    @discardableResult
    func enqueue(
        title: String = "",
        body: String,
        source: MindMapExternalCapture.Source,
        now: Date = .now
    ) throws -> MindMapExternalCapture {
        let capture = MindMapExternalCapture(
            title: title,
            body: body,
            createdAt: now,
            source: source
        )
        guard !capture.body.isEmpty else { throw MindMapSharedCaptureError.emptyCapture }

        let directory = try inboxDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder.mindMapExternalCaptureEncoder.encode(capture)
        try data.write(
            to: fileURL(for: capture.id, in: directory),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        return capture
    }

    func pendingCaptures() throws -> [MindMapExternalCapture] {
        try scanPendingCaptures().captures
    }

    /// Reads every inbox item independently. A corrupt or renamed request is
    /// quarantined instead of poisoning the entire import batch.
    func scanPendingCaptures() throws -> MindMapSharedCaptureInboxScan {
        let directory = try inboxDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return MindMapSharedCaptureInboxScan(captures: [], issues: [])
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }

        var captures: [MindMapExternalCapture] = []
        var issues: [MindMapSharedCaptureInboxIssue] = []
        for url in fileURLs {
            do {
                let data = try Data(contentsOf: url)
                var capture = try JSONDecoder.mindMapExternalCaptureDecoder.decode(
                    MindMapExternalCapture.self,
                    from: data
                )
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == capture.id else {
                    issues.append(quarantine(
                        url,
                        in: directory,
                        kind: .mismatchedIdentifier,
                        description: "The capture identifier did not match its inbox filename."
                    ))
                    continue
                }
                capture.title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
                capture.body = capture.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !capture.body.isEmpty else {
                    issues.append(quarantine(
                        url,
                        in: directory,
                        kind: .emptyCapture,
                        description: "The capture did not contain any note text."
                    ))
                    continue
                }
                capture.sourceFileURL = url
                captures.append(capture)
            } catch {
                issues.append(quarantine(
                    url,
                    in: directory,
                    kind: .malformedCapture,
                    description: "The capture could not be decoded: \(error.localizedDescription)"
                ))
            }
        }

        captures.sort {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
        return MindMapSharedCaptureInboxScan(captures: captures, issues: issues)
    }

    func remove(_ capture: MindMapExternalCapture) throws {
        let directory = try inboxDirectory().standardizedFileURL
        let decodedURL = capture.sourceFileURL?.standardizedFileURL
        let url: URL
        if let decodedURL,
           decodedURL.deletingLastPathComponent() == directory {
            url = decodedURL
        } else {
            url = fileURL(for: capture.id, in: directory)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes the entire app-group inbox, including quarantined unreadable files.
    /// Settings calls this only as part of the user's explicit Delete Everything action.
    func deleteAllQueuedCaptures() throws {
        let directory = try inboxDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func quarantine(
        _ sourceURL: URL,
        in inboxDirectory: URL,
        kind: MindMapSharedCaptureInboxIssue.Kind,
        description: String
    ) -> MindMapSharedCaptureInboxIssue {
        let quarantineDirectory = inboxDirectory.appendingPathComponent("Quarantine", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true
            )
            let destinationURL = quarantineDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return MindMapSharedCaptureInboxIssue(
                kind: kind,
                fileName: sourceURL.lastPathComponent,
                description: description
            )
        } catch {
            return MindMapSharedCaptureInboxIssue(
                kind: .quarantineFailed,
                fileName: sourceURL.lastPathComponent,
                description: "\(description) The invalid file could not be quarantined: \(error.localizedDescription)"
            )
        }
    }

    private func inboxDirectory() throws -> URL {
        if let injectedDirectoryURL { return injectedDirectoryURL }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MindMapSystemIntegrationConfiguration.appGroupIdentifier
        ) else {
            throw MindMapSharedCaptureError.appGroupUnavailable
        }
        return container.appendingPathComponent("CaptureInbox", isDirectory: true)
    }

    private func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }
}

private nonisolated extension JSONEncoder {
    static var mindMapExternalCaptureEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private nonisolated extension JSONDecoder {
    static var mindMapExternalCaptureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct CaptureMindMapNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a MindMap Note"
    static let description = IntentDescription(
        "Save text to your private MindMap AI library from Siri or Shortcuts."
    )

    @Parameter(title: "Note")
    var note: String

    @Parameter(title: "Title", default: "")
    var noteTitle: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$note) in MindMap AI") {
            \.$noteTitle
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try MindMapSharedCaptureInbox().enqueue(
            title: noteTitle,
            body: note,
            source: .shortcut
        )
        return .result(dialog: "Saved to your MindMap AI capture inbox.")
    }
}

nonisolated struct MindMapAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureMindMapNoteIntent(),
            phrases: [
                "Capture a note in \(.applicationName)",
                "Save a thought in \(.applicationName)",
                "Remember this with \(.applicationName)"
            ],
            shortTitle: "Capture Note",
            systemImageName: "square.and.pencil"
        )
    }
}

actor SerializedReplacementCoordinator<Value: Sendable> {
    typealias Operation = @Sendable (Value) async throws -> Void

    private struct Request: Sendable {
        var generation: UInt64
        var value: Value
    }

    private let operation: Operation
    private var pending: Request?
    private var isRunning = false
    private var nextGeneration: UInt64 = 0
    private var newestAcceptedGeneration: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    var submissionCount: UInt64 { nextGeneration }

    func submit(_ value: Value) async throws {
        nextGeneration &+= 1
        let generation = nextGeneration
        try await submitAccepted(value, generation: generation)
    }

    /// Submits a snapshot whose generation was reserved synchronously at the
    /// point where its source state changed. A delayed task can therefore never
    /// overwrite a newer edit or deletion merely because it reached this actor
    /// later.
    func submit(_ value: Value, generation: UInt64) async throws {
        guard generation > newestAcceptedGeneration else { return }
        nextGeneration = max(nextGeneration, generation)
        try await submitAccepted(value, generation: generation)
    }

    private func submitAccepted(_ value: Value, generation: UInt64) async throws {
        newestAcceptedGeneration = generation
        try await withCheckedThrowingContinuation { continuation in
            waiters[generation] = continuation
            pending = Request(generation: generation, value: value)
            guard !isRunning else { return }
            isRunning = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            do {
                try await operation(request.value)
                resolveWaiters(through: request.generation, error: nil)
            } catch {
                resolveWaiters(through: request.generation, error: error)
            }
        }
        isRunning = false
    }

    private func resolveWaiters(through generation: UInt64, error: Error?) {
        let completed = waiters.keys.filter { $0 <= generation }
        for key in completed {
            guard let continuation = waiters.removeValue(forKey: key) else { continue }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
        }
    }
}

private nonisolated final class SpotlightRevisionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func reserve() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        return revision
    }
}

nonisolated struct SpotlightSearchableSnapshot: @unchecked Sendable {
    var items: [CSSearchableItem]
    var deletesLegacyDomain: Bool = false
}

private nonisolated final class SpotlightIndexBackend: @unchecked Sendable {
    private static let legacyCleanupDefaultsKey = "MindMapAI.SpotlightNamedIndexMigration.v1"

    private let index: CSSearchableIndex
    private let legacyIndex: CSSearchableIndex
    private let defaults: UserDefaults

    init(index: CSSearchableIndex, legacyIndex: CSSearchableIndex, defaults: UserDefaults) {
        self.index = index
        self.legacyIndex = legacyIndex
        self.defaults = defaults
    }

    func replace(with snapshot: SpotlightSearchableSnapshot) async throws {
        if snapshot.deletesLegacyDomain || !defaults.bool(forKey: Self.legacyCleanupDefaultsKey) {
            try await Self.deleteCurrentDomain(from: legacyIndex)
            defaults.set(true, forKey: Self.legacyCleanupDefaultsKey)
        }

        try await Self.deleteCurrentDomain(from: index)
        guard !snapshot.items.isEmpty else { return }
        try await Self.indexItems(snapshot.items, in: index)
    }

    private static func deleteCurrentDomain(from index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(
                withDomainIdentifiers: [MindMapSystemIntegrationConfiguration.spotlightDomainIdentifier]
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func indexItems(_ items: [CSSearchableItem], in index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

nonisolated struct MindMapSpotlightIndexer: Sendable {
    /// The app-wide instance keeps one coordinator and one named index alive
    /// even while SwiftUI recreates view values.
    static let shared = MindMapSpotlightIndexer()

    private let coordinator: SerializedReplacementCoordinator<SpotlightSearchableSnapshot>
    private let revisionClock: SpotlightRevisionClock

    init(
        index: CSSearchableIndex = CSSearchableIndex(
            name: MindMapSystemIntegrationConfiguration.spotlightIndexName,
            protectionClass: .complete
        ),
        legacyIndex: CSSearchableIndex = .default(),
        defaults: UserDefaults = .standard
    ) {
        let backend = SpotlightIndexBackend(
            index: index,
            legacyIndex: legacyIndex,
            defaults: defaults
        )
        revisionClock = SpotlightRevisionClock()
        coordinator = SerializedReplacementCoordinator { snapshot in
            try await backend.replace(with: snapshot)
        }
    }

    /// Test seam for verifying ordering and deletion without touching the
    /// device's real Spotlight index.
    init(
        replacementOperation: @escaping @Sendable (SpotlightSearchableSnapshot) async throws -> Void
    ) {
        revisionClock = SpotlightRevisionClock()
        coordinator = SerializedReplacementCoordinator(operation: replacementOperation)
    }

    /// Reserve this before launching an unstructured task that carries a note
    /// snapshot. The coordinator rejects snapshots with an older revision.
    func reserveRevision() -> UInt64 {
        revisionClock.reserve()
    }

    func replaceIndex(with notes: [MindNote]) async throws {
        let revision = reserveRevision()
        try await replaceIndex(with: notes, revision: revision)
    }

    func replaceIndex(with notes: [MindNote], revision: UInt64) async throws {
        try await coordinator.submit(SpotlightSearchableSnapshot(
            items: notes.map(Self.searchableItem(for:))
        ), generation: revision)
    }

    /// Explicitly clears every current and legacy note-domain item. Delete
    /// Everything awaits this API so it cannot report success while private
    /// note text remains in Spotlight.
    func deleteAllNoteItems() async throws {
        let revision = reserveRevision()
        try await deleteAllNoteItems(revision: revision)
    }

    func deleteAllNoteItems(revision: UInt64) async throws {
        try await coordinator.submit(
            SpotlightSearchableSnapshot(items: [], deletesLegacyDomain: true),
            generation: revision
        )
    }

    static func searchableItem(for note: MindNote) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = note.displayTitle
        attributes.contentDescription = note.body
        attributes.keywords = Array(Set(
            note.acceptedTags
                + [note.tripTheme, note.place?.name ?? "", note.place?.detail ?? ""]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ))
        attributes.contentCreationDate = note.createdAt
        attributes.contentModificationDate = note.updatedAt
        attributes.namedLocation = note.place?.name

        return CSSearchableItem(
            uniqueIdentifier: note.id.uuidString,
            domainIdentifier: MindMapSystemIntegrationConfiguration.spotlightDomainIdentifier,
            attributeSet: attributes
        )
    }

}
