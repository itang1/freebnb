//
//  ChoiceSection.swift
//  freebnb
//
//  A radio-style form section: each option shows a checkmark, its name, and a
//  caption explaining the tradeoff. The create-listing form uses it for host
//  motivation and cancellation policy, which were copies of the same layout.
//

import SwiftUI

struct ChoiceSection<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let name: (Option) -> String
    let detail: (Option) -> String

    var body: some View {
        Section(title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(options, id: \.self) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: selection == option ? "checkmark.circle.fill" : "circle")
                                // Full strength: the empty circle is the only mark
                                // saying "not chosen", so it can't be a ghost.
                                .foregroundColor(selection == option ? .accent : .secondaryText)
                            Text(name(option))
                                .font(.body)
                        }
                        Text(detail(option))
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                            .padding(.leading, 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection == option ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    @Previewable @State var policy: CancellationPolicy = .flexible
    Form {
        ChoiceSection(
            title: "Cancellation policy",
            options: CancellationPolicy.allCases,
            selection: $policy,
            name: { $0.displayName },
            detail: { $0.description }
        )
    }
}
