import SwiftUI

/// One look for every "pick one of a few" control in Preferences. The highlight slides to the new choice.
struct ChoiceBar<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
    }

    let options: [Option]
    let selection: Value
    var monospacedDigits = false
    let onSelect: (Value) -> Void

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Text(option.title)
                    .font(font(selected: selected))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.22))
                                .matchedGeometryEffect(id: "choice", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !selected else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            onSelect(option.value)
                        }
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func font(selected: Bool) -> Font {
        let base = Font.callout
        let styled = monospacedDigits ? base.monospacedDigit() : base
        return styled.weight(selected ? .semibold : .regular)
    }
}
