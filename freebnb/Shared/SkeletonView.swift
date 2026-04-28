//
//  SkeletonView.swift
//  freebnb
//

import SwiftUI

private struct SkeletonModifier: ViewModifier {
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .opacity(animating ? 0.4 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.appTeal.opacity(0.25))
            .frame(width: width, height: height)
            .modifier(SkeletonModifier())
    }
}

struct SkeletonHomeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photo placeholder
            Color.appTeal.opacity(0.18)
                .frame(height: 190)
                .modifier(SkeletonModifier())
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 20
                ))

            VStack(alignment: .leading, spacing: 10) {
                // Summary pills
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock(width: 70, height: 26, cornerRadius: 13)
                    }
                }

                // Amenity row
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonBlock(width: 32, height: 32, cornerRadius: 8)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.skyBlue.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.appTeal.opacity(0.10), radius: 8, x: 0, y: 5)
    }
}

struct SkeletonConversationRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 44, height: 44, cornerRadius: 22)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 120, height: 14)
                SkeletonBlock(width: 200, height: 12, cornerRadius: 5)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
