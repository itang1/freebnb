//
//  Extensions.swift
//  freebnb
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FlippedPrimaryColor: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundColor(colorScheme == .dark ? .black : .white)
    }
}

extension View {
    func flippedPrimaryColor() -> some View {
        self.modifier(FlippedPrimaryColor())
    }

    func appliesStoredAppearance() -> some View {
        self.modifier(AppearanceModifier())
    }
}

extension HostMotivation {
    /// Tint used for the motivation badge across the listing card and detail page.
    var tintColor: Color {
        switch self {
        case .eager:     return .red
        case .open:      return .orange
        case .selective: return .secondary
        }
    }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"

    func body(content: Content) -> some View {
        content
            .onAppear { apply(appearance) }
            .onChange(of: appearance) { _, newValue in apply(newValue) }
    }

    private func apply(_ value: String) {
        #if canImport(UIKit)
        let style: UIUserInterfaceStyle
        switch value {
        case "light": style = .light
        case "dark":  style = .dark
        default:      style = .unspecified
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.overrideUserInterfaceStyle = style }
        #endif
    }
}

// A layout that arranges subviews in rows, wrapping to the next row when needed
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.positions[index].x,
                    y: bounds.minY + result.positions[index].y
                ),
                proposal: .unspecified
            )
        }
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
