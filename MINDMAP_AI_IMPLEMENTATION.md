# MindMap AI MVP v2.0

MindMap AI is an offline-first SwiftUI app for quickly capturing personal notes, organizing them with lightweight context, retrieving evidence, and turning grounded conclusions into reusable plans.

## Run the app

1. Open `NoteMap AI.xcodeproj` in Xcode.
2. Select the `MindMapAI` scheme and an iOS 17 or newer simulator/device.
3. Build and run. The installed app is named **MindMap AI**.

Capture, Library, map, filters, tags, plans, export, and keyword retrieval work locally. To generate an AI conclusion, open **Settings**, save an OpenAI API key in the iOS Keychain, choose an enabled model, and review the first-use processing disclosure.

## Privacy and grounding

- Notes, accepted tags, plans, and optional history use an atomic local archive plus a sanitized current-state recovery copy. Drafts and live permissions use a separate atomic sidecar so typing never rewrites the whole library and stale consent cannot be restored.
- Location capture is optional and permission-based. A saved place can be edited or removed from its note.
- An AI request contains only the question, displayed retrieval assumption, and relevant excerpts already shown in Ask. Each selected excerpt carries the retrieval reference time plus labeled capture time, explicit or text-derived event date, matched tags, and human-readable place context so the model can distinguish upcoming events from completed ones and when a note was captured from when its event occurs. It does not contain the full library. Precise coordinates are removed from saved location fields; coordinates deliberately typed into visible note text remain visible and are disclosed before consent.
- Large evidence sets are sent in bounded groups under one 20-second overall deadline. Each response is validated independently, then merged deterministically with cross-batch numeric/operator conflict detection.
- The provider response separates exact `source_fact` content from `generated_guidance`. Source facts still require known source IDs, verbatim displayed quotes, and contiguous relationship-preserving validation. AI guidance may synthesize useful planning, organization, study, and verification steps, but it must cite the notes that motivated it and cannot introduce or rearrange concrete names, numbers, dates, times, prices, or factual relationships.
- Responses that fail this grounding gate remain hidden by default. If the provider returned readable text, Ask can show it only after an explicit user choice with a persistent unverified warning; it is never treated as a grounded conclusion or eligible for plan saving.
- The OpenAI API key is stored separately in the iOS Keychain and is excluded from exports.
- Plan sharing starts with no sources selected and never includes note bodies or excerpts.
- Deleted-note tombstones retain no saved title/body-derived text or shareable date, and local deletion removes query references plus stale recovery artifacts.

## Main implementation areas

- `MindMapAI/Domain`: notes, sources, conclusions, plans, preferences, and persisted archive models.
- `MindMapAI/Store`: durable local storage, draft recovery, duplicate-save prevention, deletion cascades, history, and export.
- `MindMapAI/Services`: full-index retrieval, tag suggestions, location/connectivity, Keychain access, OpenAI Responses client, and grounding validation.
- `MindMapAI/UI`: Home, note editing, Library list/card/map views, Ask, conclusions, Plans, Settings, sharing, and accessible design components.

## Public-release boundary

The current implementation uses a user-supplied OpenAI API key. Before a public release, choose and deploy a production credential strategy (normally a server-side gateway), confirm provider retention/training controls, complete the privacy review, and run the PRD's student usability and retrieval-quality evaluation set.

## Verification

- Debug and Release simulator builds pass with no compiler warnings.
- 61 unit/service/privacy tests pass, including synthesized quiz-plan guidance, temporal retrieval regression coverage, adversarial invented-detail rejection, unverified-response opt-in handling, and in-flight consent revocation between AI batches.
- Five functional end-to-end UI tests cover onboarding, durable capture/relaunch, navigation and no-results recovery, local no-evidence behavior, and excerpt review before AI generation.
