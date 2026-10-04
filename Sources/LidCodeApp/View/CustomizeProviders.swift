import SwiftUI
import LidCodeKit

struct CustomizeProviders: View {
    @ObservedObject var model: AppModel
    @AppStorage("appTheme") private var themeName = AppTheme.blue.rawValue
    @State private var provider: AIProfile.Provider = .claude
    @State private var name = ""
    @State private var directory = ""
    @State private var setupError: String?
    @State private var editingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            themePicker
            menuBarUsage
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
                        Button("Sign In") { model.signIn(profile) }
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
                HStack {
                    if editingID != nil { Button("Cancel") { clearForm() } }
                    Spacer()
                    Button(editingID == nil ? "Add \(provider.title)" : "Save") { save() }
                        .buttonStyle(.borderedProminent).disabled(!validDirectory)
                }
            }.padding(14).dashboardCard()
            if let error = setupError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            if let error = model.profileError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Color").font(.system(size: 14, weight: .semibold))
                Text("Choose your Lidcode accent").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: AppTheme.allCases.count), spacing: 8) {
                ForEach(AppTheme.allCases) { choice in
                    let selected = themeName == choice.rawValue
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            themeName = choice.rawValue
                        }
                        NotificationCenter.default.post(name: .lidCodeThemeDidChange, object: choice.rawValue)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(choice.color)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.name) theme")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }.padding(14).dashboardCard()
    }

    private var menuBarUsage: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Menu bar usage").font(.system(size: 14, weight: .semibold))
                Text("Choose which remaining limits to show").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: AIProfileStore.columns(for: model.profiles.count)), spacing: 8) {
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        profileUsageToggle("5h", profile: profile, weekly: false)
                        profileUsageToggle("1w", profile: profile, weekly: true)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(14).dashboardCard()
    }

    private func profileUsageToggle(_ title: String, profile: AIProfile, weekly: Bool) -> some View {
        let fallback = profile.provider == .claude
            ? (weekly ? model.setting.menuBarShowClaude1w : model.setting.menuBarShowClaude5h)
            : (weekly ? model.setting.menuBarShowCodex1w : model.setting.menuBarShowCodex5h)
        return Toggle(title, isOn: Binding(get: {
            (weekly ? profile.menuBarShow1w : profile.menuBarShow5h) ?? fallback
        }, set: { enabled in
            model.saveProfiles(model.profiles.map { item in
                var item = item
                if item.id == profile.id {
                    if weekly { item.menuBarShow1w = enabled } else { item.menuBarShow5h = enabled }
                }
                return item
            })
        })).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
    }

    private var validDirectory: Bool {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || NSString(string: value).expandingTildeInPath.hasPrefix("/")
    }
    private func save() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = model.profiles.filter { $0.provider == provider && $0.id != editingID }.count
        let defaultName = count == 0 ? provider.title : "\(provider.title) \(count + 1)"
        var next = AIProfile(id: editingID ?? UUID().uuidString, provider: provider,
                             name: label.isEmpty ? defaultName : label,
                             directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
                             isEnabled: editingID.flatMap { id in model.profiles.first { $0.id == id }?.isEnabled } ?? true)
        if let old = model.profiles.first(where: { $0.id == editingID }) {
            next.menuBarShow5h = old.menuBarShow5h; next.menuBarShow1w = old.menuBarShow1w
        }
        do { next = try AIProfileStore.prepared(next, alongside: model.profiles) }
        catch { setupError = "This folder already belongs to another account, or could not be created."; return }
        setupError = nil
        if let editingID { model.saveProfiles(model.profiles.map { $0.id == editingID ? next : $0 }) }
        else { model.saveProfiles(model.profiles + [next]) }
        if model.profileError == nil {
            if editingID == nil { model.signIn(next) }
            clearForm()
        }
    }
    private func clearForm() { editingID = nil; name = ""; directory = ""; setupError = nil }
}
