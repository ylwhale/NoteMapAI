import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// Map-only search bar to filter radio stations and place pins by name.
struct MapStationSearchBar: View {
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search places or your pins", text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .accessibilityLabel("Search places or your pins")
                .accessibilityHint("Filters the map and shows matching places and saved pins")
                .onSubmit {
                    onSubmit?()
                }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    AppLog.action("Map search cleared")
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clears the current map search query")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Small map controls shown on the Map tab.
/// - Center on user location
/// - Center on the currently playing radio station
struct MapCenterControls: View {
    let places: [Place]
    let stations: [RadioStation]
    // This map view owns its region (no parent binding)
    @Binding var region: MKCoordinateRegion
    @ObservedObject var locationManager: LocationManager
    let onTimerTap: () -> Void

    @ObservedObject private var audio = AudioManager.shared
    @State private var awaitingUserLocationCenter = false

    private enum CurrentMapTarget {
        case place(Place)
        case station(RadioStation)
    }

    /// Updates the current map region to center on a coordinate with a specified span.
    private func setRegion(center: CLLocationCoordinate2D, delta: Double) {
        guard center.latitude.isFinite, center.longitude.isFinite else { return }
        region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    private var currentlyPlayingStation: RadioStation? {
        guard let url = audio.currentStreamURLString else { return nil }
        return stations.first(where: { $0.streamURL == url })
    }

    private var currentlyPlayingPlace: Place? {
        if let explicitID = audio.currentFavoriteTargetID,
           let resolved = places.first(where: { $0.id == explicitID }) {
            return resolved
        }

        let normalizedCurrentPlaceName = (audio.currentPlaceName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedCurrentPlaceName.isEmpty else { return nil }

        return places.first { place in
            let normalizedPlaceName = place.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return normalizedPlaceName == normalizedCurrentPlaceName
        }
    }

    private var currentMapTarget: CurrentMapTarget? {
        if let place = currentlyPlayingPlace {
            return .place(place)
        }
        if let station = currentlyPlayingStation {
            return .station(station)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                AppLog.action("Center on my location tapped")
                if let coord = locationManager.coordinate {
                    AppLog.dump("Center on cached location coordinate", [
                        "lat": coord.latitude,
                        "lon": coord.longitude
                    ])
                    setRegion(center: coord, delta: 0.8)
                } else {
                    awaitingUserLocationCenter = true
                    AppLog.info("Center on my location: requesting one-shot location")
                    locationManager.requestOneShotLocation()
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on my location")
            .accessibilityHint("Requests your location and centers the map")

            Button {
                AppLog.action("Sleep timer button tapped")
                onTimerTap()
            } label: {
                Image(systemName: "zzz")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep timer")
            .accessibilityHint("Opens the sleep timer settings")


            Button {
                switch currentMapTarget {
                case .place(let place):
                    AppLog.action("Center on currently playing place: \(place.id) \(place.name)")
                    setRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), delta: 0.8)
                case .station(let station):
                    AppLog.action("Center on currently playing station: \(station.id) \(station.name)")
                    setRegion(center: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude), delta: 10)
                case .none:
                    AppLog.info("Center on currently playing audio tapped with no active pin")
                }
            } label: {
                Image(systemName: "mappin")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
                    .opacity(currentMapTarget == nil ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(currentMapTarget == nil)
            .accessibilityLabel("Center on currently playing pin")
            .accessibilityHint("Centers the map on the place or pin that is currently playing audio")
        }
        .onReceive(locationManager.$coordinate) { newValue in
            guard awaitingUserLocationCenter, let coord = newValue else { return }
            AppLog.dump("Center on my location resolved", [
                "lat": coord.latitude,
                "lon": coord.longitude
            ])
            setRegion(center: coord, delta: 0.8)
            awaitingUserLocationCenter = false
        }
        .onChange(of: locationManager.authorizationStatus) { _, newValue in
            switch newValue {
            case .denied, .restricted:
                awaitingUserLocationCenter = false
            default:
                break
            }
        }
    }
}

/// A small results card shown under the map's search bar.
/// - Only appears when the query is non-empty (after trimming).
/// - If there are no matches, shows a friendly "No matching content found" message.
/// - If there are matches, lists both place pins and radio stations.
struct MapStationSearchResultsCard: View {
    let query: String
    let stations: [RadioStation]
    let places: [Place]
    let onSelectStation: (RadioStation) -> Void
    let onSelectPlace: (Place) -> Void

    /// Controls whether the inline results card shows every matching place.
    @State private var showAllPlaces: Bool = false
    /// Controls whether the inline results card shows every matching station.
    @State private var showAllStations: Bool = false

    private let collapsedRowLimit: Int = 4

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visiblePlaces: [Place] {
        showAllPlaces ? places : Array(places.prefix(collapsedRowLimit))
    }

    private var visibleStations: [RadioStation] {
        showAllStations ? stations : Array(stations.prefix(collapsedRowLimit))
    }

    private var usesExpandedLayout: Bool {
        showAllPlaces || showAllStations
    }

    @ViewBuilder
    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !visiblePlaces.isEmpty {
                Text("Places")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(Array(visiblePlaces.enumerated()), id: \.element.id) { idx, place in
                    Button {
                        onSelectPlace(place)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: place.iconSystemName)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Text(place.subtitle.isEmpty ? place.effectiveCategory.displayName : place.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Place result: \(place.name)")
                    .accessibilityValue(place.effectiveCategory.displayName)
                    .accessibilityHint("Opens the place details")

                    if idx != visiblePlaces.count - 1 {
                        Divider()
                            .padding(.leading, 12 + 28 + 12)
                    }
                }

                if places.count > collapsedRowLimit {
                    Button {
                        showAllPlaces.toggle()
                        AppLog.action(showAllPlaces ? "Expanded map search places list" : "Collapsed map search places list")
                    } label: {
                        HStack(spacing: 6) {
                            Text(showAllPlaces ? "Show fewer places" : "+ \(places.count - collapsedRowLimit) more places")
                            Image(systemName: showAllPlaces ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAllPlaces ? "Show fewer place results" : "Show all place results")
                    .accessibilityHint("Expands or collapses the matching places list")
                }
            }

            if !visiblePlaces.isEmpty && !visibleStations.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            if !visibleStations.isEmpty {
                Text("Radio stations")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(Array(visibleStations.enumerated()), id: \.element.id) { idx, station in
                    Button {
                        onSelectStation(station)
                    } label: {
                        HStack(spacing: 12) {
                            StationLogoView(logoURLString: station.logoURL)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(station.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(station.country)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Radio station result: \(station.name)")
                    .accessibilityValue(station.country)
                    .accessibilityHint("Opens the station details")

                    if idx != visibleStations.count - 1 {
                        Divider()
                            .padding(.leading, 12 + 28 + 12)
                    }
                }

                if stations.count > collapsedRowLimit {
                    Button {
                        showAllStations.toggle()
                        AppLog.action(showAllStations ? "Expanded map search stations list" : "Collapsed map search stations list")
                    } label: {
                        HStack(spacing: 6) {
                            Text(showAllStations ? "Show fewer stations" : "+ \(stations.count - collapsedRowLimit) more stations")
                            Image(systemName: showAllStations ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAllStations ? "Show fewer station results" : "Show all station results")
                    .accessibilityHint("Expands or collapses the matching radio stations list")
                }
            }
        }
    }

    var body: some View {
        if trimmed.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if visiblePlaces.isEmpty && visibleStations.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Text("No matching content found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 14)
                        Spacer(minLength: 0)
                    }
                } else {
                    if usesExpandedLayout {
                        resultsContent
                    } else {
                        ScrollView {
                            resultsContent
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .onChange(of: trimmed) { _, _ in
                showAllPlaces = false
                showAllStations = false
            }
        }
    }
}

/// Small logo view used in the map's search results card.
/// Falls back to a default radio icon if the URL is missing or fails.
struct StationLogoView: View {
    let logoURLString: String?

    var body: some View {
        AlamofireStationLogoView(logoURLString: logoURLString)
    }
}

// MARK: - Place Search Results (MapKit)

/// A sheet that shows MapKit place search results, allowing the user to add a new pin.
///
/// This is triggered when the user submits the Map tab search bar. The on-map
/// search results card continues to show local place-pin and radio-station matches.
struct PlaceSearchResultsSheet: View {
    let query: String
    let results: [MKMapItem]
    let isSearching: Bool
    let errorMessage: String?
    let onSelect: (MKMapItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
                } else if let msg = errorMessage, results.isEmpty {
                    ContentUnavailableView(msg, systemImage: "magnifyingglass")
                } else {
                    List {
                        ForEach(results, id: \.self) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unnamed place")
                                        .font(.headline)
                                    if let title = item.placemark.title, !title.isEmpty {
                                        Text(title)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
        }
    }
}

/// Small overview map used to preview pins and station locations in list contexts.
struct PlacesStationsOverviewMapView: View {
    let places: [Place]
    let stations: [RadioStation]
    @Binding var activeSheet: PlacesMapTabView.ActiveSheet?
    @Binding var flightRequest: RandomStationFlightRequest?

    // Used to render thumbnail pins for places that have user-added photos/videos.
    @EnvironmentObject private var mediaStore: PinMediaStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = false

    // Region is owned by the parent Map tab and passed in as a binding.
    @Binding var region: MKCoordinateRegion

    @State private var cameraPosition: MapCameraPosition

    @State private var pendingInitialRegion: MKCoordinateRegion?
    @State private var flightTask: Task<Void, Never>? = nil
    @State private var isPerformingRandomStationFlight: Bool = false
    @State private var isApplyingGestureDrivenRegionSync: Bool = false

    /// Shared timing values for the full random-station flyover so every phase stays synchronized.
    ///
    /// The sample counts intentionally run near display refresh cadence so the camera path reads
    /// as one continuous motion instead of a small number of visible jumps between waypoints.
    private enum RandomStationFlightProfile {
        static let cameraHandoffDelay: TimeInterval = 0.01
        static let takeoffZoomDuration: TimeInterval = 1.0
        static let midFlightDuration: TimeInterval = 0.90
        static let landingDuration: TimeInterval = 0.74
        static let landingSampleCount: Int = 36
        static let settleDuration: TimeInterval = 0.20
        static let settleSampleCount: Int = 12
        static let completionPadding: TimeInterval = 0.03
    }

    // MARK: - Region safety
    /// MapKit will throw `Invalid Region` if the span is too large or contains NaN.
    /// When we show global radio stations, naive min/max longitude can produce a
    /// delta > 360 (or pick the long way around the dateline). This helper clamps
    /// and also computes the *shortest* longitude span around the globe.
    private static func safeRegion(for coords: [CLLocationCoordinate2D], minDelta: Double) -> MKCoordinateRegion {
        // Filter out invalid points.
        let pts = coords.filter {
            $0.latitude.isFinite && $0.longitude.isFinite &&
            $0.latitude >= -90 && $0.latitude <= 90
        }
        guard !pts.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.7897, longitude: -87.5997),
                span: MKCoordinateSpan(latitudeDelta: max(minDelta, 0.02), longitudeDelta: max(minDelta, 0.02))
            )
        }

        /// Normalizes a longitude value into the valid -180...180 range.
        func normalizeLon(_ lon: Double) -> Double {
            var x = lon.truncatingRemainder(dividingBy: 360)
            if x >= 180 { x -= 360 }
            if x < -180 { x += 360 }
            return x
        }

        // Latitude span is straightforward.
        let lats = pts.map { $0.latitude }
        let minLat = lats.min() ?? pts[0].latitude
        let maxLat = lats.max() ?? pts[0].latitude
        let centerLat = (minLat + maxLat) / 2

        // Longitude span: choose the shortest arc (handles dateline crossing).
        let sortedLons = pts.map { normalizeLon($0.longitude) }.sorted()
        let n = sortedLons.count

        var lonSpan: Double = 0
        var centerLon: Double = sortedLons[0]

        if n > 1 {
            var maxGap: Double = -1
            var gapIndex: Int = 0

            // Gaps between consecutive longitudes.
            for i in 0..<(n - 1) {
                let gap = sortedLons[i + 1] - sortedLons[i]
                if gap > maxGap {
                    maxGap = gap
                    gapIndex = i
                }
            }

            // Wrap-around gap (last -> first across +360).
            let wrapGap = (sortedLons[0] + 360) - sortedLons[n - 1]
            if wrapGap > maxGap {
                maxGap = wrapGap
                gapIndex = n - 1
            }

            lonSpan = max(0, 360 - maxGap)

            // The minimal interval starts right after the largest gap.
            let start = sortedLons[(gapIndex + 1) % n]
            let end = start + lonSpan
            centerLon = normalizeLon((start + end) / 2)
        }

        // Add padding but keep MapKit happy.
        let padding: Double = 1.25
        var latDelta = max(minDelta, (maxLat - minLat) * padding)
        var lonDelta = max(minDelta, lonSpan * padding)

        if !latDelta.isFinite || latDelta <= 0 { latDelta = minDelta }
        if !lonDelta.isFinite || lonDelta <= 0 { lonDelta = minDelta }

        // Hard clamps to avoid `Invalid Region`.
        latDelta = min(latDelta, 179.0)
        lonDelta = min(lonDelta, 359.0)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    init(
        places: [Place],
        stations: [RadioStation],
        activeSheet: Binding<PlacesMapTabView.ActiveSheet?>,
        region: Binding<MKCoordinateRegion>,
        flightRequest: Binding<RandomStationFlightRequest?>
    ) {
        self.places = places
        self.stations = stations
        self._activeSheet = activeSheet
        self._region = region
        self._flightRequest = flightRequest

        // If the parent gave us a wide "world" default, zoom to fit all annotations.
        let isWorldDefault =
            region.wrappedValue.span.latitudeDelta >= 79.0 &&
            region.wrappedValue.span.longitudeDelta >= 79.0

        if isWorldDefault {
            let coords: [CLLocationCoordinate2D] =
                (places.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }) +
                (stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })

            let fitted = Self.safeRegion(for: coords, minDelta: 0.5)
            _pendingInitialRegion = State(initialValue: fitted)
            _cameraPosition = State(initialValue: .camera(Self.camera(for: fitted, heading: 0, pitch: 0)))
        } else {
            _pendingInitialRegion = State(initialValue: nil)
            _cameraPosition = State(initialValue: .camera(Self.camera(for: region.wrappedValue, heading: 0, pitch: 0)))
        }
    }

    /// Identifies whether a map annotation represents a place pin or a radio station.
    private enum AnnotationKind {
        case place(Place)
        case station(RadioStation)
    }

    /// Identifiable wrapper used to drive map annotations for places and stations.
    private struct AnnotationItem: Identifiable {
        let kind: AnnotationKind
        let coordinate: CLLocationCoordinate2D
        let title: String

        var id: String {
            switch kind {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }

        /// Text handed to MapKit for the system-managed annotation title.
        ///
        /// Station titles are intentionally suppressed here because MapKit can occasionally
        /// reuse or misplace those title layers while zooming, which causes duplicated or
        /// stray labels on the map. Accessibility still uses `title` on the tappable button.
        var systemAnnotationTitle: String {
            switch kind {
            case .place:
                return title
            case .station:
                return ""
            }
        }

        /// Keeps the visible marker anchored to the correct point on the map.
        ///
        /// - Places continue to use a bottom anchor so the pin tip sits on the coordinate.
        /// - Stations use a centered anchor because they render as a dot, not a pin with a tip.
        var anchor: UnitPoint {
            switch kind {
            case .place:
                return .bottom
            case .station:
                return .center
            }
        }

        /// Matches the content alignment to the anchor so enlarged tap targets do not visually
        /// offset the marker while zooming or panning the map.
        var contentAlignment: Alignment {
            switch kind {
            case .place:
                return .bottom
            case .station:
                return .center
            }
        }
    }

    private var items: [AnnotationItem] {
        let placeItems: [AnnotationItem] = places.map { p in
            AnnotationItem(
                kind: .place(p),
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                title: p.name
            )
        }
        let stationItems: [AnnotationItem] = stations.map { s in
            AnnotationItem(
                kind: .station(s),
                coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                title: s.name
            )
        }
        return placeItems + stationItems
    }

    /// A token that changes whenever the user updates the media (photo/video) for a pin.
    /// Using it with `.id(...)` forces MapKit to refresh the annotation view immediately.
    private func mediaRefreshToken(for pinKey: String) -> String {
        mediaStore.changeToken(for: pinKey)
    }

    /// Builds a stable, per-pin refresh token so annotation views stay unique even
    /// when multiple pins have no attached media yet.
    private func annotationRefreshToken(for pinKey: String) -> String {
        pinKey + "_" + mediaRefreshToken(for: pinKey)
    }

    /// Compares two regions with a tolerance to avoid jittery region updates.
    private func regionsApproximatelyEqual(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        // Small epsilon to prevent feedback loops between camera updates and region binding.
        let eps = 0.000_001
        return abs(a.center.latitude - b.center.latitude) < eps &&
               abs(a.center.longitude - b.center.longitude) < eps &&
               abs(a.span.latitudeDelta - b.span.latitudeDelta) < eps &&
               abs(a.span.longitudeDelta - b.span.longitudeDelta) < eps
    }

    /// Normalized representation of a map region used to compare regions and avoid redundant updates.
    private struct RegionKey: Equatable {
        let centerLat: Double
        let centerLon: Double
        let latDelta: Double
        let lonDelta: Double

        init(_ r: MKCoordinateRegion) {
            // Round to reduce chatter from tiny camera updates.
            /// Performs the `round6` operation for this type.
            func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
            centerLat = round6(r.center.latitude)
            centerLon = round6(r.center.longitude)
            latDelta  = round6(r.span.latitudeDelta)
            lonDelta  = round6(r.span.longitudeDelta)
        }
    }

    /// Presents a sheet reliably even if the user taps the same annotation twice in a row.
    private func presentSheet(_ sheet: PlacesMapTabView.ActiveSheet) {
        if activeSheet?.id == sheet.id {
            activeSheet = nil
            DispatchQueue.main.async {
                activeSheet = sheet
            }
        } else {
            activeSheet = sheet
        }
    }

    /// Opens the correct modal for a map annotation and logs the interaction.
    private func openAnnotation(_ item: AnnotationItem) {
        switch item.kind {
        case .place(let place):
            AppLog.action("Map pin tapped: place \(place.id) \(place.name)")
            AppLog.dump("Map place pin coordinate", [
                "lat": place.latitude,
                "lon": place.longitude
            ])
            presentSheet(.place(place))

        case .station(let station):
            AppLog.action("Map pin tapped: station \(station.id) \(station.name)")
            AppLog.dump("Map station pin coordinate", [
                "lat": station.latitude,
                "lon": station.longitude
            ])
            presentSheet(.station(station))
        }
    }

    /// Approximates a camera distance that fits the supplied region in view.
    private static func approximateCameraDistance(for region: MKCoordinateRegion) -> CLLocationDistance {
        let latitudeFactor = max(region.span.latitudeDelta, 0.02)
        let longitudeFactor = max(region.span.longitudeDelta, 0.02) * max(cos(region.center.latitude * .pi / 180), 0.2)
        let dominantDegrees = max(latitudeFactor, longitudeFactor)
        let meters = dominantDegrees * 111_000
        return min(max(meters * 2.1, 14_000), 18_000_000)
    }

    /// Builds a concrete `MapCamera` from a region so the map can stay in camera mode even when idle.
    private static func camera(for region: MKCoordinateRegion, heading: CLLocationDirection, pitch: Double) -> MapCamera {
        MapCamera(
            centerCoordinate: region.center,
            distance: approximateCameraDistance(for: region),
            heading: heading,
            pitch: pitch
        )
    }

    /// Interpolates longitudes across the shortest global arc so camera moves stay smooth near the dateline.
    private static func interpolatedLongitude(from start: Double, to end: Double, progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)

        var delta = end - start
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        var value = start + (delta * clamped)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// Shared interpolation helper used throughout the full flyover path.
    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + ((end - start) * min(max(progress, 0), 1))
    }

    /// Smooths a 0...1 progress value using a symmetric curve so the camera eases in and out naturally.
    private static func smootherStep(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    /// A sine-based ease-in-out curve used for the initial liftoff so the flyover starts gently.
    private static func easeInOutSine(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return -(cos(.pi * clamped) - 1) / 2
    }

    /// A cubic ease-out curve that produces a true soft landing at the destination.
    private static func easeOutCubic(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    /// Interpolates between two headings across the shortest rotation so the map never spins the long way around.
    private static func interpolatedHeading(from start: CLLocationDirection, to end: CLLocationDirection, progress: Double) -> CLLocationDirection {
        let clamped = min(max(progress, 0), 1)

        var delta = end - start
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        var value = start + (delta * clamped)
        if value < 0 { value += 360 }
        if value >= 360 { value -= 360 }
        return value
    }

    /// Interpolates between two regions, including wrapped longitude handling, so the map can glide across the globe.
    private static func interpolatedRegion(from start: MKCoordinateRegion, to end: MKCoordinateRegion, progress: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: interpolate(from: start.center.latitude, to: end.center.latitude, progress: progress),
                longitude: interpolatedLongitude(from: start.center.longitude, to: end.center.longitude, progress: progress)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: interpolate(from: start.span.latitudeDelta, to: end.span.latitudeDelta, progress: progress),
                longitudeDelta: interpolate(from: start.span.longitudeDelta, to: end.span.longitudeDelta, progress: progress)
            )
        )
    }

    /// Computes a travel heading so the animated camera subtly leans into the direction of travel.
    private static func heading(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let startLat = start.latitude * .pi / 180
        let startLon = start.longitude * .pi / 180
        let endLat = end.latitude * .pi / 180
        let endLon = end.longitude * .pi / 180

        let y = sin(endLon - startLon) * cos(endLat)
        let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(endLon - startLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    /// Cancels any in-flight random-station animation before starting a new sequence.
    @MainActor
    /// Cancels flight work items.
    private func cancelFlightWorkItems() {
        flightTask?.cancel()
        flightTask = nil
        isPerformingRandomStationFlight = false
    }

    /// Converts the map to an explicit camera state immediately so the first animated frame does not stutter.
    @MainActor
    /// Stores camera immediately.
    private func setCameraImmediately(to targetRegion: MKCoordinateRegion, heading: CLLocationDirection, pitch: Double) {
        cameraPosition = .camera(Self.camera(for: targetRegion, heading: heading, pitch: pitch))
    }

    /// Animates the SwiftUI map camera to a region with optional pitch + heading for a more cinematic feel.
    /// Uses the supplied animation so the takeoff can run as one continuous zoom while sampled phases stay linear.
    @MainActor
    /// Animates camera.
    private func animateCamera(to targetRegion: MKCoordinateRegion,
                               heading: CLLocationDirection,
                               pitch: Double,
                               animation: Animation) {
        withAnimation(animation) {
            cameraPosition = .camera(Self.camera(for: targetRegion, heading: heading, pitch: pitch))
        }
    }

    /// Convenience wrapper for sampled segments that should move linearly between intermediate camera states.
    @MainActor
    /// Animates camera.
    private func animateCamera(to targetRegion: MKCoordinateRegion, heading: CLLocationDirection, pitch: Double, duration: Double) {
        animateCamera(
            to: targetRegion,
            heading: heading,
            pitch: pitch,
            animation: .linear(duration: duration)
        )
    }

    /// Suspends for a frame-sized delay between samples without blocking the main thread.
    private func pauseBetweenFlightSamples(_ duration: TimeInterval) async -> Bool {
        let safeDuration = max(duration, 0)
        let nanoseconds = UInt64(safeDuration * 1_000_000_000)

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Runs one sampled flight segment in sequence so the map updates continuously without queuing hundreds of steps up front.
    @MainActor
    @discardableResult
    /// Runs flight segment.
    private func runFlightSegment(from startRegion: MKCoordinateRegion,
                                  to endRegion: MKCoordinateRegion,
                                  headingStart: CLLocationDirection,
                                  headingEnd: CLLocationDirection,
                                  pitchStart: Double,
                                  pitchEnd: Double,
                                  duration: TimeInterval,
                                  sampleCount: Int,
                                  easing: @escaping (Double) -> Double,
                                  logMessage: String) async -> Bool {
        let resolvedSampleCount = max(sampleCount, 1)
        let stepDuration = duration / Double(resolvedSampleCount)

        AppLog.info(logMessage)

        for step in 1...resolvedSampleCount {
            guard !Task.isCancelled else { return false }

            let rawProgress = Double(step) / Double(resolvedSampleCount)
            let progress = easing(rawProgress)
            let intermediateRegion = Self.interpolatedRegion(from: startRegion, to: endRegion, progress: progress)
            let intermediateHeading = Self.interpolatedHeading(from: headingStart, to: headingEnd, progress: progress)
            let intermediatePitch = Self.interpolate(from: pitchStart, to: pitchEnd, progress: progress)

            animateCamera(
                to: intermediateRegion,
                heading: intermediateHeading,
                pitch: intermediatePitch,
                duration: stepDuration
            )

            guard await pauseBetweenFlightSamples(stepDuration) else { return false }
        }

        return true
    }

    /// Runs a single continuous camera segment for phases that should feel like one unbroken motion.
    /// This is used for the opening takeoff so the map performs one smooth one-second zoom-out.
    @MainActor
    @discardableResult
    /// Runs continuous flight segment.
    private func runContinuousFlightSegment(to endRegion: MKCoordinateRegion,
                                            heading: CLLocationDirection,
                                            pitch: Double,
                                            duration: TimeInterval,
                                            animation: Animation,
                                            logMessage: String) async -> Bool {
        guard !Task.isCancelled else { return false }

        AppLog.info(logMessage)
        animateCamera(
            to: endRegion,
            heading: heading,
            pitch: pitch,
            animation: animation
        )

        return await pauseBetweenFlightSamples(duration)
    }

    /// Performs the full random-station flyover while respecting Reduce Motion.
    /// Keeps the map under flight control until the final flat landing is complete so the end state does not snap.
    @MainActor
    /// Performs random station flight.
    private func performRandomStationFlight(_ request: RandomStationFlightRequest) {
        cancelFlightWorkItems()

        if accessibilityReduceMotion {
            AppLog.info("Reduce Motion enabled; random station flyover collapsed to a direct jump")
            withAnimation(.easeInOut(duration: 0.2)) {
                cameraPosition = .region(request.finalRegion)
            }
            region = request.finalRegion
            flightRequest = nil
            return
        }

        isPerformingRandomStationFlight = true

        let visibleStartRegion = region
        let travelHeading = Self.heading(from: visibleStartRegion.center, to: request.targetCoordinate)
        let overviewRegion = request.overviewRegion
        let approachRegion = Self.interpolatedRegion(
            from: overviewRegion,
            to: request.finalRegion,
            progress: 0.68
        )
        // The opening second now runs as one continuous zoom-out.
        // Keeping the center fixed, the heading flat, and the pitch modest removes the micro-step feel
        // that can show up when the first frames are built from many tiny pan/zoom/rotate samples.
        let takeoffZoomRegion = MKCoordinateRegion(
            center: visibleStartRegion.center,
            span: MKCoordinateSpan(
                latitudeDelta: Self.interpolate(
                    from: visibleStartRegion.span.latitudeDelta,
                    to: overviewRegion.span.latitudeDelta,
                    progress: 0.56
                ),
                longitudeDelta: Self.interpolate(
                    from: visibleStartRegion.span.longitudeDelta,
                    to: overviewRegion.span.longitudeDelta,
                    progress: 0.56
                )
            )
        )

        // The map stays in explicit camera mode even while idle, but we still rewrite the current
        // visible state here so the flyover always begins from the exact camera values the user sees.
        AppLog.info("Prewarming map camera for a smoother random station takeoff")
        setCameraImmediately(to: visibleStartRegion, heading: 0, pitch: 0)

        flightTask = Task { @MainActor in
            AppLog.info("Running random station flyover animation with a staged takeoff, direct mid-flight move, soft landing, and final settle")

            guard await pauseBetweenFlightSamples(RandomStationFlightProfile.cameraHandoffDelay) else {
                flightTask = nil
                return
            }

            let didTakeoff = await runContinuousFlightSegment(
                to: takeoffZoomRegion,
                heading: 0,
                pitch: 18,
                duration: RandomStationFlightProfile.takeoffZoomDuration,
                animation: .timingCurve(0.18, 0.92, 0.24, 1.0, duration: RandomStationFlightProfile.takeoffZoomDuration),
                logMessage: "Random station flyover entering a one-second continuous takeoff zoom-out"
            )
            guard didTakeoff else {
                flightTask = nil
                return
            }

            let didMidFlight = await runContinuousFlightSegment(
                to: approachRegion,
                heading: travelHeading,
                pitch: 32,
                duration: RandomStationFlightProfile.midFlightDuration,
                animation: .timingCurve(0.20, 0.78, 0.26, 1.0, duration: RandomStationFlightProfile.midFlightDuration),
                logMessage: "Random station flyover flowing directly from the opening zoom-out into one continuous mid-flight move"
            )
            guard didMidFlight else {
                flightTask = nil
                return
            }

            let didLand = await runFlightSegment(
                from: approachRegion,
                to: request.finalRegion,
                headingStart: travelHeading,
                headingEnd: 0,
                pitchStart: 32,
                pitchEnd: 6,
                duration: RandomStationFlightProfile.landingDuration,
                sampleCount: RandomStationFlightProfile.landingSampleCount,
                easing: Self.easeOutCubic,
                logMessage: "Random station flyover entering full soft landing"
            )
            guard didLand else {
                flightTask = nil
                return
            }

            let didSettle = await runFlightSegment(
                from: request.finalRegion,
                to: request.finalRegion,
                headingStart: 0,
                headingEnd: 0,
                pitchStart: 6,
                pitchEnd: 0,
                duration: RandomStationFlightProfile.settleDuration,
                sampleCount: RandomStationFlightProfile.settleSampleCount,
                easing: Self.easeOutCubic,
                logMessage: "Random station flyover entering final settle at destination"
            )
            guard didSettle else {
                flightTask = nil
                return
            }

            region = request.finalRegion

            guard await pauseBetweenFlightSamples(RandomStationFlightProfile.completionPadding) else {
                flightTask = nil
                return
            }

            isPerformingRandomStationFlight = false
            flightRequest = nil
            flightTask = nil
        }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(items) { item in
                Annotation(item.systemAnnotationTitle, coordinate: item.coordinate, anchor: item.anchor) {
                    Button {
                        openAnnotation(item)
                    } label: {
                        ZStack(alignment: item.contentAlignment) {
                            // Keep the visual marker the same, but enlarge the tappable target so
                            // taps are reliably recognized instead of being interpreted as map pans.
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 44, height: 44)

                            Group {
                                switch item.kind {
                                case .place:
                                    if let ui = mediaStore.firstThumbnail(for: item.id) {
                                        Image(uiImage: ui)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 34, height: 34)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                            .shadow(radius: 2)
                                    } else {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.red)
                                            .shadow(radius: 2)
                                    }

                                case .station:
                                    // Stations still look like a small red dot, but now sit inside
                                    // a larger invisible tap target for reliability.
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 10, height: 10)
                                        .shadow(radius: 1)
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .id(annotationRefreshToken(for: item.id))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityHint("Opens details")
                        .accessibilityAddTraits(.isButton)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .task {
            guard let r = pendingInitialRegion else { return }
            pendingInitialRegion = nil
            // Defer updating the parent binding until after the first render to avoid
            // \"Modifying state during view update\" warnings.
            await MainActor.run {
                region = r
                setCameraImmediately(to: r, heading: 0, pitch: 0)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Keep the parent's region binding in sync (used by search / UI),
            // but do not feed camera updates back into the binding while the flyover is running.
            guard !isPerformingRandomStationFlight else { return }

            let updatedRegion = context.region
            guard !regionsApproximatelyEqual(region, updatedRegion) else { return }

            // Mark gesture-driven updates so the matching binding change does not immediately
            // rebuild the camera and cause the small visible "jump" that happens after panning.
            isApplyingGestureDrivenRegionSync = true
            region = updatedRegion

            DispatchQueue.main.async {
                isApplyingGestureDrivenRegionSync = false
            }
        }
        .onChange(of: RegionKey(region)) { _, _ in
            // If something external updates the region (e.g. search result jump),
            // reflect it in the camera position unless the random flyover currently owns the camera.
            guard !isPerformingRandomStationFlight else { return }
            guard !isApplyingGestureDrivenRegionSync else { return }

            let newRegion = region
            setCameraImmediately(to: newRegion, heading: 0, pitch: 0)
        }
        .onChange(of: flightRequest?.id) { _, _ in
            guard let request = flightRequest else { return }
            performRandomStationFlight(request)
        }
        .onDisappear {
            cancelFlightWorkItems()
            flightRequest = nil
        }
    }
}



/// Map view used on the Places tab to show places and stations in context.
struct PlacesOverviewMapView: View {
    let places: [Place]
    @Binding var modalPlace: Place?

    // Used to render thumbnail pins for places that have user-added photos/videos.
    @EnvironmentObject private var mediaStore: PinMediaStore

    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = false

    @State private var cameraPosition: MapCameraPosition

    init(places: [Place], modalPlace: Binding<Place?>) {
        self.places = places
        self._modalPlace = modalPlace
        let initial = Self.initialRegion(for: places)
        _cameraPosition = State(initialValue: .region(initial))
    }

    /// Produces a token that forces media subviews to refresh when the attachment list changes.
    private func mediaRefreshToken(for pinKey: String) -> String {
        mediaStore.changeToken(for: pinKey)
    }

    /// Builds a stable, per-pin refresh token so annotation views stay unique even
    /// when multiple pins have no attached media yet.
    private func annotationRefreshToken(for pinKey: String) -> String {
        pinKey + "_" + mediaRefreshToken(for: pinKey)
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(places) { p in
                Annotation(p.name, coordinate: p.coordinate, anchor: .bottom) {
                    Button {
                        modalPlace = p
                    } label: {
                        if let ui = mediaStore.firstThumbnail(for: "place_" + p.id) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(radius: 2)
                        } else {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .shadow(radius: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open place card")
                    .id(annotationRefreshToken(for: "place_" + p.id))
                }
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .frame(minHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    /// Performs initial region.
    private static func initialRegion(for places: [Place]) -> MKCoordinateRegion {
        guard !places.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.7921, longitude: -87.5994),
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        }

        let lats = places.map { $0.latitude }
        let lons = places.map { $0.longitude }
        let minLat = lats.min() ?? places[0].latitude
        let maxLat = lats.max() ?? places[0].latitude
        let minLon = lons.min() ?? places[0].longitude
        let maxLon = lons.max() ?? places[0].longitude

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Add a little padding so pins aren't glued to the edges.
        // Also clamp to keep MapKit from throwing `Invalid Region` for extreme spans.
        var latDelta = max(0.02, (maxLat - minLat) * 1.6)
        var lonDelta = max(0.02, (maxLon - minLon) * 1.6)
        if !latDelta.isFinite || latDelta <= 0 { latDelta = 0.04 }
        if !lonDelta.isFinite || lonDelta <= 0 { lonDelta = 0.04 }
        latDelta = min(latDelta, 179.0)
        lonDelta = min(lonDelta, 359.0)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}
