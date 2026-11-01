//
//  ThemeMotion.swift
//  freebnb
//
//  Ambient, vacation-paced motion: things bob like they're floating. Reduce Motion turns all of it off
//  (the view simply rests in place), read from the environment so it reacts when the switch flips.
//

import SwiftUI

private struct BobbingModifier: ViewModifier {
    var amplitude: CGFloat
    var period: Double
    var tiltDegrees: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation) { timeline in
                let swell = sin(timeline.date.timeIntervalSinceReferenceDate / max(period, 0.1) * 2 * .pi)
                content
                    .offset(y: CGFloat(swell) * amplitude)
                    .rotationEffect(.degrees(swell * tiltDegrees))
            }
        }
    }
}

extension View {
    /// Floats this view gently up and down, as if on a slow swell. Off under Reduce Motion.
    func bobbing(amplitude: CGFloat = 4, period: Double = 3.2, tilt: Double = 2) -> some View {
        modifier(BobbingModifier(amplitude: amplitude, period: period, tiltDegrees: tilt))
    }
}

#Preview {
    Image(systemName: "sailboat.fill")
        .font(.system(size: 60))
        .foregroundStyle(Color.accent)
        .bobbing()
        .padding(40)
}
