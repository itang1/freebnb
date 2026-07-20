//
//  InlineErrorLabel.swift
//  freebnb
//
//  The one way a form surfaces a failed action. Screens drop it into their own
//  Section (or stack) so placement stays flexible while the look stays uniform.
//

import SwiftUI

struct InlineErrorLabel: View {
    let message: String
    /// `.warning` for cautions the user can proceed past, `.danger` for failures.
    var tint: Color = .danger

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundColor(tint)
    }
}

#Preview {
    Form {
        Section {
            InlineErrorLabel(message: "Something went wrong. Try again.")
        }
        Section {
            InlineErrorLabel(message: "Add your name before creating a listing.", tint: .warning)
        }
    }
}
