import Foundation

@MainActor
final class ProfileStore {
    private let defaults: UserDefaults
    private let key = "connectionProfiles.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return [.local] }
        return profiles
    }

    func save(_ profiles: [ConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }
}
