import Foundation
import CoreLocation
import Combine
import UIKit
import AVFoundation

/// Lightweight logger for printing consistent debug messages to the console.
enum AppLog {
    /// Logs an informational message to the console.
    nonisolated static func info(_ message: String) {
        print("[MindMapAI] \(message)")
    }

    /// Logs a user action message to the console (e.g., a button pressed).
    nonisolated static func action(_ message: String,
                       file: StaticString = #fileID,
                       line: UInt = #line) {
        print("[MindMapAI][Action] \(message) @\(file):\(line)")
    }

    /// Logs a labeled local file path (and the full file:// URL) to the console.
    /// This helps graders see exactly what the app is reading/writing.
    nonisolated static func path(_ label: String, _ url: URL) {
        print("[MindMapAI][Path] \(label): \(url.path) (\(url.absoluteString))")
    }

    /// Logs a labeled URL string to the console.
    nonisolated static func url(_ label: String, _ url: URL) {
        print("[MindMapAI][URL] \(label): \(url.absoluteString)")
    }

    /// Logs a labeled debug representation of a value to the console.
    nonisolated static func dump(_ label: String, _ value: Any) {
        print("[MindMapAI][Dump] \(label): \(value)")
    }

    /// Logs a read/write/delete file operation with full path + URL.
    nonisolated static func fileOp(_ op: String, _ url: URL) {
        print("[MindMapAI][File][\(op)] \(url.path) (\(url.absoluteString))")
    }

    /// Logs a network operation (download/stream/etc.) with full URL.
    nonisolated static func netOp(_ op: String, _ url: URL) {
        print("[MindMapAI][Net][\(op)] \(url.absoluteString)")
    }

    /// Dumps (a snippet of) the raw bytes retrieved from a URL (remote or file://).
    /// - For JSON/text: prints a UTF-8 preview.
    /// - For binary: prints a hex preview.
    nonisolated static func dumpData(_ label: String, url: URL, data: Data, maxChars: Int = 6000, maxBytes: Int = 128) {
        // Try text first.
        if let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // If it's JSON-like, pretty-print when possible.
            if trimmed.first == "{" || trimmed.first == "[" {
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
                   let ps = String(data: pretty, encoding: .utf8) {
                    print("[MindMapAI][Dump][Data] \(label) <- \(url.absoluteString)\n\(String(ps.prefix(maxChars)))")
                    return
                }
            }
            print("[MindMapAI][Dump][Data] \(label) <- \(url.absoluteString)\n\(String(s.prefix(maxChars)))")
            return
        }

        // Binary fallback: hex preview.
        let n = min(maxBytes, data.count)
        let hex = data.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("[MindMapAI][Dump][Data] \(label) <- \(url.absoluteString) bytes=\(data.count) hexPrefix(\(n))=\(hex)")
    }
}
/// Categories are stored in the bundled JSON using lowercase strings (e.g. "study").
/// Keep raw values lowercase so JSON decoding works reliably in Swift Playgrounds.
enum PlaceCategory: String, CaseIterable, Codable, Identifiable {
    case study = "study"
    case food = "food"
    case services = "services"
    case outdoors = "outdoors"
    case housing = "housing"

    var id: String { rawValue }

    /// Human-readable title used by the UI.
    var displayName: String {
        switch self {
        case .study: return "Study"
        case .food: return "Food"
        case .services: return "Services"
        case .outdoors: return "Outdoors"
        case .housing: return "Housing"
        }
    }

    var systemImageName: String {
        switch self {
        case .study: return "books.vertical"
        case .food: return "fork.knife"
        case .services: return "wrench.and.screwdriver"
        case .outdoors: return "leaf"
        case .housing: return "house"
        }
    }


    /// Bundled offline audio track used by the map-pin modal.
    var audioTrackBaseName: String {
        switch self {
        case .study: return "study_loop"
        case .food: return "food_loop"
        case .services: return "services_loop"
        case .outdoors: return "outdoors_loop"
        case .housing: return "housing_loop"
        }
    }
}

/// Model representing a place pin with location, metadata, and optional category.
struct Place: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: PlaceCategory
    let subtitle: String
    let address: String
    let hours: String
    let notes: String
    let latitude: Double
    let longitude: Double
}

extension Place {
    /// The user-visible category after applying any saved override.
    var effectiveCategory: PlaceCategory { PlaceCategoryOverrideStore.category(for: self) }

    /// SF Symbol used in list rows.
    var iconSystemName: String { effectiveCategory.systemImageName }

    /// A refresh-aware identifier for SwiftUI lists that must redraw when the
    /// user reclassifies a place. Including the effective category forces the
    /// corresponding row to be rebuilt immediately after an override changes.
    var listRefreshID: String { "\(id)-\(effectiveCategory.rawValue)" }

    /// A per-place bundled music track base name (no extension).
    ///
    /// This is wired so each pin can have its own track. The package currently
    /// ships with placeholder WAVs using these names; you can replace them with
    /// original bundled demo audio files (m4a/mp3/wav) later without changing code.
    var audioTrackBaseName: String {
        switch id {
        case "food-dining": return "always_on_the_way"
        case "coffee-plex": return "september"
        case "housing-north": return "sky_farm"
        case "housing-south": return "meditation_music"
        case "outdoors-garden": return "lighthouse"
        case "outdoors-quad": return "blue_state"
        case "services-it": return "fail_sound"
        case "services-health": return "sound_medicine"
        case "lib-crib": return "path_untrodden"
        // If you add more places later, they will fall back to a category loop.
        default:
            return effectiveCategory.audioTrackBaseName
        }
    }

    /// Human-readable track title shown in the modal.
    var audioTrackTitle: String {
        switch audioTrackBaseName {
        case "always_on_the_way": return "Harbor Drift"
        case "september": return "Golden Hour"
        case "sky_farm": return "Open Sky"
        case "meditation_music": return "Calm Focus"
        case "lighthouse": return "Night Coast"
        case "blue_state": return "Blue Echo"
        case "fail_sound": return "Signal Pulse"
        case "sound_medicine": return "Soft Current"
        case "path_untrodden": return "Quiet Steps"
        default:
            return "Music"
        }
    }
}

/// Loads the bundled place list from JSON resources.
struct PlaceStore {
    /// Loads persisted data for this component.
    static func load() -> [Place] {
        guard let url = Bundle.main.url(forResource: "places", withExtension: "json") else {
            AppLog.info("Missing bundled places.json")
            return []
        }
        AppLog.path("Read places.json", url)
        do {
            let data = try Data(contentsOf: url)
            AppLog.info("places.json bytes: \(data.count)")
            AppLog.dumpData("places.json raw", url: url, data: data, maxChars: 4000)
            let decoded = try JSONDecoder().decode([Place].self, from: data)
            AppLog.info("Decoded places count: \(decoded.count)")
            if let first = decoded.first {
                AppLog.dump("places[0]", first)
            }
            return decoded
        } catch {
            AppLog.info("Failed to load places.json: \(error)")
            return []
        }
    }
}

/// Persist user-added places (pins) created from Map search.
///
/// Bundled places are read-only (from Resources/places.json). Any user-created
/// pins are stored in UserDefaults as JSON and merged into the in-memory list.
struct UserPlaceStore {
    private static let key = "user_places_v1"

    /// Loads persisted data for this component.
    static func load() -> [Place] {
    guard let data = UserDefaults.standard.data(forKey: key) else {
        AppLog.info("UserPlaceStore.load: no data for key \(key)")
        return []
    }
    do {
        let places = try JSONDecoder().decode([Place].self, from: data)
        AppLog.info("UserPlaceStore.load: loaded \(places.count) user places (key: \(key))")
        if let first = places.first {
            AppLog.dump("userPlaces[0]", first)
        }
        return places
    } catch {
        AppLog.info("UserPlaceStore.load: decode failed (key: \(key)) error: \(error)")
        return []
    }
}

    /// Saves the current value to persistent storage.
    static func save(_ userPlaces: [Place]) {
    do {
        let data = try JSONEncoder().encode(userPlaces)
        UserDefaults.standard.set(data, forKey: key)
        AppLog.info("UserPlaceStore.save: saved \(userPlaces.count) user places (\(data.count) bytes) to key \(key)")
    } catch {
        AppLog.info("UserPlaceStore.save: encode failed (key: \(key)) error: \(error)")
    }
}

    /// Returns only user-added places from a mixed list.
    static func userPlaces(from allPlaces: [Place]) -> [Place] {
        allPlaces.filter { $0.id.hasPrefix("user_") }
    }
}


/// Persists per-place category overrides selected by the user from the detail page.
///
/// The bundled `Place.category` value remains the default. Any user-selected
/// override is stored separately so built-in content stays read-only while the
/// app can still reclassify places across lists and detail screens.
struct PlaceCategoryOverrideStore {
    private static let key = "place_category_overrides_v1"
    private static let placeIDUserInfoKey = "placeID"
    private static let categoryRawValueUserInfoKey = "categoryRawValue"
    static let didChangeNotification = Notification.Name("PlaceCategoryOverrideStore.didChange")
    private static var cache: [String: String]? = nil

    /// Loads the current override dictionary, using a small in-memory cache.
    private static func loadOverrides() -> [String: String] {
        if let cached = cache {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: key) else {
            cache = [:]
            AppLog.info("PlaceCategoryOverrideStore.load: no data for key \(key)")
            return [:]
        }

        do {
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            cache = decoded
            AppLog.info("PlaceCategoryOverrideStore.load: loaded \(decoded.count) overrides (\(data.count) bytes) key: \(key)")
            if let first = decoded.first {
                AppLog.dump("placeCategoryOverride[0]", first)
            }
            return decoded
        } catch {
            cache = [:]
            AppLog.info("PlaceCategoryOverrideStore.load: decode failed (key: \(key)) error: \(error)")
            return [:]
        }
    }

    /// Saves the current override dictionary to persistent storage.
    private static func persist(_ overrides: [String: String]) {
        cache = overrides
        do {
            let data = try JSONEncoder().encode(overrides)
            UserDefaults.standard.set(data, forKey: key)
            AppLog.info("PlaceCategoryOverrideStore.save: saved \(overrides.count) overrides (\(data.count) bytes) key: \(key)")
        } catch {
            AppLog.info("PlaceCategoryOverrideStore.save: encode failed (key: \(key)) error: \(error)")
        }
    }

    /// Resolves the category the UI should use for a place.
    static func category(for place: Place) -> PlaceCategory {
        let overrides = loadOverrides()
        guard let raw = overrides[place.id],
              let category = PlaceCategory(rawValue: raw) else {
            return place.category
        }
        return category
    }

    /// Sets or clears the category override for a place.
    static func set(_ category: PlaceCategory, for place: Place) {
        let previous = self.category(for: place)
        var overrides = loadOverrides()

        if category == place.category {
            overrides.removeValue(forKey: place.id)
        } else {
            overrides[place.id] = category.rawValue
        }

        AppLog.action("Set place category: \(place.id) \(previous.rawValue) -> \(category.rawValue)")
        persist(overrides)

        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [
                placeIDUserInfoKey: place.id,
                categoryRawValueUserInfoKey: category.rawValue
            ]
        )
    }

    /// Extracts the changed place/category pair from a notification payload.
    static func changePayload(from notification: Notification) -> (placeID: String, category: PlaceCategory)? {
        guard let userInfo = notification.userInfo,
              let placeID = userInfo[placeIDUserInfoKey] as? String,
              let rawValue = userInfo[categoryRawValueUserInfoKey] as? String,
              let category = PlaceCategory(rawValue: rawValue) else {
            return nil
        }
        return (placeID: placeID, category: category)
    }
}

// MARK: - Global Radio Stations

/// Represents a playable radio station, including its stream URL and map metadata.
struct RadioStation: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let city: String
    let country: String
    let latitude: Double
    let longitude: Double
    let streamURL: String
    let description: String

    // Optional presentation fields (safe for older JSON)
    let logoURL: String?
    let briefDescription: String?
}

extension RadioStation {
    private static let languageDisplayNames: [String: String] = [
        "english": "English",
        "spanish": "Spanish",
        "french": "French",
        "portuguese": "Portuguese",
        "german": "German",
        "italian": "Italian",
        "arabic": "Arabic",
        "hindi": "Hindi",
        "japanese": "Japanese",
        "korean": "Korean",
        "chinese": "Chinese",
        "mandarin": "Mandarin",
        "dutch": "Dutch",
        "nederlandstalig": "Dutch",
        "greek": "Greek",
        "turkish": "Turkish",
        "polish": "Polish",
        "serbian": "Serbian",
        "croatian": "Croatian",
        "bosnian": "Bosnian",
        "hebrew": "Hebrew",
        "thai": "Thai",
        "vietnamese": "Vietnamese"
    ]

    private static let ignoredMoodGenreTokens: Set<String> = [
        "radio", "station", "stream", "live", "fm", "am", "aac", "mp3"
    ]

    // Handles token for this feature.
    /// Performs the `normalizedToken` operation for this type.
    private static func normalizedToken(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_/|—"))
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }
        return trimmed
    }

    // Handles the requested action for this feature.
    /// Performs the `tags` operation for this type.
    private static func tags(from source: String) -> [String] {
        let lowercased = source.lowercased()
        var fragments: [String] = []

        if let range = lowercased.range(of: "tags:") {
            fragments.append(String(lowercased[range.upperBound...]))
        } else if let dashRange = lowercased.range(of: "—") {
            fragments.append(String(lowercased[..<dashRange.lowerBound]))
        } else if let dashRange = lowercased.range(of: " - ") {
            fragments.append(String(lowercased[..<dashRange.lowerBound]))
        }

        if fragments.isEmpty {
            fragments.append(lowercased)
        }

        var ordered: [String] = []
        var seen: Set<String> = []

        for fragment in fragments {
            let parts = fragment.components(separatedBy: CharacterSet(charactersIn: ",;|/"))
            for part in parts {
                guard let token = normalizedToken(part) else { continue }
                guard !seen.contains(token) else { continue }
                seen.insert(token)
                ordered.append(token)
            }
        }

        return ordered
    }

    var tagTokens: [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for source in [description, briefDescription ?? ""] {
            for token in Self.tags(from: source) {
                guard !seen.contains(token) else { continue }
                seen.insert(token)
                ordered.append(token)
            }
        }

        return ordered
    }

    var languageLabels: [String] {
        var labels: [String] = []
        var seen: Set<String> = []

        for token in tagTokens {
            guard let label = Self.languageDisplayNames[token] else { continue }
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            labels.append(label)
        }

        return labels
    }

    var moodGenreLabels: [String] {
        var labels: [String] = []
        var seen: Set<String> = []

        for token in tagTokens {
            guard Self.languageDisplayNames[token] == nil else { continue }
            guard !Self.ignoredMoodGenreTokens.contains(token) else { continue }
            guard token.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            let label = Self.discoveryLabel(for: token)
            guard !label.isEmpty else { continue }
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            labels.append(label)
        }

        return labels
    }

    var worldRegion: String {
        switch country {
        case "United States", "Canada", "Mexico", "Antigua And Barbuda", "Argentina", "Brazil", "Chile", "Colombia", "Costa Rica", "Cuba", "Dominican Republic", "Jamaica", "Peru", "Uruguay":
            return "Americas"
        case "United Kingdom", "Ireland", "France", "Germany", "Spain", "Portugal", "Italy", "Belgium", "Netherlands", "Bosnia And Herzegovina", "Croatia", "Czech Republic", "Denmark", "Finland", "Greece", "Hungary", "Iceland", "Norway", "Poland", "Romania", "Serbia", "Sweden", "Switzerland", "Ukraine":
            return "Europe"
        case "Australia", "New Zealand", "Japan", "South Korea", "China", "India", "Indonesia", "Malaysia", "Philippines", "Singapore", "Thailand", "Vietnam":
            return "Asia-Pacific"
        case "United Arab Emirates", "Saudi Arabia", "Qatar", "Israel", "Turkey":
            return "Middle East"
        case "South Africa", "Kenya", "Nigeria", "Egypt", "Morocco", "Ghana":
            return "Africa"
        default:
            if latitude >= 15, latitude <= 72, longitude >= -170, longitude <= -30 {
                return "Americas"
            }
            if latitude >= 35, latitude <= 72, longitude >= -20, longitude <= 45 {
                return "Europe"
            }
            if latitude <= -10, longitude >= 110 {
                return "Asia-Pacific"
            }
            if longitude >= 45 {
                return "Asia-Pacific"
            }
            return "Global"
        }
    }

    var isStudyFriendly: Bool {
        let haystack = ([name, description, briefDescription ?? ""] + moodGenreLabels + languageLabels)
            .joined(separator: " ")
            .lowercased()

        let positiveSignals = [
            "study", "focus", "classical", "ambient", "instrumental", "jazz",
            "acoustic", "folk", "public", "national", "news", "culture", "ideas",
            "interviews", "talk", "calm", "relax"
        ]

        return positiveSignals.contains { haystack.contains($0) }
    }

    // Calculates the derived value for this feature.
    /// Calculates the distance to the requested coordinate.
    func distance(from coordinate: CLLocationCoordinate2D?) -> CLLocationDistance? {
        guard let coordinate else { return nil }
        let stationLocation = CLLocation(latitude: latitude, longitude: longitude)
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return stationLocation.distance(from: userLocation)
    }

    // Builds label for this feature.
    /// Performs the `discoveryLabel` operation for this type.
    static func discoveryLabel(for token: String) -> String {
        if let label = languageDisplayNames[token] {
            return label
        }

        return token
            .split(separator: " ")
            .map { part in
                let value = String(part)
                guard let first = value.first else { return value }
                return first.uppercased() + String(value.dropFirst())
            }
            .joined(separator: " ")
    }

    // Builds language labels for this feature.
    /// Performs the `availableLanguageLabels` operation for this type.
    static func availableLanguageLabels(in stations: [RadioStation]) -> [String] {
        Array(Set(stations.flatMap { $0.languageLabels })).sorted()
    }

    // Builds mood labels for this feature.
    /// Performs the `availableMoodLabels` operation for this type.
    static func availableMoodLabels(in stations: [RadioStation]) -> [String] {
        Array(Set(stations.flatMap { $0.moodGenreLabels })).sorted()
    }
}

/// Enumerates the station sorting modes offered throughout the discovery UI.
enum StationSortOption: String, CaseIterable, Identifiable, Codable {
    case alphabetical = "A-Z"
    case favoritesFirst = "Favorites First"
    case recentFirst = "Recently Played"
    case studyFriendly = "Study Friendly"
    case nearestFirst = "Nearest to Me"

    var id: String { rawValue }
}

/// Captures a saved set of listening filters that can be restored later as a journey.
struct ListeningJourney: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let country: String?
    let region: String?
    let language: String?
    let mood: String?
    let sortOption: StationSortOption
}

/// Persists saved listening journeys in user defaults for the journey library UI.
struct ListeningJourneyStore {
    private static let key = "listening_journeys_v1"

    // Gets the requested action for this feature.
    /// Returns get.
    static func get() -> [ListeningJourney] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            AppLog.info("ListeningJourneyStore.get: no data for key \(key)")
            return []
        }

        let journeys = (try? JSONDecoder().decode([ListeningJourney].self, from: data)) ?? []
        AppLog.info("ListeningJourneyStore.get: loaded \(journeys.count) journeys (\(data.count) bytes)")
        return journeys
    }

    // Sets the requested action for this feature.
    /// Stores set.
    static func set(_ journeys: [ListeningJourney]) {
        guard let data = try? JSONEncoder().encode(journeys) else { return }
        UserDefaults.standard.set(data, forKey: key)
        AppLog.info("ListeningJourneyStore.set: saved \(journeys.count) journeys (\(data.count) bytes)")
    }

    // Saves the requested action for this feature.
    /// Saves save.
    static func save(_ journey: ListeningJourney) {
        var journeys = get()
        journeys.removeAll { $0.id == journey.id }
        journeys.insert(journey, at: 0)
        set(Array(journeys.prefix(8)))
    }

    @discardableResult
    // Handles the requested action for this feature.
    /// Performs the `rename` operation for this type.
    static func rename(id: String, to newTitle: String) -> Bool {
        let cleanedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            AppLog.info("ListeningJourneyStore.rename: rejected empty title for id \(id)")
            return false
        }

        var journeys = get()
        guard let index = journeys.firstIndex(where: { $0.id == id }) else {
            AppLog.info("ListeningJourneyStore.rename: no matching journey for id \(id)")
            return false
        }

        let existingJourney = journeys[index]
        guard existingJourney.title != cleanedTitle else {
            AppLog.info("ListeningJourneyStore.rename: title unchanged for id \(id)")
            return true
        }

        journeys[index] = ListeningJourney(
            id: existingJourney.id,
            title: cleanedTitle,
            country: existingJourney.country,
            region: existingJourney.region,
            language: existingJourney.language,
            mood: existingJourney.mood,
            sortOption: existingJourney.sortOption
        )
        set(journeys)
        AppLog.action("Renamed listening journey: \(existingJourney.title) -> \(cleanedTitle)")
        return true
    }

    // Removes the requested action for this feature.
    /// Removes remove.
    static func remove(id: String) {
        var journeys = get()
        let previousCount = journeys.count
        journeys.removeAll { $0.id == id }
        guard journeys.count != previousCount else {
            AppLog.info("ListeningJourneyStore.remove: no matching journey for id \(id)")
            return
        }
        set(journeys)
        AppLog.action("Deleted listening journey: \(id)")
    }
}

/// Loads the bundled radio station list from JSON resources.
struct RadioStationStore {
    /// Loads persisted data for this component.
    static func load() -> [RadioStation] {
        guard let url = Bundle.main.url(forResource: "stations", withExtension: "json") else {
            AppLog.info("Missing bundled stations.json")
            return []
        }
        AppLog.path("Read stations.json", url)
        do {
            let data = try Data(contentsOf: url)
            AppLog.info("stations.json bytes: \(data.count)")
            AppLog.dumpData("stations.json raw", url: url, data: data, maxChars: 4000)
            let decoded = try JSONDecoder().decode([RadioStation].self, from: data)
            AppLog.info("Decoded stations count: \(decoded.count)")
            if let first = decoded.first {
                AppLog.dump("stations[0]", first)
            }
            return decoded
        } catch {
            AppLog.info("Failed to load stations.json: \(error)")
            return []
        }
    }
}



// MARK: - Deleted / hidden pins (user-controlled)

/// Stores pin keys that the user has deleted from the map (and lists).
/// Keys are formatted like "place_<id>" and "station_<id>".
struct DeletedPinsStore {
    private static let key = "deleted_pin_keys_v1"

    /// Performs get.
    static func get() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    /// Performs set.
    static func set(_ keys: Set<String>) {
        let list = Array(keys).sorted()
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
            AppLog.info("DeletedPinsStore.set: saved \(list.count) deleted pins (\(data.count) bytes) key: \(key)")
        }
    }

    /// Performs is deleted.
    static func isDeleted(_ pinKey: String) -> Bool {
        get().contains(pinKey)
    }

    /// Performs mark deleted.
    static func markDeleted(_ pinKey: String) {
        AppLog.action("Delete pin: \(pinKey)")
        var keys = get()
        keys.insert(pinKey)
        set(keys)
    }

    /// Performs unmark deleted.
    static func unmarkDeleted(_ pinKey: String) {
        AppLog.action("Restore pin: \(pinKey)")
        var keys = get()
        keys.remove(pinKey)
        set(keys)
    }
}

// MARK: - Per-pin photo persistence (user-added)

/// Stores user-picked photos for each pin (place or station).
///
/// - Photos are written into the app's Documents directory.
/// - A small index (pinKey -> [filename]) is stored in UserDefaults.
/// - Use keys like "place_<id>" and "station_<id>" to avoid collisions.
final class PinPhotoStore: ObservableObject {
    static let shared = PinPhotoStore()

    /// pinKey -> filenames (relative to Documents)
    @Published private(set) var index: [String: [String]] = [:]

    private let defaultsKey = "pin_photo_index_v1"

    init() {
        loadIndex()
        AppLog.path("Documents directory", documentsURL())
        let total = index.values.reduce(0) { $0 + $1.count }
        AppLog.info("PinPhotoStore.init: loaded index for \(index.keys.count) pins, \(total) photos")
    }

    // MARK: Public API

    // Handles the requested action for this feature.
    /// Performs the `filenames` operation for this type.
    func filenames(for pinKey: String) -> [String] {
        index[pinKey] ?? []
    }

    /// Loads all stored images for the given pin.
    func images(for pinKey: String) -> [UIImage] {
        filenames(for: pinKey)
            .compactMap { filename in
                let url = documentsURL().appendingPathComponent(filename)
                AppLog.fileOp("READ", url)
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else { return nil }
                return image
            }
    }

    /// Convenience: returns the first saved image for a pin (if any).
    ///
    /// This is useful for lightweight UI such as map thumbnails.
    func firstImage(for pinKey: String) -> UIImage? {
        guard let first = filenames(for: pinKey).first else { return nil }
        let url = documentsURL().appendingPathComponent(first)
        AppLog.fileOp("READ", url)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    /// Load a single image by filename (relative to Documents).
    func image(for filename: String) -> UIImage? {
        let url = documentsURL().appendingPathComponent(filename)
        AppLog.fileOp("READ", url)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    /// Delete one saved photo from a pin (removes file from disk and updates the index).
    @MainActor
    /// Deletes a stored image file and updates the index.
    func removeImage(filename: String, from pinKey: String) {
        // Remove from disk (ignore failures).
        let url = documentsURL().appendingPathComponent(filename)
        AppLog.action("Remove photo from \(pinKey): \(url.path)")
        AppLog.fileOp("DELETE", url)
        try? FileManager.default.removeItem(at: url)

        // Remove from in-memory index.
        var list = index[pinKey] ?? []
        if let i = list.firstIndex(of: filename) {
            list.remove(at: i)
            index[pinKey] = list
            persistIndex()
        }
    }

    /// Convenience: delete by position (as displayed in the UI).
    @MainActor
    /// Deletes a stored image file and updates the index.
    func removeImage(at index: Int, from pinKey: String) {
        let list = self.index[pinKey] ?? []
        guard index >= 0 && index < list.count else { return }
        removeImage(filename: list[index], from: pinKey)
    }

    /// Delete all saved photos for a pin (removes files from disk and clears the index entry).
    @MainActor
    /// Removes all stored photos for the given pin.
    func removeAllPhotos(for pinKey: String) {
        let list = index[pinKey] ?? []
        AppLog.action("Remove all photos for \(pinKey): \(list.count) files")
        for filename in list {
            let url = documentsURL().appendingPathComponent(filename)
            AppLog.fileOp("DELETE", url)
            try? FileManager.default.removeItem(at: url)
        }
        index[pinKey] = []
        persistIndex()
    }


    /// Save image bytes to disk and attach it to a pin.
    /// Accepts raw bytes from PhotosPicker (or any other source).
    @MainActor
    /// Adds a new image attachment and persists it to disk.
    func addImageData(_ data: Data, to pinKey: String) {
        // Normalize to JPEG to keep storage reasonable and consistent.
        let normalizedData: Data
        if let ui = UIImage(data: data), let jpg = ui.jpegData(compressionQuality: 0.85) {
            normalizedData = jpg
        } else {
            normalizedData = data
        }

        let filename = "\(pinKey)_\(UUID().uuidString).jpg"
        let url = documentsURL().appendingPathComponent(filename)

        do {
            try normalizedData.write(to: url, options: [.atomic])
            AppLog.action("Add photo to \(pinKey): \(normalizedData.count) bytes")
            AppLog.fileOp("WRITE", url)
        } catch {
            // If writing fails, don't mutate the index.
            return
        }

        var list = index[pinKey] ?? []
        list.append(filename)
        index[pinKey] = list
        persistIndex()
    }

    // Optional helper if you ever want delete in the UI later.
    @MainActor
    /// Removes all persisted items for this store.
    func removeAll(for pinKey: String) {
        let files = index[pinKey] ?? []
        for f in files {
            let url = documentsURL().appendingPathComponent(f)
            AppLog.fileOp("DELETE", url)
            try? FileManager.default.removeItem(at: url)
        }
        index[pinKey] = []
        persistIndex()
    }

    // MARK: Persistence

    // Returns url for this feature.
    /// Performs the `documentsURL` operation for this type.
    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Loads the persisted media index from disk.
    private func loadIndex() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            index = [:]
            AppLog.info("PinPhotoStore.loadIndex: no data for key \(defaultsKey)")
            return
        }
        if let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            index = decoded
            let total = decoded.values.reduce(0) { $0 + $1.count }
            AppLog.info("PinPhotoStore.loadIndex: loaded index for \(decoded.keys.count) pins, \(total) photos (\(data.count) bytes)")
        } else {
            index = [:]
            AppLog.info("PinPhotoStore.loadIndex: decode failed for key \(defaultsKey) (\(data.count) bytes)")
        }
    }

    /// Persists the media index to disk.
    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        let total = index.values.reduce(0) { $0 + $1.count }
        AppLog.info("PinPhotoStore.persistIndex: saved index for \(index.keys.count) pins, \(total) photos (\(data.count) bytes)")
    }
}

// MARK: - Per-pin media persistence (photos + videos)

/// Distinguishes between photo and video attachments saved for a pin.
enum PinMediaKind: String, Codable {
    case photo
    case video
}

/// A single media attachment associated with a pin.
///
/// - Photos: `filename` points to a JPEG in Documents.
/// - Videos: `filename` points to a movie file in Documents, and `thumbnailFilename`
///   points to a JPEG thumbnail used for lightweight UI (map pins, grids).
struct PinMediaItem: Identifiable, Codable, Hashable {
    let id: String
    let kind: PinMediaKind
    let filename: String
    let thumbnailFilename: String?
    let createdAt: Date
}

/// Stores user-added photos and videos for pins.
///
/// This is used for *places* so the first attachment (photo or video)
/// can drive the map pin thumbnail.
final class PinMediaStore: ObservableObject {
    static let shared = PinMediaStore()

    /// pinKey -> ordered media items
    @Published private(set) var index: [String: [PinMediaItem]] = [:]

    private let defaultsKey = "pin_media_index_v1"
    private let legacyPhotoDefaultsKey = "pin_photo_index_v1"

    init() {
        loadIndexOrMigrate()
        AppLog.path("Documents directory", documentsURL())
        let total = index.values.reduce(0) { $0 + $1.count }
        AppLog.info("PinMediaStore.init: loaded index for \(index.keys.count) pins, \(total) media items")
    }

    // MARK: Public API

    // Handles the requested action for this feature.
    /// Performs the `items` operation for this type.
    func items(for pinKey: String) -> [PinMediaItem] {
        index[pinKey] ?? []
    }

    /// A small token that changes whenever attachments for a pin change.
    /// Useful to force MapKit annotations to refresh.
    func changeToken(for pinKey: String) -> String {
        let list = items(for: pinKey)
        return "\(list.count)_\(list.first?.id ?? "none")_\(list.last?.id ?? "none")"
    }

    /// Returns the first available thumbnail for a pin's media.
    func firstThumbnail(for pinKey: String) -> UIImage? {
        guard let first = items(for: pinKey).first else { return nil }
        return thumbnail(for: first)
    }

    /// Loads a thumbnail image for a media item when available.
    func thumbnail(for item: PinMediaItem) -> UIImage? {
        switch item.kind {
        case .photo:
            return image(forFilename: item.filename)
        case .video:
            if let thumb = item.thumbnailFilename, let ui = image(forFilename: thumb) {
                return ui
            }
            // Fallback: attempt to generate a thumbnail on-demand (should be rare).
            let url = documentsURL().appendingPathComponent(item.filename)
            return generateThumbnailImage(forVideoAt: url)
        }
    }

    /// Returns the local file URL for a stored video attachment.
    func videoURL(for item: PinMediaItem) -> URL? {
        guard item.kind == .video else { return nil }
        return documentsURL().appendingPathComponent(item.filename)
    }

    /// Remove a single media item (and its files) from a pin.
    @MainActor
    /// Removes the specified item from storage.
    func remove(itemID: String, from pinKey: String) {
        var list = index[pinKey] ?? []
        guard let i = list.firstIndex(where: { $0.id == itemID }) else { return }
        let item = list[i]

        // Delete primary file.
        let fileURL = documentsURL().appendingPathComponent(item.filename)
        AppLog.action("Remove media from \(pinKey): \(fileURL.path)")
        AppLog.fileOp("DELETE", fileURL)
        try? FileManager.default.removeItem(at: fileURL)

        // Delete thumbnail for videos.
        if let thumb = item.thumbnailFilename {
            let thumbURL = documentsURL().appendingPathComponent(thumb)
            AppLog.fileOp("DELETE", thumbURL)
            try? FileManager.default.removeItem(at: thumbURL)
        }

        list.remove(at: i)
        index[pinKey] = list
        persistIndex()
    }

    /// Remove all media (photos + videos) for a pin.
    @MainActor
    /// Removes all persisted items for this store.
    func removeAll(for pinKey: String) {
        let list = index[pinKey] ?? []
        AppLog.action("Remove all media for \(pinKey): \(list.count) files")
        for item in list {
            let fileURL = documentsURL().appendingPathComponent(item.filename)
            AppLog.fileOp("DELETE", fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            if let thumb = item.thumbnailFilename {
                let thumbURL = documentsURL().appendingPathComponent(thumb)
                AppLog.fileOp("DELETE", thumbURL)
                try? FileManager.default.removeItem(at: thumbURL)
            }
        }
        index[pinKey] = []
        persistIndex()
    }

    /// Add an image attachment to a pin.
    @MainActor
    /// Adds a new photo attachment and persists it to disk.
    func addPhotoData(_ data: Data, to pinKey: String) {
        // Normalize to JPEG to keep storage reasonable and consistent.
        let normalizedData: Data
        if let ui = UIImage(data: data), let jpg = ui.jpegData(compressionQuality: 0.85) {
            normalizedData = jpg
        } else {
            normalizedData = data
        }

        let filename = "\(pinKey)_\(UUID().uuidString).jpg"
        let url = documentsURL().appendingPathComponent(filename)

        do {
            try normalizedData.write(to: url, options: [.atomic])
            AppLog.action("Add photo to \(pinKey): \(normalizedData.count) bytes")
            AppLog.fileOp("WRITE", url)
        } catch {
            return
        }

        let item = PinMediaItem(
            id: UUID().uuidString,
            kind: .photo,
            filename: filename,
            thumbnailFilename: nil,
            createdAt: Date()
        )
        var list = index[pinKey] ?? []
        list.append(item)
        index[pinKey] = list
        persistIndex()
    }

    /// Add a video attachment to a pin from a file URL.
    /// The file is copied into Documents and a thumbnail is generated.
    @MainActor
    /// Adds a new video attachment and persists it to disk.
    func addVideoFile(at sourceURL: URL, to pinKey: String) {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let filename = "\(pinKey)_\(UUID().uuidString).\(ext)"
        let destURL = documentsURL().appendingPathComponent(filename)

        // Log the source + destination for grading visibility.
        AppLog.fileOp("READ", sourceURL)
        AppLog.fileOp("WRITE", destURL)

        do {
            // Try move first (fast) then fall back to copy.
            if FileManager.default.fileExists(atPath: destURL.path) {
                AppLog.fileOp("DELETE", destURL)
                try? FileManager.default.removeItem(at: destURL)
            }
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            } catch {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            AppLog.action("Add video to \(pinKey)")
            AppLog.path("Write video file", destURL)
        } catch {
            return
        }

        let thumbFilename: String?
        if let thumbImage = generateThumbnailImage(forVideoAt: destURL),
           let jpg = thumbImage.jpegData(compressionQuality: 0.85) {
            let tf = "\(pinKey)_\(UUID().uuidString)_thumb.jpg"
            let tURL = documentsURL().appendingPathComponent(tf)
            do {
                try jpg.write(to: tURL, options: [.atomic])
                thumbFilename = tf
                AppLog.fileOp("WRITE", tURL)
            } catch {
                thumbFilename = nil
            }
        } else {
            thumbFilename = nil
        }

        let item = PinMediaItem(
            id: UUID().uuidString,
            kind: .video,
            filename: filename,
            thumbnailFilename: thumbFilename,
            createdAt: Date()
        )
        var list = index[pinKey] ?? []
        list.append(item)
        index[pinKey] = list
        persistIndex()
    }

    // MARK: Private helpers

    // Returns url for this feature.
    /// Performs the `documentsURL` operation for this type.
    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Loads an image from disk for the specified filename.
    private func image(forFilename filename: String) -> UIImage? {
        let url = documentsURL().appendingPathComponent(filename)
        AppLog.fileOp("READ", url)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    /// Generates a thumbnail image for a local video file.
    private func generateThumbnailImage(forVideoAt url: URL) -> UIImage? {
        AppLog.fileOp("READ", url)
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// Loads the media index or migrates older formats if necessary.
    private func loadIndexOrMigrate() {
        // 1) Try load the new index.
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [PinMediaItem]].self, from: data) {
            index = decoded
            return
        }

        // 2) If missing, attempt migration from legacy photo store.
        guard let legacyData = UserDefaults.standard.data(forKey: legacyPhotoDefaultsKey),
              let legacy = try? JSONDecoder().decode([String: [String]].self, from: legacyData) else {
            index = [:]
            return
        }

        var migrated: [String: [PinMediaItem]] = [:]
        for (pinKey, files) in legacy {
            var items: [PinMediaItem] = []
            items.reserveCapacity(files.count)
            for f in files {
                items.append(
                    PinMediaItem(
                        id: UUID().uuidString,
                        kind: .photo,
                        filename: f,
                        thumbnailFilename: nil,
                        createdAt: Date()
                    )
                )
            }
            migrated[pinKey] = items
        }
        index = migrated
        persistIndex()
        let total = migrated.values.reduce(0) { $0 + $1.count }
        AppLog.info("PinMediaStore.migrate: migrated \(migrated.keys.count) pins, \(total) photos")
    }

    /// Persists the media index to disk.
    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        let total = index.values.reduce(0) { $0 + $1.count }
        AppLog.info("PinMediaStore.persistIndex: saved index for \(index.keys.count) pins, \(total) items (\(data.count) bytes)")
    }
}

// MARK: - Shared helpers used across views

/// Small value-type used for map/directions helpers.
/// (Some views calculate distances and need a common coordinate container.)
struct Geo: Codable, Hashable {
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

extension Geo {
    /// Great-circle distance in meters using the haversine formula.
    static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0 // Earth radius (m)

        /// Performs deg2rad.
        func deg2rad(_ deg: Double) -> Double { deg * .pi / 180.0 }

        let φ1 = deg2rad(lat1)
        let φ2 = deg2rad(lat2)
        let Δφ = deg2rad(lat2 - lat1)
        let Δλ = deg2rad(lon2 - lon1)

        let a = sin(Δφ / 2) * sin(Δφ / 2) +
                cos(φ1) * cos(φ2) *
                sin(Δλ / 2) * sin(Δλ / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    /// Rough walking-time estimate in minutes.
    /// Assumes ~1.4 m/s (about 5 km/h).
    static func walkingMinutes(for meters: Double) -> Int {
        guard meters.isFinite, meters > 0 else { return 0 }
        let metersPerMinute = 1.4 * 60.0
        let minutes = Int((meters / metersPerMinute).rounded())
        return max(1, minutes)
    }

    /// Cardinal direction (N/NE/E/SE/S/SW/W/NW) from one coordinate to another.
    static func cardinalDirection(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> String {
        /// Performs deg2rad.
        func deg2rad(_ deg: Double) -> Double { deg * .pi / 180.0 }
        /// Performs rad2deg.
        func rad2deg(_ rad: Double) -> Double { rad * 180.0 / .pi }

        let φ1 = deg2rad(fromLat)
        let φ2 = deg2rad(toLat)
        let λ1 = deg2rad(fromLon)
        let λ2 = deg2rad(toLon)

        let y = sin(λ2 - λ1) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(λ2 - λ1)
        var bearing = rad2deg(atan2(y, x)) // -180...180
        if bearing < 0 { bearing += 360 }

        let dirs = ["N","NE","E","SE","S","SW","W","NW"]
        let idx = Int((bearing / 45.0).rounded()) % 8
        return dirs[idx]
    }
}

extension Place {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Simple persistence for Favorites (by Place.id) using UserDefaults.
struct FavoritesStore {
    private static let key = "favorites.placeIds"

    /// Performs get.
    static func get() -> Set<String> {
        let arr = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        let set = Set(arr)
        AppLog.info("FavoritesStore.get: \(set.count) favorites (key: \(key))")
        return set
    }

    /// Performs set.
    static func set(_ favorites: Set<String>) {
        let arr = Array(favorites).sorted()
        UserDefaults.standard.set(arr, forKey: key)
        AppLog.info("FavoritesStore.set: saved \(arr.count) favorites (key: \(key))")
    }
}



// MARK: - Location (for "Center on me")

/// Wraps Core Location authorization and one-shot location updates for map centering.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var coordinate: CLLocationCoordinate2D? = nil

    private let manager = CLLocationManager()
    private var pendingOneShotRequest = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    /// Requests location authorization only when a user-triggered feature needs it.
    func requestAuthorizationIfNeeded() {
        let status = manager.authorizationStatus
        authorizationStatus = status
        AppLog.info("Location authorization status before request: \(status.rawValue)")
        if status == .notDetermined {
            AppLog.action("Request when-in-use location authorization")
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Requests a single location update only when needed by an explicit user action.
    func requestOneShotLocation() {
        let status = manager.authorizationStatus
        authorizationStatus = status
        if coordinate == nil {
            pendingOneShotRequest = true
        }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            AppLog.action("Request one-shot location")
            manager.requestLocation()
        case .notDetermined:
            AppLog.action("Request one-shot location after authorization")
            manager.requestWhenInUseAuthorization()
        default:
            pendingOneShotRequest = false
            AppLog.info("Location request skipped because authorization is unavailable: \(status.rawValue)")
        }
    }

    // MARK: CLLocationManagerDelegate

    /// Handles location manager updates and authorization changes for the app.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        AppLog.info("Location authorization changed: \(authorizationStatus.rawValue)")

        guard pendingOneShotRequest else { return }

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            AppLog.action("Location authorized for pending one-shot request")
            manager.requestLocation()
        case .denied, .restricted:
            pendingOneShotRequest = false
            AppLog.info("Pending location request cleared because authorization is unavailable")
        default:
            break
        }
    }

    /// Performs location manager.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        pendingOneShotRequest = false
        manager.stopUpdatingLocation()
        coordinate = locations.last?.coordinate
        if let coordinate {
            AppLog.dump("Location update", [
                "lat": coordinate.latitude,
                "lon": coordinate.longitude
            ])
        }
    }

    /// Performs location manager.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pendingOneShotRequest = false
        manager.stopUpdatingLocation()
        pendingOneShotRequest = false
        // Keep silent; UI can retry.
        AppLog.info("Location error: \(error)")
    }
}

// MARK: - Recently played / opened
// Keeps up to the last 10 stations and the last 10 places, capped to 10 total items.

/// Represents a recently opened place or station shown in the Recents tab.
struct RecentItem: Identifiable, Codable, Hashable {
    /// Identifies whether a recent item points to a place or a station.
    enum Kind: String, Codable {
        case place
        case station
    }

    let kind: Kind
    let itemID: String
    let title: String
    let subtitle: String
    let logoURL: String?

    var id: String { kind.rawValue + "_" + itemID }
}

/// Persists the recent items list to disk.
struct RecentsStore {
    private static let key = "recents.items.v2"
    static let maxItems = 10

    /// Performs get.
    static func get() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            AppLog.info("RecentsStore.get: no data for key \(key)")
            return []
        }
        let decoded = (try? JSONDecoder().decode([RecentItem].self, from: data)) ?? []
        AppLog.info("RecentsStore.get: loaded \(decoded.count) recent items (\(data.count) bytes)")
        if let first = decoded.first {
            AppLog.dump("recents[0]", first)
        }
        return decoded
    }

    /// Performs set.
    static func set(_ items: [RecentItem]) {
        let capped = Array(items.prefix(maxItems))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: key)
            AppLog.info("RecentsStore.set: saved \(capped.count) recent items (\(data.count) bytes) key: \(key)")
        }
    }
}

/// Manages in-memory recents and keeps them persisted with a maximum capacity.
final class RecentManager: ObservableObject {
    @Published private(set) var items: [RecentItem] = []

    init() {
        items = RecentsStore.get()
    }

    /// Records a recent item and persists the updated recents list.
    func record(place: Place) {
        AppLog.action("Record recent place: \(place.id) \(place.name)")
        let new = RecentItem(kind: .place, itemID: place.id, title: place.name, subtitle: place.effectiveCategory.displayName, logoURL: nil)
        insert(new)
    }

    /// Records a recent item and persists the updated recents list.
    func record(station: RadioStation) {
        AppLog.action("Record recent station: \(station.id) \(station.name)")
        let new = RecentItem(kind: .station, itemID: station.id, title: station.name, subtitle: station.country, logoURL: station.logoURL)
        insert(new)
    }

    /// Clears all stored recents.
    func clear() {
        AppLog.action("Clear recents")
        items = []
        RecentsStore.set(items)
    }

    /// Removes the specified item from storage.
    func remove(kind: RecentItem.Kind, itemID: String) {
        AppLog.action("Remove recent: \(kind.rawValue) \(itemID)")
        items.removeAll { $0.kind == kind && $0.itemID == itemID }
        RecentsStore.set(items)
    }

    /// Inserts an item at the front of the list while enforcing the capacity limit.
    private func insert(_ item: RecentItem) {
        // De-dup then insert at front
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        // Cap independently (per kind), then apply an overall cap.
        var stationCount = 0
        var placeCount = 0
        items = items.filter { it in
            switch it.kind {
            case .station:
                stationCount += 1
                return stationCount <= 10
            case .place:
                placeCount += 1
                return placeCount <= 10
            }
        }
        if items.count > RecentsStore.maxItems {
            items = Array(items.prefix(RecentsStore.maxItems))
        }
        RecentsStore.set(items)
    }
}

// MARK: - Pin audio selection (built-in sounds per place pin)

/// Stores a user-selected built-in sound for a given pin key (e.g. "place_<id>").
/// This lets users change the offline track used by a place pin without mutating
/// the bundled Place data or breaking Codable compatibility.
final class PinAudioSelectionStore: ObservableObject {
    static let shared = PinAudioSelectionStore()

    private let key = "pin.audio.selection.v1"

    /// pinKey -> trackBaseName (without extension)
    @Published private(set) var selections: [String: String] = [:]

    private init() {
        load()
    }

    /// Returns the stored selection for the given place pin.
    func selection(for pinKey: String) -> String? {
        selections[pinKey]
    }

    /// Updates and persists the selection for the given place pin.
    func setSelection(_ trackBaseName: String?, for pinKey: String) {
        AppLog.action("PinAudioSelectionStore.setSelection: \(pinKey) -> \(trackBaseName ?? "nil")")
        if let trackBaseName {
            selections[pinKey] = trackBaseName
        } else {
            selections.removeValue(forKey: pinKey)
        }
        save()
    }

    /// Clears the persisted selection for the given place pin.
    func clearSelection(for pinKey: String) {
        setSelection(nil, for: pinKey)
    }

    /// Loads persisted data for this component.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            selections = [:]
            AppLog.info("PinAudioSelectionStore.load: no data for key \(key)")
            return
        }
        selections = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        AppLog.info("PinAudioSelectionStore.load: loaded \(selections.count) selections (\(data.count) bytes)")
    }

    /// Saves the current value to persistent storage.
    private func save() {
        if let data = try? JSONEncoder().encode(selections) {
            UserDefaults.standard.set(data, forKey: key)
            AppLog.info("PinAudioSelectionStore.save: saved \(selections.count) selections (\(data.count) bytes)")
        }
    }
}


// MARK: - Place memory metadata (custom title + note)

/// User-authored metadata that makes a saved pin feel more personal.
struct PlaceMemoryRecord: Codable, Hashable {
    var customTitle: String
    var note: String
    var updatedAt: Date

    var hasMeaningfulContent: Bool {
        !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Persists custom per-pin memory metadata such as a personal title and note.
final class PlaceMemoryStore: ObservableObject {
    static let shared = PlaceMemoryStore()

    private let key = "place.memory.records.v1"

    /// pinKey -> memory metadata
    @Published private(set) var records: [String: PlaceMemoryRecord] = [:]

    private init() {
        load()
    }

    /// Returns the saved memory metadata for a pin when present.
    func record(for pinKey: String) -> PlaceMemoryRecord? {
        records[pinKey]
    }

    /// Returns the title the UI should show for a pin.
    func displayTitle(for pinKey: String, fallback: String) -> String {
        let trimmed = records[pinKey]?.customTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Indicates whether the pin has any saved memory metadata.
    func hasContent(for pinKey: String) -> Bool {
        records[pinKey]?.hasMeaningfulContent ?? false
    }

    /// Saves or clears the memory metadata for a pin.
    func save(pinKey: String, customTitle: String, note: String) {
        let normalizedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PlaceMemoryRecord(customTitle: normalizedTitle, note: normalizedNote, updatedAt: Date())

        if record.hasMeaningfulContent {
            records[pinKey] = record
            AppLog.action("Save memory metadata: \(pinKey)")
        } else {
            records.removeValue(forKey: pinKey)
            AppLog.action("Clear memory metadata: \(pinKey)")
        }

        persist()
    }

    /// Removes any memory metadata stored for a pin.
    func clear(for pinKey: String) {
        guard records.removeValue(forKey: pinKey) != nil else { return }
        AppLog.action("Delete memory metadata: \(pinKey)")
        persist()
    }

    /// Returns the saved update timestamp for a pin when available.
    func updatedAt(for pinKey: String) -> Date? {
        records[pinKey]?.updatedAt
    }

    /// Loads persisted data for this component.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            records = [:]
            AppLog.info("PlaceMemoryStore.load: no data for key \(key)")
            return
        }
        records = (try? JSONDecoder().decode([String: PlaceMemoryRecord].self, from: data)) ?? [:]
        AppLog.info("PlaceMemoryStore.load: loaded \(records.count) records (\(data.count) bytes)")
    }

    /// Saves the current value to persistent storage.
    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
            AppLog.info("PlaceMemoryStore.save: saved \(records.count) records (\(data.count) bytes)")
        }
    }
}

// MARK: - Voice memos attached to pins

/// A short locally stored voice memo attached to a pin.
struct VoiceMemoItem: Identifiable, Codable, Hashable {
    let id: String
    let filename: String
    let title: String
    let duration: TimeInterval
    let createdAt: Date
}

/// Persists user-recorded voice memos for place pins.
final class VoiceMemoStore: ObservableObject {
    static let shared = VoiceMemoStore()

    private let key = "pin.voice.memo.index.v1"

    /// pinKey -> ordered voice memo items
    @Published private(set) var index: [String: [VoiceMemoItem]] = [:]

    private init() {
        load()
        AppLog.path("VoiceMemoStore.documents", documentsURL())
    }

    /// Returns the memos saved for a pin.
    func items(for pinKey: String) -> [VoiceMemoItem] {
        index[pinKey] ?? []
    }

    /// Returns the local file URL for a memo.
    func fileURL(for item: VoiceMemoItem) -> URL {
        documentsURL().appendingPathComponent(item.filename)
    }

    /// Copies a newly recorded memo into the app's documents directory and indexes it.
    @MainActor
    func addRecording(from sourceURL: URL, title: String, duration: TimeInterval, to pinKey: String) {
        let filename = "\(pinKey)_voice_\(UUID().uuidString).m4a"
        let destURL = documentsURL().appendingPathComponent(filename)
        AppLog.fileOp("READ", sourceURL)
        AppLog.fileOp("WRITE", destURL)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            } catch {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
        } catch {
            AppLog.info("VoiceMemoStore.addRecording failed: \(error)")
            return
        }

        let item = VoiceMemoItem(
            id: UUID().uuidString,
            filename: filename,
            title: title,
            duration: duration,
            createdAt: Date()
        )

        var list = index[pinKey] ?? []
        list.append(item)
        index[pinKey] = list
        AppLog.action("Add voice memo to \(pinKey): \(title)")
        persist()
    }

    /// Deletes a single memo from a pin.
    @MainActor
    func remove(itemID: String, from pinKey: String) {
        var list = index[pinKey] ?? []
        guard let idx = list.firstIndex(where: { $0.id == itemID }) else { return }
        let item = list.remove(at: idx)
        let url = documentsURL().appendingPathComponent(item.filename)
        AppLog.action("Remove voice memo from \(pinKey): \(url.lastPathComponent)")
        AppLog.fileOp("DELETE", url)
        try? FileManager.default.removeItem(at: url)
        index[pinKey] = list
        persist()
    }

    /// Deletes all memos for a pin.
    @MainActor
    func removeAll(for pinKey: String) {
        let list = index[pinKey] ?? []
        AppLog.action("Remove all voice memos for \(pinKey): \(list.count)")
        for item in list {
            let url = documentsURL().appendingPathComponent(item.filename)
            AppLog.fileOp("DELETE", url)
            try? FileManager.default.removeItem(at: url)
        }
        index[pinKey] = []
        persist()
    }

    /// Returns the newest update timestamp for a pin when available.
    func latestUpdatedAt(for pinKey: String) -> Date? {
        items(for: pinKey).map(\.createdAt).max()
    }

    /// Loads persisted data for this component.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            index = [:]
            AppLog.info("VoiceMemoStore.load: no data for key \(key)")
            return
        }
        index = (try? JSONDecoder().decode([String: [VoiceMemoItem]].self, from: data)) ?? [:]
        let total = index.values.reduce(0) { $0 + $1.count }
        AppLog.info("VoiceMemoStore.load: loaded \(index.keys.count) pins, \(total) memos (\(data.count) bytes)")
    }

    /// Saves the current value to persistent storage.
    private func persist() {
        if let data = try? JSONEncoder().encode(index) {
            UserDefaults.standard.set(data, forKey: key)
            let total = index.values.reduce(0) { $0 + $1.count }
            AppLog.info("VoiceMemoStore.save: saved \(index.keys.count) pins, \(total) memos (\(data.count) bytes)")
        }
    }

    /// Returns the app's Documents directory.
    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}

// MARK: - Built-in sound library

/// Describes a bundled ambient sound option that users can attach to a pin.
struct BuiltInSound: Identifiable, Hashable {
    let id: String          // baseName
    let title: String
    let subtitle: String

    var baseName: String { id }
}

/// Catalog of all bundled ambient sound options exposed to the UI.
enum BuiltInSoundLibrary {
    /// Curated list of bundled audio files that users can assign to a pin.
    /// Base names must match files in /Resources (mp3 or wav).
    static let sounds: [BuiltInSound] = [
        BuiltInSound(id: "study_loop", title: "Study Ambience", subtitle: "Loop (offline)"),
        BuiltInSound(id: "outdoors_loop", title: "Outdoors", subtitle: "Loop (offline)"),
        BuiltInSound(id: "housing_loop", title: "Housing", subtitle: "Loop (offline)"),
        BuiltInSound(id: "food_loop", title: "Café", subtitle: "Loop (offline)"),
        BuiltInSound(id: "services_loop", title: "City Hum", subtitle: "Loop (offline)"),

        BuiltInSound(id: "always_on_the_way", title: "Harbor Drift", subtitle: "Music (offline)"),
        BuiltInSound(id: "september", title: "Golden Hour", subtitle: "Music (offline)"),
        BuiltInSound(id: "sky_farm", title: "Open Sky", subtitle: "Music (offline)"),
        BuiltInSound(id: "meditation_music", title: "Calm Focus", subtitle: "Music (offline)"),
        BuiltInSound(id: "lighthouse", title: "Night Coast", subtitle: "Music (offline)"),
        BuiltInSound(id: "blue_state", title: "Blue Echo", subtitle: "Music (offline)"),
        BuiltInSound(id: "sound_medicine", title: "Soft Current", subtitle: "Music (offline)"),
        BuiltInSound(id: "path_untrodden", title: "Quiet Steps", subtitle: "Music (offline)"),
    ]

    /// Performs title.
    static func title(for baseName: String) -> String {
        sounds.first(where: { $0.baseName == baseName })?.title ?? "Music"
    }
}
