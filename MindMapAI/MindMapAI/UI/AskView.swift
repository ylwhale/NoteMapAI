import SwiftUI

enum AIRequestBoundaryError: Error, Equatable {
    case consentRevoked
}

struct AskView: View {
    @EnvironmentObject private var store: MindMapStore
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @EnvironmentObject private var router: MindMapRouter

    let provider: any GroundedConclusionProviding
    let apiKeyStore: APIKeyStore

    @State private var session = AskSession(question: "", filters: .init())
    @State private var showsFilters = false
    @State private var showsDisclosure = false
    @State private var selectedSource: SourceReference?
    @State private var selectedSourceIDs: Set<UUID> = []
    @State private var activeTask: Task<Void, Never>?
    @State private var saveMessage: String?
    @State private var sourceVersions: [UUID: Date] = [:]
    @FocusState private var questionFocused: Bool

    private let retrievalEngine = RetrievalEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                    intro
                    questionCard

                    if showsFilters {
                        AskRefinePanel(filters: filtersBinding, availableTags: store.acceptedTags)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if session.phase != .idle {
                        statusContent
                    }

                    if !session.retrievalAssumption.isEmpty {
                        MindMapCallout(
                            kind: .info,
                            title: "Retrieval assumption",
                            message: session.retrievalAssumption
                        )
                        .accessibilityIdentifier("ask_retrieval_assumption")
                    }

                    if let conclusion = session.conclusion {
                        conclusionSection(conclusion)
                    }

                    if !session.sources.isEmpty {
                        evidenceSection
                    }

                    if !store.queryHistory.isEmpty, session.phase == .idle {
                        historySection
                    }
                }
                .padding(.horizontal, MindMapSpacing.large)
                .padding(.top, MindMapSpacing.large)
                .padding(.bottom, MindMapSpacing.xxLarge)
                .mindMapReadableWidth()
            }
            .background(MindMapTheme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsDisclosure) {
                AIProcessingDisclosureView(
                    sourceCount: selectedSources.count,
                    retrievalAssumption: session.retrievalAssumption,
                    onAccept: acceptDisclosure,
                    onDecline: declineDisclosure
                )
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
            }
            .sheet(item: $selectedSource) { source in
                SourceEvidenceSheet(
                    source: source,
                    note: store.note(withID: source.noteID)
                )
            }
            .alert("Plan saved", isPresented: Binding(
                get: { saveMessage != nil },
                set: { if !$0 { saveMessage = nil } }
            )) {
                Button("Open Plans") { router.openPlans() }
                Button("Stay here", role: .cancel) { }
            } message: {
                Text(saveMessage ?? "Your editable plan is ready.")
            }
            .onAppear {
                consumeRequestedQuestion()
                synchronizeDraft()
            }
            .onChange(of: router.requestedAskQuestion) { _, _ in
                consumeRequestedQuestion()
            }
            .onChange(of: store.notes) { _, _ in
                invalidateEvidenceIfNeeded()
            }
            .onChange(of: store.preferences.aiProcessingConsent) { _, consent in
                guard consent != .accepted else { return }
                guard session.phase == .generating || session.phase == .batching else { return }
                activeTask?.cancel()
                activeTask = nil
                session.conclusion = nil
                session.phase = .providerUnavailable
                session.errorMessage = "AI processing permission changed. The active request was stopped and no further note excerpts will be sent."
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text("Turn fragments into a supported answer")
                .mindMapTextStyle(.screenTitle)
                .accessibilityAddTraits(.isHeader)
            Text("MindMap AI searches your entire local library first, then uses only the evidence you can inspect below.")
                .mindMapTextStyle(.supporting)
        }
    }

    private var questionCard: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                Text("What do you want to figure out?")
                    .mindMapTextStyle(.cardTitle)

                ZStack(alignment: .topLeading) {
                    if questionBinding.wrappedValue.isEmpty {
                        Text("Based on my notes, what should I plan for the exam?")
                            .foregroundStyle(MindMapTheme.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: questionBinding)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 112)
                        .focused($questionFocused)
                        .accessibilityLabel("Question for your notes")
                        .accessibilityHint("MindMap AI will search your saved notes for relevant evidence")
                }
                .padding(MindMapSpacing.small)
                .background(MindMapTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.medium) {
                        refineButton
                        submitOrCancelButton
                    }
                    VStack(spacing: MindMapSpacing.medium) {
                        refineButton
                        submitOrCancelButton
                    }
                }
            }
        }
    }

    private var refineButton: some View {
        MindMapSecondaryButton(
            title: showsFilters ? "Hide filters" : "Refine",
            systemImage: "slider.horizontal.3",
            action: { withAnimation(.easeInOut(duration: 0.2)) { showsFilters.toggle() } }
        )
    }

    @ViewBuilder
    private var submitOrCancelButton: some View {
        if isWorking {
            MindMapSecondaryButton(
                title: "Cancel",
                systemImage: "xmark",
                action: cancel
            )
        } else {
            MindMapPrimaryButton(
                title: "Find evidence",
                systemImage: "sparkles",
                isDisabled: questionBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: submit
            )
            .accessibilityIdentifier("ask_submit")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session.phase {
        case .awaitingConsent:
            MindMapCallout(
                kind: selectedSourceIDs.isEmpty ? .warning : .info,
                title: "Review what will be sent",
                message: selectedSourceIDs.isEmpty
                    ? "Select at least one exact excerpt below before asking the AI to generate a conclusion."
                    : "Only the \(selectedSourceIDs.count) selected excerpt\(selectedSourceIDs.count == 1 ? "" : "s") and your question will be included in the AI request."
            ) {
                MindMapPrimaryButton(
                    title: "Generate with \(selectedSourceIDs.count) excerpt\(selectedSourceIDs.count == 1 ? "" : "s")",
                    systemImage: "checkmark.shield",
                    isDisabled: selectedSourceIDs.isEmpty,
                    expands: false,
                    action: continueAfterEvidenceReview
                )
                .accessibilityIdentifier("ask_generate_selected")
            }
        case .needsClarification:
            MindMapCallout(
                kind: .warning,
                title: "One detail will improve the answer",
                message: session.clarificationQuestion
            ) {
                MindMapSecondaryButton(
                    title: "Refine question",
                    systemImage: "pencil",
                    expands: false,
                    action: {
                        questionFocused = true
                    }
                )
            }
        case .noEvidence:
            MindMapCallout(
                kind: .empty,
                title: "No supported answer yet",
                message: "Your notes do not contain enough support for a conclusion. Your question is preserved."
            ) {
                HStack {
                    MindMapSecondaryButton(
                        title: "Adjust filters",
                        systemImage: "slider.horizontal.3",
                        expands: false,
                        action: { showsFilters = true }
                    )
                    MindMapSecondaryButton(
                        title: "Open Library",
                        systemImage: "books.vertical",
                        expands: false,
                        action: { router.openLibrary(query: questionBinding.wrappedValue) }
                    )
                }
            }
        case .offline:
            MindMapCallout(
                kind: .warning,
                title: "Conclusion generation needs a connection",
                message: "Your evidence, question, filters, notes, plans, and local search are still available."
            ) {
                MindMapSecondaryButton(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    expands: false,
                    action: retryGeneration
                )
            }
        case .providerUnavailable:
            MindMapCallout(
                kind: .warning,
                title: "AI provider unavailable",
                message: session.errorMessage
            ) {
                HStack {
                    MindMapSecondaryButton(
                        title: "Open Settings",
                        systemImage: "gearshape",
                        expands: false,
                        action: { router.openSettings() }
                    )
                    MindMapSecondaryButton(
                        title: "Retry",
                        systemImage: "arrow.clockwise",
                        expands: false,
                        action: retryGeneration
                    )
                }
            }
        case .failed:
            MindMapErrorCallout(
                title: "Conclusion not created",
                message: session.errorMessage,
                retryTitle: "Retry",
                onRetry: retryGeneration
            )
        case .cancelled:
            MindMapCallout(
                kind: .info,
                title: "Generation cancelled",
                message: "Your question, filters, and retrieved evidence are preserved."
            ) {
                MindMapSecondaryButton(
                    title: "Continue",
                    systemImage: "play.fill",
                    expands: false,
                    action: retryGeneration
                )
            }
        case .complete:
            MindMapStatusCallout(phase: session.phase, message: session.errorMessage)
        default:
            MindMapStatusCallout(phase: session.phase, message: session.errorMessage)
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Evidence",
                subtitle: canEditSourceSelection
                    ? "Review the exact local excerpts and choose which ones may be sent."
                    : "Ranked local matches. Tap any source to inspect the exact excerpt."
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: MindMapSpacing.small) {
                    MindMapCoverageChip(session: session)
                    Text("\(session.relevantTotal) relevant")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MindMapTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                    MindMapCoverageChip(session: session)
                    Text("\(session.relevantTotal) relevant notes")
                        .mindMapTextStyle(.supporting)
                }
            }

            if canEditSourceSelection {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.small) {
                        evidenceSelectionSummary
                        Spacer(minLength: MindMapSpacing.small)
                        selectionActions
                    }
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        evidenceSelectionSummary
                        selectionActions
                    }
                }
            } else if session.conclusion != nil {
                Label(
                    "\(selectedSourceIDs.count) excerpt\(selectedSourceIDs.count == 1 ? "" : "s") sent for this conclusion",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(MindMapTheme.success)
            }

            if !session.processingLimitMessage.isEmpty {
                MindMapCallout(
                    kind: .info,
                    title: "Processing coverage",
                    message: session.processingLimitMessage
                )
            }

            LazyVStack(spacing: MindMapSpacing.medium) {
                ForEach(session.sources) { source in
                    if canEditSourceSelection {
                        SourceSelectionCard(
                            source: source,
                            isSelected: selectedSourceIDs.contains(source.id),
                            onToggle: { toggleSourceSelection(source.id) },
                            onInspect: { selectedSource = source }
                        )
                    } else {
                        Button {
                            selectedSource = source
                        } label: {
                            SourceReferenceCard(
                                source: source,
                                requestSelection: sentStatus(for: source)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sourceAccessibilityLabel(source))
                        .accessibilityHint("Shows the supporting excerpt and original note")
                    }
                }
            }
        }
    }

    private var evidenceSelectionSummary: some View {
        Label(
            "\(selectedSourceIDs.count) of \(session.sources.count) selected",
            systemImage: "checklist"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(selectedSourceIDs.isEmpty ? MindMapTheme.warning : MindMapTheme.textSecondary)
        .accessibilityIdentifier("ask_selected_source_count")
    }

    private func sentStatus(for source: SourceReference) -> Bool? {
        guard session.conclusion != nil else { return nil }
        return selectedSourceIDs.contains(source.id)
    }

    private func sourceAccessibilityLabel(_ source: SourceReference) -> String {
        guard let sent = sentStatus(for: source) else {
            return "Open source \(source.noteTitle)."
        }
        return "Open source \(source.noteTitle). "
            + (sent ? "Sent for this conclusion." : "Not sent for this conclusion.")
    }

    private var selectionActions: some View {
        HStack(spacing: MindMapSpacing.small) {
            Button("Select all") {
                selectedSourceIDs = Set(session.sources.map(\.id))
            }
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .disabled(selectedSourceIDs.count == session.sources.count)

            Button("Deselect all") {
                selectedSourceIDs.removeAll()
            }
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .disabled(selectedSourceIDs.isEmpty)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
    }

    private func conclusionSection(_ conclusion: GroundedConclusion) -> some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Grounded conclusion",
                subtitle: "AI draft - verify the linked sources before reusing it."
            )

            if conclusion.directAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MindMapCallout(
                    kind: .empty,
                    title: "No supported conclusion",
                    message: "Your notes do not contain enough support for a conclusion. Review the missing information or refine your question."
                )
            } else {
                MindMapCard {
                    VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                        Text("Answer parts")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MindMapTheme.source)
                            .accessibilityIdentifier("ai_synthesized_answer")

                        ForEach(Array(conclusion.resolvedAnswerParts.enumerated()), id: \.element.id) { index, part in
                            answerPartView(part)

                            if index < conclusion.resolvedAnswerParts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }

            if !conclusion.statedAssumption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MindMapCallout(
                    kind: .warning,
                    title: "AI-stated assumption",
                    message: conclusion.statedAssumption
                )
            }

            if !conclusion.claims.isEmpty {
                VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                    Text("Supported details")
                        .mindMapTextStyle(.cardTitle)
                    ForEach(conclusion.claims) { claim in
                        MindMapCard(elevated: false) {
                            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                                Text(claim.text)
                                    .mindMapTextStyle(.body)
                                sourceChips(for: claim.evidence.map(\ .sourceNoteID))
                            }
                        }
                    }
                }
            }

            if !conclusion.conflicts.isEmpty {
                VStack(spacing: MindMapSpacing.medium) {
                    ForEach(conclusion.conflicts) { conflict in
                        MindMapCallout(
                            kind: .warning,
                            title: "Conflicting notes",
                            message: conflict.text
                        ) {
                            sourceChips(for: conflict.sourceNoteIDs)
                        }
                    }
                }
            }

            if !conclusion.missingInformation.isEmpty {
                MindMapCallout(
                    kind: .info,
                    title: "Missing information",
                    message: conclusion.missingInformation.map { "- \($0)" }.joined(separator: "\n")
                )
            }

            if !conclusion.suggestedChecklist.isEmpty {
                MindMapCard {
                    VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                        Text("Suggested plan steps")
                            .mindMapTextStyle(.cardTitle)
                            .accessibilityIdentifier("ai_generated_plan_steps")
                        ForEach(conclusion.suggestedChecklist) { item in
                            HStack(alignment: .top, spacing: MindMapSpacing.medium) {
                                Image(systemName: "square")
                                    .foregroundStyle(MindMapTheme.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                                    if let origin = item.origin {
                                        Label(origin.displayLabel, systemImage: origin.systemImage)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(
                                                origin == .sourceBacked
                                                    ? MindMapTheme.success
                                                    : MindMapTheme.source
                                            )
                                    }
                                    Text(item.text)
                                        .mindMapTextStyle(.body)
                                    if let evidence = item.evidence, !evidence.isEmpty {
                                        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                                            ForEach(evidence) { citation in
                                                answerCitationView(citation)
                                            }
                                        }
                                    } else {
                                        // Legacy conclusions retain their linked sources even
                                        // though they predate exact step-level quote storage.
                                        sourceChips(for: item.sourceNoteIDs)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !conclusion.directAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MindMapPrimaryButton(
                    title: "Save answer & steps as plan",
                    systemImage: "checklist",
                    action: savePlan
                )
                .accessibilityIdentifier("save_plan")
            }
        }
    }

    private func answerPartView(_ part: GroundedAnswerPart) -> some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            Label(part.origin.displayLabel, systemImage: part.origin.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(part.origin == .sourceBacked ? MindMapTheme.success : MindMapTheme.source)

            Text(part.text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(MindMapTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                ForEach(part.evidence) { evidence in
                    answerCitationView(evidence)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func answerCitationView(_ evidence: ClaimEvidence) -> some View {
        if let source = session.sources.first(where: { $0.noteID == evidence.sourceNoteID }) {
            Button {
                selectedSource = source
            } label: {
                VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                    Label(source.noteTitle, systemImage: "quote.bubble.fill")
                        .font(.caption.weight(.semibold))
                    Text("“\(evidence.quote)”")
                        .font(.caption)
                        .foregroundStyle(MindMapTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MindMapSpacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    MindMapTheme.source.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Citation from \(source.noteTitle): \(evidence.quote)")
            .accessibilityHint("Opens the exact excerpt and original note")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Recent questions",
                subtitle: "Stored only on this device."
            )

            ForEach(store.queryHistory.prefix(4)) { item in
                Button {
                    store.updateAskDraft(question: item.question, filters: store.preferences.askDraft.filters)
                    synchronizeDraft()
                } label: {
                    MindMapCard(elevated: false) {
                        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                            Text(item.question)
                                .mindMapTextStyle(.cardTitle)
                            Text(item.answerSummary)
                                .mindMapTextStyle(.supporting)
                                .lineLimit(2)
                            Text("\(item.sourceCount) sources - \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .mindMapTextStyle(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Loads this question into Ask")
            }
        }
    }

    @ViewBuilder
    private func sourceChips(for ids: [UUID]) -> some View {
        let uniqueIDs = Array(Set(ids))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MindMapSpacing.small) {
                ForEach(uniqueIDs, id: \.self) { id in
                    if let source = session.sources.first(where: { $0.noteID == id }) {
                        MindMapSourceChip(source: source) {
                            selectedSource = source
                        }
                    }
                }
            }
        }
    }

    private var questionBinding: Binding<String> {
        Binding(
            get: { store.preferences.askDraft.question },
            set: { newQuestion in
                let filters = store.preferences.askDraft.filters
                store.updateAskDraft(question: newQuestion, filters: filters)
                resetSessionForDraftChange(question: newQuestion, filters: filters)
            }
        )
    }

    private var filtersBinding: Binding<RetrievalFilters> {
        Binding(
            get: { store.preferences.askDraft.filters },
            set: { newFilters in
                let question = store.preferences.askDraft.question
                store.updateAskDraft(question: question, filters: newFilters)
                resetSessionForDraftChange(question: question, filters: newFilters)
            }
        )
    }

    private var isWorking: Bool {
        [.searching, .batching, .generating].contains(session.phase)
    }

    private var selectedSources: [SourceReference] {
        Self.sourcesSelectedForRequest(
            session.sources,
            selectedSourceIDs: selectedSourceIDs
        )
    }

    private var canEditSourceSelection: Bool {
        guard session.conclusion == nil, !session.sources.isEmpty else { return false }
        return [
            AskPhase.awaitingConsent,
            .offline,
            .providerUnavailable,
            .failed,
            .cancelled
        ].contains(session.phase) && !showsDisclosure
    }

    nonisolated static func sourcesSelectedForRequest(
        _ sources: [SourceReference],
        selectedSourceIDs: Set<UUID>
    ) -> [SourceReference] {
        sources.filter { selectedSourceIDs.contains($0.id) }
    }

    private func toggleSourceSelection(_ sourceID: UUID) {
        guard canEditSourceSelection else { return }
        if selectedSourceIDs.contains(sourceID) {
            selectedSourceIDs.remove(sourceID)
        } else {
            selectedSourceIDs.insert(sourceID)
        }
        session.processingLimitMessage = ""
        if session.phase != .awaitingConsent {
            session.phase = .awaitingConsent
        }
        session.errorMessage = ""
    }

    private func synchronizeDraft() {
        let draft = store.preferences.askDraft
        if session.question != draft.question || session.filters != draft.filters {
            resetSessionForDraftChange(question: draft.question, filters: draft.filters)
        }
    }

    private func consumeRequestedQuestion() {
        guard let requested = router.requestedAskQuestion else { return }
        let cleaned = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            store.updateAskDraft(question: cleaned, filters: store.preferences.askDraft.filters)
        }
        router.requestedAskQuestion = nil
        synchronizeDraft()
    }

    private func resetSessionForDraftChange(question: String, filters: RetrievalFilters) {
        guard session.question != question
                || session.filters != filters
                || session.phase != .idle
                || !session.sources.isEmpty
                || session.conclusion != nil else { return }
        activeTask?.cancel()
        activeTask = nil
        session = AskSession(question: question, filters: filters)
        sourceVersions = [:]
        selectedSourceIDs = []
        selectedSource = nil
        saveMessage = nil
    }

    private func submit() {
        let question = questionBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        activeTask?.cancel()
        let filterSnapshot = filtersBinding.wrappedValue
        let noteSnapshot = store.notes
        let versionSnapshot = Dictionary(uniqueKeysWithValues: noteSnapshot.map { ($0.id, $0.updatedAt) })
        let engine = retrievalEngine
        session = AskSession(question: question, filters: filterSnapshot, phase: .searching)

        activeTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            let retrievalTask = Task.detached(priority: .userInitiated) {
                engine.retrieve(
                    question: question,
                    from: noteSnapshot,
                    filters: filterSnapshot
                )
            }
            let result = await withTaskCancellationHandler(
                operation: { await retrievalTask.value },
                onCancel: { retrievalTask.cancel() }
            )
            guard !Task.isCancelled else { return }
            session.sources = result.sources
            selectedSourceIDs = Set(result.sources.map(\.id))
            sourceVersions = Dictionary(uniqueKeysWithValues: result.sources.compactMap { source in
                versionSnapshot[source.noteID].map { (source.noteID, $0) }
            })
            session.relevantTotal = result.sources.count
            session.retrievalAssumption = result.statedAssumption
            session.clarificationQuestion = result.clarificationQuestion

            switch result.resolution {
            case .needsClarification:
                session.processedTotal = result.sources.count
                session.phase = .needsClarification
                return
            case .noEvidence:
                session.phase = .noEvidence
                return
            case .ready:
                break
            }

            prepareEvidenceReview()
        }
    }

    private func prepareEvidenceReview() {
        session.processedTotal = 0
        session.processingLimitMessage = ""
        session.phase = .awaitingConsent
        session.errorMessage = ""
    }

    private func continueAfterEvidenceReview() {
        guard !selectedSources.isEmpty else {
            session.phase = .awaitingConsent
            session.errorMessage = "Select at least one excerpt before continuing."
            return
        }

        switch store.preferences.aiProcessingConsent {
        case .undecided:
            session.phase = .awaitingConsent
            showsDisclosure = true
        case .declined:
            session.phase = .providerUnavailable
            session.errorMessage = "You declined external AI processing. Local search and every saved item remain available; you can change this choice in Settings."
        case .accepted:
            startGeneration()
        }
    }

    private func acceptDisclosure() {
        store.preferences.aiProcessingConsent = .accepted
        showsDisclosure = false
        startGeneration()
    }

    private func declineDisclosure() {
        store.preferences.aiProcessingConsent = .declined
        showsDisclosure = false
        session.phase = .providerUnavailable
        session.errorMessage = "AI processing is off. Your notes and local features remain on this device and continue to work."
    }

    private func startGeneration() {
        let requestSources = selectedSources
        guard !requestSources.isEmpty else {
            session.phase = .awaitingConsent
            session.errorMessage = "Select at least one excerpt before continuing."
            return
        }

        guard store.preferences.aiProcessingConsent == .accepted else {
            session.phase = .providerUnavailable
            session.errorMessage = store.preferences.aiProcessingConsent == .declined
                ? "External AI processing is declined. Local search and every saved item remain available; change this choice in Settings to generate a conclusion."
                : "Review the AI processing disclosure before any excerpt can leave this device."
            return
        }

        guard sourcesAreCurrent else {
            session.conclusion = nil
            session.phase = .failed
            session.errorMessage = "One or more source notes changed after retrieval. Find evidence again so the conclusion uses their current text."
            return
        }

        guard connectivity.isConnected else {
            session.phase = .offline
            return
        }

        let key: String
        do {
            guard let loaded = try apiKeyStore.loadAPIKey() else {
                session.phase = .providerUnavailable
                session.errorMessage = "Add your OpenAI API key in Settings. It is stored in the iOS Keychain, never in your notes or export."
                return
            }
            key = loaded
        } catch {
            session.phase = .providerUnavailable
            session.errorMessage = error.localizedDescription
            return
        }

        activeTask?.cancel()
        let batchSize = 20
        let sourceBatches = stride(from: 0, to: requestSources.count, by: batchSize).map { start in
            Array(requestSources[start..<min(start + batchSize, requestSources.count)])
        }
        session.phase = sourceBatches.count > 1 ? .batching : .generating
        session.processedTotal = sourceBatches.count > 1 ? 0 : requestSources.count
        session.errorMessage = ""
        let question = session.retrievalAssumption.isEmpty
            ? session.question
            : "\(session.question)\n\nRetrieval assumption disclosed to the user: \(session.retrievalAssumption)"
        let sources = requestSources
        let model = store.preferences.aiModel

        activeTask = Task { @MainActor in
            do {
                let batchConclusions = try await Self.generateAuthorizedBatches(
                    provider: provider,
                    question: question,
                    sourceBatches: sourceBatches,
                    apiKey: key,
                    model: model,
                    overallTimeout: .seconds(20),
                    authorization: {
                        store.preferences.aiProcessingConsent == .accepted
                    },
                    progress: { completedBatchCount in
                        session.processedTotal = min(completedBatchCount * batchSize, sources.count)
                    }
                )

                try Task.checkCancellation()
                guard store.preferences.aiProcessingConsent == .accepted else {
                    throw AIRequestBoundaryError.consentRevoked
                }
                guard sourcesAreCurrent else {
                    session.conclusion = nil
                    session.phase = .failed
                    session.errorMessage = "A source note changed while the conclusion was being created. Your notes are safe; find evidence again to use the current version."
                    return
                }
                let conclusion = Self.mergedConclusion(batchConclusions)
                session.conclusion = conclusion
                session.phase = .complete
                if sourceBatches.count > 1 {
                    session.processingLimitMessage = "Processed all \(sources.count) selected excerpts in \(sourceBatches.count) bounded AI requests, then merged only the independently validated results."
                } else {
                    session.processingLimitMessage = "Processed only the \(sources.count) excerpt\(sources.count == 1 ? "" : "s") you selected."
                }
                if !conclusion.directAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.recordQuery(question: session.question, conclusion: conclusion, sourceCount: sources.count)
                }
            } catch AIRequestBoundaryError.consentRevoked {
                session.conclusion = nil
                session.phase = .providerUnavailable
                session.errorMessage = "AI processing permission changed. The active request was stopped and no further note excerpts were sent."
            } catch is CancellationError {
                if session.phase == .generating || session.phase == .batching {
                    session.phase = .cancelled
                }
            } catch let error as AIProviderError {
                session.errorMessage = error.localizedDescription
                session.phase = error == .noEvidence ? .noEvidence : .failed
            } catch {
                session.errorMessage = error.localizedDescription
                session.phase = .failed
            }
        }
    }

    /// Enforces authorization at the actual network boundary, not only when the user taps
    /// Generate. This prevents later batches or a completed result from crossing a consent
    /// change that happens while an earlier provider request is still in flight.
    nonisolated static func generateAuthorizedBatches(
        provider: any GroundedConclusionProviding,
        question: String,
        sourceBatches: [[SourceReference]],
        apiKey: String,
        model: String,
        overallTimeout: Duration,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async throws -> [GroundedConclusion] {
        var conclusions: [GroundedConclusion] = []
        let deadline = ContinuousClock.now.advanced(by: overallTimeout)

        for (index, batch) in sourceBatches.enumerated() {
            try Task.checkCancellation()
            guard await authorization() else { throw AIRequestBoundaryError.consentRevoked }

            let now = ContinuousClock.now
            guard now < deadline else { throw AIProviderError.timedOut }
            let conclusion = try await generateConclusion(
                provider: provider,
                question: question,
                sources: batch,
                apiKey: apiKey,
                model: model,
                timeout: now.duration(to: deadline)
            )

            try Task.checkCancellation()
            guard await authorization() else { throw AIRequestBoundaryError.consentRevoked }
            conclusions.append(conclusion)
            await progress(index + 1)
        }

        guard await authorization() else { throw AIRequestBoundaryError.consentRevoked }
        return conclusions
    }

    private nonisolated static func generateConclusion(
        provider: any GroundedConclusionProviding,
        question: String,
        sources: [SourceReference],
        apiKey: String,
        model: String,
        timeout: Duration
    ) async throws -> GroundedConclusion {
        try await withThrowingTaskGroup(of: GroundedConclusion.self) { group in
            group.addTask {
                try await provider.generateConclusion(
                    question: question,
                    sources: sources,
                    apiKey: apiKey,
                    model: model
                )
            }
            group.addTask {
                try await Task<Never, Never>.sleep(for: timeout)
                throw AIProviderError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIProviderError.timedOut }
            return first
        }
    }

    /// Every provider response is validated against its own bounded evidence batch before this
    /// deterministic merge. The merge never invents synthesis text and never promotes a field
    /// that did not survive the grounding validator.
    private static func mergedConclusion(_ conclusions: [GroundedConclusion]) -> GroundedConclusion {
        func uniqueStrings(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.compactMap { value in
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                let key = cleaned.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                guard seen.insert(key).inserted else { return nil }
                return cleaned
            }
        }

        var evidenceKeys: Set<String> = []
        let answerEvidence = conclusions.flatMap(\.answerEvidence).filter { item in
            evidenceKeys.insert("\(item.sourceNoteID.uuidString)|\(item.quote.lowercased())").inserted
        }

        var answerParts: [GroundedAnswerPart] = []
        for part in conclusions.flatMap(\.resolvedAnswerParts) {
            let key = part.text.lowercased()
            if let index = answerParts.firstIndex(where: { $0.text.lowercased() == key }) {
                var existingEvidence = Set(answerParts[index].evidence.map {
                    "\($0.sourceNoteID.uuidString)|\($0.quote.lowercased())"
                })
                answerParts[index].evidence.append(contentsOf: part.evidence.filter {
                    existingEvidence.insert("\($0.sourceNoteID.uuidString)|\($0.quote.lowercased())").inserted
                })
                if part.origin == .sourceBacked {
                    answerParts[index].origin = .sourceBacked
                }
            } else {
                answerParts.append(part)
            }
        }

        var claimKeys: Set<String> = []
        let claims = conclusions.flatMap(\.claims).filter { claim in
            claimKeys.insert(claim.text.lowercased()).inserted
        }

        var conflictKeys: Set<String> = []
        var conflicts = conclusions.flatMap(\.conflicts).filter { conflict in
            let ids = conflict.sourceNoteIDs.map(\.uuidString).sorted().joined(separator: "|")
            return conflictKeys.insert("\(conflict.text.lowercased())|\(ids)").inserted
        }

        for leftIndex in conclusions.indices {
            for rightIndex in conclusions.indices where rightIndex > leftIndex {
                let left = conclusions[leftIndex]
                let right = conclusions[rightIndex]
                guard potentialCrossBatchConflict(left.directAnswer, right.directAnswer) else { continue }
                let sourceIDs = Array(Set(
                    left.answerEvidence.map(\.sourceNoteID) + right.answerEvidence.map(\.sourceNoteID)
                ))
                guard sourceIDs.count >= 2 else { continue }
                let text = "Potential conflict across evidence batches: “\(left.directAnswer)” / “\(right.directAnswer)”"
                let ids = sourceIDs.map(\.uuidString).sorted().joined(separator: "|")
                guard conflictKeys.insert("\(text.lowercased())|\(ids)").inserted else { continue }
                conflicts.append(GroundedConflict(text: text, sourceNoteIDs: sourceIDs))
            }
        }

        var checklist: [SuggestedPlanItem] = []
        for item in conclusions.flatMap(\.suggestedChecklist) {
            if let index = checklist.firstIndex(where: {
                $0.text.localizedCaseInsensitiveCompare(item.text) == .orderedSame
            }) {
                for sourceID in item.sourceNoteIDs where !checklist[index].sourceNoteIDs.contains(sourceID) {
                    checklist[index].sourceNoteIDs.append(sourceID)
                }
                var mergedEvidence = checklist[index].evidence ?? []
                var evidenceKeys = Set(mergedEvidence.map {
                    "\($0.sourceNoteID.uuidString)|\($0.quote.lowercased())"
                })
                mergedEvidence.append(contentsOf: (item.evidence ?? []).filter {
                    evidenceKeys.insert(
                        "\($0.sourceNoteID.uuidString)|\($0.quote.lowercased())"
                    ).inserted
                })
                checklist[index].evidence = mergedEvidence.isEmpty ? nil : mergedEvidence
                if item.origin == .sourceBacked {
                    checklist[index].origin = .sourceBacked
                }
            } else {
                checklist.append(item)
            }
        }

        let directAnswers = uniqueStrings(conclusions.map(\.directAnswer))
        let answerTokens = Set(directAnswers.flatMap { Self.mergeTokens($0) })
        let missingInformation = uniqueStrings(conclusions.flatMap(\.missingInformation)).filter { item in
            let required = Set(mergeTokens(item).filter { !mergeMissingFramingWords.contains($0) })
            return required.isEmpty || !required.isSubset(of: answerTokens)
        }

        return GroundedConclusion(
            directAnswer: directAnswers.joined(separator: "\n\n"),
            answerEvidence: answerEvidence,
            claims: claims,
            conflicts: conflicts,
            missingInformation: missingInformation,
            suggestedChecklist: checklist,
            statedAssumption: uniqueStrings(conclusions.map(\.statedAssumption)).joined(separator: " "),
            answerParts: answerParts
        )
    }

    private static func potentialCrossBatchConflict(_ left: String, _ right: String) -> Bool {
        let leftTokens = Set(mergeTokens(left))
        let rightTokens = Set(mergeTokens(right))
        guard !leftTokens.isEmpty, !rightTokens.isEmpty,
              leftTokens != rightTokens else { return false }
        let shared = leftTokens.intersection(rightTokens).subtracting(mergeRelationshipWords)
        let leftNumbers = Set(leftTokens.filter { $0.contains(where: \.isNumber) })
        let rightNumbers = Set(rightTokens.filter { $0.contains(where: \.isNumber) })
        if !leftNumbers.isEmpty, !rightNumbers.isEmpty,
           leftNumbers != rightNumbers, !shared.isEmpty { return true }

        let leftOperators = leftTokens.intersection(mergeRelationshipWords)
        let rightOperators = rightTokens.intersection(mergeRelationshipWords)
        if !leftOperators.isEmpty, !rightOperators.isEmpty,
           leftOperators != rightOperators, shared.count >= 2 { return true }

        return false
    }

    private static func mergeTokens(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !mergeStopWords.contains($0) }
    }

    private static let mergeStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "be", "been", "by", "for", "from", "has", "have",
        "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "were", "with"
    ]
    private static let mergeRelationshipWords: Set<String> = [
        "after", "at", "before", "cannot", "could", "earlier", "later", "may", "might", "never",
        "no", "not", "should", "will", "without", "would"
    ]
    private static let mergeMissingFramingWords: Set<String> = [
        "absent", "available", "enough", "information", "known", "missing", "not", "provided",
        "record", "recorded", "stated", "unknown", "whether"
    ]

    private func retryGeneration() {
        if session.sources.isEmpty || !sourcesAreCurrent {
            submit()
        } else if store.preferences.aiProcessingConsent == .undecided {
            session.phase = .awaitingConsent
            showsDisclosure = true
        } else if store.preferences.aiProcessingConsent == .declined {
            session.phase = .providerUnavailable
            session.errorMessage = "External AI processing is declined. Local search and every saved item remain available; change this choice in Settings to continue."
        } else {
            startGeneration()
        }
    }

    private func cancel() {
        activeTask?.cancel()
        activeTask = nil
        session.phase = .cancelled
        session.errorMessage = ""
    }

    private func savePlan() {
        guard let conclusion = session.conclusion else { return }
        guard sourcesAreCurrent else {
            session.conclusion = nil
            session.phase = .failed
            session.errorMessage = "A source note changed after this conclusion was created. Find evidence again before saving a plan."
            return
        }
        do {
            let plan = store.makePlan(
                from: conclusion,
                question: session.question,
                retrievalAssumption: session.retrievalAssumption
            )
            try store.upsertPlan(plan)
            saveMessage = "The conclusion and sourced checklist were saved. You can edit every field in Plans."
        } catch {
            session.phase = .failed
            session.errorMessage = error.localizedDescription
        }
    }

    private var sourcesAreCurrent: Bool {
        guard !session.sources.isEmpty,
              sourceVersions.count == Set(session.sources.map(\.noteID)).count else { return false }
        return sourceVersions.allSatisfy { noteID, version in
            store.note(withID: noteID)?.updatedAt == version
        }
    }

    private func invalidateEvidenceIfNeeded() {
        guard !session.sources.isEmpty, !sourcesAreCurrent else { return }
        activeTask?.cancel()
        activeTask = nil
        selectedSource = nil
        session.conclusion = nil
        session.phase = .failed
        session.errorMessage = "A retrieved source was edited or deleted. Your question and filters are preserved; retry to refresh the evidence."
    }
}

private struct AskRefinePanel: View {
    @Binding var filters: RetrievalFilters
    let availableTags: [String]

    var body: some View {
        MindMapCard(elevated: false) {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                MindMapSectionHeader(
                    title: "Refine evidence",
                    subtitle: "Filters are applied before MindMap AI interprets your question."
                )

                if !availableTags.isEmpty {
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Text("Accepted tag")
                            .mindMapTextStyle(.cardTitle)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MindMapSpacing.small) {
                                MindMapTagChip(
                                    title: "Any",
                                    isSelected: filters.tag.isEmpty,
                                    action: { filters.tag = "" }
                                )
                                ForEach(availableTags, id: \.self) { tag in
                                    MindMapTagChip(
                                        title: tag,
                                        isSelected: filters.tag == tag,
                                        action: { filters.tag = filters.tag == tag ? "" : tag }
                                    )
                                }
                            }
                        }
                    }
                }

                Picker("Date", selection: $filters.date) {
                    ForEach(DateFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                TextField("Place", text: $filters.place)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter by place")

                TextField("Trip or theme", text: $filters.theme)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter by trip or theme")

                Toggle("Favorites only", isOn: $filters.favoritesOnly)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)

                if filters.isActive {
                    MindMapSecondaryButton(
                        title: "Clear filters",
                        systemImage: "xmark.circle",
                        expands: false,
                        action: { filters = .init() }
                    )
                }
            }
        }
    }
}

private struct SourceSelectionCard: View {
    let source: SourceReference
    let isSelected: Bool
    let onToggle: () -> Void
    let onInspect: () -> Void

    var body: some View {
        MindMapCard(elevated: false) {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                HStack(alignment: .top, spacing: MindMapSpacing.medium) {
                    Button(action: onToggle) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.title2)
                            .foregroundStyle(isSelected ? MindMapTheme.accent : MindMapTheme.textSecondary)
                            .frame(
                                width: MindMapLayout.minimumTapTarget,
                                height: MindMapLayout.minimumTapTarget
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isSelected
                            ? "Exclude excerpt from \(source.noteTitle)"
                            : "Include excerpt from \(source.noteTitle)"
                    )
                    .accessibilityHint("Controls whether this exact excerpt may be sent to OpenAI")

                    VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                        Text(source.noteTitle)
                            .mindMapTextStyle(.cardTitle)
                        Text(source.noteDate.formatted(date: .abbreviated, time: .shortened))
                            .mindMapTextStyle(.caption)
                    }

                    Spacer(minLength: MindMapSpacing.small)

                    Text(source.score.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MindMapTheme.coverage)
                }

                Text("“\(source.excerpt)”")
                    .mindMapTextStyle(.body)
                    .foregroundStyle(MindMapTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.small) {
                        selectionStatus
                        Spacer(minLength: MindMapSpacing.small)
                        inspectButton
                    }
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        selectionStatus
                        inspectButton
                    }
                }
            }
        }
    }

    private var selectionStatus: some View {
        Label(
            isSelected ? "Selected for AI" : "Stays on device",
            systemImage: isSelected ? "checkmark.shield.fill" : "iphone"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(isSelected ? MindMapTheme.success : MindMapTheme.textSecondary)
        .accessibilityIdentifier("ask_source_selection_\(source.id.uuidString)")
    }

    private var inspectButton: some View {
        Button("Inspect excerpt", action: onInspect)
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .accessibilityHint("Shows the exact excerpt and original note")
    }
}

private struct SourceReferenceCard: View {
    let source: SourceReference
    var requestSelection: Bool? = nil

    var body: some View {
        MindMapCard(elevated: false) {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                        Text(source.noteTitle)
                            .mindMapTextStyle(.cardTitle)
                        Text(source.noteDate.formatted(date: .abbreviated, time: .shortened))
                            .mindMapTextStyle(.caption)
                    }
                    Spacer()
                    Text(source.score.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MindMapTheme.coverage)
                }

                Text("“\(source.excerpt)”")
                    .mindMapTextStyle(.body)
                    .foregroundStyle(MindMapTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                MindMapSourceChip(source: source)

                if let requestSelection {
                    Label(
                        requestSelection ? "Sent for this conclusion" : "Not sent",
                        systemImage: requestSelection ? "checkmark.shield.fill" : "iphone"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(requestSelection ? MindMapTheme.success : MindMapTheme.textSecondary)
                }
            }
        }
    }
}

private struct AIProcessingDisclosureView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceCount: Int
    let retrievalAssumption: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(MindMapTheme.accent)
                        .accessibilityHidden(true)

                    Text("Before the first AI conclusion")
                        .mindMapTextStyle(.screenTitle)
                        .accessibilityAddTraits(.isHeader)

                    Text("You selected \(sourceCount) exact excerpt\(sourceCount == 1 ? "" : "s") after local retrieval. If you continue, only your question, those selected excerpts, and any retrieval assumption displayed on the Ask screen are sent to OpenAI. Unselected excerpts and other notes are not sent. Precise coordinates are removed from saved location fields; coordinates you typed into selected note text remain part of that excerpt.")
                        .mindMapTextStyle(.body)

                    if !retrievalAssumption.isEmpty {
                        MindMapCallout(
                            kind: .info,
                            title: "Assumption included with this request",
                            message: retrievalAssumption
                        )
                    }

                    MindMapCallout(
                        kind: .info,
                        title: "Grounded personal-note mode",
                        message: "The provider is instructed not to use web or general knowledge. Every displayed claim must carry a valid source ID and an exact quote, or MindMap AI removes it. The request asks OpenAI not to store the generated response; provider policies still apply."
                    )

                    Text("Declining keeps capture, library, map, filters, accepted tags, plans, history, and keyword search available on this device.")
                        .mindMapTextStyle(.supporting)

                    MindMapPrimaryButton(title: "Continue with excerpts", systemImage: "checkmark.shield", action: onAccept)
                    MindMapSecondaryButton(title: "Not now", systemImage: "hand.raised", action: onDecline)
                }
                .padding(MindMapSpacing.xLarge)
                .mindMapReadableWidth(MindMapLayout.maxFormWidth)
            }
            .background(MindMapTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SourceEvidenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: SourceReference
    let note: MindNote?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Text(source.noteTitle)
                            .mindMapTextStyle(.screenTitle)
                        Text(source.noteDate.formatted(date: .long, time: .shortened))
                            .mindMapTextStyle(.supporting)
                    }

                    MindMapCallout(
                        kind: .success,
                        title: "Exact supporting excerpt",
                        message: source.excerpt
                    )

                    if let note {
                        MindMapCard {
                            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                                Label("Original note - unchanged", systemImage: "doc.text")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(MindMapTheme.success)
                                Text(note.body)
                                    .mindMapTextStyle(.body)
                                    .textSelection(.enabled)

                                if !note.acceptedTags.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack {
                                            ForEach(note.acceptedTags, id: \.self) { tag in
                                                MindMapTagChip(title: tag)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        MindMapCallout(
                            kind: .warning,
                            title: "Source no longer available",
                            message: "This note was deleted after retrieval. It will not be used in future conclusions."
                        )
                    }
                }
                .padding(MindMapSpacing.large)
                .mindMapReadableWidth()
            }
            .background(MindMapTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                }
            }
        }
    }
}

private extension AIContentOrigin {
    var displayLabel: String {
        switch self {
        case .sourceBacked: return "From your notes"
        case .generatedGuidance: return "AI-generated guidance"
        }
    }

    var systemImage: String {
        switch self {
        case .sourceBacked: return "quote.bubble.fill"
        case .generatedGuidance: return "sparkles"
        }
    }
}
