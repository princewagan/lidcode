import SwiftUI

struct ThemeCheckboxStyle: ToggleStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? color : Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(configuration.isOn ? 0 : 0.25), lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
