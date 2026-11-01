//
//  ThemeTests.swift
//  freebnbTests
//
//  Guards the lagoon theme layer: every SF Symbol the theme names exists on this OS (a typo renders as
//  an empty space, not a crash), tab labels stay distinct for VoiceOver and UI tests, and the drawn
//  motifs stay inside the rect they're given so nothing gets clipped at the edges.
//

import SwiftUI
import Testing
import UIKit
@testable import freebnb

struct ThemeTests {
    private var themedSymbols: [String] {
        [
            ThemeCopy.Tab.exploreIcon, ThemeCopy.Tab.tripsIcon, ThemeCopy.Tab.messagesIcon,
            ThemeCopy.Tab.crewIcon, ThemeCopy.Tab.profileIcon, ThemeCopy.Onboarding.hostIcon,
            "house.lodge.fill", "sailboat.fill", "envelope.open.fill", "wind",
            "antenna.radiowaves.left.and.right.slash"
        ] + ThemeCopy.Onboarding.slides.map(\.icon)
    }

    @Test func everyThemedSymbolExists() {
        for name in themedSymbols {
            #expect(UIImage(systemName: name) != nil, "No SF Symbol named \(name)")
        }
    }

    @Test func tabLabelsAreDistinctAndNonEmpty() {
        let labels = [
            ThemeCopy.Tab.explore, ThemeCopy.Tab.trips, ThemeCopy.Tab.messages,
            ThemeCopy.Tab.crew, ThemeCopy.Tab.profile
        ]
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test(arguments: [5, 6])
    func skyFlowerStaysInsideItsRect(petals: Int) {
        let rect = CGRect(x: 10, y: 20, width: 80, height: 80)
        let bounds = SkyFlower(petals: petals).path(in: rect).boundingRect
        #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
    }

    @Test func waveStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 333, height: 40)
        for phase in stride(from: CGFloat(0), through: 1, by: 0.25) {
            let bounds = WaveShape(amplitude: 8, wavelength: 90, phase: phase).path(in: rect).boundingRect
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
        }
    }

    @Test func bubblesRiseThroughTheField() {
        let size = CGSize(width: 120, height: 200)
        for index in 0..<9 {
            let start = BubbleField.bubble(index: index, time: 0, in: size)
            #expect(start.radius >= 3 && start.radius <= 10)
            #expect(start.center.y >= -start.radius && start.center.y <= size.height + start.radius)
        }
    }
}
