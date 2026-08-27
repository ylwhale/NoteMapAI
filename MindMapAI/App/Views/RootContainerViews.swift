import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// Filter scope for list views (all items vs favorites).
enum ListScope: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    var id: String { rawValue }
}

/// Tabs available at the root level. The app now launches on Map by default
/// so the splash renders over the map instead of the list-based Places tab.
enum RootTab: Hashable {
    case places
    case map
    case recent
}

/// Top-level container that holds app state and presents the main tabs (Places, Map, Recent).
struct RootView: View {
    // Merge bundled places with any user-added pins created from Map search.
    @State private var places: [Place] = {
        let deleted = DeletedPinsStore.get()
        return (PlaceStore.load() + UserPlaceStore.load())
            .filter { !deleted.contains("place_" + $0.id) }
    }()
    @State private var stations: [RadioStation] = {
        let deleted = DeletedPinsStore.get()
        return RadioStationStore.load()
            .filter { !deleted.contains("station_" + $0.id) }
    }()
    @State private var favorites: Set<String> = FavoritesStore.get()
    @ObservedObject private var audio = AudioManager.shared

    // Persist the user's preferred map style across app launches.
    // Default is `false` so the app opens in the brighter standard-map presentation shown in the startup design.
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = false


    @StateObject private var recents = RecentManager()
    @StateObject private var photoStore = PinPhotoStore.shared
    @StateObject private var mediaStore = PinMediaStore.shared
    @StateObject private var voiceMemoStore = VoiceMemoStore.shared
    @StateObject private var placeMemoryStore = PlaceMemoryStore.shared
    @StateObject private var pinAudioStore = PinAudioSelectionStore.shared

    // Settings.bundle preference: show onboarding on launch.
    @AppStorage(SettingsKeys.showOnboarding) private var showOnboarding: Bool = true

    @State private var selectedTab: RootTab = .map
    @State private var showLaunchSplash: Bool = false
    @State private var showSplash: Bool = false
    @State private var showHelp: Bool = false
    @State private var showRatePrompt: Bool = false
    @State private var pendingRatePrompt: Bool = false
    @State private var playbackErrorMessage: String? = nil
    @State private var didRunLaunchTasks: Bool = false

    /// Bridges an optional playback error message into a Boolean alert binding.
    private var playbackAlertIsPresented: Binding<Bool> {
        Binding(
            get: { playbackErrorMessage != nil },
            set: { newValue in
                if !newValue { playbackErrorMessage = nil }
            }
        )
    }

    /// Reusable help button shown in the main tabs to present usage instructions.
    private var helpButton: some View {
        Button {
            AppLog.action("Help opened")
            showHelp = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .accessibilityLabel("Help")
    }

    /// Dismisses the launch splash overlay and advances into onboarding when enabled.
    private func dismissLaunchSplash() {
        guard showLaunchSplash else { return }

        AppLog.info("Launch splash overlay dismissed")

        withAnimation(.easeOut(duration: 0.2)) {
            showLaunchSplash = false
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 240_000_000)

            if showOnboarding {
                AppLog.action("Onboarding shown after splash")
                withAnimation(.easeIn(duration: 0.2)) {
                    showSplash = true
                }
            } else if pendingRatePrompt {
                pendingRatePrompt = false
                showRatePrompt = true
            }
        }
    }

    /// Dismisses the onboarding overlay.
    private func dismissSplash() {
        AppLog.action("Onboarding overlay dismissed")

        withAnimation(.easeOut(duration: 0.2)) {
            showSplash = false
        }

        // If the rate prompt is due, present it only after the onboarding is dismissed.
        if pendingRatePrompt {
            pendingRatePrompt = false
            Task { @MainActor in
                // Give the dismissal animation a moment to complete.
                try? await Task.sleep(nanoseconds: 250_000_000)
                showRatePrompt = true
            }
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    PlacesHomeView(places: $places, stations: $stations, favorites: $favorites)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { helpButton }
                }
                .tabItem {
                    Label("Places", systemImage: "list.bullet")
                }
                .tag(RootTab.places)

                NavigationStack {
                    PlacesMapTabView(places: $places, stations: $stations, favorites: $favorites)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { helpButton }
                }
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .tag(RootTab.map)

                RecentTabView(places: $places, stations: $stations, favorites: $favorites, onHelp: {
                    AppLog.action("Help opened")
                    showHelp = true
                })
                .tabItem {
                    Label("Favorites", systemImage: "star")
                }
                .tag(RootTab.recent)
            }
            .environmentObject(recents)
            .environmentObject(photoStore)
            .environmentObject(mediaStore)
            .environmentObject(voiceMemoStore)
            .environmentObject(placeMemoryStore)
            .environmentObject(pinAudioStore)
            .onChange(of: favorites) { _, newValue in
                FavoritesStore.set(newValue)
            }
            .onChange(of: places) { _, newValue in
                // Persist only user-created pins.
                UserPlaceStore.save(UserPlaceStore.userPlaces(from: newValue))
            }
            .onChange(of: selectedTab) { _, newValue in
                AppLog.info("RootView.selectedTab changed to \(String(describing: newValue))")
            }
            // A persistent bottom play bar showing what is currently playing.
            // NOTE: In a TabView, the system Tab Bar sits at the bottom and can overlap
            // custom overlays/insets. We lift the mini player up a bit so it sits above
            // the Tab Bar instead of stacking on top of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Show for both bundled tracks (places) and streaming radio stations.
                if audio.currentTrackBaseName != nil || audio.currentLocalFileURLString != nil || audio.currentStreamURLString != nil {
                    MiniPlayerBar(favorites: $favorites)
                        // Lift above the TabView's tab bar (avoids overlap with the tab labels).
                        .padding(.bottom, 78)
                }
            }

            if showSplash {
                SplashOnboardingView(onDismiss: dismissSplash)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showLaunchSplash {
                LaunchSplashOverlayView(onContinue: dismissLaunchSplash)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .sheet(isPresented: $showHelp) {
            InstructionsView()
        }
        // Connectivity / UX: show an alert if playback can't start (e.g., no network).
        .alert("Playback Issue", isPresented: playbackAlertIsPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(playbackErrorMessage ?? "Something went wrong.")
        }
        // Required: custom "Rate this App" alert on 3rd launch.
        .alert("Rate this App in the App Store", isPresented: $showRatePrompt) {
            Button("Rate Now") {
                SettingsManager.markRatePromptShown(userAction: "Rate Now")
            }
            Button("Later", role: .cancel) {
                SettingsManager.markRatePromptShown(userAction: "Later")
            }
        } message: {
            Text("If you enjoy using MindMap AI, would you mind rating it in the App Store?")
        }
        .onReceive(audio.$userFacingErrorMessage) { msg in
            guard let msg else { return }
            playbackErrorMessage = msg
            audio.clearUserFacingError()
        }
                .task {
            guard !didRunLaunchTasks else { return }
            didRunLaunchTasks = true

            AppLog.action("Launch splash scheduled for launch")
            showLaunchSplash = true

            if SettingsManager.consumePendingRatePrompt() {
                // Avoid presenting the rate prompt on top of the splash or onboarding overlays.
                if showLaunchSplash || showSplash {
                    pendingRatePrompt = true
                } else {
                    showRatePrompt = true
                }
            }
        }
    }
}
