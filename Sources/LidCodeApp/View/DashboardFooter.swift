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
            if model.screen == .dashboard {
                Menu {
                    Button("Customize", systemImage: "slider.horizontal.3") { model.screen = .customize }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Settings", systemImage: "gearshape") { model.screen = .settings }
                        .keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Link("Check for updates…", destination: URL(string: "https://github.com/princewagan/lidcode/releases/latest")!)
                    Button("About Lidcode", systemImage: "info.circle") {
                        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "Lidcode", .applicationVersion: LidCodeVersion.current])
                    }
                    Button("Quit Lidcode", systemImage: "power") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    HStack(spacing: 5) {
                        Text("Options").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }.padding(.leading, 14).padding(.trailing, 12).frame(height: 28)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }.padding(.horizontal, 14).frame(height: 52).background(.regularMaterial)
    }
    private func refreshCaption(now: Date) -> String {
        guard let last = model.lastUsageRefresh else { return "Refresh to read usage" }
        let remaining = max(0, Int(last.addingTimeInterval(300).timeIntervalSince(now).rounded(.up)))
        return remaining >= 60 ? "Next update in \(Int(ceil(Double(remaining) / 60)))m" : "Next update in \(remaining)s"
    }
}
