import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Places Home (Countries + Genres dashboard)

/// Summary information for browsing stations by country.
/// Each card shows a country name, emoji flag, and station count.
struct CountrySummary: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let flagEmoji: String
}

/// Summary information for browsing stations by genre tag.
/// These values power the colorful genre buttons in the Places browser.
struct GenreSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

/// Display-friendly genre label.
/// Some stations ship tags that begin with "And ..." which reads awkwardly in a list.
/// We keep the raw string for filtering/matching, but clean it up for UI display.
/// Cleans up raw genre strings for display without changing the underlying filter token.
fileprivate func displayGenreName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("and ") {
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// Creates a deterministic hash so unknown genres still map to a stable fallback color.
fileprivate func stableGenreHash(_ genre: String) -> Int {
    var hash = 0
    for scalar in genre.unicodeScalars {
        hash = (hash &* 31) &+ Int(scalar.value)
    }
    return abs(hash)
}

/// Returns a genre-specific accent color used by genre cards and chips throughout the UI.
fileprivate func genreAccentColor(for rawGenre: String) -> Color {
    let genre = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if genre.contains("pop") { return Color(red: 0.34, green: 0.80, blue: 0.45) }
    if genre.contains("rock") { return Color(red: 0.31, green: 0.53, blue: 0.96) }
    if genre.contains("elect") || genre.contains("edm") { return Color(red: 0.87, green: 0.36, blue: 0.71) }
    if genre.contains("jazz") { return Color(red: 0.56, green: 0.42, blue: 0.93) }
    if genre.contains("class") { return Color(red: 0.38, green: 0.47, blue: 0.92) }
    if genre.contains("hip") || genre.contains("rap") { return Color(red: 0.98, green: 0.58, blue: 0.23) }
    if genre.contains("news") { return Color(red: 0.53, green: 0.56, blue: 0.67) }
    if genre.contains("talk") { return Color(red: 0.50, green: 0.62, blue: 0.80) }
    if genre.contains("sport") { return Color(red: 0.25, green: 0.74, blue: 0.74) }
    if genre.contains("latin") { return Color(red: 0.98, green: 0.52, blue: 0.43) }
    if genre.contains("america") || genre.contains("américa") { return Color(red: 0.44, green: 0.66, blue: 0.91) }
    if genre.contains("culture") { return Color(red: 0.79, green: 0.49, blue: 0.86) }
    if genre.contains("stream") { return Color(red: 0.36, green: 0.74, blue: 0.88) }
    if genre.contains("music") { return Color(red: 0.96, green: 0.56, blue: 0.69) }
    if genre.contains("india") { return Color(red: 0.97, green: 0.69, blue: 0.27) }
    if genre.contains("brazil") { return Color(red: 0.41, green: 0.74, blue: 0.40) }
    if genre.contains("argentina") { return Color(red: 0.47, green: 0.76, blue: 0.93) }

    let palette: [Color] = [
        Color(red: 0.95, green: 0.55, blue: 0.61),
        Color(red: 0.98, green: 0.67, blue: 0.32),
        Color(red: 0.86, green: 0.77, blue: 0.28),
        Color(red: 0.45, green: 0.79, blue: 0.43),
        Color(red: 0.27, green: 0.79, blue: 0.68),
        Color(red: 0.34, green: 0.70, blue: 0.92),
        Color(red: 0.42, green: 0.58, blue: 0.95),
        Color(red: 0.62, green: 0.52, blue: 0.94),
        Color(red: 0.84, green: 0.49, blue: 0.89),
        Color(red: 0.95, green: 0.47, blue: 0.73)
    ]

    return palette[stableGenreHash(genre) % palette.count]
}

/// Card-like header row with an optional "see all" navigation affordance.
private struct SectionHeaderLink<Destination: View>: View {
    let title: String
    let destination: Destination

    init(_ title: String, destination: Destination) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            NavigationLink {
                destination
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("See all \(title)")
        }
    }
}

/// Home-style Places tab: nearby stations + quick entry points for countries and genres.
struct PlacesHomeView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @EnvironmentObject private var mediaStore: PinMediaStore
    @EnvironmentObject private var voiceMemoStore: VoiceMemoStore
    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    private func pinKey(for place: Place) -> String { "place_" + place.id }

    private func hasSavedMemory(for place: Place) -> Bool {
        let key = pinKey(for: place)
        return placeMemoryStore.hasContent(for: key)
            || !mediaStore.items(for: key).isEmpty
            || !voiceMemoStore.items(for: key).isEmpty
    }

    private var memoryPlaces: [Place] {
        places.filter { hasSavedMemory(for: $0) }
            .sorted { lhs, rhs in
                let lhsTitle = placeMemoryStore.displayTitle(for: pinKey(for: lhs), fallback: lhs.name)
                let rhsTitle = placeMemoryStore.displayTitle(for: pinKey(for: rhs), fallback: rhs.name)
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }
    }

    private var memoryPlacesPreview: [Place] {
        Array(memoryPlaces.prefix(4))
    }

    private var totalMediaCount: Int {
        places.reduce(into: 0) { partialResult, place in
            partialResult += mediaStore.items(for: pinKey(for: place)).count
        }
    }

    private var totalVoiceMemoCount: Int {
        places.reduce(into: 0) { partialResult, place in
            partialResult += voiceMemoStore.items(for: pinKey(for: place)).count
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Memory tools")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Turn saved places into a personal atlas with notes, photos, videos, and voice memories that stay on this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        memoryStatPill(title: "Saved memories", value: "\(memoryPlaces.count)")
                        memoryStatPill(title: "Media", value: "\(totalMediaCount)")
                        memoryStatPill(title: "Voice notes", value: "\(totalVoiceMemoCount)")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)

                NavigationLink {
                    PlacesListView(places: $places, stations: $stations, favorites: $favorites)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browse places")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Open the full places list with memory filters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full places list with memory-focused filters")

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent memory places")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    if memoryPlacesPreview.isEmpty {
                        Text("Add a note, photo, video, or voice memo to a place and it will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        VStack(spacing: 12) {
                            ForEach(memoryPlacesPreview, id: \.id) { place in
                                NavigationLink {
                                    PlaceDetailView(place: place, places: places, favorites: $favorites)
                                } label: {
                                    PlaceRow(place: place, favorites: $favorites, showsDisclosure: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .navigationTitle("Places")
    }

    private func memoryStatPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NearbyStationCardView: View {
    let station: RadioStation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StationLogoView(logoURLString: station.logoURL)
                .frame(width: 92, height: 92)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )

            Text(station.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(station.country)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

private struct CountryCardView: View {
    let country: CountrySummary

    var body: some View {
        VStack(spacing: 10) {
            Text(country.flagEmoji)
                .font(.system(size: 40))
            Text(country.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

private struct GenreCardView: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(icon)
                .font(.system(size: 36))
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 12)
        .background(tint.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
    }
}

/// All countries browser screen (grid preview + list), matching the "Countries" screenshot style.
struct CountriesBrowserView: View {
    let countries: [CountrySummary]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var query: String = ""

    private var filtered: [CountrySummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return countries }
        return countries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var top: [CountrySummary] { Array(filtered.prefix(6)) }
    private var rest: [CountrySummary] { filtered.count > 6 ? Array(filtered.dropFirst(6)) : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(top) { c in
                        NavigationLink {
                            CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                        } label: {
                            CountryCardView(country: c)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !rest.isEmpty {
                    Text("More Countries")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(rest) { c in
                            NavigationLink {
                                CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(c.flagEmoji)
                                    Text(c.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .navigationTitle("Countries")
        .searchable(text: $query, prompt: "Search")
        .onChange(of: query) { _, newValue in
            AppLog.action("Countries search query: \(newValue)")
        }
    }
}

/// All genres browser screen (grid preview + list), matching the "Genres" card style.
struct GenresBrowserView: View {
    let genres: [GenreSummary]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var query: String = ""

    /// Performs the `icon` operation for this type.
    private func icon(for genre: String) -> String {
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Common genre shortcuts
        if g.contains("pop") { return "🍿" }
        if g.contains("rock") { return "🎸" }
        if g.contains("elect") || g.contains("edm") { return "🎛️" }
        if g.contains("jazz") { return "🎷" }
        if g.contains("class") { return "🎻" }
        if g.contains("hip") || g.contains("rap") { return "🎤" }
        if g.contains("news") { return "📰" }
        if g.contains("talk") { return "💬" }
        if g.contains("sport") { return "🏟️" }
        if g.contains("latin") { return "💃" }
        if g.contains("america") || g.contains("américa") { return "🌎" }
        if g.contains("culture") { return "🎭" }
        if g.contains("stream") { return "📡" }

        // Deterministic "fun" fallback so non-standard tags don't all look the same.
        let palette: [String] = [
            "🎧", "🎶", "🎼", "📻", "🎙️", "💿", "🪩", "✨", "🌙", "☕️",
            "🌿", "🌊", "🔥", "🧠", "🛰️", "🎹", "🥁", "🎺", "🎻", "🎸",
            "🪕", "🎷", "🪘", "🎤", "🔊", "🎛️", "🎚️", "📡", "📺", "📼",
            "🗺️", "🧭", "🌎", "🌍", "🌏", "🏙️", "🌃", "🚗", "🚇", "✈️",
            "🚀", "🧘", "🏃", "📚", "📝", "🧩", "🪄", "🧊", "🌈", "🌻",
            "🍀", "🍉", "🍫", "🍣", "🍜", "🍕", "🌮", "🥐", "🍵", "🥤"
        ]

        var h: Int = 0
        for u in g.unicodeScalars {
            h = (h &* 31) &+ Int(u.value)
        }
        let idx = abs(h) % palette.count
        return palette[idx]
    }

    /// Performs the `tint` operation for this type.
    private func tint(for genre: String) -> Color {
        genreAccentColor(for: genre)
    }

    private var filtered: [GenreSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return genres }
        // Match on both the raw label and the cleaned display label.
        return genres.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            displayGenreName($0.name).localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var top: [GenreSummary] { Array(filtered.prefix(9)) }
    private var rest: [GenreSummary] { filtered.count > 9 ? Array(filtered.dropFirst(9)) : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(top) { g in
                        NavigationLink {
                            GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                        } label: {
                            GenreCardView(title: displayGenreName(g.name), icon: icon(for: g.name), tint: tint(for: g.name))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !rest.isEmpty {
                    Text("More Genres")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(rest) { g in
                            NavigationLink {
                                GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(icon(for: g.name))
                                    Text(displayGenreName(g.name))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .navigationTitle("Genres")
        .searchable(text: $query, prompt: "Search")
        .onChange(of: query) { _, newValue in
            AppLog.action("Genres search query: \(newValue)")
        }
    }
}

/// Station list filtered by a single country (card rows + favorite hearts).
struct CountryStationsListView: View {
    let country: String
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    /// Converts a station model into the shared favorites identifier format used across the app.
    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var filteredStations: [RadioStation] {
        let base = stations.filter { $0.country == country }
        let scoped: [RadioStation]
        if scope == .favorites {
            scoped = base.filter { favorites.contains(stationFavoriteID($0)) }
        } else {
            scoped = base
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = q.isEmpty ? scoped : scoped.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return searched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if filteredStations.isEmpty {
                ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredStations) { station in
                    NavigationLink {
                        StationMusicModalView(station: station, favorites: $favorites)
                    } label: {
                        StationRow(station: station, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        }
        .navigationTitle(country)
        .searchable(text: $searchText, prompt: "Search stations")
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
            AppLog.action("Country stations scope changed: \(newValue.rawValue) (\(country))")
        }
    }
}

/// Station list filtered by a single genre (card rows + favorite hearts).
struct GenreStationsListView: View {
    let genre: String
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    /// Converts a station model into the shared favorites identifier format used across the app.
    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var filteredStations: [RadioStation] {
        let base = stations.filter { $0.moodGenreLabels.contains(genre) }
        let scoped: [RadioStation]
        if scope == .favorites {
            scoped = base.filter { favorites.contains(stationFavoriteID($0)) }
        } else {
            scoped = base
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = q.isEmpty ? scoped : scoped.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.country.localizedCaseInsensitiveContains(q) }
        return searched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if filteredStations.isEmpty {
                ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredStations) { station in
                    NavigationLink {
                        StationMusicModalView(station: station, favorites: $favorites)
                    } label: {
                        StationRow(station: station, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        }
        .navigationTitle(displayGenreName(genre))
        .searchable(text: $searchText, prompt: "Search stations")
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
            AppLog.action("Genre stations scope changed: \(newValue.rawValue) (\(genre))")
        }
    }
}
