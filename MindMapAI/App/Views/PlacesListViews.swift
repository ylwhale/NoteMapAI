import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Places list (Places tab)

/// The Places tab list view (All/Favorites + category chips + search).
/// This was referenced by `RootView` but missing in the radio-stations build.
struct PlacesListView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    @EnvironmentObject private var mediaStore: PinMediaStore
    @EnvironmentObject private var voiceMemoStore: VoiceMemoStore
    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    private enum CategoryFilter: Hashable {
        case all
        case place(PlaceCategory)

        var label: String {
            switch self {
            case .all: return "All Categories"
            case .place(let c): return c.displayName
            }
        }
    }

    private enum MemoryFilter: String, CaseIterable, Identifiable {
        case all = "All places"
        case notes = "Notes"
        case media = "Media"
        case voiceNotes = "Voice notes"
        var id: String { rawValue }
    }

    @State private var selectedFilter: CategoryFilter = .all
    @State private var memoryFilter: MemoryFilter = .all

    private var placeCategories: [PlaceCategory] {
        Array(Set(places.map { $0.effectiveCategory })).sorted { $0.displayName < $1.displayName }
    }

    private var favoritePlaces: [Place] {
        places.filter { favorites.contains($0.id) }
    }

    private func pinKey(for place: Place) -> String { "place_" + place.id }

    private func hasNote(for place: Place) -> Bool {
        let key = pinKey(for: place)
        return placeMemoryStore.record(for: key)?.hasMeaningfulContent == true
    }

    private func hasMedia(for place: Place) -> Bool {
        !mediaStore.items(for: pinKey(for: place)).isEmpty
    }

    private func hasVoiceNotes(for place: Place) -> Bool {
        !voiceMemoStore.items(for: pinKey(for: place)).isEmpty
    }

    private func hasAnyMemory(for place: Place) -> Bool {
        hasNote(for: place) || hasMedia(for: place) || hasVoiceNotes(for: place)
    }

    private func memoryTitle(for place: Place) -> String {
        placeMemoryStore.displayTitle(for: pinKey(for: place), fallback: place.name)
    }

    private func matchesSearch(place: Place, query q: String) -> Bool {
        let memory = placeMemoryStore.record(for: pinKey(for: place))
        return place.name.lowercased().contains(q)
            || place.subtitle.lowercased().contains(q)
            || place.effectiveCategory.rawValue.contains(q)
            || (memory?.customTitle.lowercased().contains(q) ?? false)
            || (memory?.note.lowercased().contains(q) ?? false)
    }

    private func passesMemoryFilter(_ place: Place) -> Bool {
        switch memoryFilter {
        case .all:
            return true
        case .notes:
            return hasNote(for: place)
        case .media:
            return hasMedia(for: place)
        case .voiceNotes:
            return hasVoiceNotes(for: place)
        }
    }

    private var filteredPlaces: [Place] {
        var result = scope == .all ? places : favoritePlaces

        if case .place(let cat) = selectedFilter {
            result = result.filter { $0.effectiveCategory == cat }
        }

        result = result.filter { passesMemoryFilter($0) }

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedQuery.isEmpty {
            result = result.filter { matchesSearch(place: $0, query: trimmedQuery) }
        }

        return result.sorted {
            memoryTitle(for: $0).localizedCaseInsensitiveCompare(memoryTitle(for: $1)) == .orderedAscending
        }
    }

    private var memoryPlaceCount: Int {
        places.filter { hasAnyMemory(for: $0) }.count
    }

    private var totalMediaCount: Int {
        places.reduce(into: 0) { partialResult, place in
            partialResult += mediaStore.items(for: pinKey(for: place)).count
        }
    }

    private var totalVoiceNoteCount: Int {
        places.reduce(into: 0) { partialResult, place in
            partialResult += voiceMemoStore.items(for: pinKey(for: place)).count
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Memory tools")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Filter places by the notes, photos, videos, and voice memories you have saved on this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        memorySummaryPill(title: "Saved memories", value: "\(memoryPlaceCount)")
                        memorySummaryPill(title: "Media", value: "\(totalMediaCount)")
                        memorySummaryPill(title: "Voice notes", value: "\(totalVoiceNoteCount)")
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MemoryFilter.allCases) { filter in
                                Button {
                                    memoryFilter = filter
                                } label: {
                                    Text(filter.rawValue)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(memoryFilter == filter ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(filter.rawValue)
                                .accessibilityValue(memoryFilter == filter ? "Selected" : "Not selected")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowSeparator(.hidden)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    Button {
                        selectedFilter = .all
                    } label: {
                        Text(CategoryFilter.all.label)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedFilter == .all ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityLabel(CategoryFilter.all.label)
                    .accessibilityValue(selectedFilter == .all ? "Selected" : "Not selected")
                    .accessibilityHint("Shows all place categories")

                    ForEach(placeCategories, id: \.self) { cat in
                        Button {
                            selectedFilter = .place(cat)
                        } label: {
                            Text(cat.displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedFilter == .place(cat) ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .accessibilityLabel(cat.displayName)
                        .accessibilityValue(selectedFilter == .place(cat) ? "Selected" : "Not selected")
                        .accessibilityHint("Filters the list to the \(cat.displayName) category")
                    }
                }
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.plain)
            }
            .scrollIndicators(.visible)
            .listRowSeparator(.hidden)

            if filteredPlaces.isEmpty {
                EmptyStateView(
                    title: scope == .favorites ? "No favorite places" : "No matching places",
                    systemImage: scope == .favorites ? "heart" : "map",
                    message: scope == .favorites
                        ? "Tap the heart on a place card to add it to favorites."
                        : "Try another search or switch to a different memory filter."
                )
                .listRowSeparator(.hidden)
            } else {
                Section("Places") {
                    ForEach(filteredPlaces, id: \.listRefreshID) { place in
                        NavigationLink {
                            PlaceDetailView(place: place, places: places, favorites: $favorites)
                        } label: {
                            PlaceRow(place: place, favorites: $favorites)
                        }
                        .cardListRowStyle()
                    }
                }
            }
        }
        .navigationTitle("Places")
        .searchable(text: $searchText, prompt: "Search places or your memories…")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scope", selection: $scope) {
                    ForEach(ListScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("List scope")
            }
        }
        .onChange(of: scope) { _, newValue in
            AppLog.action("Set places list scope: \(newValue.rawValue)")
        }
        .onChange(of: selectedFilter) { _, newValue in
            AppLog.action("Set places category filter: \(newValue.label)")
        }
        .onChange(of: memoryFilter) { _, newValue in
            AppLog.action("Set memory filter: \(newValue.rawValue)")
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.info(trimmed.isEmpty ? "Cleared places search query" : "Updated places search query: \(trimmed)")
        }
    }

    private func memorySummaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Applies a consistent card-like style to rows embedded in a `List`.
struct CardListRowModifier: ViewModifier {
    /// Builds and returns the view hierarchy for this SwiftUI view.
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// Applies consistent insets/background for card-like rows inside a `List`.
    func cardListRowStyle() -> some View {
        modifier(CardListRowModifier())
    }
}

/// Card-like row view for displaying a place in a list.
struct PlaceRow: View {
    let place: Place
    @Binding var favorites: Set<String>

    /// When used outside a `NavigationLink` (e.g. inside a button that opens a sheet),
    /// show an explicit disclosure indicator to match the list styling.
    var showsDisclosure: Bool = false

    private var isFavorite: Bool { favorites.contains(place.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.iconSystemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(place.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(place.effectiveCategory.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(place.id)
                } else {
                    favorites.insert(place.id)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            // Borderless prevents the tap from triggering the parent NavigationLink/Button.
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Card-like row view for displaying a radio station in a list.
struct StationRow: View {
    let station: RadioStation
    @Binding var favorites: Set<String>

    /// When used outside a `NavigationLink` (e.g. inside a button that opens a sheet),
    /// show an explicit disclosure indicator to match the list styling.
    var showsDisclosure: Bool = false

    private var favoriteID: String { "station_" + station.id }
    private var isFavorite: Bool { favorites.contains(favoriteID) }

    var body: some View {
        HStack(spacing: 12) {
            // Prefer the station's logo if it exists, otherwise fall back to the default radio icon.
            AlamofireStationLogoView(logoURLString: station.logoURL)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(station.country)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Radio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(favoriteID)
                } else {
                    favorites.insert(favoriteID)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            // Borderless prevents the tap from triggering the parent NavigationLink/Button.
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Small map used on the Place details screen

/// Displays a compact interactive map focused on the current place detail.
struct PlaceMapView: View {
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = false

    let place: Place
    @Binding var modalPlace: Place?

    @State private var cameraPosition: MapCameraPosition

    init(place: Place, modalPlace: Binding<Place?>) {
        self.place = place
        self._modalPlace = modalPlace
        let initial = MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
        _cameraPosition = State(initialValue: .region(initial))
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                Button {
                    modalPlace = place
                } label: {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open place card")
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Sleep Timer UI

/// Shows the remaining sleep-timer time in a compact pill-shaped status view.
struct SleepTimerCountdownChip: View {
    let remainingText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "zzz")
                .font(.system(size: 13, weight: .semibold))
            Text(remainingText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep timer remaining \(remainingText)")
    }
}

/// Sheet that lets the user select a sleep timer duration.
struct SleepTimerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var sleepTimer = SleepTimerManager.shared

    @State private var hours: Int = 0
    @State private var minutes: Int = 30

    private var totalMinutes: Int { hours * 60 + minutes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set sleep timer")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    HStack(spacing: 12) {
                        SleepTimerUnitPicker(
                            title: "hours",
                            values: Array(0...12),
                            selection: $hours
                        ) { value in
                            "\(value)"
                        }

                        SleepTimerUnitPicker(
                            title: "min",
                            values: Array(0...59),
                            selection: $minutes
                        ) { value in
                            String(format: "%02d", value)
                        }
                    }
                    .frame(height: 170)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )

                    if sleepTimer.isActive {
                        Button(role: .destructive) {
                            AppLog.action("Sleep timer sheet: cancel timer tapped")
                            sleepTimer.cancel()
                            isPresented = false
                        } label: {
                            Text("Cancel timer")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel timer")
                        .accessibilityHint("Cancels the active sleep timer")
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )

                        Text("Current remaining: \(sleepTimer.formattedRemaining())")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AppLog.action("Sleep timer sheet: done tapped with \(hours) hours and \(minutes) minutes")
                        if totalMinutes > 0 {
                            sleepTimer.setTimer(minutes: totalMinutes)
                        } else {
                            AppLog.info("Sleep timer sheet: zero duration selected; closing without starting a timer")
                        }
                        isPresented = false
                    }
                    .accessibilityHint("Closes the sheet and starts the timer if the duration is greater than zero")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            // If there is an active timer, initialize the wheels to the current remaining time.
            if sleepTimer.isActive {
                let s = max(0, sleepTimer.remainingSeconds)
                let h = min(12, s / 3600)
                let m = min(59, (s % 3600) / 60)
                hours = h
                minutes = m
            }
        }
    }
}

// SleepTimerUnitPicker renders a custom interface component for this feature area.
private struct SleepTimerUnitPicker: View {
    let title: String
    let values: [Int]
    @Binding var selection: Int
    let formatter: (Int) -> String

    var body: some View {
        HStack(spacing: 8) {
            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(formatter(value))
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(width: 72)
            .clipped()
            .accessibilityLabel(title)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}
