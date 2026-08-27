import CoreSpotlight
import SwiftUI

struct MindMapRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var store: MindMapStore
    @StateObject private var locationService: MindMapLocationService
    @StateObject private var connectivityMonitor: ConnectivityMonitor
    @StateObject private var router: MindMapRouter
    @State private var systemIntegrationAlertMessage: String?

    private let apiKeyStore: APIKeyStore
    private let conclusionProvider: any GroundedConclusionProviding
    private let sharedCaptureInbox = MindMapSharedCaptureInbox()
    private let spotlightIndexer: MindMapSpotlightIndexer

    init(
        store: MindMapStore? = nil,
        locationService: MindMapLocationService? = nil,
        connectivityMonitor: ConnectivityMonitor? = nil,
        router: MindMapRouter? = nil,
        apiKeyStore: APIKeyStore = APIKeyStore(),
        conclusionProvider: any GroundedConclusionProviding = OpenAIConclusionService(),
        spotlightIndexer: MindMapSpotlightIndexer = .shared
    ) {
        _store = StateObject(wrappedValue: store ?? MindMapStore())
        _locationService = StateObject(wrappedValue: locationService ?? MindMapLocationService())
        _connectivityMonitor = StateObject(wrappedValue: connectivityMonitor ?? ConnectivityMonitor())
        _router = StateObject(wrappedValue: router ?? MindMapRouter())
        self.apiKeyStore = apiKeyStore
        self.conclusionProvider = conclusionProvider
        self.spotlightIndexer = spotlightIndexer
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            MindMapHomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(MindMapTab.home)

            MindMapLibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(MindMapTab.library)

            AskView(provider: conclusionProvider, apiKeyStore: apiKeyStore)
                .tabItem {
                    Label("Ask", systemImage: "sparkles")
                }
                .tag(MindMapTab.ask)

            PlansView(onOpenAsk: { router.openAsk() })
                .tabItem {
                    Label("Plans", systemImage: "checklist")
                }
                .tag(MindMapTab.plans)

            NavigationStack {
                MindMapSettingsView(
                    store: store,
                    locationService: locationService,
                    connectivityMonitor: connectivityMonitor,
                    apiKeyStore: apiKeyStore
                )
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(MindMapTab.settings)
        }
        .tint(MindMapTheme.accent)
        .environmentObject(store)
        .environmentObject(locationService)
        .environmentObject(connectivityMonitor)
        .environmentObject(router)
        .task {
            guard !skipsSystemIntegrationsForUITesting else { return }
            await refreshSystemIntegrations(importCaptures: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard !skipsSystemIntegrationsForUITesting else { return }
            Task { await refreshSystemIntegrations(importCaptures: true) }
        }
        .onChange(of: store.notes) { _, notes in
            guard !skipsSystemIntegrationsForUITesting else { return }
            let revision = spotlightIndexer.reserveRevision()
            Task {
                await refreshSpotlightIndex(with: notes, revision: revision)
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .onContinueUserActivity(CSSearchableItemActionType, perform: openSpotlightItem)
        .alert("System integration needs attention", isPresented: Binding(
            get: { systemIntegrationAlertMessage != nil },
            set: { if !$0 { systemIntegrationAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { systemIntegrationAlertMessage = nil }
        } message: {
            Text(systemIntegrationAlertMessage ?? "MindMap AI will retry when the app becomes active.")
        }
    }

    /// App Groups are unavailable in unsigned UI-test installs. The production
    /// integration remains enabled unless the test process opts out explicitly.
    private var skipsSystemIntegrationsForUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-MindMapAIUITestSkipSystemIntegrations")
    }

    private func refreshSystemIntegrations(importCaptures: Bool) async {
        var issues: [String] = []

        if importCaptures {
            do {
                let scan = try sharedCaptureInbox.scanPendingCaptures()
                for capture in scan.captures {
                    let draft = CaptureDraft(
                        id: capture.id,
                        title: capture.title,
                        body: capture.body
                    )
                    _ = try store.createNote(
                        from: draft,
                        now: capture.createdAt,
                        preserveCaptureDraft: true
                    )
                    try sharedCaptureInbox.remove(capture)
                }
                if !scan.issues.isEmpty {
                    let quarantinedCount = scan.issues.filter { $0.kind != .quarantineFailed }.count
                    let failedCount = scan.issues.count - quarantinedCount
                    if quarantinedCount > 0 {
                        issues.append(
                            "\(quarantinedCount) unreadable outside capture\(quarantinedCount == 1 ? " was" : "s were") moved aside so valid captures could still be imported. Share those items again if you still need them."
                        )
                    }
                    if failedCount > 0 {
                        issues.append(
                            "\(failedCount) unreadable outside capture\(failedCount == 1 ? " could" : "s could") not be moved aside and will be retried."
                        )
                    }
                }
            } catch {
                issues.append("Outside captures could not be imported: \(error.localizedDescription)")
            }
        }

        do {
            let revision = spotlightIndexer.reserveRevision()
            try await spotlightIndexer.replaceIndex(with: store.notes, revision: revision)
        } catch {
            issues.append(
                "Spotlight could not update its private note index. Search inside MindMap AI is unchanged, and Spotlight will retry when the app becomes active. \(error.localizedDescription)"
            )
        }

        if !issues.isEmpty {
            systemIntegrationAlertMessage = issues.joined(separator: "\n\n")
        } else {
            systemIntegrationAlertMessage = nil
        }
    }

    private func refreshSpotlightIndex(with notes: [MindNote], revision: UInt64) async {
        do {
            try await spotlightIndexer.replaceIndex(with: notes, revision: revision)
        } catch {
            systemIntegrationAlertMessage = "Spotlight could not update its private note index. Search inside MindMap AI is unchanged, and Spotlight will retry when the app becomes active. \(error.localizedDescription)"
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.localizedCaseInsensitiveCompare(
            MindMapSystemIntegrationConfiguration.captureURLScheme
        ) == .orderedSame else { return }

        if url.host == "note",
           let idValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value,
           let id = UUID(uuidString: idValue),
           store.note(withID: id) != nil {
            router.openLibrary(noteID: id)
            return
        }

        router.selectedTab = .home
    }

    private func openSpotlightItem(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let noteID = UUID(uuidString: identifier),
              store.note(withID: noteID) != nil else { return }
        router.openLibrary(noteID: noteID)
    }
}
