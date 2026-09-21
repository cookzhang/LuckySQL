import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("appLanguage") private var language = "system"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedProfileID }, set: model.selectProfile)) {
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { model.addProfile() } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Add connection")
                    Button { model.deleteSelectedProfile() } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete connection")
                    .disabled(model.selectedProfileID == nil)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
            }
            .frame(width: 190)
            VStack(alignment: .leading, spacing: 14) {
                if let profile = binding {
                    Form {
                        TextField("Name", text: profile.name)
                        TextField("Host", text: profile.host)
                        TextField("Port", value: profile.port, format: .number.grouping(.never))
                        TextField("User", text: profile.username)
                        SecureField("Password", text: $model.password)
                        if model.isLoadingPassword { Text("Waiting for Keychain authorization…").font(.caption).foregroundStyle(.secondary) }
                        TextField("Default database", text: profile.database)
                        Picker("Environment", selection: Binding(get: { profile.wrappedValue.environment ?? "Development" }, set: { profile.wrappedValue.environment = $0; model.saveProfiles() })) {
                            Text("Development").tag("Development"); Text("Staging").tag("Staging"); Text("Production").tag("Production")
                        }
                        Toggle("Read-only protection", isOn: Binding(get: { profile.wrappedValue.readOnly ?? false }, set: { profile.wrappedValue.readOnly = $0; model.saveProfiles() }))
                        Text("Client-side protection; use a read-only database account for security.").font(.caption).foregroundStyle(.secondary)
                        Picker("Language / 语言", selection: $language) { Text("System / 跟随系统").tag("system"); Text("English").tag("en"); Text("简体中文").tag("zh-Hans") }
                            .onChange(of: language) { _, value in
                                if value == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                                else { UserDefaults.standard.set([value], forKey: "AppleLanguages") }
                            }
                        Text("Restart LuckySQL to apply the language.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Save & Connect") { model.saveProfiles(); model.connect() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isRunning)
                    }
                } else { ContentUnavailableView("Select a connection", systemImage: "server.rack") }
            }
            .padding(20)
        }
        .frame(width: 700, height: 510)
        .disabled(model.isRunning)
    }

    private var binding: Binding<ConnectionProfile>? {
        guard let id = model.selectedProfileID,
              let index = model.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return $model.profiles[index]
    }
}
