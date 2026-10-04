import SwiftUI

extension Notification.Name {
    static let lidCodeThemeDidChange = Notification.Name("LidCodeThemeDidChange")
}

/// Saved locally and shared by every themed control.
enum AppTheme: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, teal
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.29, green: 0.49, blue: 0.79)
        case .purple: return Color(red: 0.52, green: 0.39, blue: 0.72)
        case .pink: return Color(red: 0.80, green: 0.39, blue: 0.52)
        case .orange: return Color(red: 0.84, green: 0.48, blue: 0.25)
        case .green: return Color(red: 0.29, green: 0.59, blue: 0.43)
        case .teal: return Color(red: 0.20, green: 0.55, blue: 0.57)
        }
    }
}
