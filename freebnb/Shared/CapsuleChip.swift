//
//  CapsuleChip.swift
//  freebnb
//
//  The pill used by the feed's filter, sort, radius, and saved controls: lagoon-tinted at rest,
//  sunshine-yellow when `prominent` marks a control whose setting is active, so the row reads at a
//  glance which chips are doing something (and the teal-on-teal active state no longer dips below 4.5:1).
//

import SwiftUI

extension View {
    func capsuleChip(prominent: Bool = false) -> some View {
        self
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(prominent ? Color.sunshine : Color.accent.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.onSunshine.opacity(0.25) : .clear, lineWidth: 1))
            .foregroundColor(prominent ? Color.onSunshine : Color.accent)
    }
}

#Preview {
    HStack(spacing: 8) {
        Label("Filter", systemImage: "line.3.horizontal.decrease").capsuleChip()
        Label("Saved", systemImage: "bookmark.fill").capsuleChip(prominent: true)
    }
    .padding()
}
