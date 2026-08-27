# App Review Notes

This App Store build removes the bundled third-party radio-station catalog, remote station logos, and third-party streaming endpoints that were present in earlier review attempts.

The current build keeps these features:

- curated place browsing on the map and in lists;
- bundled offline demo audio for places;
- favorites, recents, sleep timer, and background playback for bundled local audio;
- user-added place pins and user-attached local photos/videos;
- user-saved memory titles/notes, local voice notes, and a local memory journal for revisiting saved places.

The current build no longer includes:

- bundled third-party radio streams;
- bundled third-party radio discovery/catalog data;
- remote station-logo fetching.

MindMap AI requests location only when the user explicitly chooses a location-based action, such as tapping the location control to center the map on the current area. The app does not start continuous location updates in the background or on launch.

The microphone permission is used only when the user chooses to record a local voice note for a saved place or capture audio while recording a pin video. Voice notes stay on device.


## 2026-03-24 Update
- Voice notes now use the shared playback bar and expanded player so users can pause, resume, stop, and favorite the associated saved place from the same controls.
- Removed bundled third-party-style music content from the user experience. Existing bundled audio resource files were replaced with local blank placeholders so no unverified music ships in the app bundle.
