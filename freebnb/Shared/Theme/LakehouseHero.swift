//
//  LakehouseHero.swift
//  freebnb
//
//  The postcard scene at the top of the welcome and onboarding screens: a coral lakehouse up on dock
//  stilts, sky flowers drifting through a sunny sky, a little sailboat bobbing on rolling water. Built
//  from SF Symbols and the shapes in Motifs.swift. At night (dark mode) the sky turns to lagoon dusk and
//  the sun to a moon. Decorative, so hidden from VoiceOver; motion stops under Reduce Motion.
//

import SwiftUI

struct LakehouseHero: View {
    var height: CGFloat = 240
    /// The colour of whatever sits below the hero, so the front wave melts into it.
    var groundColor: Color = .primaryBackground

    @Environment(\.colorScheme) private var colorScheme

    private var isNight: Bool { colorScheme == .dark }

    private var skyColors: [Color] {
        isNight
            ? [Color.accent.opacity(0.35), Color.primaryBackground]
            : [Color.sunshine.opacity(0.55), Color.secondaryAccent.opacity(0.75)]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            groundColor
            LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)
            SkyFlowerScatter(color: .tertiaryBackground, strength: isNight ? 0.25 : 0.85)

            sun
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 54)
                .padding(.trailing, 40)

            lakehouse
                .padding(.bottom, height * 0.12)

            Shoreline(height: height * 0.3, frontColor: groundColor)

            Image(systemName: "sailboat.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accent)
                .bobbing(amplitude: 3, period: 2.8, tilt: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .padding(.bottom, height * 0.13)
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var sun: some View {
        Circle()
            .fill(Color.sunshine.opacity(isNight ? 0.85 : 1))
            .frame(width: isNight ? 44 : 64, height: isNight ? 44 : 64)
            .shadow(color: Color.sunshine.opacity(0.6), radius: isNight ? 10 : 22)
    }

    private var lakehouse: some View {
        VStack(spacing: 0) {
            Image(systemName: "house.lodge.fill")
                .font(.system(size: height * 0.32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.callToAction)
            DockPlanks(boards: 2)
                .frame(width: height * 0.82, height: 12)
            // Stilts down into the water; the shoreline in front hides where they meet it.
            HStack(spacing: height * 0.18) {
                ForEach(0..<4, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.driftwood)
                        .frame(width: 6, height: height * 0.2)
                }
            }
        }
    }
}

#Preview("Day") {
    VStack(spacing: 0) {
        LakehouseHero()
        Spacer()
    }
    .background(Color.primaryBackground)
}

#Preview("Night") {
    VStack(spacing: 0) {
        LakehouseHero()
        Spacer()
    }
    .background(Color.primaryBackground)
    .preferredColorScheme(.dark)
}
