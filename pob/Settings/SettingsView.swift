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
            if let profile = model.profiles.first(where: { $0.id == model.selectedProfileID }) {
                ProfileData(model: model, profile: profile)
                    .id(profile.id)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

/// The selected profile's history, blocked sites and deletion. Windows open and close and sites change while Settings
/// stays open behind, so what can change from elsewhere is read again each time the window comes forward.
private struct ProfileData: View {
    let model: SettingsModel
    let profile: ProfileInfo
    @Environment(\.appearsActive) private var appearsActive
    @State private var sites: [String] = []
    @State private var confirmsClear = false
    @State private var confirmsDelete = false
    @State private var showsFailure = false
    @State private var failure = ""

    private var deleteCaption: String? {
        if model.deleting.contains(profile.id) { return "Deleting…" }
        if model.profiles.count - model.deleting.count < 2 { return "pob needs at least one profile" }
        return model.canDelete(profile.id) ? nil : "Close this profile's windows first"
    }

    var body: some View {
        Section("Sites with ad blocking off") {
            if sites.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(sites, id: \.self) { host in
                LabeledContent(host) {
                    Button("Turn On") {
                        model.turnBlockingBackOn(host, in: profile.id)
                        sites = model.sitesWithBlockingOff(of: profile.id)
                    }
                }
            }
        }
        .onChange(of: appearsActive, initial: true) { sites = model.sitesWithBlockingOff(of: profile.id) }
        Section {
            Button("Clear History…") { confirmsClear = true }
                .confirmationDialog("Clear all history for \(profile.name)?", isPresented: $confirmsClear, titleVisibility: .visible) {
                    Button("Clear History", role: .destructive) {
                        Task { await model.clearHistory(of: profile.id) }
                    }
                }
            VStack(alignment: .leading) {
                Button("Delete Profile…", role: .destructive) { confirmsDelete = true }
                    .disabled(deleteCaption != nil)
                if let deleteCaption {
                    Text(deleteCaption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("Its tabs, history, bookmarks, logins and site data are removed.")
            }
            .alert("Couldn't delete \(profile.name)", isPresented: $showsFailure) {} message: {
                Text(failure)
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await model.delete(profile.id)
            } catch {
                failure = error.localizedDescription
                showsFailure = true
            }
        }
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
