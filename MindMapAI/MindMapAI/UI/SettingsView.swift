import CoreLocation
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MindMapSettingsView: View {
    @ObservedObject private var store: MindMapStore
    @ObservedObject private var locationService: MindMapLocationService
    @ObservedObject private var connectivityMonitor: ConnectivityMonitor

    @Environment(\.openURL) private var openURL

    private let apiKeyStore: APIKeyStore
    private let connectionTester: any OpenAIConnectionTesting

    @State private var apiKeyDraft = ""
    @State private var maskedAPIKey = ""
    @State private var hasAPIKey = false
    @State private var isLoadingAPIKeyStatus = true
    @State private var apiKeyMessage: String?
    @State private var apiKeyError: String?

    @State private var modelDraft = ""
    @State private var selectedModelOptionID = OpenAIModelCatalog.customSelectionID
    @State private var modelMessage: String?
    @State private var modelError: String?
    @State private var isTestingConnection = false
    @State private var connectionTestMessage: String?
    @State private var connectionTestError: String?
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var connectionTestGeneration: UUID?
    @State private var consentMessage: String?
    @State private var consentError: String?

    @State private var dataMessage: String?
    @State private var dataError: String?
    @State private var exportDocument: MindMapExportDocument?
    @State private var isPresentingExporter = false
    @State private var pendingConfirmation: SettingsConfirmation?
    @State private var isDeletingAllData = false

    @FocusState private var focusedField: SettingsField?

    init(
        store: MindMapStore,
        locationService: MindMapLocationService,
        connectivityMonitor: ConnectivityMonitor,
        apiKeyStore: APIKeyStore = APIKeyStore(),
        connectionTester: any OpenAIConnectionTesting = OpenAISetupService()
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._locationService = ObservedObject(wrappedValue: locationService)
        self._connectivityMonitor = ObservedObject(wrappedValue: connectivityMonitor)
        self.apiKeyStore = apiKeyStore
        self.connectionTester = connectionTester
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MindMapSpacing.xLarge) {
                if let persistenceMessage = store.persistenceMessage {
                    MindMapErrorCallout(
                        title: "Local storage needs attention",
                        message: persistenceMessage
                    )
                }

                aiSection
                locationSection
                captureEverywhereSection
                historySection
                dataSection
                privacySection
            }
            .padding(.horizontal, MindMapSpacing.large)
            .padding(.vertical, MindMapSpacing.xLarge)
            .mindMapReadableWidth()
        }
        .background(MindMapTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: loadInitialState)
        .onDisappear {
            // Do not retain a credential typed into an abandoned edit.
            apiKeyDraft = ""
            connectionTestGeneration = nil
            connectionTestTask?.cancel()
            connectionTestTask = nil
            isTestingConnection = false
        }
        .onChange(of: store.preferences.aiModel) { _, newValue in
            guard focusedField != .model else { return }
            synchronizeModelDraft(with: newValue)
        }
        .onChange(of: modelDraft) { oldValue, newValue in
            guard oldValue != newValue else { return }
            clearConnectionTestFeedback()
        }
        .fileExporter(
            isPresented: $isPresentingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                dataError = nil
                dataMessage = "A JSON copy of your local MindMap AI data was exported. The API key was not included."
            case .failure(let error):
                dataMessage = nil
                dataError = "The export could not be completed. \(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .alert(item: $pendingConfirmation) { confirmation in
            switch confirmation {
            case .deleteAPIKey:
                return Alert(
                    title: Text("Delete API key?"),
                    message: Text("The OpenAI key will be removed from this device. Local notes, plans, and search will remain available."),
                    primaryButton: .destructive(Text("Delete Key"), action: deleteAPIKey),
                    secondaryButton: .cancel()
                )
            case .clearHistory:
                return Alert(
                    title: Text("Clear recent question history?"),
                    message: Text("Saved notes and plans will not be deleted. This action cannot be undone."),
                    primaryButton: .destructive(Text("Clear History"), action: clearHistory),
                    secondaryButton: .cancel()
                )
            case .deleteAllData:
                return Alert(
                    title: Text("Delete all MindMap AI data?"),
                    message: Text("This removes every note, tag suggestion, plan, recent question, draft, preference, and the securely stored API key. This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete Everything"), action: deleteAllData),
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "AI processing",
                subtitle: "Choose what can leave this device and configure OpenAI."
            )

            MindMapCallout(
                kind: .info,
                title: "What external AI receives",
                message: "When you allow conclusion generation, MindMap AI sends your question and only the relevant note excerpts shown in the source list to OpenAI. It does not send your full library or silently add web knowledge. Coordinates are removed from saved location fields, but coordinates typed into visible note text remain part of that excerpt. Local capture, browse, filters, map, and keyword search work if you decline."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        Text("External processing choice")
                            .mindMapTextStyle(.cardTitle)

                        Text("You can change this before a future request.")
                            .mindMapTextStyle(.supporting)

                        Picker("External AI processing", selection: consentBinding) {
                            Text("Ask before first use").tag(AIProcessingConsent.undecided)
                            Text("Allow relevant excerpts").tag(AIProcessingConsent.accepted)
                            Text("Do not allow").tag(AIProcessingConsent.declined)
                        }
                        .pickerStyle(.menu)
                        .tint(MindMapTheme.accent)
                        .frame(minHeight: MindMapLayout.minimumTapTarget)
                        .accessibilityHint("Controls whether relevant note excerpts may be sent to OpenAI")
                    }

                    if let consentError {
                        MindMapErrorCallout(
                            title: "Processing choice not updated",
                            message: consentError
                        )
                    } else if let consentMessage {
                        MindMapCallout(
                            kind: store.preferences.aiProcessingConsent == .declined ? .warning : .success,
                            title: "Processing choice updated",
                            message: consentMessage
                        )
                    }

                    Divider()

                    SettingsStatusRow(
                        title: providerStatus.title,
                        detail: providerStatus.detail,
                        systemImage: providerStatus.systemImage,
                        tint: providerStatus.tint
                    )

                    SettingsStatusRow(
                        title: networkStatus.title,
                        detail: networkStatus.detail,
                        systemImage: networkStatus.systemImage,
                        tint: networkStatus.tint
                    )

                    Divider()

                    modelEditor

                    Divider()

                    apiKeyEditor

                    Divider()

                    connectionTestSection
                }
            }
        }
    }

    private var modelEditor: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text("OpenAI model")
                .mindMapTextStyle(.cardTitle)

            Text("Choose a supported GPT-5.6 model, or use Custom for another model ID enabled for your OpenAI project. Changing it affects future conclusions only.")
                .mindMapTextStyle(.supporting)

            Picker("OpenAI model", selection: modelOptionBinding) {
                ForEach(OpenAIModelCatalog.curated) { option in
                    Text(option.name).tag(option.id)
                }
                Text("Custom model ID").tag(OpenAIModelCatalog.customSelectionID)
            }
            .pickerStyle(.menu)
            .tint(MindMapTheme.accent)
            .frame(minHeight: MindMapLayout.minimumTapTarget)
            .accessibilityHint("Selects a curated model or reveals a custom model ID field")

            if let option = OpenAIModelCatalog.option(for: modelDraft),
               selectedModelOptionID != OpenAIModelCatalog.customSelectionID {
                VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                    Text(option.id)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(MindMapTheme.textPrimary)
                    Text(option.summary)
                        .mindMapTextStyle(.caption)
                }
                .padding(.horizontal, MindMapSpacing.medium)
                .padding(.vertical, MindMapSpacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    MindMapTheme.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                )
            } else {
                TextField("Custom model ID", text: $modelDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focusedField, equals: .model)
                    .onSubmit(saveModel)
                    .padding(.horizontal, MindMapSpacing.medium)
                    .frame(minHeight: MindMapLayout.minimumTapTarget)
                    .background(MindMapTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                            .stroke(MindMapTheme.border.opacity(0.55), lineWidth: 1)
                    }
                    .accessibilityLabel("Custom OpenAI model ID")
            }

            MindMapSecondaryButton(
                title: "Save model",
                systemImage: "checkmark",
                isDisabled: cleanedModelDraft.isEmpty || cleanedModelDraft == store.preferences.aiModel,
                expands: false,
                action: saveModel
            )

            if let modelMessage {
                MindMapCallout(kind: .success, title: "Model updated", message: modelMessage)
            }

            if let modelError {
                MindMapErrorCallout(title: "Model not updated", message: modelError)
            }
        }
    }

    private var connectionTestSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text("Test OpenAI setup")
                .mindMapTextStyle(.cardTitle)

            Text("Sends a fixed diagnostic prompt to check the saved Keychain key, project billing access, and selected model. It may use a small number of API tokens, but sends no question, note, excerpt, location, plan, or history content.")
                .mindMapTextStyle(.supporting)

            MindMapSecondaryButton(
                title: isTestingConnection ? "Testing connection…" : "Test connection",
                systemImage: isTestingConnection ? "ellipsis" : "network.badge.shield.half.filled",
                isDisabled: isTestingConnection || cleanedModelDraft.isEmpty,
                expands: false,
                action: testConnection
            )
            .accessibilityIdentifier("settings_test_openai_connection")

            if isTestingConnection {
                HStack(spacing: MindMapSpacing.small) {
                    ProgressView()
                    Text("Checking the Keychain key and \(cleanedModelDraft)…")
                        .mindMapTextStyle(.supporting)
                }
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Testing OpenAI connection")
            }

            if let connectionTestMessage {
                MindMapCallout(
                    kind: .success,
                    title: "OpenAI connection ready",
                    message: connectionTestMessage
                )
                .accessibilityIdentifier("settings_openai_connection_success")
            }

            if let connectionTestError {
                MindMapErrorCallout(
                    title: "OpenAI setup needs attention",
                    message: connectionTestError
                )
                .accessibilityIdentifier("settings_openai_connection_error")
            }
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text("OpenAI API key")
                .mindMapTextStyle(.cardTitle)

            Text("The key is stored in the iOS Keychain for this device and is excluded from JSON exports. A saved key is never shown in full here.")
                .mindMapTextStyle(.supporting)

            if isLoadingAPIKeyStatus {
                HStack(spacing: MindMapSpacing.small) {
                    ProgressView()
                    Text("Checking secure storage…")
                        .mindMapTextStyle(.supporting)
                }
                .frame(minHeight: MindMapLayout.minimumTapTarget)
            } else if hasAPIKey {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MindMapSpacing.medium) {
                        storedKeyLabel
                        Spacer(minLength: MindMapSpacing.medium)
                        deleteKeyButton
                    }

                    VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                        storedKeyLabel
                        deleteKeyButton
                    }
                }
            } else {
                SettingsStatusRow(
                    title: "No API key saved",
                    detail: "Add a project key to enable external conclusion generation after consent.",
                    systemImage: "key.slash",
                    tint: MindMapTheme.warning
                )
            }

            SecureField(hasAPIKey ? "Enter a replacement key" : "Enter API key", text: $apiKeyDraft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedField, equals: .apiKey)
                .onSubmit(saveAPIKey)
                .padding(.horizontal, MindMapSpacing.medium)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .background(MindMapTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                        .stroke(MindMapTheme.border.opacity(0.55), lineWidth: 1)
                }
                .privacySensitive()
                .accessibilityLabel(hasAPIKey ? "Replacement OpenAI API key" : "OpenAI API key")

            MindMapPrimaryButton(
                title: hasAPIKey ? "Update key" : "Save key",
                systemImage: "key.fill",
                isDisabled: cleanedAPIKeyDraft.isEmpty,
                expands: false,
                action: saveAPIKey
            )

            if let apiKeyMessage {
                MindMapCallout(kind: .success, title: "Secure key storage", message: apiKeyMessage)
            }

            if let apiKeyError {
                MindMapErrorCallout(title: "Keychain error", message: apiKeyError)
            }
        }
    }

    private var storedKeyLabel: some View {
        Label {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text("Key saved")
                    .font(.subheadline.weight(.semibold))
                Text(maskedAPIKey)
                    .font(.caption.monospaced())
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .privacySensitive()
            }
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(MindMapTheme.success)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenAI API key is securely saved and masked")
    }

    private var deleteKeyButton: some View {
        Button(role: .destructive) {
            pendingConfirmation = .deleteAPIKey
        } label: {
            Label("Delete key", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityHint("Requires confirmation")
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Location",
                subtitle: "Control automatic place context for newly saved notes."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    SettingsToggleRow(
                        title: "Capture location with new notes",
                        detail: "When enabled and iOS permission is available, a current place can be attached during save. A note still saves if location fails.",
                        isOn: locationCaptureBinding
                    )

                    Divider()

                    SettingsStatusRow(
                        title: locationPermission.title,
                        detail: locationPermission.detail,
                        systemImage: locationPermission.systemImage,
                        tint: locationPermission.tint
                    )

                    if locationService.canRequestPermission {
                        MindMapPrimaryButton(
                            title: "Request location access",
                            systemImage: "location.fill",
                            expands: false,
                            action: locationService.requestPermission
                        )
                    } else {
                        MindMapSecondaryButton(
                            title: "Open iOS Settings",
                            systemImage: "gear",
                            expands: false,
                            action: openSystemSettings
                        )
                    }

                    Text("Location remains visible on a saved note and can be edited or removed. Revoking iOS permission stops future capture; it does not silently erase places already stored in notes.")
                        .mindMapTextStyle(.caption)

                    if let lastErrorMessage = locationService.lastErrorMessage {
                        MindMapErrorCallout(
                            title: "Location unavailable",
                            message: lastErrorMessage
                        )
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Local history",
                subtitle: "Recent questions are stored on this device only when enabled."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    SettingsToggleRow(
                        title: "Keep recent question history",
                        detail: "Turning this off prevents future entries. Existing entries remain until you clear them.",
                        isOn: localHistoryBinding
                    )

                    if store.queryHistory.isEmpty {
                        MindMapEmptyState(
                            title: "No recent questions",
                            message: "Questions and short answer summaries will appear here after a completed Ask request when local history is enabled."
                        )
                    } else {
                        Divider()

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(store.queryHistory.enumerated()), id: \.element.id) { index, item in
                                SettingsHistoryRow(item: item)

                                if index < store.queryHistory.count - 1 {
                                    Divider()
                                }
                            }
                        }

                        Button(role: .destructive) {
                            pendingConfirmation = .clearHistory
                        } label: {
                            Label("Clear question history", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: MindMapLayout.minimumTapTarget)
                                .contentShape(Rectangle())
                        }
                        .accessibilityHint("Requires confirmation")
                    }
                }
            }
        }
    }

    private var captureEverywhereSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Capture from anywhere",
                subtitle: "Use the same private note library from Apple system experiences."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    SettingsStatusRow(
                        title: "Share from other apps",
                        detail: "Choose Save to MindMap AI in an app's Share sheet. You can review or add text before saving.",
                        systemImage: "square.and.arrow.up",
                        tint: MindMapTheme.accent
                    )

                    Divider()

                    SettingsStatusRow(
                        title: "Quick Capture widget",
                        detail: "Add the MindMap AI Quick Capture widget to open a new note from the Home Screen.",
                        systemImage: "rectangle.3.group",
                        tint: MindMapTheme.info
                    )

                    Divider()

                    SettingsStatusRow(
                        title: "Siri and Shortcuts",
                        detail: "Run Capture a MindMap Note and provide note text without opening the app first.",
                        systemImage: "mic.badge.plus",
                        tint: MindMapTheme.source
                    )

                    Divider()

                    SettingsStatusRow(
                        title: "Spotlight search",
                        detail: "Saved notes are indexed privately on this device. Opening a result takes you to that note in Library.",
                        systemImage: "magnifyingglass",
                        tint: MindMapTheme.success
                    )
                }
            }

            MindMapCallout(
                kind: .info,
                title: "One library, no duplicate store",
                message: "Share and Shortcut captures wait in a protected inbox, then import through the normal note-save path when MindMap AI next runs."
            )
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Your data",
                subtitle: "Export a readable archive or permanently remove local data."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MindMapSpacing.small) {
                            dataCountChips
                        }

                        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
                            dataCountChips
                        }
                    }

                    Text("JSON export includes notes, accepted tags, plans, recent questions, drafts, and preferences. It never includes the OpenAI API key.")
                        .mindMapTextStyle(.supporting)

                    MindMapSecondaryButton(
                        title: "Export JSON file",
                        systemImage: "square.and.arrow.up",
                        expands: false,
                        action: prepareExport
                    )

                    Divider()

                    SettingsDestructiveButton(
                        title: "Delete all data and API key",
                        systemImage: "trash.fill"
                    ) {
                        pendingConfirmation = .deleteAllData
                    }
                    .disabled(isDeletingAllData)

                    if let dataMessage {
                        MindMapCallout(kind: .success, title: "Data controls", message: dataMessage)
                    }

                    if let dataError {
                        MindMapErrorCallout(title: "Data action incomplete", message: dataError)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dataCountChips: some View {
        MindMapTagChip(title: "\(store.notes.count) notes", systemImage: "note.text")
        MindMapTagChip(title: "\(store.plans.count) plans", systemImage: "checklist")
        MindMapTagChip(title: "\(store.queryHistory.count) recent", systemImage: "clock")
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.medium) {
            MindMapSectionHeader(
                title: "Privacy behavior",
                subtitle: "A concise summary of where information is handled."
            )

            MindMapCard {
                VStack(alignment: .leading, spacing: MindMapSpacing.large) {
                    SettingsPrivacyPoint(
                        title: "Local by default",
                        detail: "Notes, tags, plans, drafts, filters, and optional history are stored in the app’s local data file.",
                        systemImage: "iphone"
                    )

                    Divider()

                    SettingsPrivacyPoint(
                        title: "External AI is opt-in",
                        detail: "Only the question and retrieved excerpts needed for a conclusion are sent after consent. Provider retention or training behavior depends on the OpenAI service and project settings in use.",
                        systemImage: "network.badge.shield.half.filled"
                    )

                    Divider()

                    SettingsPrivacyPoint(
                        title: "Location is controlled by you",
                        detail: "iOS permission and the in-app toggle govern future capture. Saved places remain editable and removable note by note.",
                        systemImage: "location.circle"
                    )

                    Divider()

                    SettingsPrivacyPoint(
                        title: "Private content stays out of analytics by default",
                        detail: "Note bodies, precise locations, and full prompts must not be included in analytics. Export happens only when you request it.",
                        systemImage: "hand.raised.fill"
                    )
                }
            }

            MindMapCallout(
                kind: .warning,
                title: "Pre-release and high-stakes safeguard",
                message: "Before public launch, verify provider retention and training settings, provider access security, deletion and location documentation, privacy review, and handling of third-party content. MindMap AI can be incomplete or wrong; do not rely on it for medical, legal, financial, emergency, safety-critical, or academic-integrity decisions. Check the original notes and qualified sources."
            )
        }
    }

    private var consentBinding: Binding<AIProcessingConsent> {
        Binding(
            get: { store.preferences.aiProcessingConsent },
            set: { newValue in
                let previousValue = store.preferences.aiProcessingConsent
                consentMessage = nil
                consentError = nil
                store.preferences.aiProcessingConsent = newValue

                guard store.preferences.aiProcessingConsent == newValue else {
                    var details = store.persistenceMessage
                        ?? "The choice could not be saved to local storage."

                    // If durable storage fails while the user is withdrawing an accepted
                    // permission, remove the provider credential as a fail-closed fallback.
                    // This prevents future excerpts from being sent even though the preference
                    // itself had to roll back to its last durable value.
                    if previousValue == .accepted, newValue != .accepted {
                        do {
                            try apiKeyStore.deleteAPIKey()
                            hasAPIKey = false
                            maskedAPIKey = ""
                            apiKeyDraft = ""
                            apiKeyError = nil
                            apiKeyMessage = "The OpenAI API key was removed to keep external processing off."
                            details += " The stored OpenAI API key was removed to keep external processing off; fix local storage before enabling it again."
                        } catch {
                            apiKeyMessage = nil
                            apiKeyError = error.localizedDescription
                            details += " The OpenAI API key also could not be removed: \(error.localizedDescription)"
                        }
                    }

                    consentError = details
                    return
                }

                switch newValue {
                case .undecided:
                    consentMessage = "MindMap AI will explain external processing again before the first AI conclusion request."
                case .accepted:
                    consentMessage = "Relevant excerpts may be sent for future AI conclusion requests."
                case .declined:
                    consentMessage = "External conclusion generation is off. All local features remain available."
                }
            }
        )
    }

    private var locationCaptureBinding: Binding<Bool> {
        Binding(
            get: { store.preferences.locationCaptureEnabled },
            set: { store.preferences.locationCaptureEnabled = $0 }
        )
    }

    private var modelOptionBinding: Binding<String> {
        Binding(
            get: { selectedModelOptionID },
            set: { newSelection in
                let previousSelection = selectedModelOptionID
                selectedModelOptionID = newSelection
                modelMessage = nil
                modelError = nil
                clearConnectionTestFeedback()

                if newSelection == OpenAIModelCatalog.customSelectionID {
                    if previousSelection != OpenAIModelCatalog.customSelectionID,
                       OpenAIModelCatalog.option(for: modelDraft) != nil {
                        modelDraft = ""
                    }
                    focusedField = .model
                } else if let option = OpenAIModelCatalog.option(for: newSelection) {
                    modelDraft = option.id
                    focusedField = nil
                }
            }
        )
    }

    private var localHistoryBinding: Binding<Bool> {
        Binding(
            get: { store.preferences.keepLocalHistory },
            set: { store.preferences.keepLocalHistory = $0 }
        )
    }

    private var cleanedAPIKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanedModelDraft: String {
        modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var providerStatus: SettingsStatus {
        if isLoadingAPIKeyStatus {
            return SettingsStatus(
                title: "Checking OpenAI configuration",
                detail: "Reading credential status from the iOS Keychain.",
                systemImage: "ellipsis.circle",
                tint: MindMapTheme.info
            )
        }

        guard hasAPIKey else {
            return SettingsStatus(
                title: "OpenAI setup incomplete",
                detail: "A securely stored API key is required for AI conclusions.",
                systemImage: "key.slash",
                tint: MindMapTheme.warning
            )
        }

        guard store.preferences.aiProcessingConsent == .accepted else {
            return SettingsStatus(
                title: "External processing not enabled",
                detail: "The key is configured, but relevant excerpts will not be sent unless you allow processing.",
                systemImage: "hand.raised.fill",
                tint: MindMapTheme.warning
            )
        }

        guard connectivityMonitor.isConnected else {
            return SettingsStatus(
                title: "OpenAI unavailable while offline",
                detail: "The key is configured. Local features continue to work without a connection.",
                systemImage: "wifi.slash",
                tint: MindMapTheme.error
            )
        }

        return SettingsStatus(
            title: "OpenAI ready to try",
            detail: "Consent, a key, and network access are available. The provider validates the key and model only when a request is made.",
            systemImage: "checkmark.shield.fill",
            tint: MindMapTheme.success
        )
    }

    private var networkStatus: SettingsStatus {
        let snapshot = connectivityMonitor.snapshot
        switch snapshot.status {
        case .connected:
            var details = [snapshot.interface.rawValue]
            if snapshot.isConstrained { details.append("Low Data Mode") }
            if snapshot.isExpensive { details.append("metered connection") }
            return SettingsStatus(
                title: "Network connected",
                detail: details.joined(separator: " • "),
                systemImage: snapshot.interface == .cellular ? "antenna.radiowaves.left.and.right" : "wifi",
                tint: MindMapTheme.success
            )
        case .requiresConnection:
            return SettingsStatus(
                title: "Network needs attention",
                detail: "A connection may become available after the device completes network setup.",
                systemImage: "wifi.exclamationmark",
                tint: MindMapTheme.warning
            )
        case .offline:
            return SettingsStatus(
                title: "Offline",
                detail: "Capture, library, filters, map, plans, and local search remain available.",
                systemImage: "wifi.slash",
                tint: MindMapTheme.error
            )
        }
    }

    private var locationPermission: SettingsStatus {
        switch locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return SettingsStatus(
                title: "Location access allowed",
                detail: store.preferences.locationCaptureEnabled
                    ? "New notes can capture a current place during save."
                    : "iOS access is allowed, but automatic capture is turned off above.",
                systemImage: "location.fill",
                tint: MindMapTheme.success
            )
        case .notDetermined:
            return SettingsStatus(
                title: "Location access not requested",
                detail: "Request access only if you want automatic place context on new notes.",
                systemImage: "location.circle",
                tint: MindMapTheme.info
            )
        case .denied:
            return SettingsStatus(
                title: "Location access denied",
                detail: "Enable access in iOS Settings to capture a current place. Notes still save without it.",
                systemImage: "location.slash.fill",
                tint: MindMapTheme.warning
            )
        case .restricted:
            return SettingsStatus(
                title: "Location access restricted",
                detail: "A device or family restriction prevents location access. Notes still save without it.",
                systemImage: "lock.fill",
                tint: MindMapTheme.warning
            )
        @unknown default:
            return SettingsStatus(
                title: "Location status unavailable",
                detail: "Notes still save without a place.",
                systemImage: "questionmark.circle",
                tint: MindMapTheme.warning
            )
        }
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "MindMap-AI-Export-\(formatter.string(from: .now))"
    }

    private func loadInitialState() {
        synchronizeModelDraft(with: store.preferences.aiModel)
        reloadAPIKeyStatus()
    }

    private func synchronizeModelDraft(with model: String) {
        modelDraft = model
        selectedModelOptionID = OpenAIModelCatalog.selectionID(for: model)
    }

    private func reloadAPIKeyStatus() {
        isLoadingAPIKeyStatus = true
        defer { isLoadingAPIKeyStatus = false }

        do {
            if let apiKey = try apiKeyStore.loadAPIKey() {
                hasAPIKey = true
                maskedAPIKey = Self.maskedKeyDescription(apiKey)
            } else {
                hasAPIKey = false
                maskedAPIKey = ""
            }
            apiKeyError = nil
        } catch {
            hasAPIKey = false
            maskedAPIKey = ""
            apiKeyError = error.localizedDescription
        }
    }

    private func saveAPIKey() {
        let newKey = cleanedAPIKeyDraft
        guard !newKey.isEmpty else {
            apiKeyError = "Enter an API key before saving."
            apiKeyMessage = nil
            return
        }

        do {
            clearConnectionTestFeedback()
            try apiKeyStore.saveAPIKey(newKey)
            hasAPIKey = true
            maskedAPIKey = Self.maskedKeyDescription(newKey)
            apiKeyDraft = ""
            focusedField = nil
            apiKeyError = nil
            apiKeyMessage = "The API key was saved in the iOS Keychain. Its value is not written to the local archive."
        } catch {
            apiKeyMessage = nil
            apiKeyError = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            clearConnectionTestFeedback()
            try apiKeyStore.deleteAPIKey()
            hasAPIKey = false
            maskedAPIKey = ""
            apiKeyDraft = ""
            apiKeyError = nil
            apiKeyMessage = "The API key was removed. Local notes, plans, and search were not changed."
        } catch {
            apiKeyMessage = nil
            apiKeyError = error.localizedDescription
        }
    }

    private func saveModel() {
        let model = cleanedModelDraft
        guard !model.isEmpty else {
            modelMessage = nil
            modelError = "Enter a model ID before saving."
            return
        }

        clearConnectionTestFeedback()
        store.preferences.aiModel = model
        guard store.preferences.aiModel == model else {
            synchronizeModelDraft(with: store.preferences.aiModel)
            modelMessage = nil
            modelError = store.persistenceMessage ?? "The model ID could not be saved to local storage."
            return
        }

        synchronizeModelDraft(with: store.preferences.aiModel)
        focusedField = nil
        modelError = nil
        modelMessage = "Future AI conclusion requests will use \(model)."
    }

    private func testConnection() {
        guard !isTestingConnection else { return }

        let model = cleanedModelDraft
        guard !model.isEmpty else {
            connectionTestMessage = nil
            connectionTestError = OpenAIConnectionTestError.missingModel.localizedDescription
            return
        }

        let key: String
        do {
            guard let storedKey = try apiKeyStore.loadAPIKey() else {
                connectionTestMessage = nil
                connectionTestError = OpenAIConnectionTestError.missingAPIKey.localizedDescription
                return
            }
            key = storedKey
        } catch {
            connectionTestMessage = nil
            connectionTestError = "MindMap AI could not read the saved API key from the iOS Keychain. \(error.localizedDescription)"
            return
        }

        guard connectivityMonitor.isConnected else {
            connectionTestMessage = nil
            connectionTestError = OpenAIConnectionTestError.networkUnavailable.localizedDescription
            return
        }

        clearConnectionTestFeedback()
        let generation = UUID()
        connectionTestGeneration = generation
        isTestingConnection = true
        let tester = connectionTester

        connectionTestTask = Task { @MainActor in
            defer {
                if connectionTestGeneration == generation {
                    isTestingConnection = false
                    connectionTestTask = nil
                    connectionTestGeneration = nil
                }
            }

            do {
                let result = try await tester.testConnection(apiKey: key, model: model)
                try Task.checkCancellation()
                guard connectionTestGeneration == generation else { return }
                connectionTestError = nil
                connectionTestMessage = "OpenAI accepted the saved Keychain key and confirmed access to \(result.modelID). No note content was sent."
            } catch is CancellationError {
                return
            } catch let error as OpenAIConnectionTestError {
                guard connectionTestGeneration == generation else { return }
                connectionTestMessage = nil
                connectionTestError = error.localizedDescription
            } catch {
                guard connectionTestGeneration == generation else { return }
                connectionTestMessage = nil
                connectionTestError = OpenAIConnectionTestError.invalidResponse.localizedDescription
            }
        }
    }

    private func clearConnectionTestFeedback() {
        connectionTestGeneration = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        isTestingConnection = false
        connectionTestMessage = nil
        connectionTestError = nil
    }

    private func prepareExport() {
        do {
            exportDocument = MindMapExportDocument(data: try store.exportData())
            dataError = nil
            dataMessage = nil
            isPresentingExporter = true
        } catch {
            exportDocument = nil
            dataMessage = nil
            dataError = error.localizedDescription
        }
    }

    private func clearHistory() {
        if store.clearQueryHistory() {
            dataError = nil
            dataMessage = "Recent question history was cleared. Saved notes and plans were not changed."
        } else {
            dataMessage = nil
            dataError = store.persistenceMessage ?? "Recent question history could not be cleared."
        }
    }

    private func deleteAllData() {
        guard !isDeletingAllData else { return }
        isDeletingAllData = true
        clearConnectionTestFeedback()
        dataMessage = nil
        dataError = nil

        Task { @MainActor in
            await performDeleteAllData()
            isDeletingAllData = false
        }
    }

    private func performDeleteAllData() async {
        var failures: [String] = []

        do {
            try store.deleteAllLocalData()
        } catch {
            failures.append("Local data: \(error.localizedDescription)")
        }

        do {
            try apiKeyStore.deleteAPIKey()
        } catch {
            failures.append("API key: \(error.localizedDescription)")
        }

        do {
            try MindMapSharedCaptureInbox().deleteAllQueuedCaptures()
        } catch {
            failures.append("Shared capture inbox: \(error.localizedDescription)")
        }

        do {
            try await MindMapSpotlightIndexer.shared.deleteAllNoteItems()
        } catch {
            failures.append("Spotlight note index: \(error.localizedDescription)")
        }

        apiKeyDraft = ""
        synchronizeModelDraft(with: store.preferences.aiModel)
        reloadAPIKeyStatus()

        if failures.isEmpty {
            dataError = nil
            dataMessage = "All local MindMap AI data, queued outside captures, Spotlight note entries, and the API key were deleted."
            consentMessage = nil
            modelMessage = nil
        } else {
            dataMessage = nil
            dataError = "Some items could not be removed. " + failures.joined(separator: " ")
        }
    }

    private func openSystemSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private static func maskedKeyDescription(_ apiKey: String) -> String {
        // A fixed mask avoids exposing key length. Only a suffix is shown when
        // the stored value is long enough to avoid revealing the whole secret.
        guard apiKey.count > 4 else { return "••••••••••••" }
        return "•••••••••••• \(apiKey.suffix(4))"
    }
}

/// Screen-name alias matching the other top-level MindMap AI tabs.
typealias SettingsView = MindMapSettingsView

/// JSON document used by the system file exporter. It contains only the data
/// produced by `MindMapStore.exportData()`; credentials never enter this type.
struct MindMapExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum SettingsField: Hashable {
    case model
    case apiKey
}

private enum SettingsConfirmation: String, Identifiable {
    case deleteAPIKey
    case clearHistory
    case deleteAllData

    var id: String { rawValue }
}

private struct SettingsStatus {
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color
}

private struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MindMapTheme.textPrimary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MindMapTheme.textPrimary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, MindMapSpacing.small)
        }
        .tint(MindMapTheme.accent)
        .frame(minHeight: MindMapLayout.minimumTapTarget)
        .accessibilityHint(detail)
    }
}

private struct SettingsHistoryRow: View {
    let item: QueryHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: MindMapSpacing.small) {
            Text(item.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MindMapTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !item.answerSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.answerSummary)
                    .font(.caption)
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .lineLimit(3)
            }

            HStack(spacing: MindMapSpacing.medium) {
                Label(
                    item.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock"
                )
                Label(
                    "\(item.sourceCount) source\(item.sourceCount == 1 ? "" : "s")",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .font(.caption2)
            .foregroundStyle(MindMapTheme.textTertiary)
        }
        .padding(.vertical, MindMapSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Question: \(item.question). Asked \(item.createdAt.formatted(date: .abbreviated, time: .shortened)). \(item.sourceCount) source notes."
        )
    }
}

private struct SettingsPrivacyPoint: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: MindMapSpacing.xSmall) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MindMapTheme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MindMapTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(MindMapTheme.accent)
                .frame(width: 28, height: 28)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsDestructiveButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MindMapSpacing.large)
                .padding(.vertical, MindMapSpacing.small)
                .frame(maxWidth: .infinity)
                .frame(minHeight: MindMapLayout.minimumTapTarget)
                .background(MindMapTheme.error.opacity(0.09), in: RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MindMapCornerRadius.control, style: .continuous)
                        .stroke(MindMapTheme.error.opacity(0.35), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .accessibilityHint("Requires confirmation")
    }
}
