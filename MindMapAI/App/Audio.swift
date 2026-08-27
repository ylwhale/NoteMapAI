import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import Network

/// Centralized audio playback for both bundled tracks and streaming radio.
/// Configured for background playback (requires UIBackgroundModes = audio in Info.plist).
final class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVPlayerItemMetadataOutputPushDelegate {
    static let shared = AudioManager()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTrackBaseName: String? = nil   // local file (without extension)
    @Published private(set) var currentStreamURLString: String? = nil // remote stream URL
    @Published private(set) var currentTrackTitle: String? = nil
    @Published private(set) var currentPlaceName: String? = nil
    @Published private(set) var currentArtworkImage: UIImage? = nil
    @Published private(set) var currentLocalFileURLString: String? = nil
    @Published private(set) var currentLocalPlaybackKind: String? = nil
    @Published private(set) var currentFavoriteTargetID: String? = nil
    @Published private(set) var isRepeatEnabled: Bool = false

    // For radio streams, we try to read ICY/metadata (track/artist) when available.
    @Published private(set) var nowPlayingText: String? = nil

    /// True while a radio stream is connecting/buffering.
    @Published private(set) var isBuffering: Bool = false

    /// User-facing error message (used to drive alerts for connectivity/playback issues).
    @Published private(set) var userFacingErrorMessage: String? = nil

    private var audioPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    @Published private(set) var previewTrackBaseName: String? = nil
    @Published private(set) var isPreviewing: Bool = false

    /// Tracks what should resume after an interruption or temporary preview.
    private enum ResumeState {
        case local(baseName: String, title: String?, placeName: String?)
        case stream(urlString: String, title: String?, placeName: String?)
    }
    private var resumeStateAfterPreview: ResumeState? = nil
    private var streamPlayer: AVPlayer?

    // iOS 13+: Stream metadata is delivered via AVPlayerItemMetadataOutput.
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private let metadataQueue = DispatchQueue(label: "radioatlas.stream.metadata")
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentPlayerItem: AVPlayerItem?

    // MARK: - Network reachability (for stream recovery)

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "radioatlas.network.monitor")
    private var isNetworkReachable: Bool = true
    private var pendingNetworkRetryForStream: Bool = false
    private var userWantsPlayback: Bool = false
    private var currentArtworkURLString: String? = nil
    private static let artworkCache = NSCache<NSString, UIImage>()

    // If an interruption happens while we were playing (phone call, Siri, etc.),
    // remember that state so we can resume reliably.
    private var shouldResumeAfterInterruption: Bool = false

    // Some iOS versions / simulator builds can momentarily pause audio when the app
    // transitions to inactive/background (home button, lock screen). We track whether
    // we were playing right before that transition so we can defensively re-assert
    // the session and keep playback going.
    private var wasPlayingBeforeBackground: Bool = false

    // MARK: - Init / Setup

    override private init() {
        super.init()
        // DEBUG: confirm the built app contains UIBackgroundModes = audio (required for background playback).
        let bg = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") ?? "<nil>"
        print("[MindMapAI] UIBackgroundModes:", bg)
        print("[MindMapAI] BundleID:", Bundle.main.bundleIdentifier ?? "<nil>")
        configureAudioSessionIfNeeded(force: true)
        configureRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        // Defensive: some devices/configurations will deactivate the audio session when
        // the app backgrounds unless we re-assert it. Keeping the session active while
        // audio is playing prevents "auto-pause" on lock/home.
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        UIApplication.shared.beginReceivingRemoteControlEvents()

        startNetworkMonitor()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pathMonitor.cancel()
    }

    /// Starts monitoring reachability so the app can react when connectivity changes.
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = (path.status == .satisfied)

            // Avoid unnecessary work if nothing changed.
            if reachable == self.isNetworkReachable { return }

            self.isNetworkReachable = reachable

            if !reachable {
                // If a stream is playing and we lose connectivity, mark for retry.
                if self.currentStreamURLString != nil && self.userWantsPlayback {
                    self.pendingNetworkRetryForStream = true
                }
            }

            // If we previously failed due to losing connectivity, retry once when it returns.
            if reachable {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.retryCurrentStreamIfNeeded(reason: "network restored")
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /// Retries the current radio stream after connectivity is restored.
    private func retryCurrentStreamIfNeeded(reason: String) {
        guard userWantsPlayback else { return }
        guard pendingNetworkRetryForStream else { return }
        guard let stream = currentStreamURLString else {
            pendingNetworkRetryForStream = false
            return
        }

        pendingNetworkRetryForStream = false
        AppLog.action("Retry stream (\(reason))")
        // Retry without spamming alerts.
        playStream(urlString: stream, trackTitle: currentTrackTitle, placeName: currentPlaceName, artworkURLString: currentArtworkURLString, userInitiated: false)
    }

    // MARK: - Audio Session (Background Playback)

    /// Configure a playback audio session. This is required for background audio.
    private func configureAudioSessionIfNeeded(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            // IMPORTANT:
            // If the session is not in `.playback` (or is not active), iOS will pause
            // audio when the app goes to the background or the screen locks.
            //
            // Keep the session in `.playback` so audio continues when the app backgrounds/locks.
            if force || session.category != .playback {
                // Use standard `.playback` without `routeSharingPolicy`.
                // Some iOS versions (and especially the simulator) reject certain
                // option + policy combinations (e.g. `.longFormAudio` + bluetooth/airplay),
                // which causes background playback to fail.
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [
                        .allowAirPlay,
                        .allowBluetoothHFP,
                        .allowBluetoothA2DP
                    ]
                )
            }
            // Always ensure the session is active before playback.
            try session.setActive(true, options: [])
        } catch {
            AppLog.info("Failed to configure audio session for background playback: \(error)")
        }
    }

    // MARK: - Local audio (bundled files: mp3 / wav / m4a)

    // Handles audio url for this feature.
    /// Performs the `bundledAudioURL` operation for this type.
    private func bundledAudioURL(forBaseName baseName: String) -> URL? {
        // We keep this list small and explicit so failures are easy to reason about.
        let exts = ["mp3", "m4a", "wav"]
        for ext in exts {
            if let url = Bundle.main.url(forResource: baseName, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    /// Performs play.
    func play(trackBaseName: String, trackTitle: String?, placeName: String?) {
        configureAudioSessionIfNeeded()
        AppLog.action("Play local: \(trackBaseName) title=\(trackTitle ?? "nil") place=\(placeName ?? "nil")")
        userFacingErrorMessage = nil
        isBuffering = false
        userWantsPlayback = true
        pendingNetworkRetryForStream = false
        // Switching source: stop any stream
        stopStreamPlayer()

        // If already playing this local track, pause
        if currentTrackBaseName == trackBaseName, isPlaying {
            AppLog.action("Toggle local: pause \(trackBaseName)")
            pause()
            return
        }

        stopLocalPlayer()

        currentTrackBaseName = trackBaseName
        currentLocalFileURLString = nil
        currentLocalPlaybackKind = nil
        currentFavoriteTargetID = nil
        currentStreamURLString = nil
        currentTrackTitle = trackTitle
        currentPlaceName = placeName
        currentArtworkURLString = nil
        currentArtworkImage = nil
        nowPlayingText = nil

        guard let url = bundledAudioURL(forBaseName: trackBaseName) else {
            AppLog.info("Missing bundled audio in app: \(trackBaseName).(mp3|m4a|wav)")
            userFacingErrorMessage = "Missing bundled audio file for this place."
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        AppLog.path("Local audio file", url)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            // The UI says this is a looping offline track for each place.
            // Looping also makes background testing very obvious.
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            AppLog.info("Failed to play local audio: \(error)")
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    /// Toggle a bundled local audio track:
    /// - If the same track is selected, this will play/pause.
    /// - If a different track is selected, it switches tracks and plays.
    func toggle(trackBaseName: String, trackTitle: String?, placeName: String?) {
        if currentTrackBaseName == trackBaseName, currentStreamURLString == nil {
            isPlaying ? pause() : resume()
        } else {
            play(trackBaseName: trackBaseName, trackTitle: trackTitle, placeName: placeName)
        }
    }


    /// Plays a user-generated local audio file, such as a voice memo attached to a place.
    func playLocalFile(fileURL: URL, trackTitle: String?, placeName: String?, favoriteTargetID: String?, playbackKind: String = "localFile", shouldLoop: Bool? = nil) {
        configureAudioSessionIfNeeded()
        AppLog.action("Play local file: \(fileURL.lastPathComponent) title=\(trackTitle ?? "nil") place=\(placeName ?? "nil")")
        userFacingErrorMessage = nil
        isBuffering = false
        userWantsPlayback = true
        pendingNetworkRetryForStream = false

        stopStreamPlayer()

        if currentLocalFileURLString == fileURL.absoluteString, isPlaying {
            pause()
            return
        }

        stopLocalPlayer()

        currentTrackBaseName = nil
        currentLocalFileURLString = fileURL.absoluteString
        currentLocalPlaybackKind = playbackKind
        currentFavoriteTargetID = favoriteTargetID
        currentStreamURLString = nil
        currentTrackTitle = trackTitle
        currentPlaceName = placeName
        currentArtworkURLString = nil
        currentArtworkImage = nil
        nowPlayingText = nil

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLog.info("Missing local audio file at path: \(fileURL.path)")
            userFacingErrorMessage = "The selected audio file could not be found."
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        AppLog.path("Local audio file", fileURL)
        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            let resolvedShouldLoop = shouldLoop ?? isRepeatEnabled
            player.numberOfLoops = resolvedShouldLoop ? -1 : 0
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            AppLog.info("Failed to play local file audio: \(error)")
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    /// Toggles playback for a user-generated local audio file.
    func toggleLocalFile(fileURL: URL, trackTitle: String?, placeName: String?, favoriteTargetID: String?, playbackKind: String = "localFile", shouldLoop: Bool? = nil) {
        if currentLocalFileURLString == fileURL.absoluteString, currentStreamURLString == nil {
            isPlaying ? pause() : resume()
        } else {
            playLocalFile(fileURL: fileURL, trackTitle: trackTitle, placeName: placeName, favoriteTargetID: favoriteTargetID, playbackKind: playbackKind, shouldLoop: shouldLoop)
        }
    }

    // MARK: - Preview (sound picker)

    /// Play/stop a short preview of a bundled sound without permanently changing the user's selection.
    /// We temporarily pause the current playback and restore it when the preview stops.
    func togglePreview(trackBaseName: String) {
        if previewTrackBaseName == trackBaseName, isPreviewing {
            stopPreview()
        } else {
            startPreview(trackBaseName: trackBaseName)
        }
    }

    /// Stops preview playback and restores previous playback if needed.
    func stopPreview() {
        AppLog.action("Stop preview")
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewing = false
        previewTrackBaseName = nil

        // Restore previous playback if we paused it for preview.
        if let resumeStateAfterPreview {
            self.resumeStateAfterPreview = nil
            restoreAfterPreview(resumeStateAfterPreview)
        }
    }

    /// Starts preview playback for a built-in sound.
    private func startPreview(trackBaseName: String) {
        configureAudioSessionIfNeeded()
        AppLog.action("Preview local: \(trackBaseName)")

        // Snapshot current playback so we can restore it.
        if isPlaying {
            if let currentStreamURLString {
                resumeStateAfterPreview = .stream(urlString: currentStreamURLString, title: currentTrackTitle, placeName: currentPlaceName)
            } else if let currentTrackBaseName {
                resumeStateAfterPreview = .local(baseName: currentTrackBaseName, title: currentTrackTitle, placeName: currentPlaceName)
            }
            pause()
        } else {
            resumeStateAfterPreview = nil
        }

        // Stop any existing preview.
        previewPlayer?.stop()
        previewPlayer = nil

        guard let url = bundledAudioURL(forBaseName: trackBaseName) else {
            AppLog.info("Missing bundled audio for preview: \(trackBaseName)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.numberOfLoops = 0
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            previewTrackBaseName = trackBaseName
            isPreviewing = true
        } catch {
            AppLog.info("Failed to preview audio: \(error)")
        }
    }

    /// Restores the previous playback state after a preview ends.
    private func restoreAfterPreview(_ state: ResumeState) {
        switch state {
        case let .local(baseName, title, placeName):
            // Restore the previous local track.
            play(trackBaseName: baseName, trackTitle: title, placeName: placeName)
        case let .stream(urlString, title, placeName):
            // Restore the previous stream.
            playStream(urlString: urlString, trackTitle: title ?? "Radio", placeName: placeName, artworkURLString: currentArtworkURLString)
        }
    }

    // MARK: - Streaming audio (AVPlayer)

    // Starts stream for this feature.
    /// Starts a radio stream and updates playback metadata, buffering state, and artwork.
    func playStream(urlString: String, trackTitle: String?, placeName: String?, artworkURLString: String? = nil, userInitiated: Bool = true) {
        configureAudioSessionIfNeeded()
        AppLog.action("Play stream: \(urlString) title=\(trackTitle ?? "nil") place=\(placeName ?? "nil")")
        userFacingErrorMessage = nil
        isBuffering = true
        userWantsPlayback = true
        pendingNetworkRetryForStream = false
        // Switching source: stop any local player
        stopLocalPlayer()

        // If already playing this stream, pause
        if currentStreamURLString == urlString, isPlaying {
            AppLog.action("Toggle stream: pause \(urlString)")
            pause()
            return
        }

        stopStreamPlayer()

        currentStreamURLString = urlString
        currentTrackBaseName = nil
        currentLocalFileURLString = nil
        currentLocalPlaybackKind = nil
        currentFavoriteTargetID = nil
        currentTrackTitle = trackTitle
        currentPlaceName = placeName
        nowPlayingText = "Live stream"
        currentArtworkURLString = artworkURLString
        updateArtwork(from: artworkURLString)

        guard let url = URL(string: urlString) else {
            AppLog.info("Invalid stream URL: \(urlString)")
            userFacingErrorMessage = "Invalid radio stream URL."
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        AppLog.url("Stream URL", url)

        // Some radio providers reject requests without a User-Agent or without ICY metadata enabled.
        // Using an AVURLAsset with headers makes playback much more reliable across stations.
        let headers: [String: String] = [
            "User-Agent": "MindMapAI/1.0 (iOS)",
            "Icy-MetaData": "1",
            "Accept": "*/*"
        ]
        // NOTE:
        // Some SDKs / toolchains don't expose `AVURLAssetHTTPHeaderFieldsKey` as a symbol.
        // The underlying key is still the same string, so using the literal keeps the
        // project building across Xcode versions.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        currentPlayerItem = item
        setupStreamMetadataObservation(for: item)

        let player = AVPlayer(playerItem: item)
        streamPlayer = player
        // Make AVPlayer behave like an audio app when backgrounding/locking.
        if #available(iOS 16.0, *) {
            // Fully qualify to avoid type-inference issues on some toolchains.
            player.audiovisualBackgroundPlaybackPolicy = AVPlayerAudiovisualBackgroundPlaybackPolicy.continuesIfPossible
        }
        player.automaticallyWaitsToMinimizeStalling = true

        // Start playback only when the item becomes ready.
        // This avoids a common failure mode where play() is called too early and nothing happens.
        statusObservation?.invalidate()
        // Use explicit root types + explicit options to avoid "cannot infer" compile errors
        // that can happen with some Swift toolchains.
        statusObservation = item.observe(\AVPlayerItem.status, options: [NSKeyValueObservingOptions.initial, NSKeyValueObservingOptions.new]) { [weak self] observedItem, _ in
            guard let self, let player = self.streamPlayer, self.currentPlayerItem === item else { return }
            switch observedItem.status {
            case .readyToPlay:
                if #available(iOS 10.0, *) {
                    player.playImmediately(atRate: 1.0)
                } else {
                    player.play()
                }
                self.isPlaying = true
                self.isBuffering = false
                self.updateNowPlayingInfo()
            case .failed:
                self.isPlaying = false
                self.isBuffering = false
                // Only show an alert for user-initiated plays. Auto-retries should be silent.
                if userInitiated {
                    self.userFacingErrorMessage = "Unable to start the radio stream. Please check your connection."
                }
                self.nowPlayingText = "Stream unavailable"
                self.updateNowPlayingInfo()

                // If we are offline, mark for a single retry when the network returns.
                if !self.isNetworkReachable {
                    self.pendingNetworkRetryForStream = true
                }
                if let err = observedItem.error {
                    AppLog.info("Stream failed: \(err)")
                }
            default:
                break
            }
        }

        // Log state changes (useful for debugging on device) and recover from stalls.
        timeControlObservation?.invalidate()
        timeControlObservation = player.observe(\AVPlayer.timeControlStatus, options: [NSKeyValueObservingOptions.new]) { _, _ in }
        NotificationCenter.default.addObserver(self, selector: #selector(handleStreamStalled(_:)), name: .AVPlayerItemPlaybackStalled, object: item)

        // Optimistically update UI; actual isPlaying will be set once ready.
        isPlaying = true
        updateNowPlayingInfo()
    }

    /// Toggles playback for the currently selected stream URL.
    func toggleStream(urlString: String, trackTitle: String?, placeName: String?, artworkURLString: String? = nil) {
        if currentStreamURLString == urlString {
            currentArtworkURLString = artworkURLString ?? currentArtworkURLString
            if currentArtworkImage == nil {
                updateArtwork(from: currentArtworkURLString)
            }
            isPlaying ? pause() : resume()
        } else {
            playStream(urlString: urlString, trackTitle: trackTitle, placeName: placeName, artworkURLString: artworkURLString)
        }
    }

    // MARK: - Transport

    /// Clear the latest user-facing error after the UI has displayed it.
    func clearUserFacingError() {
        userFacingErrorMessage = nil
    }


    /// Performs pause.
    func pause() {
        isBuffering = false
        AppLog.action("Pause")
        userWantsPlayback = false
        if let audioPlayer {
            audioPlayer.pause()
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        if let streamPlayer {
            streamPlayer.pause()
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
    }

    /// Performs resume.
    func resume() {
        AppLog.action("Resume")
        configureAudioSessionIfNeeded()
        if let audioPlayer {
            audioPlayer.play()
            isPlaying = true
            userWantsPlayback = true
            updateNowPlayingInfo()
            return
        }
        if let streamPlayer {
            // If the current item previously failed (e.g., network dropped), AVPlayer.play()
            // won't recover. Rebuild the item instead.
            if let item = currentPlayerItem, item.status == .failed, let stream = currentStreamURLString {
                AppLog.action("Resume stream: rebuilding after failure")
                playStream(urlString: stream, trackTitle: currentTrackTitle, placeName: currentPlaceName, artworkURLString: currentArtworkURLString, userInitiated: true)
                return
            }
            streamPlayer.play()
            isPlaying = true
            userWantsPlayback = true
            updateNowPlayingInfo()
            return
        }

        // If players got released, recreate based on last known selection
        if let base = currentTrackBaseName {
            play(trackBaseName: base, trackTitle: currentTrackTitle, placeName: currentPlaceName)
        } else if let fileURLString = currentLocalFileURLString, let fileURL = URL(string: fileURLString) {
            playLocalFile(fileURL: fileURL, trackTitle: currentTrackTitle, placeName: currentPlaceName, favoriteTargetID: currentFavoriteTargetID, playbackKind: currentLocalPlaybackKind ?? "localFile", shouldLoop: nil)
        } else if let stream = currentStreamURLString {
            playStream(urlString: stream, trackTitle: currentTrackTitle, placeName: currentPlaceName, artworkURLString: currentArtworkURLString, userInitiated: true)
        }
    }

    /// Performs stop.
    func toggleRepeat() {
        isRepeatEnabled.toggle()
        AppLog.action("Repeat \(isRepeatEnabled ? "ENABLED" : "DISABLED")")
        if currentStreamURLString == nil {
            audioPlayer?.numberOfLoops = isRepeatEnabled ? -1 : 0
        }
        updateNowPlayingInfo()
    }

    func stop() {
        isBuffering = false
        AppLog.action("Stop")
        userWantsPlayback = false
        pendingNetworkRetryForStream = false
        stopLocalPlayer()
        stopStreamPlayer()
        currentTrackBaseName = nil
        currentLocalFileURLString = nil
        currentLocalPlaybackKind = nil
        currentFavoriteTargetID = nil
        currentStreamURLString = nil
        currentTrackTitle = nil
        currentPlaceName = nil
        currentArtworkURLString = nil
        currentArtworkImage = nil
        nowPlayingText = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Internals

    // Stops local player for this feature.
    /// Stops local player.
    private func stopLocalPlayer() {
        isBuffering = false
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Stops the AVPlayer used for streaming radio.
    private func stopStreamPlayer() {
        isBuffering = false
        if let currentPlayerItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: currentPlayerItem)
        }
        if let currentPlayerItem, let metadataOutput {
            currentPlayerItem.remove(metadataOutput)
        }
        metadataOutput = nil
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        currentPlayerItem = nil

        streamPlayer?.pause()
        streamPlayer = nil
        nowPlayingText = nil
    }

    /// Handles stalled stream playback by attempting a safe recovery.
    @objc private func handleStreamStalled(_ notification: Notification) {
        // When a live stream stalls (temporary network hiccup), attempting to resume often recovers.
        guard userWantsPlayback else { return }

        // If we're offline, wait for reachability before retrying.
        if !isNetworkReachable {
            pendingNetworkRetryForStream = true
            return
        }

        if let streamPlayer {
            streamPlayer.play()
        } else if let stream = currentStreamURLString {
            // If the player was released, recreate it.
            playStream(urlString: stream, trackTitle: currentTrackTitle, placeName: currentPlaceName, artworkURLString: currentArtworkURLString, userInitiated: false)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    // Handles player did finish playing for this feature.
    /// Handles completion events from the local audio player.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Preview finished.
        if player === previewPlayer {
            stopPreview()
            return
        }

        // When a local track ends, update state.
        isPlaying = false
        updateNowPlayingInfo()
    }

    // MARK: - Stream metadata (Now Playing)

    // Handles stream metadata observation for this feature.
    /// Performs the `setupStreamMetadataObservation` operation for this type.
    private func setupStreamMetadataObservation(for item: AVPlayerItem) {
        // Remove any previous output attached to the item.
        if let metadataOutput {
            item.remove(metadataOutput)
        }

        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: metadataQueue)
        item.add(output)
        metadataOutput = output
    }

    // MARK: AVPlayerItemMetadataOutputPushDelegate

    // Handles output for this feature.
    /// Handles streamed metadata updates and extracts displayable station information.
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        // Parse the first meaningful string we can find.
        let items: [AVMetadataItem] = groups.flatMap { $0.items }
        guard !items.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }

            for meta in items {
                // stringValue is async in iOS 16+.
                if let s = try? await meta.load(.stringValue),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let cleaned = self.cleanStreamTitle(s)
                    if !cleaned.isEmpty {
                        await MainActor.run {
                            self.nowPlayingText = cleaned
                            self.updateNowPlayingInfo()
                        }
                        return
                    }
                }

                // Fallback: some streams deliver ICY-ish text via the generic value field.
                if let v = try? await meta.load(.value),
                   let s = v as? String,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let cleaned = self.cleanStreamTitle(s)
                    if !cleaned.isEmpty {
                        await MainActor.run {
                            self.nowPlayingText = cleaned
                            self.updateNowPlayingInfo()
                        }
                        return
                    }
                }
            }
        }
    }

    /// Normalizes stream metadata strings for display.
    private func cleanStreamTitle(_ raw: String) -> String {
        var s = raw

        // Common ICY pattern.
        if let range = s.range(of: "StreamTitle='") {
            s = String(s[range.upperBound...])
            if let end = s.range(of: "';") {
                s = String(s[..<end.lowerBound])
            }
        }

        // Remove surrounding quotes and trim.
        s = s.replacingOccurrences(of: "\"", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some streams send "" or "-".
        if s == "" || s == "-" { return "" }
        return s
    }

    // MARK: - Remote Controls + Lock Screen

    // Configures remote commands for this feature.
    /// Configures remote commands.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.isPlaying ? self.pause() : self.resume()
            return .success
        }

        // Not supported in this app (no queue controls).
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    /// Updates the system Now Playing metadata shown on the lock screen.
    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]

        let titleText: String = {
            if let currentTrackTitle, !currentTrackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return currentTrackTitle
            }
            if let base = currentTrackBaseName {
                return base
            }
            if let stream = currentStreamURLString {
                return stream
            }
            return "Audio"
        }()

        info[MPMediaItemPropertyTitle] = titleText

        if let nowPlayingText, !nowPlayingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, nowPlayingText != titleText {
            info[MPMediaItemPropertyArtist] = nowPlayingText
        }

        if let place = currentPlaceName, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = place
        }

        let artworkImage = currentArtworkImage ?? defaultNowPlayingArtworkImage()
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }

        // Indicate this is a live stream when streaming.
        info[MPNowPlayingInfoPropertyIsLiveStream] = (currentStreamURLString != nil)

        // Playback rate is required so Control Center/Lock Screen shows play/pause properly.
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Best-effort elapsed time (only meaningful for local files).
        if let audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = audioPlayer.duration
        } else if let streamPlayer {
            // For streams we don't have stable duration; just set elapsed time if we can read it.
            if let t = streamPlayer.currentItem?.currentTime().seconds, t.isFinite {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Downloads or clears the active artwork used by the lock screen and player page.
    private func updateArtwork(from artworkURLString: String?) {
        let normalizedArtworkURLString = artworkURLString?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedArtworkURLString,
              !normalizedArtworkURLString.isEmpty,
              let url = URL(string: normalizedArtworkURLString) else {
            currentArtworkImage = nil
            updateNowPlayingInfo()
            return
        }

        // Clear any previous station artwork immediately so the mini player and
        // expanded player never keep showing the last station's image while the
        // new station is loading, missing artwork, or fails to download.
        currentArtworkImage = nil
        updateNowPlayingInfo()

        if let cached = Self.artworkCache.object(forKey: normalizedArtworkURLString as NSString) {
            currentArtworkImage = cached
            updateNowPlayingInfo()
            return
        }

        AppLog.url("Download now playing artwork", url)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }

            if let error {
                AppLog.info("Now playing artwork download failed: \(error)")
                return
            }

            guard let data, let image = UIImage(data: data) else { return }
            Self.artworkCache.setObject(image, forKey: normalizedArtworkURLString as NSString)

            DispatchQueue.main.async {
                guard self.currentArtworkURLString == normalizedArtworkURLString else { return }
                self.currentArtworkImage = image
                self.updateNowPlayingInfo()
            }
        }.resume()
    }

    /// Builds a fallback lock-screen artwork image when a station does not provide a logo.
    private func defaultNowPlayingArtworkImage() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor.systemIndigo.setFill()
            context.fill(bounds)

            let inset = bounds.insetBy(dx: 64, dy: 64)
            let rounded = UIBezierPath(roundedRect: inset, cornerRadius: 96)
            UIColor.white.withAlphaComponent(0.18).setFill()
            rounded.fill()

            let config = UIImage.SymbolConfiguration(pointSize: 180, weight: .regular)
            let symbol = UIImage(systemName: currentStreamURLString == nil ? "music.note" : "dot.radiowaves.left.and.right", withConfiguration: config)
            let tint = UIColor.white
            let tinted = symbol?.withTintColor(tint, renderingMode: .alwaysOriginal)
            let symbolSize = CGSize(width: 220, height: 220)
            let symbolOrigin = CGPoint(x: (size.width - symbolSize.width) / 2, y: (size.height - symbolSize.height) / 2)
            tinted?.draw(in: CGRect(origin: symbolOrigin, size: symbolSize))
        }
    }

    // MARK: - Notifications

    /// Handles audio session interruption.
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // System interruption (phone call, Siri, etc.)
            // Remember whether we were actively playing, so we can resume even in
            // cases where iOS doesn't include `.shouldResume` (some lock/background
            // transitions can look like interruptions on certain devices).
            shouldResumeAfterInterruption = isPlaying
            // If this interruption is caused by a home/lock transition (common on some
            // simulator/device configurations), we still want to keep playing in the
            // background. Preserve the "we were playing" snapshot so our lifecycle
            // handlers can nudge playback back on.
            wasPlayingBeforeBackground = wasPlayingBeforeBackground || shouldResumeAfterInterruption
            // IMPORTANT:
            // Avoid explicitly pausing the players here. During some background/lock
            // transitions, iOS may post an interruption-began notification without a
            // matching "ended" notification until the app returns to foreground.
            // If we call pause() ourselves, playback will *always* stop in background.
            // Let iOS manage the actual audio output, and only update our state/UI.
            isPlaying = false
            updateNowPlayingInfo()
        case .ended:
            // Re-assert the audio session and resume if we were playing before.
            configureAudioSessionIfNeeded(force: true)
            if shouldResumeAfterInterruption {
                resume()
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    // MARK: - App lifecycle (defensive session re-assert)

    /// Handles will resign active.
    @objc private func handleWillResignActive(_ notification: Notification) {
        // Snapshot whether we were playing *right before* going inactive.
        wasPlayingBeforeBackground = isPlaying
    }

    /// Handles app lifecycle transitions when the scene becomes active.
    @objc private func handleDidBecomeActive(_ notification: Notification) {
        // When coming back, if we were playing and the system paused us, try to resume.
        if wasPlayingBeforeBackground {
            configureAudioSessionIfNeeded(force: true)
            if !isPlaying {
                // Only resume if we still have a player instance.
                if audioPlayer != nil || streamPlayer != nil {
                    resume()
                }
            }
        }
        wasPlayingBeforeBackground = false
    }

    /// Handles app lifecycle transitions when entering the background.
    @objc private func handleDidEnterBackground(_ notification: Notification) {
        // If audio is supposed to keep playing, ensure the session stays active.
        // Also defensively "nudge" the player after a short delay in case iOS
        // auto-paused during the transition.
        let shouldKeepPlaying = isPlaying || wasPlayingBeforeBackground || shouldResumeAfterInterruption
        guard shouldKeepPlaying else { return }

        configureAudioSessionIfNeeded(force: true)
        updateNowPlayingInfo()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.configureAudioSessionIfNeeded(force: true)
            // If the system paused us during the transition, resume.
            if !self.isPlaying {
                if self.audioPlayer != nil || self.streamPlayer != nil {
                    self.resume()
                }
            }
        }
    }

    /// Handles app lifecycle transitions when returning to the foreground.
    @objc private func handleWillEnterForeground(_ notification: Notification) {
        // Keep the session consistent when returning.
        if isPlaying {
            configureAudioSessionIfNeeded(force: true)
            updateNowPlayingInfo()
        }
    }

    /// Handles audio route changes (e.g., headphones unplugged) for stable playback.
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // If headphones/Bluetooth disconnects, pause to avoid blasting audio.
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }
}


// MARK: - Sleep Timer

/// A simple sleep timer that can pause whatever AudioManager is currently playing.
/// Uses a 1-second ticking Timer so the UI can show a live countdown.
final class SleepTimerManager: ObservableObject {
    static let shared = SleepTimerManager()

    @Published private(set) var endDate: Date? = nil
    @Published private(set) var remainingSeconds: Int = 0

    private var ticker: Timer?

    var isActive: Bool { endDate != nil && remainingSeconds > 0 }

    private init() {}

    /// Sets the sleep timer duration and starts the countdown.
    func setTimer(minutes: Int) {
        guard minutes > 0 else {
            AppLog.action("Set sleep timer requested with non-positive duration: \(minutes) minute(s); cancelling")
            cancel()
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        AppLog.action("Set sleep timer: \(minutes) minute(s)")
        AppLog.info("Sleep timer end date: \(end)")
        endDate = end
        tick()
        startTicker()
    }

    /// Cancels the sleep timer and stops the countdown.
    func cancel() {
        if endDate != nil || remainingSeconds > 0 {
            AppLog.action("Cancel sleep timer: \(remainingSeconds) second(s) remaining")
        } else {
            AppLog.action("Cancel sleep timer: no active timer")
        }
        endDate = nil
        remainingSeconds = 0
        ticker?.invalidate()
        ticker = nil
    }

    /// Starts the repeating timer used to count down the sleep timer.
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        AppLog.info("Sleep timer ticker started")
        // Ensure the timer runs while scrolling / tracking UI interactions
        RunLoop.main.add(ticker!, forMode: .common)
    }

    /// Advances the sleep timer countdown and stops playback when it reaches zero.
    private func tick() {
        guard let end = endDate else {
            remainingSeconds = 0
            return
        }
        let seconds = Int(end.timeIntervalSinceNow.rounded(.down))
        if seconds <= 0 {
            // Time's up
            AppLog.action("Sleep timer expired; pausing playback")
            remainingSeconds = 0
            endDate = nil
            ticker?.invalidate()
            ticker = nil
            AudioManager.shared.pause()
        } else {
            remainingSeconds = seconds
        }
    }

    /// Formats the remaining sleep timer time for display.
    func formattedRemaining() -> String {
        let s = max(0, remainingSeconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        } else {
            return String(format: "%d:%02d", m, sec)
        }
    }
}
