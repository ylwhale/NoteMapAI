import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// Placeholder detail view shown when no selection is active (useful for larger screens).
struct DefaultDetailView: View {
    let places: [Place]

    @State private var modalPlace: Place? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a place")
                .font(.title3).bold()
            Text("Choose an item from the list to see details, or use the map below to preview all locations.")
                .foregroundColor(.secondary)
                .font(.subheadline)

            if places.isEmpty {
                EmptyStateView(
                    title: "No places loaded",
                    systemImage: "exclamationmark.triangle",
                    message: "The bundled places.json couldn't be read. Make sure Resources/places.json exists in the project."
                )
            } else {
                PlacesOverviewMapView(places: places, modalPlace: $modalPlace)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle("Overview")
        .sheet(item: $modalPlace) { p in
            PlaceMusicModalView(place: p)
        }
    }
}

/// Detail view for a place that shows metadata, media, and playback controls.
struct PlaceDetailView: View {
    let place: Place
    let places: [Place]
    @Binding var favorites: Set<String>

    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    @State private var startID: String = ""
    @State private var modalPlace: Place? = nil
    @State private var selectedCategory: PlaceCategory
    @State private var showingCategoryPicker: Bool = false

    init(place: Place, places: [Place], favorites: Binding<Set<String>>) {
        self.place = place
        self.places = places
        self._favorites = favorites
        self._selectedCategory = State(initialValue: place.effectiveCategory)
    }

    private var startPlace: Place? {
        places.first(where: { $0.id == startID }) ?? places.first
    }

    private var distanceMeters: Double? {
        guard let startPlace else { return nil }
        return Geo.haversineMeters(lat1: startPlace.latitude, lon1: startPlace.longitude, lat2: place.latitude, lon2: place.longitude)
    }

    private var isFavorite: Bool { favorites.contains(place.id) }

    private var pinKey: String { "place_" + place.id }

    private var displayTitle: String {
        placeMemoryStore.displayTitle(for: pinKey, fallback: place.name)
    }

    // Synchronizes selected category from store for this feature.
    /// Synchronizes selected category from store.
    private func syncSelectedCategoryFromStore() {
        let resolvedCategory = PlaceCategoryOverrideStore.category(for: place)
        if selectedCategory != resolvedCategory {
            selectedCategory = resolvedCategory
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayTitle)
                            .font(.title2).bold()
                        Text(place.subtitle)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        toggleFavorite(place.id)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isFavorite ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }

                // Add an offline map preview with a pin...
                PlaceMapView(place: place, modalPlace: $modalPlace)

                PlaceMemorySection(pinKey: pinKey, fallbackTitle: place.name)

                VoiceMemoSection(pinKey: pinKey)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Category")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        AppLog.action("Open place category picker: \(place.id)")
                        showingCategoryPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedCategory.systemImageName)
                                .foregroundStyle(.secondary)
                            Text(selectedCategory.displayName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Choose Category",
                        isPresented: $showingCategoryPicker,
                        titleVisibility: .visible
                    ) {
                        ForEach(PlaceCategory.allCases) { category in
                            Button(category == selectedCategory ? "✓ \(category.displayName)" : category.displayName) {
                                selectedCategory = category
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Choose a category for this place.")
                    }
                    .accessibilityLabel("Category")
                    .accessibilityValue(selectedCategory.displayName)
                    .accessibilityHint("Choose a category for this place.")
                    .accessibilityAddTraits(.isButton)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                InfoCard(title: "Hours", value: place.hours)
                InfoCard(title: "Address", value: place.address)
                if !place.notes.isEmpty {
                    InfoCard(title: "Notes", value: place.notes)
                }

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Offline directions")
                        .font(.headline)

                    Text("Pick a starting point and get quick walking directions. This demo stays offline—no network needed.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Start", selection: $startID) {
                        ForEach(places.sorted(by: { $0.name < $1.name })) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if let startPlace, startPlace.id != place.id, let meters = distanceMeters {
                        DirectionsCard(start: startPlace, end: place, meters: meters)
                    } else if let startPlace, startPlace.id == place.id {
                        EmptyStateView(
                            title: "You're already here",
                            systemImage: "figure.walk",
                            message: "Choose a different starting point."
                        )
                            .padding(.top, 6)
                    } else {
                        EmptyStateView(
                            title: "Pick a start",
                            systemImage: "location.circle",
                            message: "Select a starting point to see directions."
                        )
                            .padding(.top, 6)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCategory) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PlaceCategoryOverrideStore.set(newValue, for: place)
        }
        .sheet(item: $modalPlace) { p in
            PlaceMusicModalView(place: p)
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaceCategoryOverrideStore.didChangeNotification)) { notification in
            guard let payload = PlaceCategoryOverrideStore.changePayload(from: notification),
                  payload.placeID == place.id else { return }
            if selectedCategory != payload.category {
                selectedCategory = payload.category
            }
        }
        .onAppear {
            syncSelectedCategoryFromStore()
            if startID.isEmpty {
                startID = places.first?.id ?? ""
            }
        }
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite(_ id: String) {
        let willFavorite = !favorites.contains(id)
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): \(id)")
        if willFavorite {
            favorites.insert(id)
        } else {
            favorites.remove(id)
        }
    }
}

/// Reusable card presenting a directions action for a place.
struct DirectionsCard: View {
    let start: Place
    let end: Place
    let meters: Double

    var body: some View {
        let minutes = Geo.walkingMinutes(for: meters)
        let dir = Geo.cardinalDirection(fromLat: start.latitude, fromLon: start.longitude, toLat: end.latitude, toLon: end.longitude)
        let prettyDistance = meters >= 1000 ? String(format: "%.2f km", meters / 1000.0) : String(format: "%.0f m", meters)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "figure.walk")
                Text("\(prettyDistance) · ~\(minutes) min")
                    .font(.subheadline).bold()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1) Leave **\(start.name)** and head **\(dir)**.")
                Text("2) Keep going until you reach **\(end.name)**.")
                Text("3) Look for: \(end.subtitle).")
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Badge(text: start.effectiveCategory.displayName)
                Badge(text: end.effectiveCategory.displayName)
                Spacer()
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Reusable container card used throughout the UI for grouped content.
struct InfoCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.body)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Small badge view used to highlight short bits of metadata.
struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }
}

/// Pill-shaped chip used for compact actions or status indicators.
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Use Color.* instead of ShapeStyle.* to avoid older compiler issues.
                .background(isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// About screen describing the app and the required project information.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("MindMap AI")
                    .font(.title2).bold()

                Text("A tiny offline demo: search places, favorite them, preview locations on a map, and generate quick walking directions. No network required.")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try this flow")
                        .font(.headline)
                    Text("1) Use Search to find a place (try “coffee” or “library”).")
                    Text("2) Tap the ⭐ to favorite it.")
                    Text("3) Switch the top picker to Favorites.")
                    Text("4) Open a place and choose a Start to see directions.")
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Why it fits the assignment")
                        .font(.headline)
                    Text("• Interactive and understandable in under 3 minutes.")
                    Text("• Works offline: all data is bundled locally.")
                    Text("• Shows core iOS UI patterns: Navigation, Search, Filters, Persistence.")
                }
                .font(.subheadline)
            }
            .padding(16)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - User-added photos per pin

/// Reusable section used in pin modal cards to let the user attach photos
/// from their photo library, and display the saved images.
struct PinPhotoSection: View {
    let title: String
    let pinKey: String

    @EnvironmentObject private var photoStore: PinPhotoStore
    @State private var pickedItems: [PhotosPickerItem] = []

    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var showNoCameraAlert = false

    private var files: [String] {
        photoStore.filenames(for: pinKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()

if #available(iOS 16.0, *) {
                    HStack(spacing: 12) {
                        PhotosPicker(
                            selection: $pickedItems,
                            maxSelectionCount: 10,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label("Add", systemImage: "photo.on.rectangle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                isShowingCamera = true
                            } else {
                                showNoCameraAlert = true
                            }
                        } label: {
                            Label("Take a photo", systemImage: "camera")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("Requires iOS 16+")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if files.isEmpty {
                Text("No photos yet. Tap Add to choose from your library.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(files, id: \.self) { filename in
                            if let img = photoStore.image(for: filename) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 90)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    Button(role: .destructive) {
                                        photoStore.removeImage(filename: filename, from: pinKey)
                                    } label: {
                                        Image(systemName: "trash.circle.fill")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .red)
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Delete photo")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $isShowingCamera, onDismiss: {
            guard let img = capturedImage, let data = img.jpegData(compressionQuality: 0.85) else { return }
            photoStore.addImageData(data, to: pinKey)
            capturedImage = nil
        }) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .alert("Camera Not Available", isPresented: $showNoCameraAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This device doesn't have a camera, or camera access is restricted.")
        }
        .onChange(of: pickedItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            photoStore.addImageData(data, to: pinKey)
                        }
                    }
                }
                await MainActor.run {
                    pickedItems = []
                }
            }
        }
    }
}

// MARK: - User-added media per place pin (photos + videos)

@available(iOS 16.0, *)
/// Value type that tracks a selected or recorded video and its local file URL.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            // Copy into a stable temp URL we own.
            AppLog.action("Import video")
            AppLog.fileOp("READ", received.file)
            AppLog.fileOp("WRITE", temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return PickedVideo(url: temp)
        }
    }
}


/// UI section for saving a personal title and note for a pin.
struct PlaceMemorySection: View {
    let pinKey: String
    let fallbackTitle: String

    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    @State private var customTitle: String = ""
    @State private var note: String = ""
    @State private var didLoadInitialValues = false

    private var trimmedTitle: String {
        customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSavedContent: Bool {
        placeMemoryStore.hasContent(for: pinKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory")
                        .font(.headline)
                    Text("Give this place a personal title or note that stays on this device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if hasSavedContent {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom title")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField(fallbackTitle, text: $customTitle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom title")

                Text("Memory note")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))

                    if note.isEmpty {
                        Text("Add a short note, story, or reminder for this place.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                    }

                    TextEditor(text: $note)
                        .padding(10)
                        .frame(minHeight: 108)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .accessibilityLabel("Memory note")
                }
                .frame(minHeight: 108)
            }

            HStack(spacing: 10) {
                Button {
                    placeMemoryStore.save(pinKey: pinKey, customTitle: trimmedTitle, note: trimmedNote)
                } label: {
                    Label("Save Memory", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    customTitle = ""
                    note = ""
                    placeMemoryStore.clear(for: pinKey)
                } label: {
                    Label("Clear", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            guard !didLoadInitialValues else { return }
            didLoadInitialValues = true
            let record = placeMemoryStore.record(for: pinKey)
            customTitle = record?.customTitle ?? ""
            note = record?.note ?? ""
        }
        .onReceive(placeMemoryStore.$records) { records in
            let record = records[pinKey]
            let newTitle = record?.customTitle ?? ""
            let newNote = record?.note ?? ""
            if newTitle != customTitle { customTitle = newTitle }
            if newNote != note { note = newNote }
        }
    }
}

/// UI section for recording and replaying local voice notes attached to a pin.
struct VoiceMemoSection: View {
    let pinKey: String

    @EnvironmentObject private var voiceMemoStore: VoiceMemoStore
    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore
    @ObservedObject private var audio = AudioManager.shared

    @State private var recorder: AVAudioRecorder? = nil
    @State private var currentRecordingURL: URL? = nil
    @State private var recordingStartedAt: Date? = nil
    @State private var showMicPermissionAlert = false
    @State private var showRecordingErrorAlert = false
    @State private var recordingErrorMessage = ""

    private var items: [VoiceMemoItem] {
        voiceMemoStore.items(for: pinKey)
    }

    private var isRecording: Bool { recorder?.isRecording == true }

    private var favoriteTargetID: String? {
        guard pinKey.hasPrefix("place_") else { return nil }
        return String(pinKey.dropFirst("place_".count))
    }

    private var resolvedPlaceName: String {
        guard let placeID = favoriteTargetID else {
            return placeMemoryStore.displayTitle(for: pinKey, fallback: "Saved Place")
        }
        let allPlaces = PlaceStore.load() + UserPlaceStore.load()
        let fallback = allPlaces.first(where: { $0.id == placeID })?.name ?? "Saved Place"
        return placeMemoryStore.displayTitle(for: pinKey, fallback: fallback)
    }

    private var activeSelectedID: String? {
        guard audio.currentLocalPlaybackKind == "voiceNote",
              let urlString = audio.currentLocalFileURLString else { return nil }
        return items.first(where: { voiceMemoStore.fileURL(for: $0).absoluteString == urlString })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice Notes")
                        .font(.headline)
                    Text("Record short voice memories for this place. Notes stay on this device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Button {
                if isRecording {
                    finishRecording()
                } else {
                    beginRecordingFlow()
                }
            } label: {
                HStack {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                    Text(isRecording ? "Stop Recording" : "Record Voice Note")
                        .font(.headline)
                    Spacer()
                }
                .padding(12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if items.isEmpty {
                Text("No voice notes yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(items.sorted(by: { $0.createdAt > $1.createdAt })) { item in
                        HStack(spacing: 10) {
                            Image(systemName: activeSelectedID == item.id ? "speaker.wave.2.fill" : "waveform")
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(.accent)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(item.duration))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Button {
                                togglePlayback(for: item)
                            } label: {
                                Image(systemName: activeSelectedID == item.id && audio.isPlaying ? "pause.fill" : "play.fill")
                                    .imageScale(.large)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(activeSelectedID == item.id && audio.isPlaying ? "Pause voice note" : "Play voice note")

                            Button(role: .destructive) {
                                if activeSelectedID == item.id {
                                    stopPlayback()
                                }
                                voiceMemoStore.remove(itemID: item.id, from: pinKey)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete voice note")
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("Microphone Access Needed", isPresented: $showMicPermissionAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Allow microphone access so you can record voice notes for saved places.")
        }
        .alert("Voice Note Error", isPresented: $showRecordingErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(recordingErrorMessage)
        }
        .onDisappear {
            if isRecording {
                finishRecording()
            }
        }
    }

    private func beginRecordingFlow() {
        requestMicrophonePermission { granted in
            guard granted else {
                showMicPermissionAlert = true
                return
            }
            startRecording()
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    private func startRecording() {
        stopPlayback()
        AudioManager.shared.stop()

        let session = AVAudioSession.sharedInstance()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice_note_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            newRecorder.prepareToRecord()
            guard newRecorder.record() else {
                throw NSError(domain: "MindMapAIVoiceMemo", code: -2, userInfo: [NSLocalizedDescriptionKey: "The recorder could not start."])
            }
            recorder = newRecorder
            currentRecordingURL = tempURL
            recordingStartedAt = Date()
            AppLog.action("Start voice memo recording: \(pinKey)")
            AppLog.fileOp("WRITE", tempURL)
        } catch {
            recordingErrorMessage = error.localizedDescription
            showRecordingErrorAlert = true
        }
    }

    private func finishRecording() {
        guard let recorder, let tempURL = currentRecordingURL else { return }
        recorder.stop()
        self.recorder = nil

        let duration = max(1, recordingStartedAt.map { Date().timeIntervalSince($0) } ?? recorder.currentTime)
        let title = voiceMemoTitle(for: items.count + 1)
        voiceMemoStore.addRecording(from: tempURL, title: title, duration: duration, to: pinKey)

        recordingStartedAt = nil
        currentRecordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        AppLog.action("Stop voice memo recording: \(pinKey)")
    }

    private func togglePlayback(for item: VoiceMemoItem) {
        let url = voiceMemoStore.fileURL(for: item)
        if activeSelectedID == item.id {
            if audio.isPlaying {
                audio.pause()
            } else {
                audio.resume()
            }
            return
        }

        AppLog.action("Play voice memo in shared player: \(item.id)")
        AppLog.fileOp("READ", url)
        audio.playLocalFile(
            fileURL: url,
            trackTitle: item.title,
            placeName: resolvedPlaceName,
            favoriteTargetID: favoriteTargetID,
            playbackKind: "voiceNote",
            shouldLoop: nil
        )
    }

    private func stopPlayback() {
        guard activeSelectedID != nil else { return }
        audio.stop()
    }

    private func voiceMemoTitle(for index: Int) -> String {
        "Voice Note \(index)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// UI section for adding, viewing, and deleting photo/video media attachments on a place pin.
struct PinMediaSection: View {
    let title: String
    let pinKey: String

    @EnvironmentObject private var mediaStore: PinMediaStore

    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    @State private var pickedVideoItems: [PhotosPickerItem] = []

    @State private var showAddMediaDialog = false
    @State private var showTakeNewDialog = false
    @State private var showPhotoLibraryPicker = false
    @State private var showVideoLibraryPicker = false

    @State private var isShowingPhotoCamera = false
    @State private var capturedImage: UIImage? = nil

    @State private var isShowingVideoCamera = false
    @State private var capturedVideoURL: URL? = nil

    @State private var showNoCameraAlert = false

    @State private var activeVideoItem: PinMediaItem? = nil
    @State private var activeVideoPlayer: AVPlayer? = nil

    private var items: [PinMediaItem] {
        mediaStore.items(for: pinKey)
    }

    /// Performs stop video.
    private func stopVideo() {
        activeVideoPlayer?.pause()
        activeVideoPlayer = nil
        activeVideoItem = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            mediaGallery
            activeVideoSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $isShowingPhotoCamera, onDismiss: handleCapturedPhoto) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingVideoCamera, onDismiss: handleCapturedVideo) {
            VideoCapturePicker(videoURL: $capturedVideoURL)
                .ignoresSafeArea()
        }
        .alert("Camera Not Available", isPresented: $showNoCameraAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This device doesn't have a camera, or camera access is restricted.")
        }
        .onChange(of: pickedPhotoItems) { _, newItems in
            handlePickedPhotos(newItems)
        }
        .onChange(of: pickedVideoItems) { _, newItems in
            handlePickedVideos(newItems)
        }
        .onChange(of: activeVideoItem?.id) { _, _ in
            rebuildActiveVideoPlayer()
        }
        .onDisappear {
            activeVideoPlayer?.pause()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()

            if #available(iOS 16.0, *) {
                HStack(spacing: 12) {
                    addMediaButton
                    takeNewButton
                }
            } else {
                Text("Requires iOS 16+")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var addMediaButton: some View {
        Button {
            showAddMediaDialog = true
        } label: {
            Label("Add media", systemImage: "photo.on.rectangle")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Add media", isPresented: $showAddMediaDialog, titleVisibility: .visible) {
            Button("Choose photo") { showPhotoLibraryPicker = true }
            Button("Choose video") { showVideoLibraryPicker = true }
            Button("Cancel", role: .cancel) { }
        }
        .photosPicker(
            isPresented: $showPhotoLibraryPicker,
            selection: $pickedPhotoItems,
            maxSelectionCount: 10,
            matching: .images,
            photoLibrary: .shared()
        )
        .photosPicker(
            isPresented: $showVideoLibraryPicker,
            selection: $pickedVideoItems,
            maxSelectionCount: 3,
            matching: .videos,
            photoLibrary: .shared()
        )
    }

    private var takeNewButton: some View {
        Button {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showTakeNewDialog = true
            } else {
                showNoCameraAlert = true
            }
        } label: {
            Label("Take new", systemImage: "camera")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .confirmationDialog("Take new", isPresented: $showTakeNewDialog, titleVisibility: .visible) {
            Button("Take photo") { isShowingPhotoCamera = true }
            Button("Record video") { isShowingVideoCamera = true }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var mediaGallery: some View {
        if items.isEmpty {
            Text("No media yet. Add a photo or video.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        mediaThumbnail(for: item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func mediaThumbnail(for item: PinMediaItem) -> some View {
        let isVideo = item.kind == .video

        ZStack(alignment: .topTrailing) {
            if isVideo {
                Button {
                    activeVideoItem = item
                } label: {
                    thumbnailArtwork(for: item, isVideo: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play video")
                .accessibilityHint("Opens video player")
            } else {
                thumbnailArtwork(for: item, isVideo: false)
                    .accessibilityLabel("Photo attachment")
            }

            Button(role: .destructive) {
                if activeVideoItem?.id == item.id {
                    stopVideo()
                }
                mediaStore.remove(itemID: item.id, from: pinKey)
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVideo ? "Delete video" : "Delete photo")
        }
    }

    @ViewBuilder
    private func thumbnailArtwork(for item: PinMediaItem, isVideo: Bool) -> some View {
        ZStack {
            if let thumb = mediaStore.thumbnail(for: item) {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: isVideo ? "video" : "photo")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    )
            }

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.25))
            }
        }
        .frame(width: 120, height: 90)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var activeVideoSection: some View {
        if let item = activeVideoItem,
           let url = mediaStore.videoURL(for: item) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "video")
                    Text("Video")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        stopVideo()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close video")
                }

                Group {
                    if let player = activeVideoPlayer {
                        CrispInlineVideoPlayer(player: player)
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onAppear {
                    if activeVideoPlayer == nil {
                        let player = AVPlayer(url: url)
                        activeVideoPlayer = player
                        player.play()
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func handleCapturedPhoto() {
        guard let image = capturedImage,
              let data = image.jpegData(compressionQuality: 0.85) else { return }
        mediaStore.addPhotoData(data, to: pinKey)
        capturedImage = nil
    }

    private func handleCapturedVideo() {
        guard let url = capturedVideoURL else { return }
        mediaStore.addVideoFile(at: url, to: pinKey)
        capturedVideoURL = nil
    }

    private func handlePickedPhotos(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else { return }
        Task {
            for item in newItems {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        mediaStore.addPhotoData(data, to: pinKey)
                    }
                }
            }
            await MainActor.run {
                pickedPhotoItems = []
            }
        }
    }

    private func handlePickedVideos(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else { return }
        Task {
            for item in newItems {
                if #available(iOS 16.0, *),
                   let picked = try? await item.loadTransferable(type: PickedVideo.self) {
                    await MainActor.run {
                        mediaStore.addVideoFile(at: picked.url, to: pinKey)
                    }
                }
            }
            await MainActor.run {
                pickedVideoItems = []
            }
        }
    }

    private func rebuildActiveVideoPlayer() {
        guard let item = activeVideoItem,
              let url = mediaStore.videoURL(for: item) else {
            activeVideoPlayer?.pause()
            activeVideoPlayer = nil
            return
        }

        activeVideoPlayer?.pause()
        let player = AVPlayer(url: url)
        activeVideoPlayer = player
        player.play()
    }
}

/// UIKit camera capture wrapper used by `PinPhotoSection`.
///
/// We use `UIImagePickerController` for broad compatibility.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    /// Bridges camera photo capture results from UIKit back into the SwiftUI picker.
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        /// Performs image picker controller.
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let ui = info[.originalImage] as? UIImage {
                parent.image = ui
            }
            picker.dismiss(animated: true)
        }

        /// Performs image picker controller did cancel.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }

    /// Creates the coordinator object used to bridge UIKit delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates and returns the UIKit view controller used by this representable.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    /// Updates the wrapped view controller when SwiftUI state changes.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }
}

/// UIKit video capture wrapper used by `PinMediaSection`.
struct VideoCapturePicker: UIViewControllerRepresentable {
    @Binding var videoURL: URL?

    /// Creates and returns the UIKit view controller used by this representable.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    /// Updates the wrapped view controller when SwiftUI state changes.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Creates the coordinator object used to bridge UIKit delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Bridges captured video URLs from UIKit back into the SwiftUI picker.
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: VideoCapturePicker
        init(_ parent: VideoCapturePicker) { self.parent = parent }

        /// Performs image picker controller.
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.videoURL = url
            }
            picker.dismiss(animated: true)
        }

        /// Performs image picker controller did cancel.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
