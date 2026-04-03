//
//  Extensions.swift
//  freebnb
//
//  Created by Irene Tang on 8/9/25.
//

import SwiftUI

struct FlippedPrimaryColor: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundColor(colorScheme == .dark ? .black : .white)
    }
}

extension Color {
    static let appTeal = Color("AppTeal")
}

extension View {
    func flippedPrimaryColor() -> some View {
        self.modifier(FlippedPrimaryColor())
    }
}
