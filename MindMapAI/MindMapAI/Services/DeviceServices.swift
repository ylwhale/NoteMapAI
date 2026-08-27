import Combine
import CoreLocation
import Foundation
import Network
import Security

// MARK: - Location

/// Small abstraction around `CLLocationManager` so location behavior can be
/// exercised with a deterministic test double.
@MainActor
protocol MindMapLocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }

    func requestWhenInUseAuthorization()
    func requestLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: MindMapLocationManaging {}

/// Injectable reverse-geocoding boundary used by `MindMapLocationService`.
@MainActor
protocol MindMapReverseGeocoding: AnyObject {
    func placemarks(for location: CLLocation) async throws -> [CLPlacemark]
}

@MainActor
final class SystemMindMapReverseGeocoder: MindMapReverseGeocoding {
    private let geocoder = CLGeocoder()

    func placemarks(for location: CLLocation) async throws -> [CLPlacemark] {
        try await geocoder.reverseGeocodeLocation(location)
    }
}

enum MindMapLocationFailure: Equatable, LocalizedError {
    case permissionDenied
    case permissionRestricted
    case unavailable
    case timedOut
    case invalidLocation
    case reverseGeocodingUnavailable
    case system(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location access is off. You can still save this note without a place."
        case .permissionRestricted:
            return "Location access is restricted. You can still save this note without a place."
        case .unavailable:
            return "Your current location is unavailable. You can still save this note."
        case .timedOut:
            return "Location took too long. The note can still be saved without it."
        case .invalidLocation:
            return "The device returned an invalid location. The note can still be saved."
        case .reverseGeocodingUnavailable:
            return "The coordinates were saved, but a place name could not be found."
        case .system(let message):
            return message.isEmpty
                ? "Location is temporarily unavailable. You can still save this note."
                : message
        }
    }
}

/// Permission-aware, one-shot location capture for note creation.
///
/// Every capture path resolves to either a `SavedPlace` or `nil`; permission,
/// timeout, and geocoder failures are intentionally non-blocking for note saves.
@MainActor
final class MindMapLocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestPlace: SavedPlace?
    @Published private(set) var isLocating = false
    @Published private(set) var lastFailure: MindMapLocationFailure?

    var lastErrorMessage: String? { lastFailure?.localizedDescription }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var canRequestPermission: Bool { authorizationStatus == .notDetermined }

    private let locationManager: MindMapLocationManaging
    private let reverseGeocoder: MindMapReverseGeocoding
    private let maximumLocationAge: TimeInterval
    private var pendingRequests: [UUID: CheckedContinuation<SavedPlace?, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var activeCaptureID: UUID?

    init(
        locationManager: MindMapLocationManaging? = nil,
        reverseGeocoder: MindMapReverseGeocoding? = nil,
        maximumLocationAge: TimeInterval = 5 * 60
    ) {
        let resolvedLocationManager = locationManager ?? CLLocationManager()
        self.locationManager = resolvedLocationManager
        self.reverseGeocoder = reverseGeocoder ?? SystemMindMapReverseGeocoder()
        self.maximumLocationAge = max(0, maximumLocationAge)
        self.authorizationStatus = resolvedLocationManager.authorizationStatus
        super.init()

        resolvedLocationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        resolvedLocationManager.delegate = self
    }

    /// Requests permission without starting a location request. Calling this for
    /// an already-resolved permission state is harmless.
    func requestPermission() {
        authorizationStatus = locationManager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            lastFailure = nil
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            lastFailure = .permissionDenied
        case .restricted:
            lastFailure = .permissionRestricted
        case .authorizedAlways, .authorizedWhenInUse:
            lastFailure = nil
        @unknown default:
            lastFailure = .unavailable
        }
    }

    /// Obtains and reverse-geocodes a fresh location. The method always finishes:
    /// it returns `nil` on denial, cancellation, device failure, or timeout.
    func captureCurrentPlace(timeout: TimeInterval = 8) async -> SavedPlace? {
        let requestID = UUID()
        let boundedTimeout = max(0.25, timeout)

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pendingRequests[requestID] = continuation
                scheduleTimeout(for: requestID, seconds: boundedTimeout)

                guard !isLocating else { return }
                isLocating = true
                activeCaptureID = UUID()
                lastFailure = nil
                beginLocationFlow()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.completeRequest(requestID, with: nil)
            }
        })
    }

    /// Fire-and-forget convenience for screens that observe `latestPlace`.
    func refreshCurrentPlace(timeout: TimeInterval = 8) {
        Task { @MainActor [weak self] in
            _ = await self?.captureCurrentPlace(timeout: timeout)
        }
    }

    func clearCapturedPlace() {
        latestPlace = nil
        lastFailure = nil
    }

    func clearFailure() {
        lastFailure = nil
    }

    private func beginLocationFlow() {
        authorizationStatus = locationManager.authorizationStatus
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            completeAllRequests(with: nil, failure: .permissionDenied)
        case .restricted:
            completeAllRequests(with: nil, failure: .permissionRestricted)
        @unknown default:
            completeAllRequests(with: nil, failure: .unavailable)
        }
    }

    private func scheduleTimeout(for requestID: UUID, seconds: TimeInterval) {
        let nanoseconds = UInt64(min(seconds, 60) * 1_000_000_000)
        timeoutTasks[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.timeOutRequest(requestID)
        }
    }

    private func timeOutRequest(_ requestID: UUID) {
        guard pendingRequests[requestID] != nil else { return }
        lastFailure = .timedOut
        completeRequest(requestID, with: nil)
    }

    private func completeRequest(_ requestID: UUID, with place: SavedPlace?) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: place)

        if pendingRequests.isEmpty {
            isLocating = false
            activeCaptureID = nil
            locationManager.stopUpdatingLocation()
        }
    }

    private func completeAllRequests(
        with place: SavedPlace?,
        failure: MindMapLocationFailure? = nil
    ) {
        if let place {
            latestPlace = place
        }
        lastFailure = failure
        isLocating = false
        activeCaptureID = nil

        let continuations = Array(pendingRequests.values)
        pendingRequests.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        continuations.forEach { $0.resume(returning: place) }
    }

    private func handleAuthorizationChange(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard isLocating, !pendingRequests.isEmpty else { return }

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied:
            completeAllRequests(with: nil, failure: .permissionDenied)
        case .restricted:
            completeAllRequests(with: nil, failure: .permissionRestricted)
        case .notDetermined:
            break
        @unknown default:
            completeAllRequests(with: nil, failure: .unavailable)
        }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        guard isLocating, !pendingRequests.isEmpty else { return }

        let now = Date()
        let location = locations
            .filter { Self.isValid($0, now: now, maximumAge: maximumLocationAge) }
            .max(by: { $0.timestamp < $1.timestamp })

        guard let location else {
            completeAllRequests(with: nil, failure: .invalidLocation)
            return
        }

        guard let captureID = activeCaptureID else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let placemark = try await reverseGeocoder.placemarks(for: location).first
                guard activeCaptureID == captureID, isLocating else { return }
                let place = Self.makeSavedPlace(location: location, placemark: placemark)
                completeAllRequests(with: place)
            } catch {
                guard activeCaptureID == captureID, isLocating else { return }
                // Coordinates remain useful and editable even if the network-backed
                // place-name lookup is unavailable.
                let place = Self.makeSavedPlace(location: location, placemark: nil)
                completeAllRequests(with: place, failure: .reverseGeocodingUnavailable)
            }
        }
    }

    private func handleLocationFailure(_ error: Error) {
        let failure: MindMapLocationFailure
        if let locationError = error as? CLError {
            switch locationError.code {
            case .denied:
                failure = authorizationStatus == .restricted ? .permissionRestricted : .permissionDenied
            case .locationUnknown:
                failure = .unavailable
            default:
                failure = .system("Location is temporarily unavailable. You can still save this note.")
            }
        } else {
            failure = .system("Location is temporarily unavailable. You can still save this note.")
        }
        completeAllRequests(with: nil, failure: failure)
    }

    nonisolated private static func isValid(
        _ location: CLLocation,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude),
              location.horizontalAccuracy >= 0 else {
            return false
        }

        // A small future skew is tolerated for devices whose clocks just changed.
        let age = now.timeIntervalSince(location.timestamp)
        return age >= -30 && age <= maximumAge
    }

    nonisolated static func makeSavedPlace(
        location: CLLocation,
        placemark: CLPlacemark?
    ) -> SavedPlace {
        let coordinate = location.coordinate
        let nameCandidates = [
            placemark?.areasOfInterest?.first,
            placemark?.name,
            placemark?.subLocality,
            placemark?.locality,
            placemark?.administrativeArea,
            placemark?.country
        ]
        let name = nameCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Current location"

        let street = [placemark?.subThoroughfare, placemark?.thoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let rawDetailParts = [
            street,
            placemark?.locality ?? "",
            placemark?.administrativeArea ?? "",
            placemark?.postalCode ?? "",
            placemark?.country ?? ""
        ]

        var detailParts: [String] = []
        for rawPart in rawDetailParts {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty,
                  part.caseInsensitiveCompare(name) != .orderedSame,
                  !detailParts.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else {
                continue
            }
            detailParts.append(part)
        }

        return SavedPlace(
            name: name,
            detail: detailParts.isEmpty ? "Place name unavailable" : detailParts.joined(separator: ", "),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

extension MindMapLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(manager)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            self?.handleLocations(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleLocationFailure(error)
        }
    }
}

// MARK: - Connectivity

enum ConnectivityStatus: String, Sendable {
    case connected
    case requiresConnection
    case offline
}

enum ConnectivityInterface: String, Sendable {
    case wifi = "Wi-Fi"
    case cellular = "Cellular"
    case wiredEthernet = "Ethernet"
    case loopback = "Loopback"
    case other = "Other"
    case unavailable = "Unavailable"
}

struct ConnectivitySnapshot: Equatable, Sendable {
    var status: ConnectivityStatus
    var interface: ConnectivityInterface
    var isExpensive: Bool
    var isConstrained: Bool

    static let offline = ConnectivitySnapshot(
        status: .offline,
        interface: .unavailable,
        isExpensive: false,
        isConstrained: false
    )

    var isConnected: Bool { status == .connected }
}

/// Testable path-monitoring boundary. Production uses `NWPathMonitor`; tests can
/// emit `ConnectivitySnapshot` values directly.
protocol ConnectivityPathMonitoring: AnyObject {
    var updateHandler: ((ConnectivitySnapshot) -> Void)? { get set }
    func start(on queue: DispatchQueue)
    func cancel()
}

final class SystemConnectivityPathMonitor: ConnectivityPathMonitoring {
    var updateHandler: ((ConnectivitySnapshot) -> Void)?

    private let monitor: NWPathMonitor

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start(on queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateHandler?(Self.snapshot(from: path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private static func snapshot(from path: NWPath) -> ConnectivitySnapshot {
        let status: ConnectivityStatus
        switch path.status {
        case .satisfied:
            status = .connected
        case .requiresConnection:
            status = .requiresConnection
        case .unsatisfied:
            status = .offline
        @unknown default:
            status = .offline
        }

        let interface: ConnectivityInterface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            interface = .loopback
        } else if path.usesInterfaceType(.other) {
            interface = .other
        } else {
            interface = .unavailable
        }

        return ConnectivitySnapshot(
            status: status,
            interface: interface,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

@MainActor
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var snapshot: ConnectivitySnapshot = .offline
    @Published private(set) var isConnected = false

    var status: ConnectivityStatus { snapshot.status }
    var interface: ConnectivityInterface { snapshot.interface }
    var isExpensive: Bool { snapshot.isExpensive }
    var isConstrained: Bool { snapshot.isConstrained }

    private let pathMonitor: ConnectivityPathMonitoring
    private let queue: DispatchQueue
    private var isStarted = false
    private var isCancelled = false

    init(
        pathMonitor: ConnectivityPathMonitoring? = nil,
        queue: DispatchQueue = DispatchQueue(label: "mindmapai.connectivity")
    ) {
        self.pathMonitor = pathMonitor ?? SystemConnectivityPathMonitor()
        self.queue = queue
        start()
    }

    func start() {
        guard !isStarted, !isCancelled else { return }
        isStarted = true
        pathMonitor.updateHandler = { [weak self] newSnapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = newSnapshot
                self.isConnected = newSnapshot.isConnected
            }
        }
        pathMonitor.start(on: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        isCancelled = true
        pathMonitor.updateHandler = nil
        pathMonitor.cancel()
    }
}

// MARK: - API key storage

enum APIKeyStoreError: Equatable, LocalizedError {
    case keychain(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "The API key could not be accessed securely: \(message)"
            }
            return "The API key could not be accessed securely (\(status))."
        case .invalidStoredValue:
            return "The securely stored API key is invalid."
        }
    }
}

/// Semantic Keychain boundary that keeps Security framework details out of
/// `APIKeyStore` and makes credential behavior straightforward to unit test.
protocol KeychainDataStoring {
    func data(service: String, account: String) throws -> Data?
    func setData(_ data: Data, service: String, account: String) throws
    func removeData(service: String, account: String) throws
}

struct SystemKeychainDataStore: KeychainDataStoring {
    func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw APIKeyStoreError.invalidStoredValue }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.keychain(status)
        }
    }

    func setData(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw APIKeyStoreError.keychain(retryStatus) }
            return
        }

        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
    }

    func removeData(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

/// Stores the configured AI-provider secret only in the iOS Keychain.
final class APIKeyStore {
    let service: String
    let account: String

    private let keychain: KeychainDataStoring

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "MindMapAI") + ".credentials",
        account: String = "ai-provider-api-key",
        keychain: KeychainDataStoring = SystemKeychainDataStore()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    func loadAPIKey() throws -> String? {
        guard let data = try keychain.data(service: service, account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidStoredValue
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw APIKeyStoreError.invalidStoredValue
        }
        try keychain.setData(data, service: service, account: account)
    }

    func deleteAPIKey() throws {
        try keychain.removeData(service: service, account: account)
    }

    func hasAPIKey() throws -> Bool {
        try loadAPIKey() != nil
    }
}
