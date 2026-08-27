import SwiftUI

/// Saved, reusable plans built from grounded conclusions.
struct PlansView: View {
    @EnvironmentObject private var store: MindMapStore

    private let onOpenAsk: (() -> Void)?

    @State private var planToDelete: MindPlan?
    @State private var planToShare: MindPlan?
    @State private var errorMessage: String?

    init(onOpenAsk: (() -> Void)? = nil) {
        self.onOpenAsk = onOpenAsk
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.plans.isEmpty {
                    emptyState
                } else {
                    plansList
                }
            }
            .background(MindMapTheme.background)
            .navigationTitle("Plans")
        }
        .sheet(item: $planToShare) { plan in
            PlanSharePreviewSheet(plan: plan)
                .environmentObject(store)
        }
        .alert("Delete plan?", isPresented: deleteAlertIsPresented, presenting: planToDelete) { plan in
            Button("Delete", role: .destructive) {
                if !store.deletePlan(plan.id) {
                    errorMessage = store.persistenceMessage ?? "The plan deletion could not be saved."
                }
                planToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                planToDelete = nil
            }
        } message: { plan in
            Text("“\(plan.title)” will be removed from this device. Your original notes will not be changed.")
        }
        .alert("Could not update plan", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { planToDelete != nil },
            set: { if !$0 { planToDelete = nil } }
        )
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No plans yet", systemImage: "checklist")
        } description: {
            Text("Ask a question across your notes, verify the evidence, then save the conclusion as an editable plan.")
        } actions: {
            if let onOpenAsk {
                Button("Ask your notes", action: onOpenAsk)
                    .buttonStyle(MindMapPrimaryButtonStyle(expands: false))
                    .accessibilityHint("Opens Ask so you can build a grounded conclusion")
            } else {
                Text("Open the Ask tab to create one.")
                    .mindMapTextStyle(.caption)
            }
        }
        .padding(MindMapSpacing.xLarge)
    }

    private var plansList: some View {
        List {
            Section {
                ForEach(store.plans) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan)
                            .environmentObject(store)
                    } label: {
                        PlanListCard(
                            plan: plan,
                            sourceStates: plan.sources.map(store.planSourceState)
                        )
                    }
                    .buttonStyle(.plain)
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
                        Button(role: .destructive) {
                            planToDelete = plan
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            planToShare = plan
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(MindMapTheme.info)
                    }
                    .contextMenu {
                        Button {
                            planToShare = plan
                        } label: {
                            Label("Share preview", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            reuse(plan)
                        } label: {
                            Label("Reuse as a copy", systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            planToDelete = plan
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Newest updates first")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Saved plans")
    }

    private func reuse(_ plan: MindPlan) {
        do {
            try store.upsertPlan(plan.reusableCopy())
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlanListCard: View {
    let plan: MindPlan
    let sourceStates: [PlanSourceState]

    private var completedCount: Int {
        plan.checklist.filter(\.isComplete).count
    }

    private var changedSourceCount: Int {
        sourceStates.reduce(into: 0) { count, state in
            if case .changed = state { count += 1 }
        }
    }

    private var deletedSourceCount: Int {
        sourceStates.reduce(into: 0) { count, state in
            if case .deleted = state { count += 1 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            HStack(alignment: .top, spacing: MindMapSpacing.medium) {
                VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                    Text(plan.title.isEmpty ? "Untitled plan" : plan.title)
                        .mindMapTextStyle(.cardTitle)
                        .lineLimit(2)

                    Text(plan.provenanceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(plan.isAIGenerated ? MindMapTheme.source : MindMapTheme.info)
                }

                Spacer(minLength: MindMapSpacing.small)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MindMapTheme.textTertiary)
                    .accessibilityHidden(true)
            }

            if !plan.conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plan.conclusion)
                    .mindMapTextStyle(.supporting)
                    .lineLimit(3)
            }

            HStack(spacing: MindMapSpacing.medium) {
                if !plan.checklist.isEmpty {
                    Label("\(completedCount)/\(plan.checklist.count)", systemImage: "checkmark.circle")
                }

                if let date = plan.date {
                    Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }

                if !plan.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(plan.place, systemImage: "mappin")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(MindMapTheme.textSecondary)

            if changedSourceCount > 0 || deletedSourceCount > 0 {
                HStack(spacing: MindMapSpacing.medium) {
                    if changedSourceCount > 0 {
                        Label("\(changedSourceCount) changed", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(MindMapTheme.warning)
                    }
                    if deletedSourceCount > 0 {
                        Label("\(deletedSourceCount) deleted", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(MindMapTheme.error)
                    }
                }
                .font(.caption.weight(.semibold))
            }

            Text("Updated \(plan.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .mindMapTextStyle(.caption)
        }
        .padding(MindMapLayout.cardPadding)
        .mindMapCardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this plan for editing")
    }
}

/// Editable detail for an existing or newly created plan.
struct PlanDetailView: View {
    @EnvironmentObject private var store: MindMapStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MindPlan
    @State private var savedVersion: MindPlan
    @State private var newChecklistText = ""
    @State private var showSharePreview = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var didSave = false
    @State private var isExternallyDeleted = false
    @State private var showDiscardConfirmation = false

    init(plan: MindPlan) {
        _draft = State(initialValue: plan)
        _savedVersion = State(initialValue: plan)
    }

    private var isDirty: Bool { draft != savedVersion }

    private var isPersisted: Bool {
        store.plans.contains { $0.id == draft.id }
    }

    private var canSave: Bool {
        !isExternallyDeleted
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isDirty || !isPersisted)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                provenanceBanner

                PlanEditorSection(
                    title: "Plan",
                    subtitle: "Give the plan a clear name and keep the useful conclusion editable."
                ) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                        LabeledContent("Title") {
                            TextField("Plan title", text: planBinding(\.title))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.sentences)
                                .accessibilityLabel("Plan title")
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                            HStack {
                                Text("Conclusion")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if draft.isAIGenerated {
                                    Label(
                                        draft.hasBeenUserEdited ? "AI draft · edited" : "AI draft",
                                        systemImage: draft.hasBeenUserEdited ? "person.crop.circle.badge.checkmark" : "sparkles"
                                    )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MindMapTheme.source)
                                } else {
                                    Label("User edited", systemImage: "person.crop.circle")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MindMapTheme.info)
                                }
                            }

                            TextEditor(text: planBinding(\.conclusion))
                                .frame(minHeight: 132)
                                .padding(MindMapSpacing.small)
                                .background(MindMapTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control))
                                .accessibilityLabel("Plan conclusion")
                        }
                    }
                }

                PlanEditorSection(
                    title: "Checklist",
                    subtitle: "Edit, complete, add, or remove steps without changing the source notes."
                ) {
                    VStack(spacing: MindMapSpacing.medium) {
                        if draft.checklist.isEmpty {
                            Label("No checklist steps yet", systemImage: "checklist.unchecked")
                                .mindMapTextStyle(.supporting)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(draft.checklist) { item in
                                checklistRow(item)
                                if item.id != draft.checklist.last?.id {
                                    Divider()
                                }
                            }
                        }

                        HStack(alignment: .center, spacing: MindMapSpacing.small) {
                            TextField("Add a step", text: $newChecklistText)
                                .textInputAutocapitalization(.sentences)
                                .submitLabel(.done)
                                .onSubmit(addChecklistItem)
                                .padding(.horizontal, MindMapSpacing.medium)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)
                                .background(MindMapTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control))
                                .accessibilityLabel("New checklist step")

                            Button(action: addChecklistItem) {
                                Image(systemName: "plus")
                                    .font(.headline)
                                    .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MindMapTheme.primaryActionFill)
                            .disabled(newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Add checklist step")
                        }
                    }
                }

                if let answerParts = draft.answerParts, !answerParts.isEmpty {
                    PlanEditorSection(
                        title: "Original answer provenance",
                        subtitle: "These labels and exact excerpts describe the AI answer that was saved with this plan."
                    ) {
                        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                            ForEach(answerParts) { part in
                                savedAnswerPartRow(part)
                                if part.id != answerParts.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                PlanEditorSection(
                    title: "When and where",
                    subtitle: "These details are optional and remain editable."
                ) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                        Toggle("Add a target date", isOn: dateEnabledBinding)
                            .frame(minHeight: MindMapLayout.minimumTapTarget)

                        if draft.date != nil {
                            DatePicker(
                                "Target date",
                                selection: dateBinding,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                        }

                        Divider()

                        LabeledContent {
                            TextField("Optional place", text: planBinding(\.place))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.words)
                                .accessibilityLabel("Plan place")
                        } label: {
                            Label("Place", systemImage: "mappin")
                        }
                    }
                }

                PlanEditorSection(
                    title: "Linked sources",
                    subtitle: "Source status is checked against your local notes. A deleted source stays visible as a warning."
                ) {
                    if draft.sources.isEmpty {
                        Label("This plan has no linked source notes.", systemImage: "link.badge.plus")
                            .mindMapTextStyle(.supporting)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(draft.sources) { source in
                                sourceRow(source)
                                if source.id != draft.sources.last?.id {
                                    Divider()
                                        .padding(.vertical, MindMapSpacing.small)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: MindMapSpacing.medium) {
                    Button(action: save) {
                        Label(didSave ? "Saved" : "Save plan", systemImage: didSave ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(MindMapPrimaryButtonStyle())
                    .disabled(!canSave)

                    HStack(spacing: MindMapSpacing.medium) {
                        Button {
                            showSharePreview = true
                        } label: {
                            Label("Share preview", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(MindMapSecondaryButtonStyle())

                        Button(action: reuse) {
                            Label("Reuse copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(MindMapSecondaryButtonStyle())
                    }
                }

                if isPersisted {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete plan", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(MindMapTheme.error)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                }
            }
            .padding(MindMapSpacing.large)
            .mindMapReadableWidth(MindMapLayout.maxFormWidth)
        }
        .background(MindMapTheme.background)
        .navigationTitle(draft.title.isEmpty ? "Plan" : draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        showDiscardConfirmation = true
                    }
                    .accessibilityHint("Offers to discard unsaved plan edits")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(didSave ? "Saved" : "Save", action: save)
                    .disabled(!canSave)
                    .accessibilityHint("Saves the edited plan on this device")
            }
        }
        .sheet(isPresented: $showSharePreview) {
            PlanSharePreviewSheet(plan: draft)
                .environmentObject(store)
        }
        .alert("Delete plan?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deletePlan)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This plan will be removed. Its linked notes will remain unchanged.")
        }
        .alert("Discard plan edits?", isPresented: $showDiscardConfirmation) {
            Button("Keep editing", role: .cancel) { }
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Unsaved changes will be lost. The last saved plan will remain on this device.")
        }
        .alert("Could not save plan", isPresented: errorAlertIsPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
        .onChange(of: store.plans) { _, updatedPlans in
            guard let updated = updatedPlans.first(where: { $0.id == draft.id }) else {
                guard !isExternallyDeleted else { return }
                isExternallyDeleted = true
                errorMessage = "This plan was deleted after you opened it. It cannot be saved over the deletion; go back or use Reuse copy to create a new plan."
                return
            }
            guard updated != savedVersion else { return }
            if isDirty {
                // Privacy redaction wins over an in-progress edit: if a linked note was deleted,
                // remove its stale exact quotes from this draft before the user can share/reuse it.
                draft = normalizedDraft()
                errorMessage = "This plan changed after you opened it. Close and reopen it before saving so newer edits are not overwritten."
            } else {
                draft = updated
                savedVersion = updated
            }
        }
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var provenanceBanner: some View {
        let provenanceTint = draft.isAIGenerated ? MindMapTheme.source : MindMapTheme.info
        return HStack(alignment: .top, spacing: MindMapSpacing.medium) {
            Image(systemName: draft.hasBeenUserEdited ? "person.crop.circle.badge.checkmark" : "sparkles")
                .font(.title3)
                .foregroundStyle(provenanceTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(draft.provenanceLabel)
                    .font(.headline)
                    .foregroundStyle(MindMapTheme.textPrimary)
                Text(
                    draft.isAIGenerated && draft.hasBeenUserEdited
                        ? "This started from a grounded conclusion and now includes your edits. Original source notes remain unchanged."
                        : draft.isAIGenerated
                            ? "This started from a grounded conclusion. Review and edit it before relying on it."
                            : "Your edits are distinct from the original notes, which remain unchanged."
                )
                .mindMapTextStyle(.supporting)
            }
        }
        .padding(MindMapLayout.cardPadding)
        .background(
            provenanceTint.opacity(0.10),
            in: RoundedRectangle(cornerRadius: MindMapCornerRadius.callout)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MindMapCornerRadius.callout)
                .stroke(provenanceTint.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func checklistRow(_ item: PlanChecklistItem) -> some View {
        HStack(alignment: .center, spacing: MindMapSpacing.small) {
            Button {
                toggleChecklistItem(item.id)
            } label: {
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isComplete ? MindMapTheme.success : MindMapTheme.textSecondary)
                    .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isComplete ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                if let origin = item.origin {
                    Label(origin.planStepLabel, systemImage: origin.planStepSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            origin == .sourceBacked
                                ? MindMapTheme.success
                                : MindMapTheme.source
                        )
                }

                TextField("Checklist step", text: checklistTextBinding(for: item.id), axis: .vertical)
                    .lineLimit(1...4)
                    .strikethrough(item.isComplete, color: MindMapTheme.textSecondary)
                    .foregroundStyle(item.isComplete ? MindMapTheme.textSecondary : MindMapTheme.textPrimary)
                    .accessibilityLabel("Checklist step")

                if let citations = item.citations, !citations.isEmpty {
                    ForEach(citations) { citation in
                        savedStepCitationRow(citation)
                    }
                }
            }

            Button(role: .destructive) {
                removeChecklistItem(item.id)
            } label: {
                Image(systemName: "trash")
                    .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MindMapTheme.error)
            .accessibilityLabel("Delete checklist step")
        }
    }

    private func savedStepCitationRow(_ citation: PlanStepCitation) -> some View {
        let sourceTitle = draft.sources.first(where: { $0.id == citation.sourceLinkID })?.titleAtSave
            ?? "Unavailable saved source"
        return VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
            Label(sourceTitle, systemImage: "quote.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MindMapTheme.source)
            Text("\u{201c}\(citation.quote)\u{201d}")
                .font(.caption)
                .foregroundStyle(MindMapTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MindMapSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MindMapTheme.source.opacity(0.08),
            in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func savedAnswerPartRow(_ part: PlanAnswerPart) -> some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Label(part.origin.planStepLabel, systemImage: part.origin.planStepSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    part.origin == .sourceBacked
                        ? MindMapTheme.success
                        : MindMapTheme.source
                )

            Text(part.text)
                .font(.body)
                .foregroundStyle(MindMapTheme.textPrimary)

            ForEach(part.citations) { citation in
                let sourceTitle = draft.sources.first(where: { $0.id == citation.sourceLinkID })?.titleAtSave
                    ?? "Unavailable saved source"
                VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                    Label(sourceTitle, systemImage: "quote.bubble.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MindMapTheme.source)
                    Text("\u{201c}\(citation.quote)\u{201d}")
                        .font(.caption)
                        .foregroundStyle(MindMapTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MindMapSpacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    MindMapTheme.source.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control)
                )
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sourceRow(_ source: PlanSourceLink) -> some View {
        let state = store.planSourceState(source)

        HStack(alignment: .top, spacing: MindMapSpacing.medium) {
            Image(systemName: state.iconName)
                .font(.headline)
                .foregroundStyle(state.tint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(source.titleAtSave)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MindMapTheme.textPrimary)
                if case .deleted = state {
                    EmptyView()
                } else {
                    Text(source.noteDate.formatted(date: .abbreviated, time: .omitted))
                        .mindMapTextStyle(.caption)
                }
                Text(state.explanation)
                    .font(.caption)
                    .foregroundStyle(state.tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(source.titleAtSave), \(state.label). \(state.explanation)")

            Spacer(minLength: MindMapSpacing.small)

            if case .changed = state {
                Button("Refresh title") {
                    refreshSource(source.id)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityHint("Updates title and date metadata but keeps the changed-evidence warning")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dateEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.date != nil },
            set: { enabled in
                draft.date = enabled ? (draft.date ?? .now) : nil
                markUserEdited()
            }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft.date ?? .now },
            set: { value in
                draft.date = value
                markUserEdited()
            }
        )
    }

    private func planBinding<Value>(_ keyPath: WritableKeyPath<MindPlan, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                markUserEdited()
            }
        )
    }

    private func checklistTextBinding(for itemID: UUID) -> Binding<String> {
        Binding(
            get: { draft.checklist.first(where: { $0.id == itemID })?.text ?? "" },
            set: { value in
                guard let index = draft.checklist.firstIndex(where: { $0.id == itemID }) else { return }
                draft.checklist[index].text = value
                markUserEdited()
            }
        )
    }

    private func markUserEdited() {
        draft.hasUserEdits = true
        didSave = false
    }

    private func addChecklistItem() {
        let text = newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft.checklist.append(PlanChecklistItem(text: text))
        newChecklistText = ""
        markUserEdited()
    }

    private func toggleChecklistItem(_ itemID: UUID) {
        guard let index = draft.checklist.firstIndex(where: { $0.id == itemID }) else { return }
        draft.checklist[index].isComplete.toggle()
        markUserEdited()
    }

    private func removeChecklistItem(_ itemID: UUID) {
        draft.checklist.removeAll { $0.id == itemID }
        markUserEdited()
    }

    private func refreshSource(_ sourceID: UUID) {
        guard let sourceIndex = draft.sources.firstIndex(where: { $0.id == sourceID }),
              let noteID = draft.sources[sourceIndex].noteID,
              let note = store.note(withID: noteID) else { return }

        draft.sources[sourceIndex].titleAtSave = note.displayTitle
        draft.sources[sourceIndex].noteDate = note.eventDate ?? note.createdAt
        // Metadata can refresh, but the stale-evidence warning remains until a new grounded
        // conclusion is generated from the edited note.
        markUserEdited()
    }

    private func normalizedDraft() -> MindPlan {
        var result = draft
        let existingNoteIDs = Set(store.notes.map(\.id))
        var deletedSourceLinkIDs: Set<UUID> = []

        for sourceIndex in result.sources.indices {
            if let noteID = result.sources[sourceIndex].noteID,
               !existingNoteIDs.contains(noteID) {
                deletedSourceLinkIDs.insert(result.sources[sourceIndex].id)
                result.sources[sourceIndex].noteID = nil
                result.sources[sourceIndex].titleAtSave = "Deleted source"
                result.sources[sourceIndex].noteDate = Date(timeIntervalSince1970: 0)
            }
        }
        if var answerParts = result.answerParts {
            for partIndex in answerParts.indices {
                answerParts[partIndex].citations.removeAll {
                    deletedSourceLinkIDs.contains($0.sourceLinkID)
                }
            }
            result.answerParts = answerParts
        }
        for itemIndex in result.checklist.indices {
            result.checklist[itemIndex].sourceNoteIDs.removeAll { !existingNoteIDs.contains($0) }
            if var citations = result.checklist[itemIndex].citations {
                citations.removeAll { deletedSourceLinkIDs.contains($0.sourceLinkID) }
                result.checklist[itemIndex].citations = citations.isEmpty ? nil : citations
            }
        }
        return result
    }

    private func save() {
        guard canSave else { return }
        guard let current = store.plans.first(where: { $0.id == draft.id }) else {
            isExternallyDeleted = true
            errorMessage = "This plan was deleted after you opened it. Use Reuse copy if you want to create a new plan from this draft."
            return
        }
        guard current.updatedAt == savedVersion.updatedAt else {
            errorMessage = "This plan changed after you opened it. Close and reopen it before saving so newer edits are not overwritten."
            return
        }
        do {
            let plan = normalizedDraft()
            try store.upsertPlan(plan)
            let persisted = store.plans.first(where: { $0.id == plan.id }) ?? plan
            draft = persisted
            savedVersion = persisted
            didSave = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reuse() {
        do {
            let copy = normalizedDraft().reusableCopy()
            try store.upsertPlan(copy)
            let persisted = store.plans.first(where: { $0.id == copy.id }) ?? copy
            draft = persisted
            savedVersion = persisted
            didSave = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePlan() {
        if store.deletePlan(draft.id) {
            dismiss()
        } else {
            errorMessage = store.persistenceMessage ?? "The local store could not save this deletion."
        }
    }
}

private struct PlanEditorSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

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
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(title)
                    .mindMapTextStyle(.sectionTitle)
                if let subtitle {
                    Text(subtitle)
                        .mindMapTextStyle(.supporting)
                }
            }

            content
        }
        .padding(MindMapLayout.cardPadding)
        .mindMapCardSurface(elevated: false)
    }
}

/// Privacy-first preview: source metadata is excluded until explicitly selected.
struct PlanSharePreviewSheet: View {
    @EnvironmentObject private var store: MindMapStore
    @Environment(\.dismiss) private var dismiss

    let plan: MindPlan

    @State private var includeConclusion: Bool
    @State private var includeChecklist: Bool
    @State private var includeTargetDate = false
    @State private var includePlace = false
    @State private var selectedSourceIDs: Set<UUID> = []
    @State private var includeSourceDates = false

    init(plan: MindPlan) {
        self.plan = plan
        _includeConclusion = State(
            initialValue: !plan.conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        _includeChecklist = State(initialValue: !plan.checklist.isEmpty)
    }

    private var shareText: String {
        var sections: [String] = []

        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(title.isEmpty ? "Untitled plan" : title)
        if plan.isAIGenerated, includeConclusion || includeChecklist {
            sections.append("Provenance: \(plan.provenanceLabel)")
        }

        let conclusion = plan.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeConclusion, !conclusion.isEmpty {
            sections.append(conclusion)
        }

        if includeChecklist {
            let checklistLines = plan.checklist.compactMap { item -> String? in
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (item.isComplete ? "[x] " : "[ ] ") + text
            }
            if !checklistLines.isEmpty {
                sections.append("Checklist\n" + checklistLines.joined(separator: "\n"))
            }
        }

        var metadata: [String] = []
        if includeTargetDate, let date = plan.date {
            metadata.append("Date: \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        let place = plan.place.trimmingCharacters(in: .whitespacesAndNewlines)
        if includePlace, !place.isEmpty {
            metadata.append("Place: \(place)")
        }
        if !metadata.isEmpty {
            sections.append(metadata.joined(separator: "\n"))
        }

        let selectedSources = plan.sources.filter { $0.noteID != nil && selectedSourceIDs.contains($0.id) }
        if !selectedSources.isEmpty {
            let sourceLines = selectedSources.map { source in
                if includeSourceDates {
                    return "- \(source.titleAtSave) (\(source.noteDate.formatted(date: .abbreviated, time: .omitted)))"
                }
                return "- \(source.titleAtSave)"
            }
            sections.append("Sources\n" + sourceLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                        Text("Choose what to share")
                            .mindMapTextStyle(.screenTitle)
                        Text("Only the fields and source metadata selected below appear in the preview. Note bodies and excerpts are never included.")
                            .mindMapTextStyle(.supporting)
                    }

                    PlanEditorSection(title: "Plan fields") {
                        VStack(spacing: MindMapSpacing.small) {
                            Toggle("Conclusion", isOn: $includeConclusion)
                                .disabled(plan.conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)

                            Toggle("Checklist", isOn: $includeChecklist)
                                .disabled(plan.checklist.isEmpty)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)

                            Toggle("Target date", isOn: $includeTargetDate)
                                .disabled(plan.date == nil)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)

                            Toggle("Place", isOn: $includePlace)
                                .disabled(plan.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .frame(minHeight: MindMapLayout.minimumTapTarget)
                        }
                    }

                    PlanEditorSection(
                        title: "Source metadata",
                        subtitle: "Sources are off by default. Selecting one shares only its saved title and, if enabled, its date."
                    ) {
                        let shareableSources = plan.sources.filter { $0.noteID != nil }
                        if shareableSources.isEmpty {
                            Text("No linked sources are available.")
                                .mindMapTextStyle(.supporting)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(shareableSources) { source in
                                    Toggle(isOn: sourceSelectionBinding(source.id)) {
                                        VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                                            Text(source.titleAtSave)
                                                .font(.subheadline.weight(.semibold))
                                            Text(store.planSourceState(source).label)
                                                .font(.caption)
                                                .foregroundStyle(store.planSourceState(source).tint)
                                        }
                                    }
                                    .frame(minHeight: MindMapLayout.minimumTapTarget)

                                    if source.id != shareableSources.last?.id {
                                        Divider()
                                    }
                                }

                                if !selectedSourceIDs.isEmpty {
                                    Divider()
                                        .padding(.vertical, MindMapSpacing.small)
                                    Toggle("Include source dates", isOn: $includeSourceDates)
                                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Text("Preview")
                            .mindMapTextStyle(.sectionTitle)

                        Text(shareText)
                            .font(.body.monospaced())
                            .foregroundStyle(MindMapTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(MindMapLayout.cardPadding)
                            .mindMapCardSurface(elevated: false)
                            .accessibilityLabel("Share preview")
                    }

                    ShareLink(item: shareText) {
                        Label("Share selected content", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(MindMapPrimaryButtonStyle())
                    .accessibilityHint("Opens the system share sheet with exactly the previewed text")
                }
                .padding(MindMapSpacing.large)
                .mindMapReadableWidth(MindMapLayout.maxFormWidth)
            }
            .background(MindMapTheme.background)
            .navigationTitle("Share preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func sourceSelectionBinding(_ sourceID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedSourceIDs.contains(sourceID) },
            set: { selected in
                if selected {
                    selectedSourceIDs.insert(sourceID)
                } else {
                    selectedSourceIDs.remove(sourceID)
                }
            }
        )
    }
}

extension MindPlan {
    func reusableCopy(now: Date = .now) -> MindPlan {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = cleanedTitle.isEmpty ? "Reused plan" : "\(cleanedTitle) — reused"
        let copiedSources = sources.map {
            PlanSourceLink(
                id: UUID(),
                noteID: $0.noteID,
                titleAtSave: $0.titleAtSave,
                noteDate: $0.noteDate,
                updatedAtSave: $0.updatedAtSave
            )
        }
        let copiedSourceIDByOriginalID: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: zip(sources, copiedSources).map { original, copy in
                (original.id, copy.id)
            }
        )
        let copiedAnswerParts = answerParts?.map { part in
            PlanAnswerPart(
                id: UUID(),
                text: part.text,
                origin: part.origin,
                citations: part.citations.compactMap { citation in
                    guard let copiedSourceID = copiedSourceIDByOriginalID[citation.sourceLinkID] else {
                        return nil
                    }
                    return PlanAnswerCitation(
                        id: UUID(),
                        sourceLinkID: copiedSourceID,
                        quote: citation.quote
                    )
                }
            )
        }

        return MindPlan(
            id: UUID(),
            title: copyTitle,
            conclusion: conclusion,
            answerParts: copiedAnswerParts,
            checklist: checklist.map {
                PlanChecklistItem(
                    id: UUID(),
                    text: $0.text,
                    isComplete: false,
                    sourceNoteIDs: $0.sourceNoteIDs,
                    origin: $0.origin,
                    citations: $0.citations?.compactMap { citation -> PlanStepCitation? in
                        guard let copiedSourceID = copiedSourceIDByOriginalID[citation.sourceLinkID] else {
                            return nil
                        }
                        return PlanStepCitation(
                            id: UUID(),
                            sourceLinkID: copiedSourceID,
                            quote: citation.quote
                        )
                    }
                )
            },
            date: date,
            place: place,
            sources: copiedSources,
            createdAt: now,
            updatedAt: now,
            isAIGenerated: isAIGenerated,
            hasUserEdits: true
        )
    }
}

private extension AIContentOrigin {
    var planStepLabel: String {
        switch self {
        case .sourceBacked: return "Originally from your notes"
        case .generatedGuidance: return "Originally AI-generated guidance"
        }
    }

    var planStepSystemImage: String {
        switch self {
        case .sourceBacked: return "quote.bubble.fill"
        case .generatedGuidance: return "sparkles"
        }
    }
}

private extension PlanSourceState {
    var label: String {
        switch self {
        case .current: return "Current"
        case .changed: return "Source changed"
        case .deleted: return "Source deleted"
        }
    }

    var explanation: String {
        switch self {
        case .current:
            return "Matches the saved note."
        case .changed:
            return "This note changed after the plan was saved."
        case .deleted:
            return "The linked note was deleted; this saved reference is retained for transparency."
        }
    }

    var iconName: String {
        switch self {
        case .current: return "checkmark.circle.fill"
        case .changed: return "arrow.triangle.2.circlepath.circle.fill"
        case .deleted: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .current: return MindMapTheme.success
        case .changed: return MindMapTheme.warning
        case .deleted: return MindMapTheme.error
        }
    }
}
