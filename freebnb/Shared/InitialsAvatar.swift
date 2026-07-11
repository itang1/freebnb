//
//  InitialsAvatar.swift
//  freebnb
//
//  The app's stand-in avatars. Profiles have no photos (uploading a face is a
//  bigger privacy decision than launch needs), so every person is drawn the
//  same way: a tinted circle holding their first initial, or a person icon on
//  profile screens. One implementation keeps the tint opacity and sizing
//  consistent — the previous copies had drifted to 0.10/0.12/0.15.
//

import SwiftUI

struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 40
    var tint: Color = .accent
    var font: Font = .headline

    var body: some View {
        Circle()
            .fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(font)
                    .foregroundColor(tint)
            )
            .accessibilityHidden(true)
    }
}

/// The person-in-a-circle hero at the top of profile screens.
struct PersonAvatar: View {
    var systemImage: String = "person.fill"
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accent.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.44, height: size * 0.44)
                .foregroundColor(Color.accent)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 12) {
            InitialsAvatar(name: "Alice")
            InitialsAvatar(name: "bob")
            InitialsAvatar(name: "Carol", tint: .orange)
            InitialsAvatar(name: "Dana", size: 36, font: .subheadline.weight(.semibold))
        }
        HStack(spacing: 12) {
            PersonAvatar()
            PersonAvatar(systemImage: "person.slash", size: 100)
        }
    }
    .padding()
}
