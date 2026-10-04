import SwiftUI
import LidCodeKit

struct CustomizeProviders: View {
    @ObservedObject var model: AppModel
    @State private var provider: AIProfile.Provider = .claude
    @State private var name = ""
    @State private var directory = ""
    @State private var editingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.profiles) { profile in
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProviderIcon(source: .providerMark(profile.provider.rawValue)).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(profile.directory.isEmpty ? "Default \(profile.provider.title) profile" : profile.directory)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Toggle("Show \(profile.name)", isOn: Binding(get: { profile.isEnabled }, set: { enabled in
                            model.saveProfiles(model.profiles.map { var p = $0; if p.id == profile.id { p.isEnabled = enabled }; return p })
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    HStack {
                        Button("Edit") { editingID = profile.id; provider = profile.provider; name = profile.name; directory = profile.directory }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            model.saveProfiles(model.profiles.filter { $0.id != profile.id })
                            if editingID == profile.id { clearForm() }
                        }
                    }.font(.system(size: 11)).buttonStyle(.borderless)
                }.padding(14).dashboardCard()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(editingID == nil ? "Add AI" : "Edit AI").font(.system(size: 14, weight: .semibold))
                Picker("Provider", selection: $provider) {
                    ForEach(AIProfile.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder)
                TextField("Profile folder (optional)", text: $directory).textFieldStyle(.roundedBorder)
                Text("Leave the folder empty to use \(provider.defaultDirectory). Sign in through \(provider.title)'s CLI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if editingID != nil { Button("Cancel") { clearForm() } }
                    Spacer()
                    Button(editingID == nil ? "Add \(provider.title)" : "Save") { save() }
                        .buttonStyle(.borderedProminent).disabled(!validDirectory)
                }
            }.padding(14).dashboardCard()
            if let error = model.profileError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
    }

    private var validDirectory: Bool {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || NSString(string: value).expandingTildeInPath.hasPrefix("/")
    }
    private func save() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = AIProfile(id: editingID ?? UUID().uuidString, provider: provider,
                             name: label.isEmpty ? provider.title : label,
                             directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
                             isEnabled: editingID.flatMap { id in model.profiles.first { $0.id == id }?.isEnabled } ?? true)
        if let editingID { model.saveProfiles(model.profiles.map { $0.id == editingID ? next : $0 }) }
        else { model.saveProfiles(model.profiles + [next]) }
        if model.profileError == nil { clearForm() }
    }
    private func clearForm() { editingID = nil; name = ""; directory = "" }
}
