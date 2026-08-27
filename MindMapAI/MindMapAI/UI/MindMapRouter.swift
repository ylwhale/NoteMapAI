import Combine
import Foundation

@MainActor
final class MindMapRouter: ObservableObject {
    @Published var selectedTab: MindMapTab = .home
    @Published var requestedAskQuestion: String?
    @Published var requestedLibraryQuery: String?
    @Published var requestedLibraryNoteID: UUID?

    func openAsk(question: String = "") {
        requestedAskQuestion = question
        selectedTab = .ask
    }

    func openLibrary(query: String = "") {
        requestedLibraryQuery = query
        selectedTab = .library
    }

    func openLibrary(noteID: UUID) {
        requestedLibraryNoteID = noteID
        selectedTab = .library
    }

    func openPlans() {
        selectedTab = .plans
    }

    func openSettings() {
        selectedTab = .settings
    }
}
