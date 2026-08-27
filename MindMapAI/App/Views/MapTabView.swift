import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// Drives the animated "random walk" camera sequence on the map.
struct RandomStationFlightRequest: Identifiable {
    let id = UUID()
    let targetID: String
    let targetName: String
    let targetKind: String
    let startCoordinate: CLLocationCoordinate2D
    let targetCoordinate: CLLocationCoordinate2D
    let overviewRegion: MKCoordinateRegion
    let finalRegion: MKCoordinateRegion
}

/// Full-screen map tab with clickable pins.
/// Tapping a pin opens the same modal "Place Card" used elsewhere.
struct PlacesMapTabView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var activeSheet: ActiveSheet? = nil
    // Control sheet height so we can tweak layout only for the compact (not pulled out) state.
    // Slightly taller compact detents so content doesn't look clipped under the
    // grabber/rounded corners on iPhone in the compact state.
    @State private var placeDetent: PresentationDetent = .height(360)
    @State private var stationDetent: PresentationDetent = .height(340)

    @State private var stationSearchText: String = ""

    // Persisted map style selection (shared across map views).
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = false

    // iPad TabView shows the tab bar at the top, which can overlap our custom map overlay.
    // Add a small extra top offset only on iPad so the search bar + buttons sit below the top tab bar.
    private var topControlsOffset: CGFloat {
        // Tuned so the search bar sits just under the iPad top tab strip without leaving an excessive gap.
        UIDevice.current.userInterfaceIdiom == .pad ? 28 : 0
    }

    // On iPhone we intentionally nudge the cluster upward to sit closer to the Dynamic Island.
    // On iPad (top tab bar), keep it within the safe area to avoid overlapping the tab strip.
    private var topClusterNudge: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 0 : -50
    }

    // MapKit place search (not limited to existing pins).
    @State private var isSearchingPlaces: Bool = false
    @State private var showPlaceSearchSheet: Bool = false
    @State private var pendingSheetAfterPlaceSearch: ActiveSheet? = nil
    @State private var placeSearchQuery: String = ""
    @State private var placeSearchResults: [MKMapItem] = []
    @State private var placeSearchError: String? = nil
    @State private var showSleepTimerSheet: Bool = false
    @ObservedObject private var sleepTimer = SleepTimerManager.shared


    /// Startup map region shown after the splash + onboarding flow so the first screen matches the Europe/Africa composition from the provided mockup.
    private static let startupShowcaseRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.5, longitude: 6.0),
        span: MKCoordinateSpan(latitudeDelta: 76.0, longitudeDelta: 72.0)
    )

    @State private var region: MKCoordinateRegion = PlacesMapTabView.startupShowcaseRegion
    @State private var pendingFlightRequest: RandomStationFlightRequest? = nil
    @State private var pendingRandomStationSheetWorkItem: DispatchWorkItem? = nil
    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var audio = AudioManager.shared

    private var trimmedStationQuery: String {
        stationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stations filtered by the current query. Used for both map pins and the search results card.
    private var matchedStations: [RadioStation] {
        guard !trimmedStationQuery.isEmpty else { return stations }
        return stations.filter { $0.name.localizedCaseInsensitiveContains(trimmedStationQuery) }
    }

    /// Places filtered by the current query. Used for both map pins and the search results card.
    private var matchedPlaces: [Place] {
        guard !trimmedStationQuery.isEmpty else { return places }
        return places.filter { $0.name.localizedCaseInsensitiveContains(trimmedStationQuery) }
    }

    /// Formats a place's address into a user-friendly single line.
    private func formattedAddress(for placemark: MKPlacemark) -> String {
        var parts: [String] = []
        if let name = placemark.name { parts.append(name) }
        if let city = placemark.locality { parts.append(city) }
        if let state = placemark.administrativeArea { parts.append(state) }
        if let country = placemark.country { parts.append(country) }
        // Avoid repeating the name twice.
        let unique = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return unique.joined(separator: ", ")
    }

    /// Starts a MapKit place search for the provided query text.
    /// Runs a map-based place search and records the request/result details for logging.
    private func startPlaceSearch(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        placeSearchQuery = trimmed
        placeSearchError = nil
        placeSearchResults = []
        isSearchingPlaces = true
        showPlaceSearchSheet = true

        AppLog.action("Search places: \(trimmed)")
        AppLog.info("Map search region center=(\(region.center.latitude), \(region.center.longitude)) span=(\(region.span.latitudeDelta), \(region.span.longitudeDelta))")

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Bias results around the current visible region.
        request.region = region

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                isSearchingPlaces = false
                if let error = error {
                    AppLog.info("Map search failed for \(trimmed): \(error.localizedDescription)")
                    placeSearchError = error.localizedDescription
                    placeSearchResults = []
                    return
                }
                placeSearchResults = response?.mapItems ?? []
                AppLog.info("Map search results for \(trimmed): \(placeSearchResults.count) items")
                if let first = placeSearchResults.first {
                    AppLog.dump("Map search first result", [
                        "name": first.name ?? "",
                        "lat": first.placemark.coordinate.latitude,
                        "lon": first.placemark.coordinate.longitude
                    ] as [String: Any])
                }
                if placeSearchResults.isEmpty {
                    placeSearchError = "No places found."
                }
            }
        }
    }

    /// Creates and persists a new user place pin from a selected search result.
    /// Converts a selected map search result into a user-created place pin stored by the app.
    private func addPlacePin(from mapItem: MKMapItem) {
        let coord = mapItem.placemark.coordinate
        guard coord.latitude.isFinite, coord.longitude.isFinite else { return }

        let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeName = (name?.isEmpty == false) ? name! : placeSearchQuery
        let addr = formattedAddress(for: mapItem.placemark)

        AppLog.action("Add place pin from search: \(placeName)")
        AppLog.dump("Map search selection", [
            "name": placeName,
            "address": addr,
            "lat": coord.latitude,
            "lon": coord.longitude
        ] as [String: Any])

        // Reuse an existing pin when the user taps the same search result again so
        // the detail sheet always points at the real stored map item.
        let resolvedPlace: Place
        if let existingPlace = places.first(where: {
            $0.name == placeName &&
            abs($0.latitude - coord.latitude) < 0.00001 &&
            abs($0.longitude - coord.longitude) < 0.00001
        }) {
            resolvedPlace = existingPlace
        } else {
            let newPlace = Place(
                id: "user_" + UUID().uuidString,
                name: placeName,
                category: .services,
                subtitle: "Added from search",
                address: addr,
                hours: "",
                notes: "",
                latitude: coord.latitude,
                longitude: coord.longitude
            )
            places.append(newPlace)
            resolvedPlace = newPlace
        }

        // Clear the inline filter so the new pin is visible immediately on the map.
        stationSearchText = ""
        region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        pendingSheetAfterPlaceSearch = .place(resolvedPlace)
        showPlaceSearchSheet = false
    }

    /// Identifies which detail sheet the map tab should currently present.
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

    /// Presents a sheet reliably even when another place/station sheet is already visible.
    private func presentSheet(_ sheet: ActiveSheet) {
        if activeSheet?.id == sheet.id {
            activeSheet = nil
            DispatchQueue.main.async {
                activeSheet = sheet
            }
        } else {
            activeSheet = sheet
        }
    }

    /// Returns the midpoint longitude along the shortest wrapped arc between two coordinates.
    private func midpointLongitude(from start: Double, to end: Double) -> Double {
        var delta = end - start
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        var midpoint = start + (delta * 0.5)
        if midpoint > 180 { midpoint -= 360 }
        if midpoint < -180 { midpoint += 360 }
        return midpoint
    }

    /// Selects a random visible pin and animates the map camera to its location.
    /// Picks from the currently matched places first, then falls back to stations when present.
    private func flyToRandomPin() {
        enum RandomMapTarget {
            case place(Place)
            case station(RadioStation)

            var id: String {
                switch self {
                case .place(let place):
                    return place.id
                case .station(let station):
                    return station.id
                }
            }

            var name: String {
                switch self {
                case .place(let place):
                    return place.name
                case .station(let station):
                    return station.name
                }
            }

            var kindLabel: String {
                switch self {
                case .place:
                    return "place"
                case .station:
                    return "station"
                }
            }

            var coordinate: CLLocationCoordinate2D {
                switch self {
                case .place(let place):
                    return CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                case .station(let station):
                    return CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
                }
            }

            var finalRegion: MKCoordinateRegion {
                let center = coordinate
                switch self {
                case .place:
                    return MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: 0.8, longitudeDelta: 0.8)
                    )
                case .station:
                    return MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 0.9)
                    )
                }
            }
        }

        let placeCandidates = trimmedStationQuery.isEmpty ? places : matchedPlaces
        let stationCandidates = trimmedStationQuery.isEmpty ? stations : matchedStations
        let candidates: [RandomMapTarget] = placeCandidates.map { .place($0) } + stationCandidates.map { .station($0) }

        guard let picked = candidates.randomElement() else {
            AppLog.info("Random walk requested, but no pins matched the current filters")
            return
        }

        let startCoord = region.center
        let targetCoord = picked.coordinate

        // Compute an overview span large enough to show the current camera position and the destination together.
        let dLat = abs(startCoord.latitude - targetCoord.latitude)
        let rawLonDelta = abs(startCoord.longitude - targetCoord.longitude)
        let wrappedLonDelta = min(rawLonDelta, 360 - rawLonDelta)
        let maxDelta = max(dLat, wrappedLonDelta)
        let visibleDelta = max(region.span.latitudeDelta, region.span.longitudeDelta)
        let overviewDelta = min(max(maxDelta * 2.0 + 2.0, visibleDelta * 1.15, 8.0), 145.0)
        let overviewCenter = CLLocationCoordinate2D(
            latitude: (startCoord.latitude + targetCoord.latitude) / 2,
            longitude: midpointLongitude(from: startCoord.longitude, to: targetCoord.longitude)
        )

        let overviewRegion = MKCoordinateRegion(
            center: overviewCenter,
            span: MKCoordinateSpan(latitudeDelta: overviewDelta, longitudeDelta: overviewDelta)
        )

        let request = RandomStationFlightRequest(
            targetID: picked.id,
            targetName: picked.name,
            targetKind: picked.kindLabel,
            startCoordinate: startCoord,
            targetCoordinate: targetCoord,
            overviewRegion: overviewRegion,
            finalRegion: picked.finalRegion
        )

        AppLog.action("Random walk selected a \(picked.kindLabel): \(picked.name)")
        AppLog.dump("Random walk flyover", [
            "targetKind": picked.kindLabel,
            "targetID": picked.id,
            "targetName": picked.name,
            "fromLat": startCoord.latitude,
            "fromLon": startCoord.longitude,
            "toLat": targetCoord.latitude,
            "toLon": targetCoord.longitude,
            "overviewCenterLat": overviewCenter.latitude,
            "overviewCenterLon": overviewCenter.longitude,
            "overviewDelta": overviewDelta,
            "reduceMotion": accessibilityReduceMotion
        ] as [String: Any])

        pendingFlightRequest = request
        pendingRandomStationSheetWorkItem?.cancel()
        pendingRandomStationSheetWorkItem = nil
    }



    var body: some View {
        Group {
            PlacesStationsOverviewMapView(
                places: matchedPlaces,
                stations: matchedStations,
                activeSheet: $activeSheet,
                region: $region,
                flightRequest: $pendingFlightRequest
            )
            // Keep showing the actual map even when there are currently no bundled or user pins.
            // This preserves the normal map experience instead of replacing it with a blocking empty state.
            // The mini player is inserted from RootView via `safeAreaInset`, so it will stay above the Tab Bar.
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        // A dedicated search bar for the Map tab.
        // It filters both radio stations and place pins by name.
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 6) {
                    MapStationSearchBar(text: $stationSearchText, onSubmit: {
                        // Keep the on-screen search results card focused on local content,
                        // while still allowing MapKit place search when the user submits.
                        startPlaceSearch(for: stationSearchText)
                    })

                    HStack {
                        Button {
                            mapIsSatellite.toggle()
                            AppLog.action("Map style toggled: \(mapIsSatellite ? "satellite" : "standard")")
                        } label: {
                            Image(systemName: mapIsSatellite ? "globe.americas.fill" : "map.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mapIsSatellite ? "Switch to standard map" : "Switch to satellite map")
                        .accessibilityHint("Toggles the map appearance")

                        if !places.isEmpty || !stations.isEmpty {
                            Button {
                                AppLog.action("Random walk button tapped")
                                flyToRandomPin()
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Random walk")
                            .accessibilityHint(accessibilityReduceMotion ? "Jump to a random pin on the map" : "Animate to a random pin on the map")
                        }

                        Spacer()
                        MapCenterControls(
                            places: places,
                            stations: stations,
                            region: $region,
                            locationManager: locationManager,
                            onTimerTap: {
                                AppLog.action("Sleep timer sheet opened")
                                showSleepTimerSheet = true
                            }
                        )
                    }

                    // Search results card: appears only when the query is non-empty.
                    MapStationSearchResultsCard(
                        query: trimmedStationQuery,
                        stations: matchedStations,
                        places: matchedPlaces,
                        onSelectStation: { station in
                            AppLog.action("Map inline search selected station: \(station.id) \(station.name)")
                            presentSheet(.station(station))
                        },
                        onSelectPlace: { place in
                            AppLog.action("Map inline search selected place: \(place.id) \(place.name)")
                            AppLog.dump("Map inline search selected place coordinate", [
                                "lat": place.latitude,
                                "lon": place.longitude
                            ])
                            region = MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
                            )
                            presentSheet(.place(place))
                        }
                    )
                }
                // Keep controls tight to the top safe area (right under the Dynamic Island).
                .padding(.top, topControlsOffset)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                // Countdown chip overlays under the search bar without shifting other controls.
                if sleepTimer.isActive {
                    HStack {
                        Spacer()
                        Button {
                            AppLog.action("Sleep timer countdown chip tapped: cancel")
                            sleepTimer.cancel()
                        } label: {
                            SleepTimerCountdownChip(remainingText: sleepTimer.formattedRemaining())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel sleep timer")
                        .accessibilityValue(sleepTimer.formattedRemaining())
                        .accessibilityHint("Double tap to cancel the sleep timer")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 52 + topControlsOffset)
                    .transition(.opacity)
                }
            }
            // Pull the whole control cluster slightly into the top unsafe area so it
            // visually hugs the Dynamic Island / status bar.
            .padding(.top, topClusterNudge)
        }
        .onChange(of: activeSheet?.id) { _, _ in
            // Always start sheets in the compact detent.
            placeDetent = .height(360)
            stationDetent = .height(340)
        }
        .onChange(of: showPlaceSearchSheet) { _, isPresented in
            guard !isPresented, let pendingSheetAfterPlaceSearch else { return }
            self.pendingSheetAfterPlaceSearch = nil
            DispatchQueue.main.async {
                presentSheet(pendingSheetAfterPlaceSearch)
            }
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet(isPresented: $showSleepTimerSheet)
        }
        .sheet(isPresented: $showPlaceSearchSheet) {
            PlaceSearchResultsSheet(
                query: placeSearchQuery,
                results: placeSearchResults,
                isSearching: isSearchingPlaces,
                errorMessage: placeSearchError,
                onSelect: { item in
                    addPlacePin(from: item)
                },
                onDismiss: {
                    showPlaceSearchSheet = false
                }
            )
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .place(let place):
                PlaceMusicModalView(place: place, favorites: $favorites, detent: $placeDetent, onDelete: {
                    places.removeAll { $0.id == place.id }
                    activeSheet = nil
                })
                    .id(place.id)
                    .presentationDetents([.height(360), .medium], selection: $placeDetent)
            case .station(let station):
                StationMusicModalView(station: station, favorites: $favorites, detent: $stationDetent, onDelete: {
                    stations.removeAll { $0.id == station.id }
                    activeSheet = nil
                })
                    .id(station.id)
                    .presentationDetents([.height(340), .medium], selection: $stationDetent)
            }
        }
        .onDisappear {
            pendingRandomStationSheetWorkItem?.cancel()
            pendingRandomStationSheetWorkItem = nil
        }
    }
}
