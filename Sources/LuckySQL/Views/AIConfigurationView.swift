import SwiftUI

@MainActor
struct AIConfigurationView: View {
    @ObservedObject var store: AIConfigurationStore
    private let provider: any AIProviding
    @Environment(\.dismiss) private var dismiss
    @State private var protocolKind: AIProtocol
    @State private var drafts: [AIProtocol: AIConfigurationFormDraft]
    @State private var showAPIKey = false
    @State private var loadingKey = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var didSave = false
    @State private var error: String?
    @State private var notice: String?
    @State private var testMessage: String?
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = UUID()

    init(store: AIConfigurationStore, provider: any AIProviding = AIHTTPClient()) {
        self.store = store; self.provider = provider
        _protocolKind = State(initialValue: store.configuration.protocolKind)
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: AIProtocol.allCases.map {
            ($0, AIConfigurationFormDraft(configuration: store.configuration(for: $0)))
        }))
    }

    private var draft: AIConfigurationFormDraft { drafts[protocolKind]! }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("AI Configuration", systemImage: "sparkles").font(.title2.bold())
            Text("Shared across all connections. Each API protocol keeps its own URL, model and API key.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("API Protocol", selection: $protocolKind) {
                    ForEach(AIProtocol.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Base URL", text: Binding(get: { draft.configuration.baseURL }, set: { value in updateBaseURL(value) }))
                TextField("Model", text: Binding(get: { draft.configuration.model }, set: { value in
                    drafts[protocolKind]!.configuration.model = value; markModified()
                }))
                HStack {
                    if showAPIKey { TextField("API Key", text: apiKeyBinding) }
                    else { SecureField("API Key", text: apiKeyBinding) }
                    Button { showAPIKey.toggle() } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless)
                        .help(LocalizedStringKey(showAPIKey ? "Hide API Key" : "Show API Key"))
                        .accessibilityLabel(LocalizedStringKey(showAPIKey ? "Hide API Key" : "Show API Key"))
                }
            }.textFieldStyle(.roundedBorder).disabled(isSaving || isTesting)
            VStack(alignment: .leading, spacing: 5) {
                Text("Request URL").font(.caption.bold())
                if let endpoint = try? draft.configuration.endpointURL() {
                    Text(endpoint.absoluteString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("Enter a valid base URL to see the request destination.").font(.caption).foregroundStyle(.secondary)
                }
                Text("API keys are saved in a separate macOS Keychain service. Changing the request URL clears the key; enter a key for the new destination.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if loadingKey { HStack { ProgressView().controlSize(.small); Text("Loading saved AI API key…").font(.caption) } }
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let testMessage { Text(testMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("Test Connection sends a small AI request and may incur usage charges. It includes no database data or SQL.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if isTesting {
                    ProgressView().controlSize(.small)
                    Button("Cancel Test") { cancelTest() }
                } else {
                    Button("Test Connection") { testConnection() }.disabled(isSaving || loadingKey)
                }
                Spacer()
                Button(LocalizedStringKey(didSave ? "Done" : "Cancel")) { cancelTest(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isSaving || isTesting || loadingKey || didSave)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(isSaving)
            .task(id: protocolKind) { await loadAPIKey() }
            .onChange(of: protocolKind) { _, _ in error = nil; notice = nil; testMessage = nil; didSave = false; showAPIKey = false }
            .onDisappear { cancelTest() }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: { draft.apiKey }, set: { value in
            drafts[protocolKind]!.apiKey = value
            drafts[protocolKind]!.keyRevision += 1
            drafts[protocolKind]!.didLoadAPIKey = true
            markModified()
        })
    }

    private func markModified() {
        drafts[protocolKind]!.isModified = true
        didSave = false; error = nil; testMessage = nil
    }

    private func updateBaseURL(_ value: String) {
        let old = draft.configuration
        var updated = old; updated.baseURL = value
        let oldEndpoint = try? old.endpointURL(), newEndpoint = try? updated.endpointURL()
        if old.baseURL != value && (oldEndpoint != newEndpoint || oldEndpoint == nil || newEndpoint == nil) {
            updated.apiKeyRecordID = UUID()
            drafts[protocolKind]!.apiKey = ""
            drafts[protocolKind]!.keyRevision += 1
            drafts[protocolKind]!.didLoadAPIKey = true
            notice = NSLocalizedString("The request URL changed. Enter an API key for the new destination.", comment: "AI endpoint key scope")
        }
        drafts[protocolKind]!.configuration = updated
        markModified()
    }

    private func loadAPIKey() async {
        let kind = protocolKind, snapshot = draft
        guard !snapshot.didLoadAPIKey else { loadingKey = false; return }
        loadingKey = true
        defer { if protocolKind == kind { loadingKey = false } }
        do {
            let key = try await store.loadAPIKey(for: snapshot.configuration)
            guard !Task.isCancelled, protocolKind == kind,
                  drafts[kind]!.configuration.apiKeyRecordID == snapshot.configuration.apiKeyRecordID,
                  drafts[kind]!.keyRevision == snapshot.keyRevision else { return }
            drafts[kind]!.apiKey = key ?? ""
            drafts[kind]!.didLoadAPIKey = true
        } catch {
            guard !Task.isCancelled, protocolKind == kind, drafts[kind]!.keyRevision == snapshot.keyRevision else { return }
            drafts[kind]!.didLoadAPIKey = true
            notice = NSLocalizedString("The saved AI API key could not be loaded. Enter it again; the existing Keychain item is unchanged.", comment: "AI key read unavailable")
        }
    }

    private func save() {
        let selected = protocolKind
        let changed = AIProtocol.allCases.filter { $0 == selected || drafts[$0]!.isModified }
        let configurations = changed.map { drafts[$0]!.configuration }
        let keys = Dictionary(uniqueKeysWithValues: changed.map { ($0, drafts[$0]!.apiKey) })
        error = nil; isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let storageNotice = try await store.saveDrafts(configurations, apiKeys: keys, selectedProtocol: selected)
                if let storageNotice {
                    notice = storageNotice; didSave = true
                    for kind in changed {
                        drafts[kind]!.configuration = store.configuration(for: kind)
                        drafts[kind]!.isModified = false
                    }
                } else { dismiss() }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func testConnection() {
        do {
            let configuration = try draft.configuration.validated()
            let apiKey = try AIConfigurationStore.validatedAPIKey(draft.apiKey)
            let request = AIProviderRequest(configuration: configuration, apiKey: apiKey,
                                            systemPrompt: "Connection test. Reply with OK.",
                                            messages: [AIChatMessage(role: .user, content: "Reply with OK.")])
            let generation = UUID(); testGeneration = generation
            error = nil; testMessage = nil; isTesting = true
            testTask = Task {
                do {
                    var receivedText = false
                    for try await token in provider.stream(request) {
                        try Task.checkCancellation()
                        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { receivedText = true }
                    }
                    guard !Task.isCancelled, testGeneration == generation else { return }
                    if receivedText { testMessage = NSLocalizedString("Connection test succeeded. The selected model returned a response.", comment: "AI connection test result") }
                    else { testMessage = NSLocalizedString("The AI endpoint returned no text. Check the model and protocol.", comment: "AI connection test result") }
                } catch {
                    guard !Task.isCancelled, testGeneration == generation else { return }
                    self.error = error.localizedDescription
                }
                guard testGeneration == generation else { return }
                isTesting = false; testTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private func cancelTest() {
        testGeneration = UUID(); testTask?.cancel(); testTask = nil; isTesting = false
    }
}

private struct AIConfigurationFormDraft {
    var configuration: AIConfiguration
    var apiKey = ""
    var keyRevision = 0
    var didLoadAPIKey = false
    var isModified = false
}
