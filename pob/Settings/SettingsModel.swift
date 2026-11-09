import Foundation
import Observation

/// What the Settings window shows. Changes go straight to the profile list and the appearance settings, which save them.
@Observable final class SettingsModel {
    private(set) var profiles: [ProfileInfo]
    var searchEngine: SearchEngine {
        didSet { appearance.searchEngine = searchEngine }
    }
    var selectedProfileID: UUID?
    /// `AppController` sets these.
    @ObservationIgnored var makeDefaultBrowser: () -> Void = {}
    /// nil for an id that isn't listed.
    @ObservationIgnored var findProfile: (UUID) -> Profile? = { _ in nil }
    @ObservationIgnored var canDeleteProfile: (UUID) -> Bool = { _ in false }
    @ObservationIgnored var deleteProfile: (UUID) async throws -> Void = { _ in }

    @ObservationIgnored private let list: ProfileList
    @ObservationIgnored private let appearance: AppearanceModel

    init(profiles: ProfileList, appearance: AppearanceModel) {
        list = profiles
        self.appearance = appearance
        self.profiles = profiles.all
        searchEngine = appearance.searchEngine
        profiles.addObserver { [weak self] in
            guard let self else { return }
            self.profiles = list.all
        }
    }

    /// The new profile is selected, ready to be named.
    func addProfile() {
        selectedProfileID = list.add(name: "").id
    }

    func rename(_ id: UUID, to name: String) {
        list.rename(id, to: name)
    }

    func clearHistory(of id: UUID) async {
        await findProfile(id)?.history.clear()
    }

    func sitesWithBlockingOff(of id: UUID) -> [String] {
        findProfile(id)?.siteSettings.hostsWithAdBlockerOff ?? []
    }

    /// On is the default, so it leaves no entry.
    func turnBlockingBackOn(_ host: String, in id: UUID) {
        findProfile(id)?.siteSettings[host].adBlockerOff = nil
    }

    func canDelete(_ id: UUID) -> Bool {
        canDeleteProfile(id)
    }

    func delete(_ id: UUID) async throws {
        try await deleteProfile(id)
        if selectedProfileID == id { selectedProfileID = nil }
    }
}
