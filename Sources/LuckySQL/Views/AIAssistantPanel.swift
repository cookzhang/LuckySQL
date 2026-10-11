import AppKit
import SwiftUI

/// Keep token updates inside the assistant, away from the editor and result grid.
struct AIAssistantPanel: View {
    let model: AppModel
    @ObservedObject var assistant: AIAssistantModel
    let tabID: UUID

    var body: some View {
        Group {
            if let session = assistant.sessions[tabID],
               let tab = model.queryTabs.first(where: { $0.id == tabID }) {
                AIAssistantSessionPanel(model: model, assistant: assistant,
                                        session: session, document: tab.document, tabID: tabID)
                    .id(tabID)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: tabID) { _ = assistant.session(for: tabID) }
    }
}

private struct AIAssistantSessionPanel: View {
    let model: AppModel
    let assistant: AIAssistantModel
    @ObservedObject var session: AIAssistantSession
    @ObservedObject var document: QueryDocument
    @ObservedObject private var configurationStore = AIConfigurationStore.shared
    let tabID: UUID
    @State private var applicationError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextSummary
                    if session.includeSQL { payloadPreview }
                    if let notice = configurationStore.storageNotice {
                        Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let context = session.context { sentContext(context) }
                    if session.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Receiving AI response…").font(.callout)
                        }
                        Text("Wait for a complete suggestion before accepting SQL.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = session.errorMessage {
                        Label { Text(error).textSelection(.enabled) } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption).foregroundStyle(.orange)
                    }
                    if let suggestion = session.suggestion, !session.isRunning {
                        suggestionContent(suggestion)
                    } else if !session.isRunning && session.errorMessage == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Describe the query you need").font(.callout.weight(.medium))
                            Text("AI uses table structure to suggest SQL. You review the draft and run it yourself.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let applicationError {
                        Text(applicationError).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            composer
        }
        .onChange(of: session.action) { _, action in
            session.includeSQL = action != .generate
            applicationError = nil
        }
        .onChange(of: session.suggestion?.id) { _, _ in applicationError = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("AI Assistant", systemImage: "sparkles").font(.headline)
            Spacer(minLength: 0)
            if session.isRunning {
                Button("Stop", systemImage: "stop.circle") { assistant.cancel(tabID: tabID) }
                    .labelStyle(.iconOnly).help("Stop AI Request")
            }
            Button("Clear Conversation", systemImage: "trash") {
                assistant.clear(tabID: tabID); applicationError = nil
            }
            .labelStyle(.iconOnly).help("Clear Conversation")
            .disabled(session.messages.isEmpty && session.context == nil && session.errorMessage == nil && !session.isRunning)
            Button("AI Configuration…", systemImage: "gearshape") { model.showAIConfiguration = true }
                .labelStyle(.iconOnly).help("AI Configuration…")
            Button("Hide AI Assistant", systemImage: "sidebar.right") { model.showAIAssistant = false }
                .labelStyle(.iconOnly).help("Hide AI Assistant")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).frame(height: 38)
    }

    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Request Context").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(model.connectionLabel).font(.caption).lineLimit(2).textSelection(.enabled)
            Label(model.selectedDatabase.isEmpty ? NSLocalizedString("No database selected", comment: "") : model.selectedDatabase,
                  systemImage: "cylinder")
                .font(.callout)
            if let table = model.selectedTable {
                Label(table.id, systemImage: "tablecells").font(.caption).textSelection(.enabled)
            }
            Text("Table structure and server details are sent. Row data and connection passwords are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isConnected {
                Text("Connect to a database before sending an AI request.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func sentContext(_ context: AIContextSnapshot) -> some View {
        DisclosureGroup("Last Request Context") {
            VStack(alignment: .leading, spacing: 6) {
                if !context.connectionName.isEmpty { Text("Connection: \(context.connectionName)").font(.caption) }
                Text("Database: \(context.database)").font(.caption)
                ForEach(context.tableNames, id: \.self) { name in
                    Label(name, systemImage: "tablecells").font(.caption).textSelection(.enabled)
                }
                if context.tableNames.isEmpty { Text("No table metadata included").font(.caption).foregroundStyle(.secondary) }
                if !context.serverVersion.isEmpty { Text("Server: \(context.serverVersion)").font(.caption) }
                if !context.timeZone.isEmpty { Text("Session time zone: \(context.timeZone)").font(.caption) }
                Text(LocalizedStringKey(context.sourceSQL.isEmpty ? "Current SQL was excluded" : "SQL was included"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func suggestionContent(_ suggestion: AISuggestion) -> some View {
        let current = model.isAISuggestionCurrent(suggestion)
        VStack(alignment: .leading, spacing: 12) {
            Label("Not verified or executed", systemImage: "doc.text")
                .font(.caption).foregroundStyle(.secondary)
            Text(suggestion.explanation).font(.callout).textSelection(.enabled)
            if !suggestion.assumptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assumptions to Review").font(.caption.weight(.medium))
                    ForEach(Array(suggestion.assumptions.enumerated()), id: \.offset) { _, assumption in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(assumption).textSelection(.enabled)
                        }.font(.caption)
                    }
                }
            }
            ForEach(Array(suggestion.warnings.enumerated()), id: \.offset) { _, warning in
                Label { Text(warning).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(.orange)
            }
            if let sql = suggestion.sql {
                sqlPreview(sql)
                if !current {
                    Text("The source SQL or connection has changed. Send a new request before applying this suggestion.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("Copy SQL", systemImage: "doc.on.doc") { model.copy(sql) }
                    Button("Open in New Query", systemImage: "plus.square") { apply(suggestion, replacing: false) }
                        .disabled(!current || model.isRunning)
                }.controlSize(.small)
                Button("Replace Original SQL", systemImage: "arrow.triangle.2.circlepath") { apply(suggestion, replacing: true) }
                    .controlSize(.small)
                    .disabled(!current || suggestion.source.selection.length == 0 || model.isRunning)
                    .help("Replace only the original SQL captured for this request")
                if !suggestion.source.sourceSQL.isEmpty {
                    DisclosureGroup("Before / After") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Original SQL").font(.caption).foregroundStyle(.secondary)
                            sqlPreview(suggestion.source.sourceSQL)
                            Text("Suggested SQL").font(.caption).foregroundStyle(.secondary)
                            sqlPreview(sql)
                        }.padding(.top, 8)
                    }.font(.caption)
                }
            }
        }
    }

    private func sqlPreview(_ sql: String) -> some View {
        Text(sql).font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Action", selection: $session.action) {
                ForEach(AIAssistantAction.allCases) { action in Text(action.displayName).tag(action) }
            }
            .pickerStyle(.menu).disabled(session.isRunning)
            Toggle(LocalizedStringKey(session.action == .repair ? "Send failed SQL and error" : "Send current SQL / selection"), isOn: $session.includeSQL)
                .font(.caption).disabled(session.isRunning)
            if session.action == .repair && model.failedQueryForAI() == nil {
                Text("No failed query is available for this tab and database.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.action != .generate && !session.includeSQL {
                Text("Explain and repair require SQL context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if session.prompt.isEmpty {
                    Text("Describe a query or ask a follow-up…")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.top, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.prompt).font(.callout)
                    .scrollContentBackground(.hidden).disabled(session.isRunning)
                    .accessibilityLabel("AI Request")
            }
            .padding(5).frame(minHeight: 70, maxHeight: 100)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
            HStack {
                Text("SQL drafts stay local until included.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if session.isRunning {
                    Button("Stop") { assistant.cancel(tabID: tabID) }.controlSize(.small)
                } else {
                    Button("Send to AI", systemImage: "arrow.up") {
                        applicationError = nil
                        model.startAIAssistance(action: session.action, prompt: session.prompt, includeSQL: session.includeSQL)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(!canSend)
                }
            }
        }
        .padding(12)
    }

    private var payloadPreview: some View {
        DisclosureGroup("SQL to Send") {
            sqlPreview(sqlToSend).padding(.top, 6)
            if session.action == .repair, let failure = model.failedQueryForAI() {
                Text(failure.error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.font(.caption)
    }

    private var sqlToSend: String {
        if session.action == .repair { return model.failedQueryForAI()?.sql ?? "" }
        return SQLTools.executable(document.sql, selection: document.selection)
    }

    private var canSend: Bool {
        guard !session.isRunning, model.isConnected, !model.isRunning, model.activeTabID == tabID else { return false }
        if session.action == .generate { return !session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard session.includeSQL, !sqlToSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return session.action != .repair || model.failedQueryForAI() != nil
    }

    private func apply(_ suggestion: AISuggestion, replacing: Bool) {
        if !model.applyAISuggestion(suggestion, replacingSelection: replacing) {
            applicationError = NSLocalizedString("The suggestion no longer matches this query. Send a new request before applying it.", comment: "")
        }
    }
}
