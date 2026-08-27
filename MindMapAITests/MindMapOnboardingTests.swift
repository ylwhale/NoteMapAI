import Foundation
import Testing
@testable import MindMapAI

struct MindMapOnboardingTests {
    @Test("Onboarding appears once and completion persists")
    func firstLaunchAndCompletion() throws {
        let suiteName = "MindMapOnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MindMapOnboardingState.shouldPresent(defaults: defaults, arguments: []))

        MindMapOnboardingState.markCompleted(defaults: defaults)

        #expect(!MindMapOnboardingState.shouldPresent(defaults: defaults, arguments: []))
    }

    @Test("UI test launch controls do not affect production completion semantics")
    func testLaunchControls() throws {
        let suiteName = "MindMapOnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            !MindMapOnboardingState.shouldPresent(
                defaults: defaults,
                arguments: [MindMapOnboardingState.skipUITestArgument]
            )
        )

        MindMapOnboardingState.markCompleted(defaults: defaults)
        #expect(
            MindMapOnboardingState.shouldPresent(
                defaults: defaults,
                arguments: [MindMapOnboardingState.resetUITestArgument]
            )
        )
        #expect(!defaults.bool(forKey: MindMapOnboardingState.completionKey))
    }
}
