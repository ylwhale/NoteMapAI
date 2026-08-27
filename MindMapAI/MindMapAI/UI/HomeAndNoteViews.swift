import SwiftUI
import UIKit

// MARK: - Home

/// The no-account starting point for capture, Ask, and recent local work.
struct MindMapHomeView: View {
    @EnvironmentObject private var store: MindMapStore
    @EnvironmentObject private var router: MindMapRouter
    @EnvironmentObject private var locationService: MindMapLocationService
    @Environment(\.openURL) private var openURL

    @FocusState private var captureBodyFocused: Bool
    @State private var showsCaptureDetails = false
    @State private var showsDiscardConfirmation = false
    @State private var isSaving = false
    @State private var askQuestion = ""
    @State private var feedback: MindMapLocalFeedback?
    @State private var suggestionToReview: TagSuggestion?

    private let tagEngine = TagSuggestionEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                    introduction
                    persistenceFeedback
                    quickCaptureCard
                    pendingSuggestionCard
                    askCard
                    recentNotesSection
                    recentPlansSection
                }
                .padding(.horizontal, MindMapSpacing.large)
                .padding(.top, MindMapSpacing.large)
                .padding(.bottom, MindMapSpacing.xxLarge)
                .mindMapReadableWidth()
            }
            .background(MindMapTheme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Discard this draft?", isPresented: $showsDiscardConfirmation) {
                Button("Keep editing", role: .cancel) { }
                Button("Discard draft", role: .destructive, action: discardCaptureDraft)
            } message: {
                Text("The unsaved text and optional context will be removed from this device.")
            }
            .sheet(item: $suggestionToReview) { suggestion in
                TagSuggestionReviewSheet(
                    suggestion: suggestion,
                    noteTitle: store.note(withID: suggestion.noteID)?.displayTitle ?? "Saved note",
                    onDecision: { decision, tags in
                        handleTagDecision(suggestion, decision: decision, tags: tags)
                    }
                )
                .interactiveDismissDisabled()
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text("Capture now. Reuse it later.")
                .mindMapTextStyle(.screenTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Save a thought in seconds, then search, verify, and turn your own notes into useful plans. Everything starts on this device - no account required.")
                .mindMapTextStyle(.supporting)
        }
    }

    @ViewBuilder
    private var persistenceFeedback: some View {
        if let feedback {
            MindMapCallout(
                kind: feedback.kind,
                title: feedback.title,
                message: feedback.message
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home_feedback")
        }

        if let message = store.persistenceMessage,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MindMapErrorCallout(
                title: "Local save needs attention",
                message: message
            )
            .accessibilityIdentifier("home_persistence_error")
        }

        if let locationMessage = locationService.lastErrorMessage {
            MindMapCallout(
                kind: .warning,
                title: "Saved without a new location",
                message: locationMessage
            ) {
                MindMapSecondaryButton(
                    title: "Dismiss",
                    systemImage: "xmark",
                    expands: false,
                    action: locationService.clearFailure
                )
            }
            .accessibilityIdentifier("home_location_warning")
        }
    }

    private var quickCaptureCard: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                    Text("What do you want to remember?")
                        .mindMapTextStyle(.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("The note is saved locally first. Title, date, place, and tags are optional.")
                        .mindMapTextStyle(.supporting)
                }

                captureBodyEditor

                DisclosureGroup("Optional context", isExpanded: $showsCaptureDetails) {
                    captureDetails
                        .padding(.top, MindMapSpacing.medium)
                }
                .font(.headline)
                .tint(MindMapTheme.accent)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .accessibilityIdentifier("capture_optional_context")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.medium) {
                        cancelCaptureButton
                        saveCaptureButton
                    }

                    VStack(spacing: MindMapSpacing.medium) {
                        saveCaptureButton
                        cancelCaptureButton
                    }
                }
            }
        }
    }

    private var captureBodyEditor: some View {
        ZStack(alignment: .topLeading) {
            if captureDraft.body.isEmpty {
                Text("Type a sentence, reminder, lesson, place, price, or idea...")
                    .foregroundStyle(MindMapTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: captureBinding(\.body))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 128)
                .focused($captureBodyFocused)
                .textInputAutocapitalization(.sentences)
                .accessibilityLabel("Note body")
                .accessibilityHint("Required. Plain text and emoji are supported. Every edit is saved as a local draft.")
                .accessibilityIdentifier("quick_capture_body")
        }
        .padding(MindMapSpacing.small)
        .background(
            MindMapTheme.surfaceMuted,
            in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                .stroke(
                    cleanedCaptureBody.isEmpty ? MindMapTheme.border : MindMapTheme.accent.opacity(0.42),
                    lineWidth: 1
                )
        }
    }

    private var captureDetails: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.large) {
            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                Text("Title")
                    .font(.subheadline.weight(.semibold))
                TextField("Optional title", text: captureBinding(\.title))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.sentences)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("quick_capture_title")
            }

            Divider()

            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                Toggle("Add an event date", isOn: captureEventDateEnabled)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .padding(.trailing, MindMapSpacing.small)
                    .accessibilityIdentifier("quick_capture_event_date_toggle")

                if captureDraft.eventDate != nil {
                    DatePicker(
                        "Event date",
                        selection: captureEventDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("quick_capture_event_date")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                Text("Trip or theme")
                    .font(.subheadline.weight(.semibold))
                TextField("Optional theme, course, or trip", text: captureBinding(\.tripTheme))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("quick_capture_theme")
            }

            Divider()
            captureLocationControls

            Label("Creation date and time are added automatically when you tap Save.", systemImage: "clock")
                .mindMapTextStyle(.caption)
        }
    }

    private var captureLocationControls: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            Toggle("Attach current location after save", isOn: locationCaptureEnabled)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .padding(.trailing, MindMapSpacing.small)
                .accessibilityIdentifier("quick_capture_location_toggle")

            if store.preferences.locationCaptureEnabled {
                if locationService.isAuthorized {
                    Label(
                        "The note will save immediately, then its current location will attach in the background.",
                        systemImage: "location.fill"
                    )
                    .mindMapTextStyle(.supporting)
                } else if locationService.canRequestPermission {
                    MindMapSecondaryButton(
                        title: "Allow location access",
                        systemImage: "location",
                        expands: false,
                        action: locationService.requestPermission
                    )
                    .accessibilityIdentifier("quick_capture_location_permission")
                } else {
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Text("Location access is off. Saving remains available without it.")
                            .mindMapTextStyle(.supporting)
                        MindMapSecondaryButton(
                            title: "Open iOS Settings",
                            systemImage: "gearshape",
                            expands: false,
                            action: openSystemSettings
                        )
                        .accessibilityIdentifier("quick_capture_open_location_settings")
                    }
                }
            }
        }
    }

    private var saveCaptureButton: some View {
        MindMapPrimaryButton(
            title: isSaving ? "Saving note" : "Save note",
            systemImage: "square.and.arrow.down",
            isLoading: isSaving,
            isDisabled: cleanedCaptureBody.isEmpty,
            action: saveCapture
        )
        .accessibilityIdentifier("quick_capture_save")
    }

    private var cancelCaptureButton: some View {
        MindMapSecondaryButton(
            title: "Cancel",
            systemImage: "xmark",
            isDisabled: captureDraft.isEmpty,
            action: requestCaptureCancellation
        )
        .accessibilityIdentifier("quick_capture_cancel")
    }

    @ViewBuilder
    private var pendingSuggestionCard: some View {
        if let suggestion = store.pendingTagSuggestion,
           let note = store.note(withID: suggestion.noteID) {
            MindMapCallout(
                kind: .info,
                title: "Tags ready for \(note.displayTitle)",
                message: "Review \(suggestion.tags.count) optional suggestion\(suggestion.tags.count == 1 ? "" : "s"). Your original note will not change."
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.medium) {
                        MindMapSecondaryButton(
                            title: "Review tags",
                            systemImage: "number",
                            expands: false,
                            action: { suggestionToReview = suggestion }
                        )
                        MindMapSecondaryButton(
                            title: "Not now",
                            systemImage: "clock",
                            expands: false,
                            action: {
                                store.decideTagSuggestion(suggestion.id, decision: .ignored)
                            }
                        )
                    }

                    VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                        MindMapSecondaryButton(
                            title: "Review tags",
                            systemImage: "number",
                            action: { suggestionToReview = suggestion }
                        )
                        MindMapSecondaryButton(
                            title: "Not now",
                            systemImage: "clock",
                            action: {
                                store.decideTagSuggestion(suggestion.id, decision: .ignored)
                            }
                        )
                    }
                }
            }
            .accessibilityIdentifier("pending_tag_suggestion")
        }
    }

    private var askCard: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                MindMapSectionHeader(
                    title: "Ask your notes",
                    subtitle: "Start with a question. MindMap AI searches the full local library before any AI processing."
                )

                TextField(
                    "What should I plan, compare, or remember?",
                    text: $askQuestion,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, MindMapSpacing.medium)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .background(
                    MindMapTheme.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control)
                )
                .submitLabel(.go)
                .onSubmit(openAsk)
                .accessibilityIdentifier("home_ask_question")

                MindMapPrimaryButton(
                    title: "Ask your notes",
                    systemImage: "sparkles",
                    isDisabled: askQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    expands: false,
                    action: openAsk
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("home_open_ask")
            }
        }
    }

    @ViewBuilder
    private var recentNotesSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Recent notes",
                subtitle: "Newest local captures first.",
                actionTitle: store.notes.isEmpty ? nil : "Open Library",
                action: store.notes.isEmpty ? nil : { router.openLibrary() }
            )

            if store.notes.isEmpty {
                MindMapEmptyState(
                    title: "No notes yet",
                    message: "Your first saved thought will appear here."
                )
            } else {
                ForEach(store.notes.prefix(3)) { note in
                    NavigationLink {
                        NoteEditorView(noteID: note.id)
                    } label: {
                        MindNoteSummaryCard(note: note)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open note \(note.displayTitle)")
                    .accessibilityHint("Opens the note for editing")
                    .accessibilityIdentifier("recent_note_\(note.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("home_recent_notes")
    }

    @ViewBuilder
    private var recentPlansSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Recent plans",
                subtitle: "Editable conclusions and checklists saved from Ask.",
                actionTitle: store.plans.isEmpty ? nil : "Open Plans",
                action: store.plans.isEmpty ? nil : { router.openPlans() }
            )

            if store.plans.isEmpty {
                MindMapEmptyState(
                    title: "No plans yet",
                    message: "Ask a question, verify the sources, then save an editable plan.",
                    actionTitle: "Ask your notes",
                    action: { router.openAsk() }
                )
            } else {
                ForEach(store.plans.prefix(2)) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan)
                    } label: {
                        MindPlanSummaryCard(plan: plan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open plan \(plan.title)")
                    .accessibilityIdentifier("recent_plan_\(plan.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("home_recent_plans")
    }

    private var captureDraft: CaptureDraft { store.preferences.captureDraft }

    private var cleanedCaptureBody: String {
        captureDraft.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func captureBinding<Value>(
        _ keyPath: WritableKeyPath<CaptureDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.preferences.captureDraft[keyPath: keyPath] },
            set: { newValue in
                var draft = store.preferences.captureDraft
                draft[keyPath: keyPath] = newValue
                store.updateCaptureDraft(draft)
                if feedback?.kind == .success { feedback = nil }
            }
        )
    }

    private var captureEventDateEnabled: Binding<Bool> {
        Binding(
            get: { captureDraft.eventDate != nil },
            set: { enabled in
                var draft = captureDraft
                draft.eventDate = enabled ? (draft.eventDate ?? .now) : nil
                store.updateCaptureDraft(draft)
            }
        )
    }

    private var captureEventDate: Binding<Date> {
        Binding(
            get: { captureDraft.eventDate ?? .now },
            set: { date in
                var draft = captureDraft
                draft.eventDate = date
                store.updateCaptureDraft(draft)
            }
        )
    }

    private var locationCaptureEnabled: Binding<Bool> {
        Binding(
            get: { store.preferences.locationCaptureEnabled },
            set: { store.preferences.locationCaptureEnabled = $0 }
        )
    }

    private func requestCaptureCancellation() {
        guard !captureDraft.isEmpty else { return }
        showsDiscardConfirmation = true
    }

    private func discardCaptureDraft() {
        store.clearCaptureDraft()
        guard store.preferences.captureDraft.isEmpty else {
            feedback = .error(
                title: "Draft not discarded",
                message: store.persistenceMessage
                    ?? "The draft could not be removed from local storage. Keep editing and try again."
            )
            return
        }

        showsCaptureDetails = false
        captureBodyFocused = false
        feedback = .info(
            title: "Draft discarded",
            message: "The unsaved capture was removed. Your saved notes were not changed."
        )
    }

    private func saveCapture() {
        guard !isSaving else { return }
        let draft = captureDraft
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback = .error(
                title: "A note needs text",
                message: "Write something you want to remember before saving."
            )
            captureBodyFocused = true
            return
        }

        isSaving = true
        feedback = nil
        let shouldAttachLocation = store.preferences.locationCaptureEnabled
            && locationService.isAuthorized

        do {
            let existingTags = store.acceptedTags
            let note = try store.createNote(from: draft)
            // `createNote` is idempotent by capture-session ID. Clearing here also handles a
            // repeated invocation that returns the already-saved note.
            store.clearCaptureDraft()
            showsCaptureDetails = false
            captureBodyFocused = false
            isSaving = false
            feedback = .success(
                title: "Note saved",
                message: shouldAttachLocation
                    ? "The note is safe on this device. Location and optional tags are being added in the background."
                    : "The note is safe on this device. Optional tags are being prepared in the background."
            )

            createTagSuggestion(for: note, existingTags: existingTags)
            if shouldAttachLocation {
                attachCurrentLocation(to: note.id)
            }
        } catch {
            isSaving = false
            feedback = .error(title: "Note not saved", message: error.localizedDescription)
        }
    }

    private func createTagSuggestion(for note: MindNote, existingTags: [String]) {
        Task { @MainActor in
            await Task.yield()
            let tags = tagEngine.suggestTags(for: note, existingTags: existingTags)
            guard !tags.isEmpty else { return }
            let suggestion = TagSuggestion(noteID: note.id, tags: tags)
            store.addTagSuggestion(suggestion)
            suggestionToReview = suggestion
        }
    }

    private func attachCurrentLocation(to noteID: UUID) {
        Task { @MainActor in
            if let place = await locationService.captureCurrentPlace() {
                guard store.preferences.locationCaptureEnabled,
                      locationService.isAuthorized else { return }
                store.attachLocation(place, to: noteID)
            }
        }
    }

    private func handleTagDecision(
        _ suggestion: TagSuggestion,
        decision: TagSuggestionDecision,
        tags: [String]
    ) {
        store.decideTagSuggestion(suggestion.id, decision: decision, editedTags: tags)
        suggestionToReview = nil

        switch decision {
        case .accepted:
            feedback = .success(
                title: "Tags added",
                message: "The selected labels are now searchable. The original note text is unchanged."
            )
        case .rejected:
            feedback = .info(
                title: "Suggestions rejected",
                message: "No tags were added. The saved note is unchanged."
            )
        case .ignored:
            feedback = .info(
                title: "Tag review closed",
                message: "No tags were added. You can edit the note later."
            )
        case .pending:
            break
        }
    }

    private func openAsk() {
        let question = askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        router.openAsk(question: question)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Note editor

/// Full local editor for an existing note. Cancel never mutates the stored version; Save validates
/// the body and atomically replaces it through `MindMapStore`.
struct NoteEditorView: View {
    @EnvironmentObject private var store: MindMapStore
    @EnvironmentObject private var locationService: MindMapLocationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let noteID: UUID

    @State private var draft: MindNote?
    @State private var savedVersion: MindNote?
    @State private var didLoad = false
    @State private var newTag = ""
    @State private var feedback: MindMapLocalFeedback?
    @State private var showsDiscardConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var isUpdatingLocation = false
    @State private var suggestionToReview: TagSuggestion?

    private let tagEngine = TagSuggestionEngine()

    init(noteID: UUID) {
        self.noteID = noteID
    }

    var body: some View {
        ScrollView {
            Group {
                if !didLoad {
                    ProgressView("Opening note")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if draft == nil {
                    missingNoteState
                } else {
                    editorContent
                }
            }
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.top, MindMapSpacing.large)
            .padding(.bottom, MindMapSpacing.xxLarge)
            .mindMapReadableWidth(MindMapLayout.maxFormWidth)
        }
        .background(MindMapTheme.background.ignoresSafeArea())
        .navigationTitle(draft?.displayTitle ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(didLoad && draft != nil)
        .toolbar { editorToolbar }
        .onAppear(perform: loadNote)
        .alert("Discard changes?", isPresented: $showsDiscardConfirmation) {
            Button("Keep editing", role: .cancel) { }
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Unsaved edits will be lost. The last saved version will stay on this device.")
        }
        .alert("Delete this note?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: deleteNote)
        } message: {
            Text("This removes the note from the library, search, map, future Ask results, and linked references. This cannot be undone.")
        }
        .sheet(item: $suggestionToReview) { suggestion in
            TagSuggestionReviewSheet(
                suggestion: suggestion,
                noteTitle: draft?.displayTitle ?? "Note",
                onDecision: { decision, tags in
                    handleTagDecision(suggestion, decision: decision, tags: tags)
                }
            )
            .interactiveDismissDisabled()
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if didLoad, draft != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: requestDismissal)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_cancel")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: toggleFavorite) {
                    Image(systemName: draft?.isFavorite == true ? "star.fill" : "star")
                        .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
                }
                .accessibilityLabel(draft?.isFavorite == true ? "Remove from favorites" : "Add to favorites")
                .accessibilityIdentifier("note_editor_favorite")

                Button("Save", action: saveNote)
                    .disabled(!canSave)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_save_toolbar")
            }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
            if let feedback {
                MindMapCallout(
                    kind: feedback.kind,
                    title: feedback.title,
                    message: feedback.message
                )
                .accessibilityIdentifier("note_editor_feedback")
            }

            if let message = store.persistenceMessage,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MindMapErrorCallout(title: "Local save needs attention", message: message)
            }

            noteTextSection
            noteDatesAndThemeSection
            noteTagsSection
            notePlaceSection
            noteMetadataSection

            MindMapPrimaryButton(
                title: "Save changes",
                systemImage: "square.and.arrow.down",
                isDisabled: !canSave,
                action: saveNote
            )
            .accessibilityIdentifier("note_editor_save")

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("Delete note", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .tint(MindMapTheme.error)
            .accessibilityIdentifier("note_editor_delete")
        }
    }

    private var noteTextSection: some View {
        NoteFormSection(
            title: "Note",
            subtitle: "The body is required. Plain text and emoji are supported."
        ) {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text("Body")
                        .font(.subheadline.weight(.semibold))

                    ZStack(alignment: .topLeading) {
                        if draft?.body.isEmpty != false {
                            Text("Write something you want to remember...")
                                .foregroundStyle(MindMapTheme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: noteBinding(\.body, fallback: ""))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 156)
                            .textInputAutocapitalization(.sentences)
                            .accessibilityLabel("Note body")
                            .accessibilityIdentifier("note_editor_body")
                    }
                    .padding(MindMapSpacing.small)
                    .background(
                        MindMapTheme.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control)
                    )
                }

                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text("Title")
                        .font(.subheadline.weight(.semibold))
                    TextField("Optional title", text: noteBinding(\.title, fallback: ""))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.sentences)
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                        .accessibilityIdentifier("note_editor_title")
                }
            }
        }
    }

    private var noteDatesAndThemeSection: some View {
        NoteFormSection(
            title: "Date and theme",
            subtitle: "Optional context stays visible, editable, and removable."
        ) {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                Toggle("Add an event date", isOn: noteEventDateEnabled)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_event_date_toggle")

                if draft?.eventDate != nil {
                    DatePicker(
                        "Event date",
                        selection: noteEventDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_event_date")
                }

                Divider()

                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text("Trip or theme")
                        .font(.subheadline.weight(.semibold))
                    TextField(
                        "Optional theme, course, or trip",
                        text: noteBinding(\.tripTheme, fallback: "")
                    )
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_theme")
                }
            }
        }
    }

    private var noteTagsSection: some View {
        NoteFormSection(
            title: "Accepted tags",
            subtitle: "Edit or remove labels without changing the original note text."
        ) {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                if let tags = draft?.acceptedTags, tags.isEmpty {
                    Label("No accepted tags", systemImage: "number")
                        .mindMapTextStyle(.supporting)
                } else {
                    ForEach(Array((draft?.acceptedTags ?? []).indices), id: \.self) { index in
                        HStack(spacing: MindMapSpacing.small) {
                            TextField("Tag", text: tagBinding(at: index))
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)
                                .accessibilityLabel("Tag \(index + 1)")

                            Button(role: .destructive) {
                                removeTag(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(
                                        width: MindMapLayout.minimumTapTarget,
                                        height: MindMapLayout.minimumTapTarget
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(index + 1)")
                        }
                    }
                }

                HStack(spacing: MindMapSpacing.small) {
                    TextField("Add a tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                        .submitLabel(.done)
                        .onSubmit(addTag)
                        .accessibilityIdentifier("note_editor_new_tag")

                    Button(action: addTag) {
                        Image(systemName: "plus")
                            .frame(
                                width: MindMapLayout.minimumTapTarget,
                                height: MindMapLayout.minimumTapTarget
                            )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MindMapTheme.primaryActionFill)
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add tag")
                }

                MindMapSecondaryButton(
                    title: "Suggest relevant tags",
                    systemImage: "sparkles",
                    expands: false,
                    action: suggestTagsForDraft
                )
                .accessibilityIdentifier("note_editor_suggest_tags")
            }
        }
    }

    private var notePlaceSection: some View {
        NoteFormSection(
            title: "Place",
            subtitle: "Location is permission-based and can be edited, refreshed, or removed."
        ) {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                Toggle("Allow location attachment", isOn: locationCaptureEnabled)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .accessibilityIdentifier("note_editor_location_toggle")

                if draft?.place != nil {
                    TextField("Place name", text: placeNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                        .accessibilityIdentifier("note_editor_place_name")

                    TextField("Place details", text: placeDetailBinding, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                        .accessibilityIdentifier("note_editor_place_detail")

                    if let place = draft?.place {
                        Text("Coordinates: \(place.coordinateDescription)")
                            .mindMapTextStyle(.caption)
                    }

                    MindMapSecondaryButton(
                        title: "Remove place",
                        systemImage: "mappin.slash",
                        expands: false,
                        action: removePlace
                    )
                    .accessibilityIdentifier("note_editor_remove_place")
                }

                locationEditorAction

                if let locationMessage = locationService.lastErrorMessage {
                    Text(locationMessage)
                        .font(.caption)
                        .foregroundStyle(MindMapTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var locationEditorAction: some View {
        if store.preferences.locationCaptureEnabled {
            if locationService.isAuthorized {
                MindMapSecondaryButton(
                    title: draft?.place == nil ? "Attach current location" : "Refresh current location",
                    systemImage: "location.fill",
                    isDisabled: isUpdatingLocation,
                    expands: false,
                    action: updateCurrentLocation
                )
                .accessibilityIdentifier("note_editor_attach_location")

                if isUpdatingLocation {
                    ProgressView("Finding current location")
                        .controlSize(.small)
                }
            } else if locationService.canRequestPermission {
                MindMapSecondaryButton(
                    title: "Allow location access",
                    systemImage: "location",
                    expands: false,
                    action: locationService.requestPermission
                )
                .accessibilityIdentifier("note_editor_location_permission")
            } else {
                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text("Location access is off. This note remains fully editable without it.")
                        .mindMapTextStyle(.supporting)
                    MindMapSecondaryButton(
                        title: "Open iOS Settings",
                        systemImage: "gearshape",
                        expands: false,
                        action: openSystemSettings
                    )
                }
            }
        }
    }

    private var noteMetadataSection: some View {
        NoteFormSection(title: "Saved context") {
            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                if let draft {
                    Label(
                        "Created \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "clock"
                    )
                    Label(
                        "Updated \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    Label(
                        draft.isFavorite ? "Favorite note" : "Not a favorite",
                        systemImage: draft.isFavorite ? "star.fill" : "star"
                    )
                }
            }
            .mindMapTextStyle(.supporting)
        }
    }

    private var missingNoteState: some View {
        MindMapEmptyState(
            title: "Note not found",
            message: "It may have been deleted from this device.",
            actionTitle: "Close",
            action: { dismiss() }
        )
    }

    private var isDirty: Bool {
        guard let draft, let savedVersion else { return false }
        return draft != savedVersion
    }

    private var canSave: Bool {
        guard let draft else { return false }
        return !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isDirty
    }

    private func loadNote() {
        guard !didLoad else { return }
        didLoad = true
        draft = store.note(withID: noteID)
        savedVersion = draft
    }

    private func noteBinding<Value>(
        _ keyPath: WritableKeyPath<MindNote, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                updateDraft { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func updateDraft(_ mutation: (inout MindNote) -> Void) {
        guard var note = draft else { return }
        mutation(&note)
        draft = note
        if feedback?.kind == .success { feedback = nil }
    }

    private var noteEventDateEnabled: Binding<Bool> {
        Binding(
            get: { draft?.eventDate != nil },
            set: { enabled in
                updateDraft { $0.eventDate = enabled ? ($0.eventDate ?? .now) : nil }
            }
        )
    }

    private var noteEventDate: Binding<Date> {
        Binding(
            get: { draft?.eventDate ?? .now },
            set: { date in updateDraft { $0.eventDate = date } }
        )
    }

    private var locationCaptureEnabled: Binding<Bool> {
        Binding(
            get: { store.preferences.locationCaptureEnabled },
            set: { store.preferences.locationCaptureEnabled = $0 }
        )
    }

    private func tagBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let tags = draft?.acceptedTags, tags.indices.contains(index) else { return "" }
                return tags[index]
            },
            set: { value in
                updateDraft { note in
                    guard note.acceptedTags.indices.contains(index) else { return }
                    note.acceptedTags[index] = value
                }
            }
        )
    }

    private func addTag() {
        let tag = TagSuggestionEngine.normalizedTag(newTag)
        guard !tag.isEmpty else { return }
        updateDraft { note in
            let existing = Set(note.acceptedTags.map { TagSuggestionEngine.normalizedTag($0) })
            guard !existing.contains(tag), note.acceptedTags.count < 12 else { return }
            note.acceptedTags.append(tag)
        }
        newTag = ""
    }

    private func removeTag(at index: Int) {
        updateDraft { note in
            guard note.acceptedTags.indices.contains(index) else { return }
            note.acceptedTags.remove(at: index)
        }
    }

    private var placeNameBinding: Binding<String> {
        Binding(
            get: { draft?.place?.name ?? "" },
            set: { name in
                updateDraft { note in
                    guard var place = note.place else { return }
                    place.name = name
                    note.place = place
                }
            }
        )
    }

    private var placeDetailBinding: Binding<String> {
        Binding(
            get: { draft?.place?.detail ?? "" },
            set: { detail in
                updateDraft { note in
                    guard var place = note.place else { return }
                    place.detail = detail
                    note.place = place
                }
            }
        )
    }

    private func removePlace() {
        updateDraft { $0.place = nil }
        locationService.clearCapturedPlace()
        feedback = .info(
            title: "Place removed",
            message: "Save changes to remove this note from location search and the map."
        )
    }

    private func updateCurrentLocation() {
        guard !isUpdatingLocation else { return }
        isUpdatingLocation = true
        locationService.clearFailure()

        Task { @MainActor in
            let place = await locationService.captureCurrentPlace()
            isUpdatingLocation = false
            if let place {
                updateDraft { $0.place = place }
                feedback = .success(
                    title: "Current location attached",
                    message: "Review the editable place details, then save the note."
                )
            } else {
                feedback = .warning(
                    title: "Location not attached",
                    message: locationService.lastErrorMessage
                        ?? "The note is still available and can be saved without a place."
                )
            }
        }
    }

    private func suggestTagsForDraft() {
        guard let draft, persistedNoteStillMatchesBaseline() else {
            showExternalEditConflict()
            return
        }
        let tags = tagEngine.suggestTags(for: draft, existingTags: store.acceptedTags)
        guard !tags.isEmpty else {
            feedback = .info(
                title: "No new tags suggested",
                message: "The existing labels already cover this note, or there is not enough context yet."
            )
            return
        }

        let suggestion = TagSuggestion(noteID: noteID, tags: tags)
        store.addTagSuggestion(suggestion)
        suggestionToReview = suggestion
    }

    private func handleTagDecision(
        _ suggestion: TagSuggestion,
        decision: TagSuggestionDecision,
        tags: [String]
    ) {
        guard persistedNoteStillMatchesBaseline() else {
            suggestionToReview = nil
            showExternalEditConflict()
            return
        }
        store.decideTagSuggestion(suggestion.id, decision: decision, editedTags: tags)
        suggestionToReview = nil

        if decision == .accepted {
            let normalizedTags = tags.map { TagSuggestionEngine.normalizedTag($0) }.filter { !$0.isEmpty }
            updateDraft { note in
                var seen = Set(note.acceptedTags.map { TagSuggestionEngine.normalizedTag($0) })
                for tag in normalizedTags where seen.insert(tag).inserted {
                    note.acceptedTags.append(tag)
                }
            }
            synchronizePersistedMetadata()
            feedback = .success(
                title: "Tags accepted",
                message: "The labels are searchable now. Save any other edits when ready."
            )
        } else if decision == .rejected {
            feedback = .info(title: "Suggestions rejected", message: "No tags were added.")
        } else if decision == .ignored {
            feedback = .info(title: "Tag review closed", message: "No tags were added.")
        }
    }

    private func synchronizePersistedMetadata() {
        guard let persisted = store.note(withID: noteID), var currentDraft = draft else { return }
        currentDraft.acceptedTags = persisted.acceptedTags
        currentDraft.isFavorite = persisted.isFavorite
        savedVersion = persisted
        currentDraft.updatedAt = persisted.updatedAt
        draft = currentDraft
    }

    private func toggleFavorite() {
        guard let current = draft, persistedNoteStillMatchesBaseline() else {
            showExternalEditConflict()
            return
        }
        let requestedValue = !current.isFavorite
        guard store.setFavorite(requestedValue, noteID: noteID) else {
            feedback = .error(
                title: "Favorite not changed",
                message: store.persistenceMessage ?? "The local store could not save this change."
            )
            return
        }
        guard let persisted = store.note(withID: noteID), var currentDraft = draft else { return }
        guard persisted.isFavorite == requestedValue else {
            feedback = .error(
                title: "Favorite not changed",
                message: store.persistenceMessage ?? "The local store could not save this change."
            )
            return
        }
        currentDraft.isFavorite = persisted.isFavorite
        currentDraft.updatedAt = persisted.updatedAt
        draft = currentDraft
        savedVersion = persisted
        feedback = .success(
            title: persisted.isFavorite ? "Added to favorites" : "Removed from favorites",
            message: "The change was saved on this device."
        )
    }

    private func persistedNoteStillMatchesBaseline() -> Bool {
        guard let savedVersion,
              let persisted = store.note(withID: noteID) else { return false }
        return persisted.updatedAt == savedVersion.updatedAt
    }

    private func showExternalEditConflict() {
        feedback = .error(
            title: "Note changed elsewhere",
            message: "This note was edited after you opened it. Close and reopen it before changing tags, favorites, or text so newer changes are not overwritten."
        )
    }

    private func saveNote() {
        guard let draft else { return }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback = .error(
                title: "A note needs text",
                message: "The body is the only required field and cannot be empty."
            )
            return
        }

        guard let expectedVersion = savedVersion,
              let currentVersion = store.note(withID: noteID),
              currentVersion.updatedAt == expectedVersion.updatedAt else {
            feedback = .error(
                title: "Note changed elsewhere",
                message: "This note was edited after you opened it. Close and reopen the note before saving so newer changes are not overwritten."
            )
            return
        }

        do {
            try store.updateNote(draft)
            guard let persisted = store.note(withID: noteID) else { return }
            self.draft = persisted
            savedVersion = persisted
            feedback = .success(
                title: "Changes saved",
                message: "The note and its editable context are safe on this device."
            )
        } catch {
            feedback = .error(title: "Changes not saved", message: error.localizedDescription)
        }
    }

    private func requestDismissal() {
        if isDirty {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func deleteNote() {
        if store.deleteNote(noteID) {
            dismiss()
        } else {
            feedback = .error(
                title: "Note not deleted",
                message: store.persistenceMessage ?? "The local store could not save this deletion."
            )
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Shared private UI

private struct NoteFormSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                MindMapSectionHeader(title: title, subtitle: subtitle)
                content
            }
        }
    }
}

private struct TagSuggestionReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let suggestion: TagSuggestion
    let noteTitle: String
    let onDecision: (TagSuggestionDecision, [String]) -> Void

    @State private var editedTags: [String]
    @State private var newTag = ""

    init(
        suggestion: TagSuggestion,
        noteTitle: String,
        onDecision: @escaping (TagSuggestionDecision, [String]) -> Void
    ) {
        self.suggestion = suggestion
        self.noteTitle = noteTitle
        self.onDecision = onDecision
        _editedTags = State(initialValue: suggestion.tags)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Label("Optional AI organization", systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MindMapTheme.source)

                        Text("Review suggested tags")
                            .mindMapTextStyle(.screenTitle)
                            .accessibilityAddTraits(.isHeader)

                        Text("For \(noteTitle). Accept, edit, reject, or ignore these labels. The original note text will never be rewritten.")
                            .mindMapTextStyle(.supporting)
                    }

                    MindMapCard {
                        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                            ForEach(Array(editedTags.indices), id: \.self) { index in
                                HStack(spacing: MindMapSpacing.small) {
                                    TextField("Suggested tag", text: editedTagBinding(at: index))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                                        .accessibilityLabel("Suggested tag \(index + 1)")

                                    Button(role: .destructive) {
                                        editedTags.remove(at: index)
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(
                                                width: MindMapLayout.minimumTapTarget,
                                                height: MindMapLayout.minimumTapTarget
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove suggested tag \(index + 1)")
                                }
                            }

                            if editedTags.count < 3 {
                                HStack(spacing: MindMapSpacing.small) {
                                    TextField("Add another tag", text: $newTag)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                                        .submitLabel(.done)
                                        .onSubmit(addTag)
                                        .accessibilityIdentifier("tag_review_new_tag")

                                    Button(action: addTag) {
                                        Image(systemName: "plus")
                                            .frame(
                                                width: MindMapLayout.minimumTapTarget,
                                                height: MindMapLayout.minimumTapTarget
                                            )
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(MindMapTheme.primaryActionFill)
                                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityLabel("Add another tag")
                                }
                            }
                        }
                    }

                    MindMapPrimaryButton(
                        title: "Accept tags",
                        systemImage: "checkmark",
                        isDisabled: cleanedTags.isEmpty,
                        action: { finish(.accepted, tags: cleanedTags) }
                    )
                    .accessibilityIdentifier("tag_review_accept")

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MindMapSpacing.medium) {
                            MindMapSecondaryButton(
                                title: "Reject",
                                systemImage: "xmark",
                                action: { finish(.rejected, tags: []) }
                            )
                            MindMapSecondaryButton(
                                title: "Ignore for now",
                                systemImage: "clock",
                                action: { finish(.ignored, tags: []) }
                            )
                        }

                        VStack(spacing: MindMapSpacing.medium) {
                            MindMapSecondaryButton(
                                title: "Reject",
                                systemImage: "xmark",
                                action: { finish(.rejected, tags: []) }
                            )
                            MindMapSecondaryButton(
                                title: "Ignore for now",
                                systemImage: "clock",
                                action: { finish(.ignored, tags: []) }
                            )
                        }
                    }
                }
                .padding(MindMapSpacing.large)
                .mindMapReadableWidth(MindMapLayout.maxFormWidth)
            }
            .background(MindMapTheme.background.ignoresSafeArea())
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var cleanedTags: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in editedTags {
            let cleaned = TagSuggestionEngine.normalizedTag(tag)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return Array(result.prefix(3))
    }

    private func editedTagBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { editedTags.indices.contains(index) ? editedTags[index] : "" },
            set: { value in
                guard editedTags.indices.contains(index) else { return }
                editedTags[index] = value
            }
        )
    }

    private func addTag() {
        let cleaned = TagSuggestionEngine.normalizedTag(newTag)
        guard !cleaned.isEmpty,
              editedTags.count < 3,
              !cleanedTags.contains(cleaned) else { return }
        editedTags.append(cleaned)
        newTag = ""
    }

    private func finish(_ decision: TagSuggestionDecision, tags: [String]) {
        onDecision(decision, tags)
        dismiss()
    }
}

private struct MindMapLocalFeedback {
    var kind: MindMapCalloutKind
    var title: String
    var message: String

    static func success(title: String, message: String) -> Self {
        .init(kind: .success, title: title, message: message)
    }

    static func info(title: String, message: String) -> Self {
        .init(kind: .info, title: title, message: message)
    }

    static func warning(title: String, message: String) -> Self {
        .init(kind: .warning, title: title, message: message)
    }

    static func error(title: String, message: String) -> Self {
        .init(kind: .error, title: title, message: message)
    }
}
