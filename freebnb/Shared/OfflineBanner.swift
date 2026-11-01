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
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
            Text(ThemeCopy.Status.offline)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // A sunshine-yellow strip with dark ink (9.7:1 light, 8.5:1 dark): hard to miss, easy to read.
        .background(Color.sunshine)
        .foregroundColor(.onSunshine)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ThemeCopy.Status.offlineAccessibility)
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
