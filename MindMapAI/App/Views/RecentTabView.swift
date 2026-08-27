import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Recent tab

/// Shows recently opened places and stations with quick access back into their detail sheets.
struct RecentTabView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    /// Callback used to open the Help sheet from the toolbar.
    let onHelp: () -> Void

    @EnvironmentObject private var recents: RecentManager
    @EnvironmentObject private var mediaStore: PinMediaStore
    @EnvironmentObject private var voiceMemoStore: VoiceMemoStore
    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    @State private var activeSheet: ActiveSheet? = nil

    // Control sheet height so we can tweak layout only for the compact (not pulled out) state.
    @State private var placeDetent: PresentationDetent = .height(360)
    @State private var stationDetent: PresentationDetent = .height(340)

    /// Top segmented control mode for the Favorites tab.
    private enum FavoritesMode: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case recent = "Recent"
        case journal = "Journal"
        var id: String { rawValue }
    }

    @State private var mode: FavoritesMode = .favorites

    private struct MemoryJournalEntry: Identifiable {
        let place: Place
        let displayTitle: String
        let notePreview: String
        let mediaCount: Int
        let voiceMemoCount: Int
        let updatedAt: Date

        var id: String { place.id }
    }

    /// Category chips for the Favorites mode (mirrors the Places tab chips, but without the radio discovery filters).
    private enum FavoritesCategoryFilter: Hashable {
        case all
        case place(PlaceCategory)
        case radio

        var label: String {
            switch self {
            case .all: return "All Categories"
            case .place(let c): return c.displayName
            case .radio: return "Audio"
            }
        }
    }

    @State private var favoritesCategoryFilter: FavoritesCategoryFilter = .all

    /// Identifies which detail sheet the Recents tab should currently present.
    enum ActiveSheet: Identifiable {
        case place(Place)
        case station(RadioStation)

        var id: String {
            switch self {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }
    }

    private var recentItems: [RecentItem] { recents.items }

    /// Computes the favorites identifier used for a station.
    /// Converts a station model into the shared favorites identifier format used across the app.
    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var favoritePlaces: [Place] {
        places
            .filter { favorites.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoriteStations: [RadioStation] {
        []
    }

    private var placeCategories: [PlaceCategory] {
        Array(Set(places.map { $0.effectiveCategory }))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredFavoritePlaces: [Place] {
        switch favoritesCategoryFilter {
        case .all:
            return favoritePlaces
        case .radio:
            return []
        case .place(let c):
            return favoritePlaces.filter { $0.effectiveCategory == c }
        }
    }

    private var filteredFavoriteStations: [RadioStation] {
        switch favoritesCategoryFilter {
        case .all, .radio:
            return favoriteStations
        case .place:
            return []
        }
    }

    /// Performs the `chipButton` operation for this type.
    private func chipButton(title: String, isSelected: Bool, action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(hint)
    }

    private var favoritesCategoryChipsCard: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                chipButton(
                    title: FavoritesCategoryFilter.all.label,
                    isSelected: favoritesCategoryFilter == .all,
                    action: { favoritesCategoryFilter = .all },
                    hint: "Shows your saved places and memories"
                )

                ForEach(placeCategories, id: \.self) { cat in
                    chipButton(
                        title: cat.displayName,
                        isSelected: favoritesCategoryFilter == .place(cat),
                        action: { favoritesCategoryFilter = .place(cat) },
                        hint: "Filters your favorites to the \(cat.displayName) category"
                    )
                }

            }
            .padding(.vertical, 4)
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.plain)
        }
        .scrollIndicators(.visible)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    private var favoritesEmpty: Bool { favoritePlaces.isEmpty && favoriteStations.isEmpty }

    private func pinKey(for place: Place) -> String { "place_" + place.id }

    private var journalEntries: [MemoryJournalEntry] {
        places.compactMap { place in
            let key = pinKey(for: place)
            let memory = placeMemoryStore.record(for: key)
            let mediaCount = mediaStore.items(for: key).count
            let voiceMemoCount = voiceMemoStore.items(for: key).count

            guard memory != nil || mediaCount > 0 || voiceMemoCount > 0 else { return nil }

            let timestamps = [
                memory?.updatedAt,
                mediaStore.items(for: key).map(\.createdAt).max(),
                voiceMemoStore.items(for: key).map(\.createdAt).max()
            ].compactMap { $0 }

            let notePreview = memory?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return MemoryJournalEntry(
                place: place,
                displayTitle: placeMemoryStore.displayTitle(for: key, fallback: place.name),
                notePreview: notePreview,
                mediaCount: mediaCount,
                voiceMemoCount: voiceMemoCount,
                updatedAt: timestamps.max() ?? Date.distantPast
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    // Removes recent item for this feature.
    /// Removes recent item.
    private func removeRecentItem(_ item: RecentItem) {
        recents.remove(kind: item.kind, itemID: item.itemID)
        if activeSheet?.id == item.id {
            activeSheet = nil
        }
    }

    /// Resolves the best available logo URL for a recent station item.
    private func resolvedLogoURL(for item: RecentItem) -> String? {
        guard item.kind == .station else { return nil }
        let fromStations = stations.first(where: { $0.id == item.itemID })?.logoURL
        let candidates: [String?] = [fromStations, item.logoURL]
        for candidate in candidates {
            if let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Card-like row for recent items (keeps Recents behavior while matching the new card styling).
    private func recentCardRow(for item: RecentItem) -> some View {
        HStack(spacing: 12) {
            if item.kind == .station {
                StationLogoView(logoURLString: resolvedLogoURL(for: item))
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "music.note")
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
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
    /// Performs the `favoriteStationCardRow` operation for this type.
    private func favoriteStationCardRow(_ station: RadioStation) -> some View {
        let favoriteID = stationFavoriteID(station)
        let isFavorite = favorites.contains(favoriteID)

        return HStack(spacing: 12) {
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
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    /// Performs the `favoritePlaceCardRow` operation for this type.
    private func favoritePlaceCardRow(_ place: Place) -> some View {
        let isFavorite = favorites.contains(place.id)

        return HStack(spacing: 12) {
            Image(systemName: place.iconSystemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(placeMemoryStore.displayTitle(for: pinKey(for: place), fallback: place.name))
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
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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


    private var modePicker: some View {
            Picker("Favorites view mode", selection: $mode) {
                ForEach(FavoritesMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Favorites view mode")
            .accessibilityValue(mode.rawValue)
            .accessibilityHint("Switch between your favorites, recent items, and saved memory journal entries")
        }

    private func journalCardRow(_ entry: MemoryJournalEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !entry.notePreview.isEmpty {
                    Text(entry.notePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(entry.place.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("\(entry.mediaCount) media · \(entry.voiceMemoCount) voice notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.updatedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    var body: some View {
        NavigationStack {
            List {
                if mode == .favorites {
                    if favoritesEmpty {
                        ContentUnavailableView("No favorites yet", systemImage: "star")
                            .listRowSeparator(.hidden)
                    } else {
                        favoritesCategoryChipsCard
                            .cardListRowStyle()

                        let favStations = filteredFavoriteStations
                        let favPlaces = filteredFavoritePlaces

                        if favStations.isEmpty && favPlaces.isEmpty {
                            ContentUnavailableView("No favorites in this category", systemImage: "star")
                                .listRowSeparator(.hidden)
                        } else {
                            switch favoritesCategoryFilter {
                            case .all:
                                if !favStations.isEmpty {
                                    Section("Radio") {
                                        ForEach(favStations) { station in
                                            Button {
                                                activeSheet = .station(station)
                                            } label: {
                                                StationRow(station: station, favorites: $favorites, showsDisclosure: true)
                                            }
                                            .buttonStyle(.plain)
                                            .cardListRowStyle()
                                            .accessibilityHint("Opens this saved item. Use the heart button to remove it from favorites.")
                                        }
                                    }
                                    .textCase(nil)
                                }

                                if !favPlaces.isEmpty {
                                    Section("Places") {
                                        ForEach(favPlaces, id: \.listRefreshID) { place in
                                            Button {
                                                activeSheet = .place(place)
                                            } label: {
                                                PlaceRow(place: place, favorites: $favorites, showsDisclosure: true)
                                            }
                                            .buttonStyle(.plain)
                                            .cardListRowStyle()
                                            .accessibilityHint("Opens the place player sheet. Use the heart button to remove from favorites.")
                                        }
                                    }
                                    .textCase(nil)
                                }

                            case .radio:
                                ForEach(favStations) { station in
                                    Button {
                                        activeSheet = .station(station)
                                    } label: {
                                        StationRow(station: station, favorites: $favorites, showsDisclosure: true)
                                    }
                                    .buttonStyle(.plain)
                                    .cardListRowStyle()
                                    .accessibilityHint("Opens this saved item. Use the heart button to remove it from favorites.")
                                }

                            case .place:
                                ForEach(favPlaces, id: \.listRefreshID) { place in
                                    Button {
                                        activeSheet = .place(place)
                                    } label: {
                                        PlaceRow(place: place, favorites: $favorites, showsDisclosure: true)
                                    }
                                    .buttonStyle(.plain)
                                    .cardListRowStyle()
                                    .accessibilityHint("Opens the place player sheet. Use the heart button to remove from favorites.")
                                }
                            }
                        }
                    }
                } else if mode == .recent {
                    if recentItems.isEmpty {
                        ContentUnavailableView("No recent items", systemImage: "clock")
                            .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(recentItems) { item in
                                Button {
                                    switch item.kind {
                                    case .place:
                                        if let p = places.first(where: { $0.id == item.itemID }) {
                                            activeSheet = .place(p)
                                        }
                                    case .station:
                                        if let s = stations.first(where: { $0.id == item.itemID }) {
                                            activeSheet = .station(s)
                                        }
                                    }
                                } label: {
                                    recentCardRow(for: item)
                                }
                                .buttonStyle(.plain)
                                .cardListRowStyle()
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeRecentItem(item)
                                    } label: {
                                        Label("Remove from Recent", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeRecentItem(item)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .accessibilityHint("Opens the saved detail view. Swipe or use actions to remove this item from recent.")
                                .accessibilityAction(named: Text("Remove from recent")) {
                                    removeRecentItem(item)
                                }
                            }
                        }
                        .textCase(nil)
                    }
                } else {
                    if journalEntries.isEmpty {
                        ContentUnavailableView("No memories yet", systemImage: "book.closed")
                            .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(journalEntries) { entry in
                                Button {
                                    activeSheet = .place(entry.place)
                                } label: {
                                    journalCardRow(entry)
                                }
                                .buttonStyle(.plain)
                                .cardListRowStyle()
                                .accessibilityHint("Opens the saved place sheet with your memory note, voice notes, and media.")
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
            // Dynamic title so the Recent mode shows "Recent" while Favorites mode stays "Favorites".
            .navigationTitle(mode == .recent ? "Recent" : (mode == .journal ? "Memory Journal" : "Favorites"))
                        .toolbar {
                ToolbarItem(placement: .principal) {
                    modePicker
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onHelp) {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help")
                }

                if mode == .recent && !recentItems.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear") {
                            AppLog.action("Cleared recent items")
                            recents.clear()
                        }
                    }
                }
            }
            .onChange(of: mode) { _, newValue in
                AppLog.action("Favorites tab mode changed: \(newValue.rawValue)")
            }
            .onChange(of: favoritesCategoryFilter) { _, newValue in
                AppLog.action("Favorites category filter changed: \(newValue.label)")
            }
            .onChange(of: activeSheet?.id) { _, _ in
                placeDetent = .height(360)
                stationDetent = .height(340)
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .place(let place):
                    PlaceMusicModalView(place: place, favorites: $favorites, detent: $placeDetent, onDelete: {
                        places.removeAll { $0.id == place.id }
                        activeSheet = nil
                    })
                        .presentationDetents([.height(360), .medium], selection: $placeDetent)
                case .station(let station):
                    StationMusicModalView(station: station, favorites: $favorites, detent: $stationDetent, onDelete: {
                        stations.removeAll { $0.id == station.id }
                        activeSheet = nil
                    })
                        .presentationDetents([.height(340), .medium], selection: $stationDetent)
                }
            }
        }
    }
}
