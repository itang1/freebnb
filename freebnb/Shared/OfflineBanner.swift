//
//  OfflineBanner.swift
//  freebnb
//
//  A slim banner pinned under the status bar while the device is offline
//  (feature 41). Reassures the user that the app still works and that anything
//  they send is queued rather than lost. Driven by `NetworkMonitor`.
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
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You are offline. Changes will sync when you reconnect.")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Overlays an `OfflineBanner` at the top of any view while `isOnline` is false.
/// Applied once at the app shell so every tab inherits it.
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
