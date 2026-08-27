import SwiftUI

/// Reusable elevated container for MindMap AI content.
struct MindMapCard<Content: View>: View {
    private let padding: CGFloat
    private let elevated: Bool
    private let maxWidth: CGFloat
    private let content: Content

    init(
        padding: CGFloat = MindMapLayout.cardPadding,
        elevated: Bool = true,
        maxWidth: CGFloat = .infinity,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.elevated = elevated
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .mindMapCardSurface(elevated: elevated)
    }
}

struct MindMapPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            HStack(spacing: MindMapSpacing.small) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
        }
        .buttonStyle(MindMapPrimaryButtonStyle(expands: expands))
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(isLoading ? "\(title), in progress" : title)
    }
}

struct MindMapSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    var expands: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MindMapSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
        }
        .buttonStyle(MindMapSecondaryButtonStyle(expands: expands))
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

/// A tag can be informational or interactive. Interactive chips always provide
/// a full 44-point target even when the visual label is compact.
struct MindMapTagChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                label
            }
            .buttonStyle(MindMapChipButtonStyle(isSelected: isSelected))
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : MindMapTheme.accent)
                .padding(.horizontal, MindMapSpacing.medium)
                .padding(.vertical, MindMapSpacing.small)
                .frame(minHeight: 36)
                .background(
                    isSelected ? MindMapTheme.primaryActionFill : MindMapTheme.accentSubtle,
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    if !isSelected {
                        Capsule(style: .continuous)
                            .stroke(MindMapTheme.accent.opacity(0.24), lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var label: some View {
        HStack(spacing: MindMapSpacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }

            Text(title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum MindMapCalloutKind {
    case empty
    case info
    case success
    case warning
    case error

    fileprivate var tint: Color {
        switch self {
        case .empty: return MindMapTheme.textSecondary
        case .info: return MindMapTheme.info
        case .success: return MindMapTheme.success
        case .warning: return MindMapTheme.warning
        case .error: return MindMapTheme.error
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .empty: return "tray"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct MindMapCallout<Actions: View>: View {
    let kind: MindMapCalloutKind
    let title: String
    let message: String
    private let actions: Actions

    init(
        kind: MindMapCalloutKind,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: MindMapSpacing.medium) {
            Image(systemName: kind.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                Text(title)
                    .mindMapTextStyle(.cardTitle)

                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message)
                        .mindMapTextStyle(.supporting)
                }

                actions
                    .padding(.top, MindMapSpacing.xSmall)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MindMapSpacing.large)
        .background(kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: MindMapCornerRadius.callout, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MindMapCornerRadius.callout, style: .continuous)
                .stroke(kind.tint.opacity(0.28), lineWidth: 1)
        }
    }
}

extension MindMapCallout where Actions == EmptyView {
    init(kind: MindMapCalloutKind, title: String, message: String) {
        self.init(kind: kind, title: title, message: message) {
            EmptyView()
        }
    }
}

struct MindMapEmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        MindMapCallout(kind: .empty, title: title, message: message) {
            if let actionTitle, let action {
                MindMapSecondaryButton(
                    title: actionTitle,
                    systemImage: "plus",
                    expands: false,
                    action: action
                )
            }
        }
    }
}

struct MindMapErrorCallout: View {
    let title: String
    let message: String
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        MindMapCallout(kind: .error, title: title, message: message) {
            if let retryTitle, let onRetry {
                MindMapSecondaryButton(
                    title: retryTitle,
                    systemImage: "arrow.clockwise",
                    expands: false,
                    action: onRetry
                )
            }
        }
    }
}

/// Maps AskSession phases to a non-color-only status treatment.
struct MindMapStatusCallout: View {
    let phase: AskPhase
    var message: String = ""

    var body: some View {
        MindMapCallout(
            kind: phase.calloutKind,
            title: phase.label,
            message: resolvedMessage
        )
    }

    private var resolvedMessage: String {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? phase.defaultStatusMessage : cleaned
    }
}

/// Identifies a retrieved note and the kind of support it provides.
struct MindMapSourceChip: View {
    let title: String
    let supportType: SourceSupportType
    var score: Double? = nil
    var date: Date? = nil
    var action: (() -> Void)? = nil

    init(source: SourceReference, action: (() -> Void)? = nil) {
        self.title = source.noteTitle
        self.supportType = source.supportType
        self.score = source.score
        self.date = source.noteDate
        self.action = action
    }

    init(
        title: String,
        supportType: SourceSupportType,
        score: Double? = nil,
        date: Date? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.supportType = supportType
        self.score = score
        self.date = date
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) {
                styledLabel(minHeight: MindMapLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the source note")
        } else {
            styledLabel(minHeight: 36)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    private func styledLabel(minHeight: CGFloat) -> some View {
        HStack(spacing: MindMapSpacing.small) {
            Image(systemName: supportType.systemImage)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let scoreText {
                Text(scoreText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MindMapTheme.textSecondary)
            }

            if let dateText {
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(MindMapTheme.textSecondary)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(MindMapTheme.source)
        .padding(.horizontal, MindMapSpacing.medium)
        .padding(.vertical, MindMapSpacing.small)
        .frame(minHeight: minHeight)
        .background(MindMapTheme.source.opacity(0.09), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(MindMapTheme.source.opacity(0.26), lineWidth: 1)
        }
        .contentShape(Capsule(style: .continuous))
    }

    private var scoreText: String? {
        guard let score else { return nil }
        let bounded = min(max(score, 0), 1)
        return bounded.formatted(.percent.precision(.fractionLength(0)))
    }

    private var dateText: String? {
        date?.formatted(date: .abbreviated, time: .omitted)
    }

    private var accessibilityText: String {
        var parts = [title, "\(supportType.rawValue) source"]
        if let dateText { parts.append("dated \(dateText)") }
        if let scoreText { parts.append("relevance \(scoreText)") }
        return parts.joined(separator: ", ")
    }
}

/// Compact progress summary for retrieval sessions.
struct MindMapCoverageChip: View {
    let processed: Int
    let total: Int

    init(processed: Int, total: Int) {
        self.processed = max(processed, 0)
        self.total = max(total, 0)
    }

    init(session: AskSession) {
        self.init(processed: session.processedTotal, total: session.relevantTotal)
    }

    var body: some View {
        HStack(spacing: MindMapSpacing.small) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            Text(label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, MindMapSpacing.medium)
        .padding(.vertical, MindMapSpacing.small)
        .frame(minHeight: 36)
        .background(tint.opacity(0.09), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.26), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isComplete: Bool {
        total > 0 && processed >= total
    }

    private var systemImage: String {
        if total == 0 { return "doc.text.magnifyingglass" }
        return isComplete ? "checkmark.circle.fill" : "circle.dotted"
    }

    private var tint: Color {
        isComplete ? MindMapTheme.success : MindMapTheme.coverage
    }

    private var label: String {
        guard total > 0 else { return "No sources checked" }
        return "Coverage \(min(processed, total)) of \(total)"
    }

    private var accessibilityText: String {
        guard total > 0 else { return "Coverage: no sources checked" }
        return "Coverage: \(min(processed, total)) of \(total) relevant sources checked"
    }
}

struct MindMapSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: MindMapSpacing.large) {
                heading
                Spacer(minLength: MindMapSpacing.large)
                actionButton
            }

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                heading
                actionButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
            Text(title)
                .mindMapTextStyle(.sectionTitle)
                .accessibilityAddTraits(.isHeader)

            if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(subtitle)
                    .mindMapTextStyle(.supporting)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MindMapTheme.accent)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
    }
}

/// A compact representation of a saved note for Home and Library surfaces.
struct MindNoteSummaryCard: View {
    let note: MindNote
    var onOpen: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                HStack(alignment: .top, spacing: MindMapSpacing.medium) {
                    Text(note.displayTitle)
                        .mindMapTextStyle(.cardTitle)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    favoriteControl
                }

                Text(summaryBody)
                    .mindMapTextStyle(.body)
                    .foregroundStyle(summaryBodyColor)
                    .lineLimit(3)

                if !displayedTags.isEmpty || !cleanedTheme.isEmpty {
                    tagSummary
                }

                metadata

                if let onOpen {
                    Divider()
                    MindMapSecondaryButton(
                        title: "Open note",
                        systemImage: "arrow.right",
                        expands: false,
                        action: onOpen
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var summaryBody: String {
        let cleaned = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "No note text" : cleaned
    }

    private var summaryBodyColor: Color {
        note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MindMapTheme.textSecondary
            : MindMapTheme.textPrimary
    }

    private var cleanedTheme: String {
        note.tripTheme.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedTags: [String] {
        Array(note.acceptedTags.prefix(3))
    }

    @ViewBuilder
    private var favoriteControl: some View {
        if let onToggleFavorite {
            Button(action: onToggleFavorite) {
                Image(systemName: note.isFavorite ? "star.fill" : "star")
                    .font(.headline)
                    .foregroundStyle(note.isFavorite ? MindMapTheme.warning : MindMapTheme.textSecondary)
                    .frame(width: MindMapLayout.minimumTapTarget, height: MindMapLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.isFavorite ? "Remove from favorites" : "Add to favorites")
        } else if note.isFavorite {
            Label("Favorite", systemImage: "star.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MindMapTheme.warning)
                .accessibilityElement(children: .combine)
        }
    }

    private var tagSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MindMapSpacing.small) {
                tagChips
            }

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                tagChips
            }
        }
    }

    @ViewBuilder
    private var tagChips: some View {
        if !cleanedTheme.isEmpty {
            MindMapTagChip(title: cleanedTheme, systemImage: "sparkles")
        }

        ForEach(displayedTags, id: \.self) { tag in
            MindMapTagChip(title: tag, systemImage: "number")
        }

        if note.acceptedTags.count > displayedTags.count {
            MindMapTagChip(title: "+\(note.acceptedTags.count - displayedTags.count) more")
        }
    }

    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MindMapSpacing.large) {
                dateLabel
                placeLabel
            }

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                dateLabel
                placeLabel
            }
        }
        .font(.caption)
        .foregroundStyle(MindMapTheme.textSecondary)
    }

    private var dateLabel: some View {
        Label {
            Text(note.eventDate ?? note.updatedAt, format: .dateTime.month(.abbreviated).day().year())
        } icon: {
            Image(systemName: note.eventDate == nil ? "clock" : "calendar")
        }
        .accessibilityLabel(
            note.eventDate == nil
                ? "Updated \((note.updatedAt).formatted(date: .abbreviated, time: .omitted))"
                : "Event date \((note.eventDate ?? note.updatedAt).formatted(date: .abbreviated, time: .omitted))"
        )
    }

    @ViewBuilder
    private var placeLabel: some View {
        if let place = note.place {
            Label(place.name, systemImage: "mappin.and.ellipse")
                .lineLimit(2)
                .accessibilityLabel("Place: \(place.name)")
        }
    }
}

/// A compact plan representation with checklist progress and provenance.
struct MindPlanSummaryCard: View {
    let plan: MindPlan
    var onOpen: (() -> Void)? = nil

    var body: some View {
        MindMapCard {
            VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: MindMapSpacing.medium) {
                        planTitle

                        if plan.isAIGenerated {
                            MindMapTagChip(
                                title: plan.hasBeenUserEdited ? "AI · edited" : "AI generated",
                                systemImage: plan.hasBeenUserEdited ? "person.crop.circle.badge.checkmark" : "sparkles"
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        planTitle

                        if plan.isAIGenerated {
                            MindMapTagChip(
                                title: plan.hasBeenUserEdited ? "AI · edited" : "AI generated",
                                systemImage: plan.hasBeenUserEdited ? "person.crop.circle.badge.checkmark" : "sparkles"
                            )
                        }
                    }
                }

                if !cleanedConclusion.isEmpty {
                    Text(cleanedConclusion)
                        .mindMapTextStyle(.body)
                        .lineLimit(3)
                }

                if !plan.checklist.isEmpty {
                    ProgressView(value: Double(completedCount), total: Double(plan.checklist.count)) {
                        Text("Checklist")
                            .font(.subheadline.weight(.semibold))
                    } currentValueLabel: {
                        Text("\(completedCount) of \(plan.checklist.count)")
                            .font(.caption.monospacedDigit())
                    }
                    .tint(completedCount == plan.checklist.count ? MindMapTheme.success : MindMapTheme.accent)
                    .accessibilityLabel("Checklist progress")
                    .accessibilityValue("\(completedCount) of \(plan.checklist.count) items complete")
                }

                metadata

                if let onOpen {
                    Divider()
                    MindMapSecondaryButton(
                        title: "Open plan",
                        systemImage: "arrow.right",
                        expands: false,
                        action: onOpen
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var cleanedConclusion: String {
        plan.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var planTitle: some View {
        Text(plan.title)
            .mindMapTextStyle(.cardTitle)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completedCount: Int {
        plan.checklist.filter(\.isComplete).count
    }

    private var metadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MindMapSpacing.large) {
                metadataItems
            }

            VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                metadataItems
            }
        }
        .font(.caption)
        .foregroundStyle(MindMapTheme.textSecondary)
    }

    @ViewBuilder
    private var metadataItems: some View {
        if let date = plan.date {
            Label {
                Text(date, format: .dateTime.month(.abbreviated).day().year())
            } icon: {
                Image(systemName: "calendar")
            }
            .accessibilityLabel("Plan date \(date.formatted(date: .abbreviated, time: .omitted))")
        }

        if !plan.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(plan.place, systemImage: "mappin.and.ellipse")
                .lineLimit(2)
                .accessibilityLabel("Place: \(plan.place)")
        }

        Label(
            "\(plan.sources.count) source\(plan.sources.count == 1 ? "" : "s")",
            systemImage: "doc.text.magnifyingglass"
        )
        .accessibilityLabel("\(plan.sources.count) source notes")
    }
}

private extension AskPhase {
    var calloutKind: MindMapCalloutKind {
        switch self {
        case .complete:
            return .success
        case .needsClarification, .noEvidence:
            return .warning
        case .offline, .providerUnavailable, .failed:
            return .error
        case .idle, .searching, .batching, .awaitingConsent, .generating, .cancelled:
            return .info
        }
    }

    var defaultStatusMessage: String {
        switch self {
        case .idle: return "Ask a question grounded in your saved notes."
        case .searching: return "Finding notes that match your question and filters."
        case .batching: return "Reviewing all relevant notes in manageable groups."
        case .awaitingConsent: return "Confirm how selected note content may be processed before continuing."
        case .generating: return "Connecting supported claims while keeping sources visible."
        case .complete: return "The answer and its supporting notes are ready to review."
        case .needsClarification: return "Add the requested detail so the search can stay precise."
        case .noEvidence: return "Try broader filters or capture more relevant information first."
        case .offline: return "Your notes remain available, but AI generation needs a connection."
        case .providerUnavailable: return "The AI service is temporarily unavailable. Your notes are safe."
        case .failed: return "Nothing was changed. Try again when you are ready."
        case .cancelled: return "The request stopped before any conclusion was saved."
        }
    }
}

private extension SourceSupportType {
    var systemImage: String {
        switch self {
        case .exactText: return "quote.bubble.fill"
        case .metadata: return "calendar.badge.checkmark"
        case .related: return "doc.text.magnifyingglass"
        }
    }
}
