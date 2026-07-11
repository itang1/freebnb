//
//  CapsuleChip.swift
//  freebnb
//
//  The accent-tinted pill used by the feed's filter, sort, radius, and saved
//  controls. `prominent` marks a control whose setting is active, so the row
//  reads at a glance which chips are doing something.
//

import SwiftUI

extension View {
    func capsuleChip(prominent: Bool = false) -> some View {
        self
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accent.opacity(prominent ? 0.3 : 0.15), in: Capsule())
            .foregroundColor(Color.accent)
    }
}

#Preview {
    HStack(spacing: 8) {
        Label("Filter", systemImage: "line.3.horizontal.decrease").capsuleChip()
        Label("Saved", systemImage: "bookmark.fill").capsuleChip(prominent: true)
    }
    .padding()
}
