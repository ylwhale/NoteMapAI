import Foundation
import SwiftUI

enum MindMapOnboardingDestination {
    case home
    case settings
}

/// Small, independent first-launch preference. Keeping this outside the main
/// archive means onboarding never mutates notes, plans, privacy choices, or drafts.
enum MindMapOnboardingState {
    static let completionKey = "mindmap-ai.onboarding.completed.v1"
    static let skipUITestArgument = "-MindMapAIUITestSkipOnboarding"
    static let resetUITestArgument = "-MindMapAIUITestResetOnboarding"

    static func shouldPresent(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if arguments.contains(resetUITestArgument) {
            defaults.removeObject(forKey: completionKey)
        }

        if arguments.contains(skipUITestArgument) {
            return false
        }

        return !defaults.bool(forKey: completionKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }
}

/// Keeps the existing five-tab app out of the view hierarchy until the
/// first-launch introduction is dismissed. This prevents hidden tab controls
/// or services from competing with onboarding for focus and system resources.
struct MindMapLaunchGate: View {
    @StateObject private var router = MindMapRouter()
    @State private var isShowingOnboarding = MindMapOnboardingState.shouldPresent()

    var body: some View {
        Group {
            if isShowingOnboarding {
                MindMapOnboardingView(onFinish: finishOnboarding)
            } else {
                MindMapRootView(router: router)
            }
        }
    }

    private func finishOnboarding(at destination: MindMapOnboardingDestination) {
        MindMapOnboardingState.markCompleted()

        switch destination {
        case .home:
            router.selectedTab = .home
        case .settings:
            router.openSettings()
        }

        isShowingOnboarding = false
    }
}

struct MindMapOnboardingView: View {
    let onFinish: (MindMapOnboardingDestination) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPage = 0

    private let pages = MindMapOnboardingPage.pages

    private var isLastPage: Bool {
        selectedPage == pages.count - 1
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MindMapTheme.accentSubtle,
                    MindMapTheme.background,
                    MindMapTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    MindMapOnboardingPageView(page: pages[selectedPage])
                        .id(selectedPage)
                        .padding(.horizontal, MindMapSpacing.large)
                        .padding(.top, MindMapSpacing.large)
                        .padding(.bottom, MindMapSpacing.xLarge)
                        .mindMapReadableWidth(MindMapLayout.maxFormWidth)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .tint(MindMapTheme.accent)
    }

    private var header: some View {
        HStack(spacing: MindMapSpacing.medium) {
            Label("MindMap AI", systemImage: "sparkles")
                .font(.headline.weight(.semibold))
                .foregroundStyle(MindMapTheme.accent)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mindmap_onboarding")

            Spacer(minLength: MindMapSpacing.medium)

            Button("Skip tour") {
                onFinish(.home)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MindMapTheme.accent)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityIdentifier("onboarding_skip")
            .accessibilityHint("Skips the introduction and opens Home")
        }
        .padding(.horizontal, MindMapSpacing.large)
        .padding(.top, MindMapSpacing.small)
        .mindMapReadableWidth(MindMapLayout.maxReadableWidth)
    }

    private var footer: some View {
        VStack(spacing: MindMapSpacing.medium) {
            progressIndicator

            if isLastPage {
                finalActions
            } else {
                navigationActions
            }
        }
        .padding(.horizontal, MindMapSpacing.large)
        .padding(.top, MindMapSpacing.medium)
        .padding(.bottom, MindMapSpacing.large)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var progressIndicator: some View {
        VStack(spacing: MindMapSpacing.small) {
            HStack(spacing: MindMapSpacing.small) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == selectedPage ? MindMapTheme.accent : MindMapTheme.border)
                        .frame(width: index == selectedPage ? 28 : 8, height: 8)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedPage)
                }
            }
            .accessibilityHidden(true)

            Text("Step \(selectedPage + 1) of \(pages.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MindMapTheme.textSecondary)
                .accessibilityLabel("Step \(selectedPage + 1) of \(pages.count)")
        }
    }

    @ViewBuilder
    private var navigationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MindMapSpacing.medium) {
                if selectedPage > 0 {
                    backButton
                }
                continueButton
            }

            VStack(spacing: MindMapSpacing.small) {
                continueButton
                if selectedPage > 0 {
                    backButton
                }
            }
        }
        .mindMapReadableWidth(MindMapLayout.maxFormWidth)
    }

    private var finalActions: some View {
        VStack(spacing: MindMapSpacing.small) {
            MindMapPrimaryButton(
                title: "Start capturing",
                systemImage: "square.and.pencil",
                action: { onFinish(.home) }
            )
            .accessibilityIdentifier("onboarding_start")
            .accessibilityHint("Completes the introduction and opens Home")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: MindMapSpacing.medium) {
                    backButton
                    openAISettingsButton
                }

                VStack(spacing: MindMapSpacing.small) {
                    openAISettingsButton
                    backButton
                }
            }
        }
        .mindMapReadableWidth(MindMapLayout.maxFormWidth)
    }

    private var backButton: some View {
        MindMapSecondaryButton(
            title: "Back",
            systemImage: "chevron.left",
            action: { move(to: selectedPage - 1) }
        )
        .accessibilityIdentifier("onboarding_back")
        .accessibilityHint("Returns to the previous introduction screen")
    }

    private var continueButton: some View {
        MindMapPrimaryButton(
            title: "Continue",
            systemImage: "chevron.right",
            action: { move(to: selectedPage + 1) }
        )
        .accessibilityIdentifier("onboarding_next")
        .accessibilityHint("Opens the next introduction screen")
    }

    private var openAISettingsButton: some View {
        MindMapSecondaryButton(
            title: "Open AI settings",
            systemImage: "gearshape",
            action: { onFinish(.settings) }
        )
        .accessibilityIdentifier("onboarding_open_ai_settings")
        .accessibilityHint("Completes the introduction and opens AI processing settings")
    }

    private func move(to page: Int) {
        let destination = min(max(page, 0), pages.count - 1)
        guard destination != selectedPage else { return }

        if reduceMotion {
            selectedPage = destination
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedPage = destination
            }
        }
    }
}

private struct MindMapOnboardingPageView: View {
    let page: MindMapOnboardingPage

    @AccessibilityFocusState private var isHeadingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: MindMapCornerRadius.card, style: .continuous)
                        .fill(MindMapTheme.accentSubtle)
                        .frame(width: 84, height: 84)

                    Image(systemName: page.systemImage)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(MindMapTheme.accent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text(page.eyebrow)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MindMapTheme.accent)

                    Text(page.title)
                        .mindMapTextStyle(.screenTitle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($isHeadingFocused)

                    Text(page.body)
                        .mindMapTextStyle(.body)
                }
            }

            if !page.features.isEmpty {
                MindMapCard {
                    VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                        ForEach(Array(page.features.enumerated()), id: \.element.id) { index, feature in
                            MindMapOnboardingFeatureRow(feature: feature)

                            if index < page.features.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }

            if let callout = page.callout {
                MindMapCallout(
                    kind: callout.kind,
                    title: callout.title,
                    message: callout.message
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            isHeadingFocused = true
        }
    }
}

private struct MindMapOnboardingFeatureRow: View {
    let feature: MindMapOnboardingFeature

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(MindMapTheme.textPrimary)

                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: feature.systemImage)
                .font(.headline)
                .foregroundStyle(MindMapTheme.accent)
                .frame(width: 32, height: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MindMapOnboardingPage: Identifiable {
    let id: Int
    let eyebrow: String
    let title: String
    let body: String
    let systemImage: String
    let features: [MindMapOnboardingFeature]
    let callout: MindMapOnboardingCallout?

    static let pages: [MindMapOnboardingPage] = [
        MindMapOnboardingPage(
            id: 0,
            eyebrow: "Welcome to MindMap AI",
            title: "Capture now. Reuse it later.",
            body: "Save fragments on this device, find the evidence you need, and turn your own notes into useful answers and plans.",
            systemImage: "sparkles.rectangle.stack.fill",
            features: [
                MindMapOnboardingFeature(
                    title: "Local from the start",
                    detail: "No account is required for capture, search, maps, or plans.",
                    systemImage: "iphone"
                ),
                MindMapOnboardingFeature(
                    title: "Built around your notes",
                    detail: "MindMap AI helps you reconnect related details instead of replacing your source material.",
                    systemImage: "note.text"
                )
            ],
            callout: nil
        ),
        MindMapOnboardingPage(
            id: 1,
            eyebrow: "Capture and organize",
            title: "Write first. Add context only when it helps.",
            body: "Start with one sentence, reminder, lesson, place, price, or idea. Your draft is preserved while you type.",
            systemImage: "square.and.pencil",
            features: [
                MindMapOnboardingFeature(
                    title: "Automatic context",
                    detail: "Creation date and time are added when you save.",
                    systemImage: "clock"
                ),
                MindMapOnboardingFeature(
                    title: "Optional details",
                    detail: "Add a title, event date, theme, tags, or location when they are useful.",
                    systemImage: "tag"
                ),
                MindMapOnboardingFeature(
                    title: "One local library",
                    detail: "Search, filter, use cards, or browse located notes on a map.",
                    systemImage: "books.vertical"
                )
            ],
            callout: nil
        ),
        MindMapOnboardingPage(
            id: 2,
            eyebrow: "Ask and verify",
            title: "Ask your notes, then inspect the evidence.",
            body: "MindMap AI searches your local library first. It shows matching excerpts and uses them to create a supported answer.",
            systemImage: "quote.bubble.fill",
            features: [
                MindMapOnboardingFeature(
                    title: "1. Ask a specific question",
                    detail: "Questions with a clear topic, time, place, or goal produce better matches.",
                    systemImage: "questionmark.bubble"
                ),
                MindMapOnboardingFeature(
                    title: "2. Review the evidence",
                    detail: "Inspect the linked excerpts, conflicts, coverage, and missing details.",
                    systemImage: "doc.text.magnifyingglass"
                ),
                MindMapOnboardingFeature(
                    title: "3. Save an editable plan",
                    detail: "Keep useful answers and generated steps, then revise them whenever you need.",
                    systemImage: "checklist"
                )
            ],
            callout: MindMapOnboardingCallout(
                kind: .warning,
                title: "Verify before relying on it",
                message: "AI can be incomplete or wrong. Check the linked notes before reusing a conclusion."
            )
        ),
        MindMapOnboardingPage(
            id: 3,
            eyebrow: "Privacy and readiness",
            title: "You decide what leaves this device.",
            body: "Capture, Library, maps, filters, and plans remain available locally. AI conclusions require a connection, your permission, and your own OpenAI API key in Settings.",
            systemImage: "lock.shield.fill",
            features: [
                MindMapOnboardingFeature(
                    title: "Your full library is not sent",
                    detail: "Only your question and the displayed relevant excerpts are sent after you allow it.",
                    systemImage: "hand.raised.fill"
                ),
                MindMapOnboardingFeature(
                    title: "Your choices remain editable",
                    detail: "Change AI processing, location capture, and local history choices in Settings.",
                    systemImage: "slider.horizontal.3"
                ),
                MindMapOnboardingFeature(
                    title: "AI setup can wait",
                    detail: "Start capturing now and add an API key later whenever you want AI conclusions.",
                    systemImage: "key"
                )
            ],
            callout: nil
        )
    ]
}

private struct MindMapOnboardingFeature: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
}

private struct MindMapOnboardingCallout {
    let kind: MindMapCalloutKind
    let title: String
    let message: String
}
