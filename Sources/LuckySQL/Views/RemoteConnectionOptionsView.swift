import SwiftUI

struct RemoteConnectionOptionsView: View {
    @ObservedObject var draft: ConnectionDraft
    private func tls<T>(_ path: WritableKeyPath<TLSOptions, T>) -> Binding<T> {
        Binding(get: { (draft.profile.tls ?? TLSOptions())[keyPath: path] }, set: {
            var options = draft.profile.tls ?? TLSOptions(); options[keyPath: path] = $0; draft.profile.tls = options
        })
    }
    private func ssh<T>(_ path: WritableKeyPath<SSHOptions, T>) -> Binding<T> {
        Binding(get: { (draft.profile.ssh ?? SSHOptions())[keyPath: path] }, set: {
            var options = draft.profile.ssh ?? SSHOptions(); options[keyPath: path] = $0; draft.profile.ssh = options
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Require verified TLS", isOn: tls(\.enabled))
            if draft.profile.tls?.enabled == true {
                TextField("CA PEM file (optional; otherwise system roots)", text: tls(\.caFile))
                TextField("Certificate hostname (defaults to database host)", text: tls(\.serverName))
                TextField("Client certificate PEM (optional)", text: tls(\.certificateFile))
                TextField("Client private key PEM (optional)", text: tls(\.privateKeyFile))
                Text("Certificate and hostname verification are mandatory. No plaintext fallback.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("SSH tunnel", isOn: ssh(\.enabled))
            if draft.profile.ssh?.enabled == true {
                TextField("SSH host", text: ssh(\.host))
                HStack {
                    TextField("SSH user", text: ssh(\.username))
                    TextField("Port", value: ssh(\.port), format: .number).frame(width: 80)
                }
                TextField("Identity file (optional; SSH agent is supported)", text: ssh(\.identityFile))
                SecureField("SSH password / key passphrase (optional)", text: $draft.sshPassword)
                TextField("Known hosts file (optional; defaults to ~/.ssh/known_hosts)", text: ssh(\.knownHostsFile))
                Text("Host identity must already be trusted in known_hosts. Database host is resolved from the SSH server. Secrets are saved to Keychain only after connection succeeds.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Connect timeout (s)")
                TextField("30", value: Binding(get: { draft.profile.connectTimeout ?? 30 }, set: { draft.profile.connectTimeout = $0 }), format: .number)
                Text("Query timeout (s)")
                TextField("0", value: Binding(get: { draft.profile.queryTimeout ?? 0 }, set: { draft.profile.queryTimeout = $0 }), format: .number)
            }.font(.caption)
            Text("Query timeout 0 disables the deadline. A timeout closes the session; drafts are retained. Writes are never replayed automatically.").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}
