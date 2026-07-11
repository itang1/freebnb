//
//  Motion.swift
//  freebnb
//
//  One place for the app's animation curves and press feedback, so timings stay
//  consistent across screens instead of being re-picked at each call site.
//
//  Everything here degrades under Settings > Accessibility > Motion > Reduce
//  Motion: transforms (scale, slide) are dropped and cross-fades are kept, which
//  is the behaviour Apple's HIG asks for. Reduce Motion is read from the
//  environment rather than `UIAccessibility.isReduceMotionEnabled` so SwiftUI
//  re-renders when the user flips the switch while the app is running.
//

import SwiftUI

// MARK: - Curves

enum AppAnimation {
    /// Press-in / press-out feedback on tappable surfaces.
    static let press: Animation = .easeInOut(duration: 0.15)

    /// Swapping one piece of content for another in place, e.g. a loading
    /// skeleton giving way to the thing it stood in for.
    static let contentSwap: Animation = .easeInOut(duration: 0.25)

    /// Rows entering, leaving, or reordering within a list.
    static let listChange: Animation = .spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: - Press feedback

/// Scales a button slightly while held. Under Reduce Motion the scale is
/// dropped and the label dims instead, so the control still acknowledges the
/// touch without moving.
struct PressableButtonStyle: ButtonStyle {
    /// How far to scale in. Cards use a subtler value than small controls.
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        // The environment is only readable from a View, not from makeBody itself.
        PressableLabel(configuration: configuration, pressedScale: pressedScale)
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? pressedScale : 1.0))
                .opacity(reduceMotion && configuration.isPressed ? 0.7 : 1.0)
                .animation(AppAnimation.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Press feedback for small controls.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// Press feedback tuned for large card-sized tap targets.
    static var pressableCard: PressableButtonStyle { PressableButtonStyle(pressedScale: 0.98) }
}

// MARK: - Transitions

extension View {
    /// Cross-fades this view against whatever replaces it, keyed on `value`.
    /// Used for placeholder-to-content swaps. A cross-fade carries no motion,
    /// so it is safe to keep under Reduce Motion.
    func crossFades<V: Equatable>(on value: V) -> some View {
        transition(.opacity).animation(AppAnimation.contentSwap, value: value)
    }

    /// Animates row insertions, removals, and reordering in a collection.
    /// Suppressed under Reduce Motion, where rows would otherwise slide.
    func animatesListChanges<V: Equatable>(on value: V) -> some View {
        modifier(ListChangeAnimation(value: value))
    }
}

private struct ListChangeAnimation<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : AppAnimation.listChange, value: value)
    }
}

#Preview {
    VStack(spacing: 20) {
        Button("Pressable control") {}
            .buttonStyle(.pressable)
        Button {
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accent.opacity(0.2))
                .frame(height: 80)
                .overlay(Text("Pressable card"))
        }
        .buttonStyle(.pressableCard)
    }
    .padding()
}
