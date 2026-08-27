import SwiftUI
import MapKit

/// The persistent, offline-first home for saved MindMap AI notes.
///
/// Search and Refine use `RetrievalEngine`, so title, body, accepted tags, dates,
/// trip themes, and saved place metadata are evaluated locally across the complete
/// note collection. Navigation stores IDs instead of note copies to avoid stale
/// destinations after an edit or deletion.
struct MindMapLibraryView: View {
    @EnvironmentObject private var store: MindMapStore
    @EnvironmentObject private var router: MindMapRouter
    @EnvironmentObject private var locationService: MindMapLocationService

    @State private var searchText = ""
    @State private var filters = RetrievalFilters()
    @State private var presentation: LibraryPresentation = .list
    @State private var showsRefine = false
    @State private var openNoteRoute: LibraryNoteRoute?
    @State private var notePendingDeletion: MindNote?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedMapNoteID: UUID?
    @State private var libraryErrorMessage: String?

    private let retrievalEngine = RetrievalEngine()

    var body: some View {
        NavigationStack {
            Group {
                if store.notes.isEmpty {
                    emptyLibrary
                } else if visibleNotes.isEmpty {
                    noResults
                } else {
                    libraryContent
                }
            }
            .background(MindMapTheme.background)
            .navigationTitle("Library")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search notes"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsRefine = true
                    } label: {
                        Label(refineButtonLabel, systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityHint("Opens tag, date, place, theme, and favorites filters")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createNote) {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .accessibilityHint("Opens quick capture")
                }
            }
        }
        .sheet(isPresented: $showsRefine) {
            LibraryRefineView(
                filters: filters,
                acceptedTags: store.acceptedTags,
                savedPlaces: availablePlaces,
                tripThemes: availableThemes
            ) { updatedFilters in
                filters = updatedFilters
            }
        }
        .sheet(item: $openNoteRoute, onDismiss: {
            selectedMapNoteID = nil
        }) { route in
            NavigationStack {
                NoteEditorView(noteID: route.id)
            }
            .environmentObject(store)
            .environmentObject(locationService)
        }
        .alert(
            "Delete note?",
            isPresented: deleteAlertIsPresented,
            presenting: notePendingDeletion
        ) { note in
            Button("Delete", role: .destructive) {
                deleteImmediately(note.id)
            }
            Button("Cancel", role: .cancel) {
                notePendingDeletion = nil
            }
        } message: { note in
            Text("“\(note.displayTitle)” will be removed from this device. Links from saved plans will be marked as deleted.")
        }
        .alert("Could not delete note", isPresented: Binding(
            get: { libraryErrorMessage != nil },
            set: { if !$0 { libraryErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { libraryErrorMessage = nil }
        } message: {
            Text(libraryErrorMessage ?? "The local store could not save this deletion.")
        }
        .onAppear {
            consumeRequestedLibraryQuery(router.requestedLibraryQuery)
            consumeRequestedLibraryNote(router.requestedLibraryNoteID)
        }
        .onChange(of: router.requestedLibraryQuery) { _, requestedQuery in
            consumeRequestedLibraryQuery(requestedQuery)
        }
        .onChange(of: router.requestedLibraryNoteID) { _, requestedNoteID in
            consumeRequestedLibraryNote(requestedNoteID)
        }
        .onChange(of: visibleLocatedNoteIDs) { _, _ in
            mapPosition = .automatic
            if let selectedMapNoteID,
               !visibleNotes.contains(where: { $0.id == selectedMapNoteID }) {
                self.selectedMapNoteID = nil
            }
        }
        .onChange(of: selectedMapNoteID) { _, noteID in
            guard let noteID, store.note(withID: noteID) != nil else { return }
            openNote(noteID)
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            libraryHeader

            switch presentation {
            case .list:
                notesList
            case .cards:
                notesCards
            case .map:
                notesMap
            }
        }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            Picker("Library view", selection: $presentation) {
                ForEach(LibraryPresentation.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(alignment: .firstTextBaseline, spacing: MindMapSpacing.medium) {
                Text(resultSummary)
                    .mindMapTextStyle(.supporting)
                    .accessibilityLabel(resultSummary)

                Spacer()

                Label("On this device", systemImage: "iphone")
                    .mindMapTextStyle(.caption)
                    .accessibilityLabel("Search runs on this device")
            }
        }
        .padding(.horizontal, MindMapSpacing.large)
        .padding(.top, MindMapSpacing.small)
        .padding(.bottom, MindMapSpacing.medium)
        .background(MindMapTheme.background)
    }

    private var notesList: some View {
        List {
            Section {
                ForEach(visibleNotes) { note in
                    LibraryNoteListRow(
                        note: note,
                        onOpen: { openNote(note.id) },
                        onToggleFavorite: { toggleFavorite(note) }
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: MindMapSpacing.small,
                            leading: MindMapSpacing.large,
                            bottom: MindMapSpacing.small,
                            trailing: MindMapSpacing.large
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        deleteButton(for: note)
                        favoriteButton(for: note)
                    }
                    .contextMenu {
                        noteContextMenu(for: note)
                    }
                }
            } header: {
                Text("Newest first")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Saved notes, newest first")
    }

    private var notesCards: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: MindMapSpacing.large)],
                alignment: .leading,
                spacing: MindMapSpacing.large
            ) {
                ForEach(visibleNotes) { note in
                    MindNoteSummaryCard(
                        note: note,
                        onOpen: { openNote(note.id) },
                        onToggleFavorite: { toggleFavorite(note) }
                    )
                    .contextMenu {
                        noteContextMenu(for: note)
                    }
                }
            }
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.bottom, MindMapSpacing.xLarge)
            .mindMapReadableWidth()
        }
        .accessibilityLabel("Saved note cards, newest first")
    }

    private var notesMap: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                if visibleLocatedNotes.isEmpty {
                    MindMapCallout(
                        kind: .info,
                        title: "No matching map locations",
                        message: "These notes are still available below. Add a saved place while editing a note to show it on the map."
                    )
                } else {
                    Map(position: $mapPosition, selection: $selectedMapNoteID) {
                        ForEach(visibleLocatedNotes) { note in
                            if let place = note.place {
                                Marker(
                                    note.displayTitle,
                                    systemImage: note.isFavorite ? "star.fill" : "note.text",
                                    coordinate: CLLocationCoordinate2D(
                                        latitude: place.latitude,
                                        longitude: place.longitude
                                    )
                                )
                                .tint(note.isFavorite ? MindMapTheme.warning : MindMapTheme.accent)
                                .tag(note.id)
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .frame(minHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: MindMapCornerRadius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: MindMapCornerRadius.card, style: .continuous)
                            .stroke(MindMapTheme.border.opacity(0.5), lineWidth: 1)
                    }
                    .accessibilityLabel("Map of \(visibleLocatedNotes.count) saved notes")
                    .accessibilityHint("Select a marker to open its note")
                }

                if !visibleUnlocatedNotes.isEmpty {
                    VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                        MindMapSectionHeader(
                            title: "Without a saved location",
                            subtitle: "These notes stay in your Library even though they cannot appear as map markers."
                        )

                        ForEach(visibleUnlocatedNotes) { note in
                            LibraryNoteListRow(
                                note: note,
                                onOpen: { openNote(note.id) },
                                onToggleFavorite: { toggleFavorite(note) }
                            )
                            .padding(MindMapSpacing.medium)
                            .mindMapCardSurface(elevated: false)
                            .contextMenu {
                                noteContextMenu(for: note)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.bottom, MindMapSpacing.xLarge)
            .mindMapReadableWidth()
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your Library is ready", systemImage: "books.vertical")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        } description: {
            Text("Save a thought, memory, or trip detail. Notes stay on this device and appear here newest first.")
                .font(.body)
                .lineLimit(nil)
        } actions: {
            Button("Create a note", action: createNote)
                .buttonStyle(MindMapPrimaryButtonStyle(expands: false))
        }
        .padding(MindMapSpacing.xLarge)
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("No matching notes", systemImage: "doc.text.magnifyingglass")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        } description: {
            Text(noResultsMessage)
                .font(.body)
                .lineLimit(nil)
        } actions: {
            VStack(spacing: MindMapSpacing.medium) {
                Button("Clear search and filters", action: clearSearchAndFilters)
                    .buttonStyle(MindMapPrimaryButtonStyle(expands: false))

                Button("Refine filters") {
                    showsRefine = true
                }
                .buttonStyle(MindMapSecondaryButtonStyle(expands: false))

                Button("Create a note", action: createNote)
                    .buttonStyle(MindMapSecondaryButtonStyle(expands: false))
            }
        }
        .padding(MindMapSpacing.xLarge)
    }

    private var visibleNotes: [MindNote] {
        let result = retrievalEngine.search(
            query: searchText,
            in: store.notes,
            filters: filters,
            clarifyVagueQuery: false
        )
        let matchingIDs = Set(result.sources.map(\.noteID))
        return store.notes
            .filter { matchingIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private var visibleLocatedNotes: [MindNote] {
        visibleNotes.filter { note in
            guard let place = note.place else { return false }
            return (-90...90).contains(place.latitude) && (-180...180).contains(place.longitude)
        }
    }

    private var visibleUnlocatedNotes: [MindNote] {
        let locatedIDs = Set(visibleLocatedNotes.map(\.id))
        return visibleNotes.filter { !locatedIDs.contains($0.id) }
    }

    private var visibleLocatedNoteIDs: [UUID] {
        visibleLocatedNotes.map(\.id)
    }

    private var availablePlaces: [String] {
        uniqueSortedValues(store.notes.compactMap { note in
            let place = note.place?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return place.isEmpty ? nil : place
        })
    }

    private var availableThemes: [String] {
        uniqueSortedValues(store.notes.compactMap { note in
            let theme = note.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
            return theme.isEmpty ? nil : theme
        })
    }

    private var activeFilterCount: Int {
        var count = 0
        if !filters.tag.isEmpty { count += 1 }
        if filters.date != .any { count += 1 }
        if !filters.place.isEmpty { count += 1 }
        if !filters.theme.isEmpty { count += 1 }
        if filters.favoritesOnly { count += 1 }
        return count
    }

    private var refineButtonLabel: String {
        activeFilterCount == 0 ? "Refine" : "Refine, \(activeFilterCount) active"
    }

    private var resultSummary: String {
        let count = visibleNotes.count
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filters.isActive {
            return "\(count) saved note\(count == 1 ? "" : "s") · newest first"
        }
        return "\(count) matching note\(count == 1 ? "" : "s") · newest first"
    }

    private var noResultsMessage: String {
        let cleanedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedQuery.isEmpty && filters.isActive {
            return "Nothing matches “\(cleanedQuery)” with the current Refine filters. Your search is preserved so you can adjust it."
        }
        if !cleanedQuery.isEmpty {
            return "Nothing in your saved note text or metadata matches “\(cleanedQuery)”. Your search is preserved."
        }
        return "No notes match the current Refine filters."
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { if !$0 { notePendingDeletion = nil } }
        )
    }

    private func uniqueSortedValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func openNote(_ noteID: UUID) {
        guard store.note(withID: noteID) != nil else { return }
        openNoteRoute = LibraryNoteRoute(id: noteID)
    }

    private func toggleFavorite(_ note: MindNote) {
        guard let current = store.note(withID: note.id) else { return }
        guard store.setFavorite(!current.isFavorite, noteID: current.id) else {
            libraryErrorMessage = store.persistenceMessage ?? "The favorite change could not be saved."
            return
        }
    }

    private func requestDelete(_ note: MindNote) {
        guard store.note(withID: note.id) != nil else { return }
        notePendingDeletion = note
    }

    private func deleteImmediately(_ noteID: UUID) {
        guard store.deleteNote(noteID) else {
            libraryErrorMessage = store.persistenceMessage ?? "The local store could not save this deletion."
            return
        }
        if openNoteRoute?.id == noteID {
            openNoteRoute = nil
        }
        if selectedMapNoteID == noteID {
            selectedMapNoteID = nil
        }
        notePendingDeletion = nil
    }

    private func clearSearchAndFilters() {
        searchText = ""
        filters = .init()
    }

    private func createNote() {
        router.selectedTab = .home
    }

    private func consumeRequestedLibraryQuery(_ requestedQuery: String?) {
        guard let requestedQuery else { return }
        searchText = requestedQuery
        router.requestedLibraryQuery = nil
    }

    private func consumeRequestedLibraryNote(_ requestedNoteID: UUID?) {
        guard let requestedNoteID else { return }
        router.requestedLibraryNoteID = nil
        openNote(requestedNoteID)
    }

    @ViewBuilder
    private func favoriteButton(for note: MindNote) -> some View {
        Button {
            toggleFavorite(note)
        } label: {
            Label(
                note.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: note.isFavorite ? "star.slash" : "star"
            )
        }
        .tint(MindMapTheme.warning)
    }

    @ViewBuilder
    private func deleteButton(for note: MindNote) -> some View {
        Button(role: .destructive) {
            requestDelete(note)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func noteContextMenu(for note: MindNote) -> some View {
        Button {
            openNote(note.id)
        } label: {
            Label("Open and edit", systemImage: "square.and.pencil")
        }

        Button {
            toggleFavorite(note)
        } label: {
            Label(
                note.isFavorite ? "Remove from favorites" : "Add to favorites",
                systemImage: note.isFavorite ? "star.slash" : "star"
            )
        }

        Divider()

        Button(role: .destructive) {
            requestDelete(note)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private enum LibraryPresentation: String, CaseIterable, Identifiable {
    case list
    case cards
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .cards: return "Cards"
        case .map: return "Map"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .cards: return "rectangle.grid.2x2"
        case .map: return "map"
        }
    }
}

private struct LibraryNoteRoute: Identifiable {
    let id: UUID
}

private struct LibraryNoteListRow: View {
    let note: MindNote
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MindMapSpacing.medium) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    Text(note.displayTitle)
                        .mindMapTextStyle(.cardTitle)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(note.body.trimmingCharacters(in: .whitespacesAndNewlines))
                        .mindMapTextStyle(.supporting)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MindMapSpacing.medium) {
                            metadata
                        }
                        VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                            metadata
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(note.displayTitle)")
            .accessibilityHint("Opens this note for editing")

            Button(action: onToggleFavorite) {
                Image(systemName: note.isFavorite ? "star.fill" : "star")
                    .font(.headline)
                    .foregroundStyle(note.isFavorite ? MindMapTheme.warning : MindMapTheme.textSecondary)
                    .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.vertical, MindMapSpacing.xSmall)
    }

    @ViewBuilder
    private var metadata: some View {
        Label(
            (note.eventDate ?? note.createdAt).formatted(date: .abbreviated, time: .omitted),
            systemImage: note.eventDate == nil ? "clock" : "calendar"
        )

        if let place = note.place {
            Label(place.name.isEmpty ? place.coordinateDescription : place.name, systemImage: "mappin.and.ellipse")
                .lineLimit(1)
        }

        if !note.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(note.tripTheme, systemImage: "sparkles")
                .lineLimit(1)
        }
    }
}

private struct LibraryRefineView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RetrievalFilters

    let acceptedTags: [String]
    let savedPlaces: [String]
    let tripThemes: [String]
    let onApply: (RetrievalFilters) -> Void

    init(
        filters: RetrievalFilters,
        acceptedTags: [String],
        savedPlaces: [String],
        tripThemes: [String],
        onApply: @escaping (RetrievalFilters) -> Void
    ) {
        _draft = State(initialValue: filters)
        self.acceptedTags = acceptedTags
        self.savedPlaces = savedPlaces
        self.tripThemes = tripThemes
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Favorites only", isOn: $draft.favoritesOnly)
                } footer: {
                    Text("Refine changes which local notes are shown. It never sends note data off this device.")
                }

                Section("Date") {
                    Picker("When", selection: $draft.date) {
                        ForEach(DateFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Accepted tag") {
                    Picker("Tag", selection: $draft.tag) {
                        Text("Any accepted tag").tag("")
                        ForEach(acceptedTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    TextField("Place name or detail", text: $draft.place)
                        .textInputAutocapitalization(.words)

                    if !savedPlaces.isEmpty {
                        suggestionMenu(
                            title: "Choose a saved place",
                            systemImage: "mappin.and.ellipse",
                            values: savedPlaces,
                            selection: $draft.place
                        )
                    }
                } header: {
                    Text("Place")
                } footer: {
                    Text("Matches saved place names and descriptions. Notes do not need coordinates to stay visible in List or Cards.")
                }

                Section("Trip theme") {
                    TextField("Theme", text: $draft.theme)
                        .textInputAutocapitalization(.words)

                    if !tripThemes.isEmpty {
                        suggestionMenu(
                            title: "Choose a saved theme",
                            systemImage: "sparkles",
                            values: tripThemes,
                            selection: $draft.theme
                        )
                    }
                }

                if draft.isActive {
                    Section {
                        Button("Clear all filters", role: .destructive) {
                            draft = .init()
                        }
                    }
                }
            }
            .navigationTitle("Refine Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        cleanDraft()
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func suggestionMenu(
        title: String,
        systemImage: String,
        values: [String],
        selection: Binding<String>
    ) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button(value) {
                    selection.wrappedValue = value
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: MindMapLayout.minimumTapTarget, alignment: .leading)
        }
    }

    private func cleanDraft() {
        draft.tag = draft.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.place = draft.place.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.theme = draft.theme.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resolves the note from the store on every render. A deleted note therefore
/// never leaves a stale editor backed by an out-of-date value.
private struct LibraryNoteEditorHost: View {
    @EnvironmentObject private var store: MindMapStore
    @Environment(\.dismiss) private var dismiss

    let noteID: UUID
    let onDelete: (UUID) -> Void

    var body: some View {
        Group {
            if let note = store.note(withID: noteID) {
                LibraryNoteEditorView(note: note, onDelete: onDelete)
                    .environmentObject(store)
            } else {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Note no longer available", systemImage: "trash")
                    } description: {
                        Text("This note was deleted from the Library.")
                    } actions: {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

/// Local fallback editor used until a shared app-wide `NoteEditorView` is added.
/// It is deliberately isolated behind `LibraryNoteEditorHost`, so integration can
/// replace this destination without changing Library routing or data ownership.
private struct LibraryNoteEditorView: View {
    @EnvironmentObject private var store: MindMapStore
    @Environment(\.dismiss) private var dismiss

    let noteID: UUID
    let onDelete: (UUID) -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var tripTheme: String
    @State private var isFavorite: Bool
    @State private var hasEventDate: Bool
    @State private var eventDate: Date
    @State private var hasPlace: Bool
    @State private var placeName: String
    @State private var placeDetail: String
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    private let createdAt: Date
    private let originalUpdatedAt: Date

    init(note: MindNote, onDelete: @escaping (UUID) -> Void) {
        noteID = note.id
        self.onDelete = onDelete
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
        _tagsText = State(initialValue: note.acceptedTags.joined(separator: ", "))
        _tripTheme = State(initialValue: note.tripTheme)
        _isFavorite = State(initialValue: note.isFavorite)
        _hasEventDate = State(initialValue: note.eventDate != nil)
        _eventDate = State(initialValue: note.eventDate ?? note.createdAt)
        _hasPlace = State(initialValue: note.place != nil)
        _placeName = State(initialValue: note.place?.name ?? "")
        _placeDetail = State(initialValue: note.place?.detail ?? "")
        _latitudeText = State(initialValue: note.place.map { String(format: "%.6f", $0.latitude) } ?? "")
        _longitudeText = State(initialValue: note.place.map { String(format: "%.6f", $0.longitude) } ?? "")
        createdAt = note.createdAt
        originalUpdatedAt = note.updatedAt
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Title (optional)", text: $title)

                    TextEditor(text: $bodyText)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Note text")
                }

                Section("Organize") {
                    Toggle("Favorite", isOn: $isFavorite)

                    TextField("Accepted tags, separated by commas", text: $tagsText)
                        .textInputAutocapitalization(.never)

                    TextField("Trip theme (optional)", text: $tripTheme)
                        .textInputAutocapitalization(.words)
                }

                Section("Date") {
                    Toggle("Add an event date", isOn: $hasEventDate)

                    if hasEventDate {
                        DatePicker(
                            "Event date",
                            selection: $eventDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section {
                    Toggle("Add a saved place", isOn: $hasPlace)

                    if hasPlace {
                        TextField("Place name", text: $placeName)
                            .textInputAutocapitalization(.words)
                        TextField("Place detail (optional)", text: $placeDetail)
                        TextField("Latitude", text: $latitudeText)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Longitude", text: $longitudeText)
                            .keyboardType(.numbersAndPunctuation)
                    }
                } header: {
                    Text("Place")
                } footer: {
                    if hasPlace {
                        Text("Valid latitude and longitude are required so this note can appear on the map.")
                    }
                }

                Section("Saved locally") {
                    LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last updated", value: originalUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    Button("Delete note", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .alert("Delete note?", isPresented: $showsDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete(noteID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the note from this device and marks its saved-plan links as deleted.")
        }
        .alert("Could not save note", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let note = store.note(withID: noteID) else { return false }
        return title != note.title
            || bodyText != note.body
            || parsedTags != note.acceptedTags
            || tripTheme != note.tripTheme
            || isFavorite != note.isFavorite
            || hasEventDate != (note.eventDate != nil)
            || (hasEventDate && eventDate != note.eventDate)
            || hasPlace != (note.place != nil)
            || (hasPlace && placeFieldsDiffer(from: note.place))
    }

    private var parsedTags: [String] {
        var seen = Set<String>()
        return tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func placeFieldsDiffer(from place: SavedPlace?) -> Bool {
        guard let place else { return true }
        return placeName != place.name
            || placeDetail != place.detail
            || Double(latitudeText) != place.latitude
            || Double(longitudeText) != place.longitude
    }

    private func save() {
        guard var note = store.note(withID: noteID) else {
            dismiss()
            return
        }

        let savedPlace: SavedPlace?
        if hasPlace {
            guard let latitude = parseCoordinate(latitudeText), (-90...90).contains(latitude),
                  let longitude = parseCoordinate(longitudeText), (-180...180).contains(longitude) else {
                errorMessage = "Enter a latitude from −90 to 90 and a longitude from −180 to 180."
                return
            }
            savedPlace = SavedPlace(
                name: placeName.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: placeDetail.trimmingCharacters(in: .whitespacesAndNewlines),
                latitude: latitude,
                longitude: longitude
            )
        } else {
            savedPlace = nil
        }

        note.title = title
        note.body = bodyText
        note.acceptedTags = parsedTags
        note.tripTheme = tripTheme
        note.isFavorite = isFavorite
        note.eventDate = hasEventDate ? eventDate : nil
        note.place = savedPlace

        do {
            try store.updateNote(note)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseCoordinate(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}
