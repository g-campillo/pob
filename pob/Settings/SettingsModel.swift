import Foundation
import Observation

/// What the Settings window shows. Changes go straight to the profile list and the appearance settings, which save them.
@Observable final class SettingsModel {
    private(set) var profiles: [ProfileInfo]
    var searchEngine: SearchEngine {
        didSet { appearance.searchEngine = searchEngine }
    }
    var selectedProfileID: UUID?
    /// `AppController` sets it.
    @ObservationIgnored var makeDefaultBrowser: () -> Void = {}

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
}
