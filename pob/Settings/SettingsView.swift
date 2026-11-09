import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Picker("Search Engine", selection: $model.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Button("Make pob the Default Browser") { model.makeDefaultBrowser() }
            }
            Section("Profiles") {
                List(model.profiles, selection: $model.selectedProfileID) { profile in
                    ProfileNameField(model: model, profile: profile)
                }
                .frame(height: 160)
                Button("New Profile") { model.addProfile() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

/// Renames on Return. A name the list won't take, such as a blank one, puts the current name back.
private struct ProfileNameField: View {
    let model: SettingsModel
    let profile: ProfileInfo
    @State private var name = ""

    var body: some View {
        TextField("Profile Name", text: $name)
            .textFieldStyle(.plain)
            .onSubmit {
                model.rename(profile.id, to: name)
                name = model.profiles.first { $0.id == profile.id }?.name ?? name
            }
            .onChange(of: profile.name, initial: true) { name = profile.name }
    }
}
