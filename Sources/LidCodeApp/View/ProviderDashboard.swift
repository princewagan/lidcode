import SwiftUI
import LidCodeKit

/// Geometry and semantic surfaces follow OpenUsage v0.7.13's regular density.
/// See docs/OpenUsage-LICENSE.txt for the source attribution.
enum DashboardTheme {
    static let width: CGFloat = 320
    static let tray = Color(nsColor: .textBackgroundColor)
    static let cardRadius: CGFloat = 12
    static func meter(_ percent: Double, accent: Color) -> Color {
        percent >= 90 ? Color(nsColor: .systemRed) : percent >= 70 ? Color(nsColor: .systemYellow) : accent
    }
}

extension View {
    func dashboardCard() -> some View {
        background(RoundedRectangle(cornerRadius: DashboardTheme.cardRadius, style: .continuous)
            .fill(DashboardTheme.tray)
            .overlay(RoundedRectangle(cornerRadius: DashboardTheme.cardRadius, style: .continuous).fill(AnyShapeStyle(.fill.quaternary))))
    }
}

struct ProviderDashboard: View {
    @ObservedObject var model: AppModel
    @AppStorage("usageShowLeft") private var showLeft = true
    @AppStorage("usageAbsoluteReset") private var absoluteReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.profiles.filter(\.isEnabled).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text("Your AI, in one place").font(.system(size: 14, weight: .semibold))
                    Text("Add Claude or Codex to see your session and weekly limits.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add AI") { model.screen = .customize }
                        .buttonStyle(.borderedProminent)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).dashboardCard()
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(model.profiles.filter(\.isEnabled)) { profile in
                        let account = model.snapshot.usage?.accounts.first { $0.key == profile.id }
                        VStack(alignment: .leading) {
                            AIProviderCard(profile: profile, account: account, refreshing: model.isRefreshingUsage,
                                           showLeft: $showLeft, absoluteReset: $absoluteReset)
                            if account?.status != "ok" {
                                Button("Sign In") { model.signIn(profile) }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AIProviderCard: View {
    @AppStorage("appTheme") private var themeName = AppTheme.blue.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .blue }

    let profile: AIProfile
    let account: ClaudeAccountUsage?
    var refreshing = false
    @Binding var showLeft: Bool
    @Binding var absoluteReset: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ProviderIcon(source: .providerMark(profile.provider.rawValue), inset: 0.04).frame(width: 16, height: 16)
                Text(profile.provider.title).font(.system(size: 14, weight: .semibold))
                if profile.name != profile.provider.title {
                    Text(profile.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if refreshing { ProgressView().controlSize(.mini) }
                else if let account, account.isCarried || accountIsStale(account) {
                    Text("Outdated").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(account.asOf.map { "Last read \($0.formatted())" } ?? "Last read time unknown")
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 2).padding(.vertical, 2)
            VStack(spacing: 0) {
                if let account, account.status == "ok" {
                    meter("Session", window: account.fiveHour)
                    meter("Weekly", window: account.sevenDay)
                    if account.isCarried, let age = account.carriedAgeDisplay() {
                        Text("Last read \(age)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(statusTitle).font(.system(size: 13, weight: .semibold))
                        Text(statusDetail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.vertical, 5).dashboardCard()
        }
    }

    private func accountIsStale(_ account: ClaudeAccountUsage) -> Bool {
        account.asOf.map { Date().timeIntervalSince($0) > ClaudeUsageReader.staleAfterSecond } ?? false
    }

    private func meter(_ label: String, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let window, window.utilization >= 100 {
                    Label("Limit reached", systemImage: "flame.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.10))
                    .overlay(alignment: .leading) {
                        if let window {
                            Capsule().fill(DashboardTheme.meter(window.utilization, accent: theme.color))
                                .frame(width: geometry.size.width * (showLeft ? 1 - window.fraction : window.fraction))
                        }
                    }
            }.frame(height: 5)
            HStack(spacing: 8) {
                Button {
                    showLeft.toggle()
                } label: {
                    Text(window.map { "\(Int((showLeft ? 100 - $0.utilization : $0.utilization).rounded()))% \(showLeft ? "left" : "used")" } ?? "Unavailable")
                        .monospacedDigit()
                }.buttonStyle(.plain).help("Switch between used and left")
                Spacer(minLength: 4)
                Button { absoluteReset.toggle() } label: {
                    Text(resetText(window)).foregroundStyle(.secondary).lineLimit(1)
                }.buttonStyle(.plain).help(window?.resetsAt.map { "Reset at \($0.formatted())" } ?? "Reset time unknown")
            }.font(.system(size: 12))
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func resetText(_ window: UsageWindow?) -> String {
        guard let window else { return "" }
        if absoluteReset, let date = window.resetsAt { return date.formatted(date: .abbreviated, time: .shortened) }
        if let date = window.resetsAt {
            let hours = Int(date.timeIntervalSinceNow / 3600)
            if hours >= 24 { return "Resets in \(hours / 24)d \(hours % 24)h" }
        }
        if let display = window.resetDisplay { return "Resets in \(display)" }
        return window.resetsAt == nil ? "Reset unknown" : "Awaiting update"
    }

    private var statusTitle: String {
        if refreshing { return "Reading usage…" }
        switch account?.status {
        case "signed_out": return "Sign in to \(profile.provider.title)"
        case "expired": return "Login needs refreshing"
        case "no_data": return "No usage yet"
        case .none: return "Ready to connect"
        default: return "Usage unavailable"
        }
    }
    private var statusDetail: String {
        switch profile.provider {
        case .claude: return account?.status == "error" ? "Could not read usage. Check your connection, then refresh." : "Sign in with Claude Code, then refresh here. Lidcode uses your existing login."
        case .codex: return "Run a Codex CLI session in this profile, then refresh. Limits are read from local session logs."
        }
    }
}
