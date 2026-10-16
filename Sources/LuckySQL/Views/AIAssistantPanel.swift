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
    @State private var conversationExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contextSummary
                        if session.includeSQL { payloadPreview }
                        if let notice = configurationStore.storageNotice {
                            Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let context = session.context { sentContext(context) }
                        if let notice = session.historyNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        conversation
                        if session.isRunning {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Receiving AI response…").font(.callout)
                                }
                                Text("Wait for a complete suggestion before accepting SQL.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .id(AIAssistantScrollTarget.receiving)
                        }
                        if let error = session.errorMessage {
                            Label { Text(error).textSelection(.enabled) } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .font(.caption).foregroundStyle(.orange)
                            .id(AIAssistantScrollTarget.failure)
                        }
                        if let suggestion = session.suggestion, !session.isRunning {
                            suggestionContent(suggestion)
                                .id(AIAssistantScrollTarget.reply)
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
                .onChange(of: scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    // Wait for the new response/status anchor to join the layout.
                    // Streaming tokens do not change this target or move the view.
                    Task { @MainActor in
                        await Task.yield()
                        guard scrollTarget == target else { return }
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
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

    private var scrollTarget: AIAssistantScrollTarget? {
        if session.isRunning { return .receiving }
        if session.errorMessage != nil { return .failure }
        if session.suggestion != nil { return .reply }
        return nil
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
            Text("Table names, descriptions, selected table structures and server details are sent. Row data and connection passwords are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isConnected {
                Text("Connect to a database before sending an AI request.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func sentContext(_ context: AIContextSnapshot) -> some View {
        let tables = AISchemaPreviewTable.decode(context.schemaMetadata)
        return DisclosureGroup("Last Request Context") {
            VStack(alignment: .leading, spacing: 6) {
                if !context.connectionName.isEmpty { Text("Connection: \(context.connectionName)").font(.caption) }
                Text("Database: \(context.database)").font(.caption)
                if tables.isEmpty {
                    ForEach(context.tableNames, id: \.self) { name in
                        Label(name, systemImage: "tablecells").font(.caption).textSelection(.enabled)
                    }
                }
                if context.tableNames.isEmpty { Text("No table metadata included").font(.caption).foregroundStyle(.secondary) }
                if !context.serverVersion.isEmpty { Text("Server: \(context.serverVersion)").font(.caption) }
                if !context.timeZone.isEmpty { Text("Session time zone: \(context.timeZone)").font(.caption) }
                Text(LocalizedStringKey(context.sourceSQL.isEmpty ? "Current SQL was excluded" : "SQL was included"))
                    .font(.caption).foregroundStyle(.secondary)
                if !tables.isEmpty {
                    Divider().padding(.vertical, 3)
                    Text("Loaded Table Structures").font(.caption.weight(.medium))
                    ForEach(Array(tables.enumerated()), id: \.offset) { _, table in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(column.name).font(.system(.caption, design: .monospaced))
                                            Spacer(minLength: 0)
                                            Text(column.type).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if let comment = column.comment, !comment.isEmpty {
                                            Text(comment).font(.caption).foregroundStyle(.secondary)
                                        }
                                        if column.commentTruncated == true {
                                            Text("Description truncated").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .textSelection(.enabled)
                                }
                                if table.columnsTruncated == true {
                                    Text("Only part of this table's columns was included.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(table.table).font(.system(.caption, design: .monospaced))
                                if let comment = table.comment, !comment.isEmpty {
                                    Text(comment).font(.caption).foregroundStyle(.secondary)
                                }
                                if table.commentTruncated == true {
                                    Text("Description truncated").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.textSelection(.enabled)
                        }
                    }
                } else if !context.tableNames.isEmpty {
                    Text("Loaded table details could not be displayed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !context.tableCatalog.isEmpty {
                    Divider().padding(.vertical, 3)
                    DisclosureGroup("Table Catalog") {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            Text("Names and descriptions only. Full columns are loaded separately.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Catalog descriptions may be shortened.").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(context.tableCatalog.enumerated()), id: \.offset) { _, table in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(table.table.id)
                                        .font(.system(.caption, design: .monospaced))
                                    if !table.comment.isEmpty {
                                        Text(table.comment).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.textSelection(.enabled)
                            }
                            if context.catalogTruncated {
                                Text("Only part of the table catalog was included. Reply with an exact table name to load its structure.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 6)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var conversation: some View {
        let messages = conversationMessages
        if !messages.isEmpty {
            DisclosureGroup("Conversation", isExpanded: $conversationExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        conversationEntry(message)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.medium))
        }
    }

    private var conversationMessages: [AIChatMessage] {
        var messages = session.messages
        // The latest completed reply has its own review and acceptance controls.
        if session.suggestion != nil, messages.last?.role == .assistant { messages.removeLast() }
        if let pendingPrompt = session.pendingPrompt, session.isRunning {
            let intent = pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? session.action.displayName : pendingPrompt
            if messages.last?.role != .user || messages.last?.content != intent {
                messages.append(AIChatMessage(role: .user, content: intent))
            }
        }
        return messages
    }

    @ViewBuilder
    private func conversationEntry(_ message: AIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(message.role == .user ? "You" : "AI Reply"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if message.role == .user {
                if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Request sent without additional instructions.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(message.content).font(.callout).textSelection(.enabled)
                }
            } else if let reply = AIConversationPreview.decode(message.content) {
                Text(reply.explanation).font(.callout).textSelection(.enabled)
                if let assumptions = reply.assumptions, !assumptions.isEmpty {
                    DisclosureGroup("Earlier Assumptions") {
                        ForEach(Array(assumptions.enumerated()), id: \.offset) { _, assumption in
                            Text("• " + assumption).font(.caption).textSelection(.enabled)
                        }.padding(.top, 4)
                    }.font(.caption)
                }
                if let sql = reply.sql, !sql.isEmpty {
                    DisclosureGroup("Earlier SQL · Read Only") { sqlPreview(sql).padding(.top, 6) }
                        .font(.caption)
                }
            } else {
                Text("This earlier AI reply could not be displayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
    }

    @ViewBuilder
    private func suggestionContent(_ suggestion: AISuggestion) -> some View {
        let current = model.isAISuggestionCurrent(suggestion)
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Reply", systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if suggestion.sql != nil {
                Label("Not verified or executed", systemImage: "doc.text")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                        let prompt = session.prompt, action = session.action, includeSQL = session.includeSQL
                        model.startAIAssistance(action: action, prompt: prompt, includeSQL: includeSQL)
                        if session.isRunning { session.prompt = "" }
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

private enum AIAssistantScrollTarget: Hashable {
    case receiving, failure, reply
}

private struct AIConversationPreview: Decodable {
    let explanation: String
    let sql: String?
    let assumptions: [String]?

    static func decode(_ content: String) -> Self? {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let line = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: line)..<json.index(json.endIndex, offsetBy: -3)])
        }
        return try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

private struct AISchemaPreviewTable: Decodable {
    let table: String
    let comment: String?
    let columns: [AISchemaPreviewColumn]
    let columnsTruncated: Bool?
    let commentTruncated: Bool?

    private enum CodingKeys: String, CodingKey {
        case table, comment, columns
        case columnsTruncated = "columns_truncated"
        case commentTruncated = "comment_truncated"
    }

    static func decode(_ metadata: String) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: Data(metadata.utf8))) ?? []
    }
}

private struct AISchemaPreviewColumn: Decodable {
    let name: String
    let type: String
    let comment: String?
    let commentTruncated: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, type, comment
        case commentTruncated = "comment_truncated"
    }
}
