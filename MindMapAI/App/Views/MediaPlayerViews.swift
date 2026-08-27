import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Crisp inline video playback (avoids blurry system controls)

/// A UIView backed by `AVPlayerLayer`.
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

/// SwiftUI wrapper for `PlayerLayerView`.
private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    /// Creates and returns the UIKit view used by this representable.
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.player = player
        return v
    }

    /// Updates the wrapped UIKit view when SwiftUI state changes.
    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

/// View model that synchronizes AVPlayer time with custom playback controls.
private final class VideoPlaybackViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?

    /// Attaches observers to the provided player and begins publishing playback state.
    func attach(to player: AVPlayer) {
        detach()

        self.player = player
        refreshFromPlayer(player)
        bind(to: player.currentItem)

        timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.refreshFromPlayer(player)
            }
        }

        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.bind(to: player.currentItem)
                self?.refreshFromPlayer(player)
            }
        }

        // A slightly tighter interval keeps the scrubber in sync with playback.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                let cap = self.duration > 0 ? self.duration : seconds
                self.currentTime = max(0, min(seconds, cap))
            }

            if let item = player.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = d
                }
            }

            self.isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
        }
    }

    // Binds the requested action for this feature.
    /// Binds bind.
    private func bind(to item: AVPlayerItem?) {
        itemStatusObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        guard let item else {
            duration = 0
            currentTime = 0
            return
        }

        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = d
                }
                if item.status == .failed {
                    AppLog.info("Inline video item failed: \(item.error?.localizedDescription ?? "unknown error")")
                }
                if let player = self.player {
                    self.refreshFromPlayer(player)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.currentTime = self.duration
            self.isPlaying = false
            AppLog.info("Inline video reached end")
        }
    }

    // Refreshes from player for this feature.
    /// Refreshes from player.
    private func refreshFromPlayer(_ player: AVPlayer) {
        let now = player.currentTime().seconds
        if now.isFinite {
            let cap = duration > 0 ? duration : now
            currentTime = max(0, min(now, cap))
        }

        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 {
                duration = d
            }
        }

        isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
    }

    /// Stops observing the player and releases any observers or notifications.
    func detach() {
        if let player = player, let token = timeObserver {
            player.removeTimeObserver(token)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        timeControlObserver = nil
        currentItemObserver = nil
        itemStatusObserver = nil
        player = nil
    }

    /// Toggles between play and pause for the current media.
    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing || player.rate > 0 {
            AppLog.action("Pause inline video")
            player.pause()
            isPlaying = false
        } else {
            let isAtEnd = duration > 0 && currentTime >= max(duration - 0.05, 0)
            if isAtEnd {
                AppLog.action("Restart inline video from beginning")
                seek(to: 0)
            } else {
                AppLog.action("Play inline video")
            }
            player.play()
            isPlaying = true
        }
    }

    /// Seeks the player to a new time and keeps UI state in sync.
    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        AppLog.info("Inline video seek to \(String(format: "%.2f", clamped))s")
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self else { return }
            if finished {
                // Immediately reflect the seek target so the UI stays aligned
                // even before the next time observer tick.
                self.currentTime = clamped
                self.isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
            }
        }
    }
}

/// Formats a time interval in seconds as mm:ss for display.
private func _formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

/// Inline video view with crisp SwiftUI controls (no blurry system overlay).
struct CrispInlineVideoPlayer: View {
    let player: AVPlayer

    @StateObject private var vm = VideoPlaybackViewModel()

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var wasPlayingBeforeScrub = false
    @State private var pendingSeekWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerLayerRepresentable(player: player)

            VStack(spacing: 8) {
                // Progress
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : vm.currentTime },
                        set: { newValue in
                            scrubValue = newValue
                        }
                    ),
                    in: 0...(vm.duration > 0 ? vm.duration : 1),
                    onEditingChanged: { editing in
                        if editing {
                            // Start scrubbing: pause playback and keep UI driven by the slider.
                            wasPlayingBeforeScrub = vm.isPlaying
                            if wasPlayingBeforeScrub {
                                player.pause()
                                vm.isPlaying = false
                            }
                            scrubValue = vm.currentTime
                            isScrubbing = true
                        } else {
                            // Finish scrubbing: perform an exact seek, then resume if needed.
                            pendingSeekWorkItem?.cancel()
                            pendingSeekWorkItem = nil
                            let target = scrubValue
                            // Keep `isScrubbing` true until the seek target is reflected.
                            vm.seek(to: target)
                            DispatchQueue.main.async {
                                isScrubbing = false
                                if wasPlayingBeforeScrub {
                                    player.play()
                                    vm.isPlaying = true
                                }
                            }
                        }
                    }
                )
                .tint(.white)
                .disabled(vm.duration <= 0)
                .accessibilityLabel("Video position")
                .accessibilityValue("\(_formatTime(isScrubbing ? scrubValue : vm.currentTime)) of \(_formatTime(vm.duration))")
                .accessibilityHint("Shows and adjusts the current playback position")

                HStack(spacing: 12) {
                    Button {
                        vm.togglePlayPause()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel(vm.isPlaying ? "Pause video" : "Play video")
                    .accessibilityHint("Toggles video playback")

                    Text(_formatTime(isScrubbing ? scrubValue : vm.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.92))

                    Spacer()

                    if vm.duration > 0 {
                        Text(_formatTime(vm.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.72))
                    }
                }
            }
            .padding(10)
            // Use a simple translucent overlay (no blur) to keep controls crisp.
            .background(Color.black.opacity(0.35))
        }
        .onAppear { vm.attach(to: player) }
        .onDisappear {
            pendingSeekWorkItem?.cancel()
            pendingSeekWorkItem = nil
            vm.detach()
        }
        .onChange(of: scrubValue) { _, newValue in
            // While scrubbing, keep the displayed frame in sync with the scrubber.
            guard isScrubbing else { return }
            pendingSeekWorkItem?.cancel()
            let target = newValue
            let work = DispatchWorkItem { vm.seek(to: target) }
            pendingSeekWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
}


/// Bottom-sheet card for a place pin, including media, built-in sounds, and pin actions.
struct PlaceMusicModalView: View {
    let place: Place
    @Binding var favorites: Set<String>
    @Binding var detent: PresentationDetent

    /// Optional: when provided, shows a destructive "Delete pin" button.
    /// The caller should remove the pin from its backing array (e.g. places.removeAll { ... }).
    let onDelete: (() -> Void)?

    @ObservedObject private var audio = AudioManager.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recents: RecentManager
    @EnvironmentObject private var photoStore: PinPhotoStore
    @EnvironmentObject private var mediaStore: PinMediaStore
    @EnvironmentObject private var voiceMemoStore: VoiceMemoStore
    @EnvironmentObject private var placeMemoryStore: PlaceMemoryStore

    @State private var showDeleteConfirm = false
    // No explicit close button: the sheet is dismissed by pulling down or tapping outside.

    init(
        place: Place,
        favorites: Binding<Set<String>> = .constant([]),
        detent: Binding<PresentationDetent> = .constant(.height(360)),
        onDelete: (() -> Void)? = nil
    ) {
        self.place = place
        self._favorites = favorites
        self._detent = detent
        self.onDelete = onDelete
    }

    private var pinKey: String { "place_" + place.id }

    private var displayTitle: String {
        placeMemoryStore.displayTitle(for: pinKey, fallback: place.name)
    }

    private var customMemoryNote: String {
        placeMemoryStore.record(for: pinKey)?.note ?? ""
    }

    private var isFavorite: Bool { favorites.contains(place.id) }

    private let compactDetent: PresentationDetent = .height(360)
    private var isCompact: Bool { detent == compactDetent }

    private var hasMedia: Bool {
        !mediaStore.items(for: pinKey).isEmpty
    }

    private var headerTopPadding: CGFloat {
        // In the compact detent, content can get visually clipped under the grabber when the
        // view becomes taller (e.g. after the user adds photos). Padding never compresses
        // away like a spacer, so it keeps the header safely inside the card.
        if isCompact {
            return hasMedia ? 32 : 20
        }
        return 12
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite() {
        let willFavorite = !isFavorite
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): place_\(place.id)")
        if willFavorite {
            favorites.insert(place.id)
        } else {
            favorites.remove(place.id)
        }
    }

    /// Deletes an item from the relevant store and updates in-memory state.
    private func performDelete() {
        // Stop playback if this pin is playing.
        // Clean up user state tied to this pin.
        favorites.remove(place.id)
        recents.remove(kind: .place, itemID: place.id)
        placeMemoryStore.clear(for: pinKey)
        voiceMemoStore.removeAll(for: pinKey)
        // Remove both new (media) and legacy (photo-only) attachments.
        mediaStore.removeAll(for: pinKey)
        photoStore.removeAllPhotos(for: pinKey)
        DeletedPinsStore.markDeleted(pinKey)

        // Remove from the backing data source.
        onDelete?()

        // Close the sheet / navigation.
        dismiss()
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header row inside the card
                HStack(alignment: .top) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayTitle)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(place.subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(isFavorite ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }
                .padding(.top, headerTopPadding)
                .padding(.bottom, 6)

                Text("Save notes, photos, videos, and voice memories for this place. Everything stays on this device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !customMemoryNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(customMemoryNote)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }

                PlaceMemorySection(pinKey: pinKey, fallbackTitle: place.name)

                VoiceMemoSection(pinKey: pinKey)

                // MARK: User media (photos + videos)
                    PinMediaSection(title: "Photos & Videos", pinKey: pinKey)

if onDelete != nil {
    Button(role: .destructive) {
        showDeleteConfirm = true
    } label: {
        HStack {
            Image(systemName: "trash")
            Text("Delete pin from map")
                .font(.headline)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .alert("Delete this pin?", isPresented: $showDeleteConfirm) {
        Button("Delete", role: .destructive) { performDelete() }
        Button("Cancel", role: .cancel) { }
    } message: {
        Text("This will remove the pin and its saved photos, videos, voice notes, and memory notes from the app.")
    }
}
            }
            .padding(16)
        }
    }

    var body: some View {
        // Keep a navigation container for consistent sheet behavior, but we intentionally
        // do not show a navigation title or explicit close button.
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
        }
    }
}



/// Sheet UI used to select a built-in ambient sound for a place.
struct BuiltInSoundPickerSheet: View {
    let pinKey: String
    let defaultTitle: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pinAudioStore: PinAudioSelectionStore
    @ObservedObject private var audio = AudioManager.shared

    private var currentSelection: String? {
        pinAudioStore.selection(for: pinKey)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pinAudioStore.clearSelection(for: pinKey)
                        audio.stopPreview()
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use default")
                                    .font(.headline)
                                Text(defaultTitle)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if currentSelection == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section("Built-in sounds") {
                    ForEach(BuiltInSoundLibrary.sounds) { sound in
                        Button {
                            pinAudioStore.setSelection(sound.baseName, for: pinKey)
                            audio.stopPreview()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sound.title)
                                        .font(.headline)
                                    Text(sound.subtitle)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()

                                Button {
                                    audio.togglePreview(trackBaseName: sound.baseName)
                                } label: {
                                    Image(systemName: (audio.isPreviewing && audio.previewTrackBaseName == sound.baseName) ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel((audio.isPreviewing && audio.previewTrackBaseName == sound.baseName) ? "Stop preview" : "Play preview")
                                .accessibilityHint("Preview \(sound.title)")

                                if currentSelection == sound.baseName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        audio.stopPreview()
                        dismiss()
                    }
                }
            }
        }
    }
}


// MARK: - Now Playing color helpers

/// Computes a soft average color from an image for the expanded player background.
fileprivate func averagePlayerUIColor(from image: UIImage) -> UIColor? {
    guard let cgImage = image.cgImage else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixel = [UInt8](repeating: 0, count: 4)

    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    return UIColor(
        red: CGFloat(pixel[0]) / 255.0,
        green: CGFloat(pixel[1]) / 255.0,
        blue: CGFloat(pixel[2]) / 255.0,
        alpha: 1.0
    )
}

/// Selects a readable foreground color for an expanded now-playing background.
fileprivate func playerForegroundUIColor(for background: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
    return luminance > 0.62 ? .black : .white
}

/// Selects a darker accent color used for expanded-player controls.
fileprivate func playerControlInkUIColor(for background: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
    if luminance > 0.62 {
        return UIColor(white: 0.14, alpha: 1.0)
    }

    return UIColor(
        red: max(0.06, red * 0.34),
        green: max(0.06, green * 0.34),
        blue: max(0.06, blue * 0.34),
        alpha: 1.0
    )
}

/// Full-height player sheet opened from the bottom play bar.
struct ExpandedNowPlayingView: View {
    let currentStation: RadioStation?
    @Binding var favorites: Set<String>

    @ObservedObject private var audio = AudioManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var stopDismissProgress: CGFloat = 0
    @State private var isStoppingAndClosing = false

    private var backgroundUIColor: UIColor {
        if let image = audio.currentArtworkImage,
           let average = averagePlayerUIColor(from: image) {
            return average
        }
        return audio.currentStreamURLString == nil ? UIColor.systemIndigo : UIColor.systemBlue
    }

    private var foregroundUIColor: UIColor {
        playerForegroundUIColor(for: backgroundUIColor)
    }

    private var controlInkUIColor: UIColor {
        playerControlInkUIColor(for: backgroundUIColor)
    }

    private var titleText: String {
        if let stationName = currentStation?.name, !stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stationName
        }
        if let title = audio.currentTrackTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "Now Playing"
    }

    private var countryText: String? {
        let country = (currentStation?.country ?? audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return country.isEmpty ? nil : country
    }

    private var liveMetaText: String? {
        if audio.currentLocalPlaybackKind == "voiceNote" { return nil }
        let value = (audio.nowPlayingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "live stream", value != titleText else { return nil }
        return value
    }

    private var buttonSymbol: String {
        audio.isPlaying ? "pause.fill" : "play.fill"
    }

    private var repeatSymbol: String {
        audio.isRepeatEnabled ? "repeat.1" : "repeat"
    }

    private var repeatAvailable: Bool {
        audio.currentStreamURLString == nil && audio.currentLocalFileURLString != nil
    }

    private var currentFavoriteID: String? {
        if let explicit = audio.currentFavoriteTargetID {
            return explicit
        }
        return currentStation.map { "station_" + $0.id }
    }

    private var isFavoriteCurrentItem: Bool {
        guard let currentFavoriteID else { return false }
        return favorites.contains(currentFavoriteID)
    }

    /// Toggles audio playback from the expanded now-playing sheet.
    private func togglePlayback() {
        AppLog.action("Expanded player toggle playback")
        audio.isPlaying ? audio.pause() : audio.resume()
    }

    /// Stops playback and dismisses the expanded player while letting the entire sheet slide down.
    private func stopPlayback() {
        guard !isStoppingAndClosing else { return }
        isStoppingAndClosing = true
        AppLog.action("Expanded player stop playback")
        audio.stop()

        // Nudge the content downward immediately so the player begins reacting before
        // the sheet itself starts its native pull-down dismissal animation.
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.92, blendDuration: 0.1)) {
            stopDismissProgress = 1
        }

        // Dismiss almost immediately so the whole card slides down, not just the content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            dismiss()
        }
    }

    /// Toggles the favorite state for the current station from the expanded player.
    private func toggleFavorite() {
        guard let currentFavoriteID else { return }
        let willFavorite = !favorites.contains(currentFavoriteID)
        AppLog.action("Expanded player favorite \(willFavorite ? "ADD" : "REMOVE"): \(currentFavoriteID)")
        if willFavorite {
            favorites.insert(currentFavoriteID)
        } else {
            favorites.remove(currentFavoriteID)
        }
    }

    var body: some View {
        let backgroundColor = Color(uiColor: backgroundUIColor)
        let foregroundColor = Color(uiColor: foregroundUIColor)
        let controlInkColor = Color(uiColor: controlInkUIColor)

        ZStack {
            LinearGradient(
                colors: [
                    backgroundColor.opacity(0.96),
                    backgroundColor.opacity(0.84),
                    backgroundColor.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 20)

                Group {
                    if let artwork = audio.currentArtworkImage {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFit()
                    } else if let currentStation {
                        StationLogoView(logoURLString: currentStation.logoURL)
                            .padding(26)
                    } else if audio.currentLocalPlaybackKind == "voiceNote" {
                        Image(systemName: "waveform")
                            .resizable()
                            .scaledToFit()
                            .padding(52)
                            .foregroundStyle(foregroundColor.opacity(0.92))
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .resizable()
                            .scaledToFit()
                            .padding(40)
                            .foregroundStyle(foregroundColor.opacity(0.92))
                    }
                }
                .frame(width: 240, height: 240)
                .background(foregroundColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(foregroundColor.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 10)

                VStack(spacing: 10) {
                    Text(titleText)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(foregroundColor)
                        .padding(.horizontal, 24)

                    if let countryText {
                        Text(countryText)
                            .font(.headline)
                            .foregroundStyle(foregroundColor.opacity(0.84))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Button {
                        audio.toggleRepeat()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: repeatSymbol)
                                .font(.system(size: 18, weight: .semibold))
                            Text(audio.isRepeatEnabled ? "Repeat On" : "Repeat")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(repeatAvailable ? (audio.isRepeatEnabled ? Color.orange : foregroundColor.opacity(0.96)) : foregroundColor.opacity(0.35))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(foregroundColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!repeatAvailable)
                    .accessibilityLabel(audio.isRepeatEnabled ? "Disable repeat" : "Enable repeat")
                    .accessibilityHint("Repeats the current local audio item")

                    if let liveMetaText {
                        Text(liveMetaText)
                            .font(.subheadline)
                            .foregroundStyle(foregroundColor.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                Spacer()

                HStack(alignment: .center, spacing: 24) {
                    Button(action: stopPlayback) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(controlInkColor.opacity(0.96))
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .accessibilityHint("Stops playback")

                    Button(action: togglePlayback) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.96))

                            if audio.currentStreamURLString != nil && audio.isBuffering {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(controlInkColor)
                                    .scaleEffect(1.3)
                            } else {
                                Image(systemName: buttonSymbol)
                                    .font(.system(size: 38, weight: .semibold))
                                    .foregroundStyle(controlInkColor)
                            }
                        }
                        .frame(width: 114, height: 114)
                        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                    .accessibilityHint("Toggles playback while keeping the player page open")

                    Button(action: toggleFavorite) {
                        Image(systemName: isFavoriteCurrentItem ? "heart.fill" : "heart")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundStyle(isFavoriteCurrentItem ? Color.red : controlInkColor.opacity(0.96))
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.plain)
                    .disabled(currentFavoriteID == nil)
                    .opacity(currentFavoriteID == nil ? 0.4 : 1.0)
                    .accessibilityLabel(isFavoriteCurrentItem ? "Remove from favorites" : "Add to favorites")
                    .accessibilityHint("Adds or removes the current item from favorites")
                }
                .padding(.bottom, 20)
            }
            .offset(y: stopDismissProgress * 42)
            .scaleEffect(1 - (stopDismissProgress * 0.01))
            .opacity(1 - Double(stopDismissProgress) * 0.04)
            .allowsHitTesting(!isStoppingAndClosing)
        }
    }
}

// MARK: - Bottom mini player

/// A lightweight bottom play bar that stays visible across the app.
/// Shows the current place + track and lets the user play/pause/stop.

/// Presents playback controls and metadata for a selected radio station pin.
struct StationMusicModalView: View {
    let station: RadioStation
    @Binding var favorites: Set<String>
    @Binding var detent: PresentationDetent

    /// Optional: when provided, shows a destructive "Delete pin" button.
    /// The caller should remove the pin from its backing array (e.g. stations.removeAll { ... }).
    let onDelete: (() -> Void)?

    @ObservedObject private var audio = AudioManager.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recents: RecentManager
    @EnvironmentObject private var photoStore: PinPhotoStore

    @State private var showDeleteConfirm = false
    // No explicit close button: the sheet is dismissed by pulling down or tapping outside.

    init(
        station: RadioStation,
        favorites: Binding<Set<String>> = .constant([]),
        detent: Binding<PresentationDetent> = .constant(.height(340)),
        onDelete: (() -> Void)? = nil
    ) {
        self.station = station
        self._favorites = favorites
        self._detent = detent
        self.onDelete = onDelete
    }

    private var stationFavoriteID: String { "station_" + station.id }
    private var isFavorite: Bool { favorites.contains(stationFavoriteID) }
    private var pinKey: String { "station_" + station.id }

    private let compactDetent: PresentationDetent = .height(340)
    private var isCompact: Bool { detent == compactDetent }

    private var hasPhotos: Bool {
        !photoStore.filenames(for: pinKey).isEmpty
    }

    private var headerTopPadding: CGFloat {
        if isCompact {
            return hasPhotos ? 32 : 20
        }
        return 12
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite() {
        let willFavorite = !isFavorite
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): \(stationFavoriteID)")
        if willFavorite {
            favorites.insert(stationFavoriteID)
        } else {
            favorites.remove(stationFavoriteID)
        }
    }

    /// Deletes an item from the relevant store and updates in-memory state.
    private func performDelete() {
        // Stop playback if this station is playing.
        if audio.currentStreamURLString == station.streamURL {
            audio.stop()
        }

        // Clean up user state tied to this pin.
        favorites.remove(stationFavoriteID)
        recents.remove(kind: .station, itemID: station.id)
        photoStore.removeAllPhotos(for: pinKey)
        DeletedPinsStore.markDeleted(pinKey)

        // Remove from backing source.
        onDelete?()

        dismiss()
    }

    private var locationText: String {
        "\(station.city), \(station.country)"
    }

    private var briefText: String {
        station.briefDescription ?? station.description
    }

    private var nowPlayingLabel: String {
        let live = "Live stream"
        guard audio.currentStreamURLString == station.streamURL else { return live }
        let now = (audio.nowPlayingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return now.isEmpty ? live : now
    }

    private var streamURLValue: URL? {
        URL(string: station.streamURL)
    }

    // Copies stream url for this feature.
    /// Copies stream url.
    private func copyStreamURL() {
        UIPasteboard.general.string = station.streamURL
        AppLog.action("Copied stream URL for station: \(station.id)")
        if let url = streamURLValue {
            AppLog.url("Copied stream URL", url)
        }
    }

    // Opens stream url for this feature.
    /// Opens stream url.
    private func openStreamURL() {
        guard let url = streamURLValue else {
            AppLog.info("Invalid stream URL for station \(station.id): \(station.streamURL)")
            return
        }
        AppLog.action("Open stream URL externally for station: \(station.id)")
        AppLog.url("Open station stream URL", url)
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private var stationLogoView: some View {
        StationLogoView(logoURLString: station.logoURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        stationLogoView
                            .frame(width: 42, height: 42)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(station.name)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(locationText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button(action: toggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(isFavorite ? .red : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                    }
                    .padding(.top, headerTopPadding)
                    .padding(.bottom, 6)

                    Text(briefText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)

                    Text("Now Playing: \(nowPlayingLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    PinPhotoSection(title: "Photos", pinKey: pinKey)

                    Button {
                        // Record only when the user is effectively starting / switching playback.
                        if audio.currentStreamURLString != station.streamURL || !audio.isPlaying {
                            recents.record(station: station)
                        }
                        audio.toggleStream(
                            urlString: station.streamURL,
                            trackTitle: station.name,
                            // Mini player subtitle: country.
                            placeName: station.country,
                            artworkURLString: station.logoURL
                        )
                    } label: {
                        HStack {
                            Image(systemName: (audio.isPlaying && audio.currentStreamURLString == station.streamURL) ? "pause.fill" : "play.fill")
                            Text((audio.isPlaying && audio.currentStreamURLString == station.streamURL) ? "Pause" : "Play")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 10) {
                        Button(action: copyStreamURL) {
                            Label("Copy Stream URL", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Copies the live stream link to the clipboard")
                        .accessibilityIdentifier("copy_stream_url")

                        Button(action: openStreamURL) {
                            Label("Open Stream URL", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(streamURLValue == nil)
                        .opacity(streamURLValue == nil ? 0.45 : 1.0)
                        .accessibilityHint("Opens the live stream link in another app")
                        .accessibilityIdentifier("open_stream_url")
                    }
                }
                .padding(16)
            }
        }
    }
}



/// Persistent mini player that shows the current playback state and quick controls.
struct MiniPlayerBar: View {
    @Binding var favorites: Set<String>
    @ObservedObject private var audio = AudioManager.shared
    @State private var showExpandedPlayer = false

    // Local cache to resolve a station logo from the current stream URL.
    // This avoids threading station arrays through multiple view layers.
    @State private var stations: [RadioStation] = {
        let deleted = DeletedPinsStore.get()
        return RadioStationStore.load().filter { !deleted.contains("station_" + $0.id) }
    }()

    @State private var places: [Place] = {
            let deleted = DeletedPinsStore.get()
            return (PlaceStore.load() + UserPlaceStore.load())
                .filter { !deleted.contains("place_" + $0.id) }
        }()

    private var hasSelection: Bool {
        audio.currentTrackBaseName != nil || audio.currentLocalFileURLString != nil || audio.currentStreamURLString != nil
    }

    private var currentStation: RadioStation? {
        guard let url = audio.currentStreamURLString else { return nil }
        return stations.first(where: { $0.streamURL == url })
    }

    private var currentSubtitle: String {
        if audio.currentStreamURLString != nil {
            let country = (audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let now = (audio.nowPlayingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = now.isEmpty ? "Live stream" : now
            if country.isEmpty {
                return meta
            }
            return "\(country) · \(meta)"
        }
        if audio.currentLocalPlaybackKind == "voiceNote" {
            let place = (audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return place.isEmpty ? "Voice note" : "\(place) · Voice note"
        }
        return audio.currentPlaceName ?? ""
    }

    private var favoriteTargetID: String? {
        if let explicit = audio.currentFavoriteTargetID {
            return explicit
        }

        // Radio stream: favorite the station.
        if audio.currentStreamURLString != nil, let station = currentStation {
            return "station_" + station.id
        }

        // Local track: favorite the place that initiated playback (when we can resolve it).
        guard audio.currentStreamURLString == nil else { return nil }

        let name = (audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return places.first(where: { $0.name == name })?.id
    }

    private var isFavoriteInBar: Bool {
        guard let id = favoriteTargetID else { return false }
        return favorites.contains(id)
    }

    /// Toggles favorite state for the currently playing item from the mini player.
    private func toggleFavoriteInBar() {
        guard let id = favoriteTargetID else { return }
        let willFavorite = !favorites.contains(id)
        AppLog.action("Favorite (play bar) \(willFavorite ? "ADD" : "REMOVE"): \(id)")
        if willFavorite {
            favorites.insert(id)
        } else {
            favorites.remove(id)
        }
    }




    var body: some View {
        if hasSelection {
            HStack(spacing: 12) {
                Button {
                    AppLog.action("Open expanded player")
                    showExpandedPlayer = true
                } label: {
                    HStack(spacing: 12) {
                        if audio.currentStreamURLString != nil {
                            if let artwork = audio.currentArtworkImage {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                StationLogoView(logoURLString: currentStation?.logoURL)
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        } else if audio.currentLocalPlaybackKind == "voiceNote" {
                            Image(systemName: "waveform")
                                .font(.title3)
                        } else {
                            Image(systemName: audio.currentStreamURLString == nil ? "music.note" : "dot.radiowaves.left.and.right")
                                .font(.title3)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(audio.currentTrackTitle ?? "Now Playing")
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(currentSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full player page")

                Button {
                    toggleFavoriteInBar()
                } label: {
                    Image(systemName: isFavoriteInBar ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isFavoriteInBar ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .disabled(favoriteTargetID == nil)
                .opacity(favoriteTargetID == nil ? 0.4 : 1.0)
                .accessibilityLabel(isFavoriteInBar ? "Remove from favorites" : "Add to favorites")

                if audio.currentStreamURLString != nil && audio.isBuffering {
                    ProgressView()
                        .scaleEffect(0.75)
                        .accessibilityLabel("Connecting")
                }

                Button {
                    audio.toggleRepeat()
                } label: {
                    Image(systemName: audio.isRepeatEnabled ? "repeat.1" : "repeat")
                        .font(.title3)
                        .foregroundStyle(audio.currentStreamURLString == nil && audio.currentLocalFileURLString != nil ? (audio.isRepeatEnabled ? Color.orange : Color.primary) : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!(audio.currentStreamURLString == nil && audio.currentLocalFileURLString != nil))
                .opacity(audio.currentStreamURLString == nil && audio.currentLocalFileURLString != nil ? 1.0 : 0.4)
                .accessibilityLabel(audio.isRepeatEnabled ? "Disable repeat" : "Enable repeat")
                .accessibilityHint("Repeats the current local audio item")

                Button {
                    audio.isPlaying ? audio.pause() : audio.resume()
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                .accessibilityHint("Toggles audio playback")

                Button {
                    audio.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops playback")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 10)
            .padding(.horizontal, 12)
            .sheet(isPresented: $showExpandedPlayer) {
                ExpandedNowPlayingView(currentStation: currentStation, favorites: $favorites)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}


/// Reusable view shown when a list has no content to display.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
