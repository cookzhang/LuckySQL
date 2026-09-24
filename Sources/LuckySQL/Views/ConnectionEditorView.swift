import SwiftUI

struct ConnectionEditorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var draft: ConnectionDraft
    @State private var showAdvanced = false
    @FocusState private var focused: Field?
    private enum Field { case host, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(LocalizedStringKey(draft.isNew ? "Add Connection" : "Edit Connection"), systemImage: "server.rack")
                .font(.title2.bold())
            Form {
                TextField("Host", text: $draft.profile.host).focused($focused, equals: .host)
                TextField("Port", text: $draft.port)
                TextField("User", text: $draft.profile.username)
                SecureField("Password", text: $draft.password).focused($focused, equals: .password)
                TextField("Database (optional)", text: $draft.profile.database)
                TextField("Name (optional)", text: $draft.profile.name)
            }.textFieldStyle(.roundedBorder).disabled(model.isRunning)
            ScrollView { DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                RemoteConnectionOptionsView(draft: draft)
                Toggle("Read-only protection", isOn: Binding(get: { draft.profile.readOnly == true }, set: { draft.profile.readOnly = $0 }))
                Text("Client protection does not replace database account permissions.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isRunning) }.frame(height: showAdvanced ? 300 : 24)
            if draft.isLoadingPassword {
                HStack { ProgressView().controlSize(.small); Text("Loading saved password…").font(.caption) }
            } else if let notice = draft.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = draft.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isRunning { ProgressView().controlSize(.small); Text("Connecting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") {
                    if model.isRunning { model.disconnect() }
                    model.cancelConnectionEditor()
                }.keyboardShortcut(.cancelAction)
                Button("Connect") { model.submitConnection(draft) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || draft.isLoadingPassword)
            }
        }
        .padding(24).frame(width: 460)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear { focused = draft.isNew ? .host : .password }
    }
}
