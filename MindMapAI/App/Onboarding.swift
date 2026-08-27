import SwiftUI
import UIKit

/// A full-screen, swipeable onboarding flow shown at launch.
/// This is a real app view (not the LaunchScreen storyboard) and can be dismissed
/// either by skipping or by completing the final page.
struct SplashOnboardingView: View {
    let onDismiss: () -> Void

    @State private var selectedPage: Int = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            title: "Explore places, save pins",
            subtitle: "A calmer way to keep meaningful places on your map.",
            description: "Start with a visual welcome, then swipe to see how MindMap AI helps you search places, create your own pins, and revisit memories with local playback.",
            bullets: [
                "Swipe left to continue through the tour.",
                "Search for a place, open its card, then save it as your own pin.",
                "Playback can keep going while you explore other tabs."
            ],
            systemImage: "globe.americas.fill",
            accentOpacity: 0.22,
            showsHeroArtwork: true
        ),
        OnboardingPage(
            id: 1,
            title: "Create pins from the Map",
            subtitle: "Search places, inspect pins, and save new ones fast.",
            description: "Use the map to search for places, open a result, and save it as your own pin so it stays easy to find later.",
            bullets: [
                "Search for places directly from the map.",
                "Tap any pin to open a detailed card and controls.",
                "Save a place when you find somewhere worth keeping on your map."
            ],
            systemImage: "map.fill",
            accentOpacity: 0.16,
            showsHeroArtwork: false
        ),
        OnboardingPage(
            id: 2,
            title: "Save memories to pins",
            subtitle: "Keep favorites close and make each pin personal.",
            description: "Add notes, media, and voice notes to your saved pins so each place becomes a personal memory you can revisit.",
            bullets: [
                "Heart the places and pins you want to revisit.",
                "Add photos, videos, notes, or voice notes to selected pins.",
                "Set a sleep timer or keep local playback going while you explore."
            ],
            systemImage: "heart.circle.fill",
            accentOpacity: 0.12,
            showsHeroArtwork: false
        )
    ]

    private var isLastPage: Bool {
        selectedPage == pages.count - 1
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color("AccentColor").opacity(pages[selectedPage].accentOpacity),
                    Color(.systemBackground),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Button {
                        AppLog.action("Onboarding skipped on page \(selectedPage + 1)")
                        onDismiss()
                    } label: {
                        Text("Skip")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip onboarding")
                    .accessibilityHint("Dismiss the onboarding screens and open the app")

                    Spacer()

                    Text("Step \(selectedPage + 1) of \(pages.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Step \(selectedPage + 1) of \(pages.count)")
                }
                .padding(.horizontal, 4)

                TabView(selection: $selectedPage) {
                    ForEach(pages) { page in
                        OnboardingPageView(page: page)
                            .tag(page.id)
                            .padding(.horizontal, 2)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Onboarding pages")
                .accessibilityHint("Swipe left or right to move between screens")

                HStack(spacing: 12) {
                    if selectedPage > 0 {
                        Button {
                            let previousPage = max(selectedPage - 1, 0)
                            AppLog.action("Onboarding moved backward: \(selectedPage + 1) -> \(previousPage + 1)")
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedPage = previousPage
                            }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Return to the previous onboarding screen")
                    }

                    Button {
                        if isLastPage {
                            AppLog.action("Onboarding completed")
                            onDismiss()
                        } else {
                            let nextPage = min(selectedPage + 1, pages.count - 1)
                            AppLog.action("Onboarding advanced: \(selectedPage + 1) -> \(nextPage + 1)")
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedPage = nextPage
                            }
                        }
                    } label: {
                        Label(isLastPage ? "Get Started" : "Next", systemImage: isLastPage ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("AccentColor"))
                    .accessibilityHint(isLastPage ? "Dismiss onboarding and open the app" : "Move to the next onboarding screen")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .onAppear {
            AppLog.action("Onboarding presented")
            AppLog.info("Onboarding page visible: 1 / \(pages.count)")
        }
        .onChange(of: selectedPage) { _, newValue in
            AppLog.info("Onboarding page visible: \(newValue + 1) / \(pages.count)")
        }
    }
}

/// Data that powers a single onboarding page.
private struct OnboardingPage: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let description: String
    let bullets: [String]
    let systemImage: String
    let accentOpacity: Double
    let showsHeroArtwork: Bool
}

/// Renders the content for a single onboarding page.
private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 18) {
            if page.showsHeroArtwork {
                HeroArtworkView()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Map preview showing a saved place pin")
                    .accessibilityHint("Illustration for the welcome screen")
            } else {
                ZStack {
                    Circle()
                        .fill(Color("AccentColor").opacity(0.14))
                        .frame(width: 92, height: 92)

                    Image(systemName: page.systemImage)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color("AccentColor"))
                }
                .padding(.top, 6)
            }

            VStack(spacing: 8) {
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.headline)
                    .foregroundStyle(Color("AccentColor"))
                    .multilineTextAlignment(.center)
            }

            Text(page.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(page.bullets.enumerated()), id: \.offset) { _, bullet in
                    Label {
                        Text(bullet)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color("AccentColor"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Spacer(minLength: 0)

            if page.id == 2 {
                OnboardingBrandingFooterView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

/// Reuses the bundled app artwork when available, with a system fallback.
private struct OnboardingBrandingFooterView: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("MindMap AI")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color("AccentColor"))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.9)

            Text("Developed by Jingyu Huang")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color("AccentColor"))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MindMap AI. Developed by Jingyu Huang.")
        .accessibilityHint("App branding shown on the final onboarding screen")
        .onAppear {
            AppLog.info("Onboarding branding footer visible on final page")
        }
    }
}

// HeroArtworkView renders a custom interface component for this feature area.
private struct HeroArtworkView: View {
    private let heroImageName = "OnboardingWorldMap"

    var body: some View {
        let hasHeroImage = UIImage(named: heroImageName) != nil
        let hasAppLogo = UIImage(named: "AppLogo") != nil

        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color("AccentColor").opacity(0.18), lineWidth: 1)
                )
                .frame(height: 220)

            if hasHeroImage {
                Image(heroImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color("AccentColor").opacity(0.18), lineWidth: 1)
                    )
            } else if hasAppLogo {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(26)
                    .frame(height: 190)
            } else {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(Color("AccentColor"))
            }
        }
        .onAppear {
            if hasHeroImage {
                AppLog.info("Onboarding hero image asset loaded: \(heroImageName)")
            } else if hasAppLogo {
                AppLog.info("Onboarding hero artwork fallback loaded: AppLogo")
            } else {
                AppLog.info("Onboarding hero artwork fallback loaded: system symbol")
            }
        }
    }
}

/// A launch splash overlay that matches the in-app card style requested by the project.
/// This is intentionally separate from the static iOS LaunchScreen so it can look like a
/// live overlay, respond to taps, participate in logging, and support VoiceOver.
struct LaunchSplashOverlayView: View {
    let onContinue: () -> Void

    @State private var hasContinued = false
    @State private var autoDismissTask: Task<Void, Never>? = nil

    private let autoDismissDelayNanoseconds: UInt64 = 2_000_000_000

    /// Advances into the app from the launch splash, guarding against duplicate taps.
    private func continueIntoApp(trigger: String) {
        guard !hasContinued else { return }
        hasContinued = true
        autoDismissTask?.cancel()
        AppLog.action("Launch splash dismissed: \(trigger)")
        onContinue()
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemBackground).opacity(0.74))
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack {
                Spacer(minLength: 72)

                VStack(spacing: 18) {
                    Image(systemName: "mappin.circle")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Color("AccentColor"))
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("MindMap AI")
                            .font(.system(size: 34, weight: .bold))
                            .multilineTextAlignment(.center)

                        Text("Explore places • Save memories • Keep favorites")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("AccentColor"))
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SplashBulletRow(systemImage: "list.bullet", text: "Browse places and saved pins in the Places tab")
                        SplashBulletRow(systemImage: "map", text: "Tap pins on the Map to open details")
                        SplashBulletRow(systemImage: "mic.fill", text: "Add notes, media, and voice notes to saved places")
                        SplashBulletRow(systemImage: "play.fill", text: "Control voice notes and local playback from the bottom play bar")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(spacing: 8) {
                        Text("Developed by Jingyu Huang")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color("AccentColor"))
                            .multilineTextAlignment(.center)

                        Button {
                            continueIntoApp(trigger: "button")
                        } label: {
                            Text("Tap to continue")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color("AccentColor"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tap to continue")
                        .accessibilityHint("Dismiss the splash screen and continue into the app")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
                .frame(maxWidth: 360)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color(.systemBackground).opacity(0.96))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color("AccentColor").opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
                .padding(.horizontal, 24)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("MindMap AI splash screen")
                .accessibilityHint("Shows a short introduction before the onboarding screens")

                Spacer(minLength: 72)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            continueIntoApp(trigger: "tap anywhere")
        }
        .onAppear {
            AppLog.action("Launch splash presented")
            guard autoDismissTask == nil else { return }
            AppLog.info("Launch splash auto-dismiss scheduled in 2 seconds")
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: autoDismissDelayNanoseconds)
                guard !Task.isCancelled else { return }
                continueIntoApp(trigger: "auto after 2 seconds")
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }
}

// SplashBulletRow renders a custom interface component for this feature area.
private struct SplashBulletRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)

            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A reusable help sheet the user can open from the UI.
struct InstructionsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    Group {
                        Text("How to use MindMap AI")
                            .font(.title2.bold())

                        Text("MindMap AI helps you explore curated places, play bundled offline sounds, and save favorites. You can control audio from anywhere in the app.")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Group {
                        Text("Places")
                            .font(.headline)
                        Text("Browse the Places tab to find locations. Tap a row to open its card, then play the associated offline track or save it as a favorite.")
                            .foregroundColor(.secondary)
                    }

                    Group {
                        Text("Map")
                            .font(.headline)
                        Text("Use the Map tab to search for real-world places and add them as pins. Tap a pin to open its card and play its bundled offline sound.")
                            .foregroundColor(.secondary)
                    }

                    Group {
                        Text("Favorites")
                            .font(.headline)
                        Text("Tap the heart icon to add/remove favorites. Favorited items appear in the Favorites scope and are saved between launches.")
                            .foregroundColor(.secondary)
                    }

                    Group {
                        Text("Playback")
                            .font(.headline)
                        Text("Use the bottom play bar to pause, resume, stop, or favorite the currently playing item. Audio playback continues in the background.")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Tip: If a network connection is unavailable, Apple place search may be limited, but bundled offline sounds continue to work. The app will display an alert when playback cannot start.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("Help")
        }
    }
}
