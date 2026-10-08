//
//  Motion.swift
//  freebnb
//
//  One place for animation curves and press feedback, so timings stay consistent. Under
//  Reduce Motion, transforms are dropped and cross-fades kept (per the HIG); it's read
//  from the environment, not `UIAccessibility`, so SwiftUI re-renders when the switch flips.
//

import SwiftUI

// MARK: - Curves

enum AppAnimation {
    /// Press-in / press-out feedback on tappable surfaces.
    static let press: Animation = .easeInOut(duration: 0.15)

    /// Swapping content in place, e.g. a skeleton giving way to what it stood in for.
    static let contentSwap: Animation = .easeInOut(duration: 0.25)

    /// Rows entering, leaving, or reordering within a list.
    static let listChange: Animation = .spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: - Press feedback

/// Scales a button slightly while held. Under Reduce Motion the label dims instead of scaling.
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
    /// Cross-fades this view against its replacement, keyed on `value`; carries no motion, so it's kept under Reduce Motion.
    func crossFades<V: Equatable>(on value: V) -> some View {
        transition(.opacity).animation(AppAnimation.contentSwap, value: value)
    }

    /// Animates row insertions, removals and reordering; suppressed under Reduce Motion.
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
