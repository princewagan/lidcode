import AppKit
import SwiftUI
import LidCodeKit

/// OpenUsage's Options capsule and two-line identity, with Lidcode's actions.
struct DashboardFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Lidcode \(LidCodeVersion.current)")
                Button { model.refreshUsage(); model.refreshHealth() } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.isRefreshingUsage ? "Updating…" : refreshCaption(now: context.date)).monospacedDigit()
                    }
                }.buttonStyle(.plain).keyboardShortcut("r", modifiers: .command)
                    .help("Refresh now (⌘R)").disabled(model.isRefreshingUsage)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { model.isOptionsOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Options").font(.system(size: 13, weight: .semibold))
                    Image(systemName: model.isOptionsOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }.padding(.horizontal, 14).frame(height: 28)
            }.buttonStyle(.plain).fixedSize()
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }.padding(.horizontal, 14).frame(height: 52).background(.regularMaterial)
    }
    private func refreshCaption(now: Date) -> String {
        guard let last = model.lastUsageRefresh else { return "Refresh to read usage" }
        let remaining = max(0, Int(last.addingTimeInterval(300).timeIntervalSince(now).rounded(.up)))
        return remaining >= 60 ? "Next update in \(Int(ceil(Double(remaining) / 60)))m" : "Next update in \(remaining)s"
    }
}

/// A themed child panel anchored below the dashboard.
struct DashboardOptions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 2) {
            if model.screen != .dashboard {
                action("Home", icon: "house") { navigate(.dashboard) }
            }
            action("Customize", icon: "slider.horizontal.3") { navigate(.customize) }
                .keyboardShortcut(.return, modifiers: [])
            action("Settings", icon: "gearshape") { navigate(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            action("Check for updates", icon: "arrow.up.right") {
                NSWorkspace.shared.open(URL(string: "https://github.com/princewagan/lidcode/releases/latest")!)
            }
            action("Quit LidCode", icon: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8).frame(width: 230)
        .background(DashboardTheme.tray, in: RoundedRectangle(cornerRadius: DashboardTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: DashboardTheme.cardRadius)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(OptionsRowStyle())
    }
    private func navigate(_ screen: AppModel.DashboardScreen) {
        model.screen = screen
        model.isOptionsOpen = false
    }
}

private struct OptionsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OptionsRow(configuration: configuration)
    }
    private struct OptionsRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.foregroundStyle(.primary)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}
