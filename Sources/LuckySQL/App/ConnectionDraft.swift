import Foundation
import Combine

/// Editing is isolated from saved profiles and the live database connection.
@MainActor final class ConnectionDraft: ObservableObject, Identifiable {
    let id = UUID()
    let isNew: Bool
    @Published var profile: ConnectionProfile
    @Published var port: String
    @Published var password: String { didSet { passwordRevision += 1 } }
    @Published var isLoadingPassword = false
    @Published var notice: String?
    @Published var error: String?
    private(set) var passwordRevision = 0

    init(profile: ConnectionProfile, isNew: Bool, password: String = "") {
        self.profile = profile; self.isNew = isNew; self.password = password
        port = String(profile.port)
    }

    func validatedProfile() throws -> ConnectionProfile {
        var value = profile
        value.host = value.host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = value.username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.database = value.database.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.host.isEmpty, !value.host.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw InvalidConnection("Enter a valid host.") }
        let text = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(text), (1...65535).contains(number) else { throw InvalidConnection("Port must be between 1 and 65535.") }
        guard !value.username.isEmpty, !value.username.contains("\0") else { throw InvalidConnection("Enter a username.") }
        guard !value.database.contains("\0") else { throw InvalidConnection("Enter a valid database name.") }
        value.port = number
        if value.name.isEmpty { value.name = "\(value.username)@\(value.host)" }
        return value
    }
}

private struct InvalidConnection: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { NSLocalizedString(message, comment: "") }
}
