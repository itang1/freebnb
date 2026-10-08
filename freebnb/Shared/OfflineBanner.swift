//
//  OfflineBanner.swift
//  freebnb
//
//  A slim banner under the status bar while offline, reassuring that sends are queued, not lost. Driven by
//  `NetworkMonitor`.
//

import SwiftUI

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You're offline. Changes will sync when you reconnect.")
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        // Theme surface and full-strength label; the grey fill left text at 3.5:1 and ignored the palette.
        .foregroundColor(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.secondaryBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You are offline. Changes will sync when you reconnect.")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Overlays an `OfflineBanner` atop any view while `isOnline` is false; applied once at the app shell.
private struct OfflineBannerModifier: ViewModifier {
    let isOnline: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !isOnline {
                    OfflineBanner()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isOnline)
    }
}

extension View {
    /// Shows the offline banner above this view whenever connectivity is lost.
    func offlineBanner(isOnline: Bool) -> some View {
        modifier(OfflineBannerModifier(isOnline: isOnline))
    }
}

#Preview {
    Color.primaryBackground
        .offlineBanner(isOnline: false)
}
