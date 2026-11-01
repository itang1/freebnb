//
//  Motifs.swift
//  freebnb
//
//  Hand-drawn shapes that give the app its seaside-shack feel: sky flowers, waves, bubbles and dock
//  planks. All original geometry drawn in code (no image assets, nothing traced from anyone's artwork),
//  so they recolour with the palette and stay crisp at any size. Purely decorative: every motif view is
//  hidden from VoiceOver.
//

import SwiftUI

// MARK: - Sky flower

/// A round-petalled blossom, the pattern printed across the sky of a tropical shirt. Petals are ellipses
/// fanned around the centre; draw the centre separately (see `SkyFlowerMark`) for a two-tone flower.
struct SkyFlower: Shape {
    var petals: Int = 5

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let petalWidth = radius * 0.62
        // Each petal runs from the centre to the rim, pointing up before it is rotated into place.
        let petal = Path(ellipseIn: CGRect(x: -petalWidth / 2, y: -radius, width: petalWidth, height: radius))
        var path = Path()
        for index in 0..<max(petals, 1) {
            let angle = CGFloat(index) / CGFloat(max(petals, 1)) * 2 * .pi
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
            path.addPath(petal, transform: transform)
        }
        return path
    }
}

/// A two-tone sky flower: petals in one colour, a round heart in another.
struct SkyFlowerMark: View {
    var petalColor: Color = .tertiaryBackground
    var heartColor: Color = .sunshine
    var petals: Int = 5

    var body: some View {
        ZStack {
            SkyFlower(petals: petals).fill(petalColor)
            Circle().fill(heartColor).scaleEffect(0.3)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A loose scatter of sky flowers for page backdrops, drawn in one Canvas pass. Positions are fixed
/// fractions of the space, so the pattern holds still and looks hand-placed rather than random.
struct SkyFlowerScatter: View {
    var color: Color = .secondaryAccent
    /// How strongly the flowers show through, 0 to 1.
    var strength: Double = 0.35

    private struct Bloom {
        /// Position as fractions of the canvas.
        let across: CGFloat, down: CGFloat
        let diameter: CGFloat
        let degrees: Double
        let petals: Int

        init(_ across: CGFloat, _ down: CGFloat, _ diameter: CGFloat, _ degrees: Double, _ petals: Int) {
            self.across = across
            self.down = down
            self.diameter = diameter
            self.degrees = degrees
            self.petals = petals
        }
    }

    private static let blooms: [Bloom] = [
        Bloom(0.08, 0.06, 54, 10, 5), Bloom(0.82, 0.03, 38, 40, 6), Bloom(0.55, 0.16, 26, 0, 5),
        Bloom(0.93, 0.27, 60, 20, 5), Bloom(0.18, 0.34, 30, 55, 6), Bloom(0.70, 0.46, 44, 15, 5),
        Bloom(0.04, 0.58, 40, 30, 5), Bloom(0.40, 0.66, 22, 70, 6), Bloom(0.88, 0.74, 34, 5, 5),
        Bloom(0.22, 0.86, 58, 25, 6), Bloom(0.62, 0.93, 28, 50, 5)
    ]

    var body: some View {
        Canvas { context, size in
            for bloom in Self.blooms {
                let diameter = bloom.diameter
                let rect = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
                var flower = context
                flower.translateBy(x: bloom.across * size.width, y: bloom.down * size.height)
                flower.rotate(by: .degrees(bloom.degrees))
                flower.fill(SkyFlower(petals: bloom.petals).path(in: rect), with: .color(color.opacity(strength)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Waves

/// A filled band whose top edge is a sine wave; fill it with water (or with the colour of whatever sits
/// below, to give an edge a wavy hem). `phase` is animatable, in wavelengths.
struct WaveShape: Shape {
    var amplitude: CGFloat = 6
    var wavelength: CGFloat = 90
    var phase: CGFloat = 0

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let crest = rect.minY + amplitude
        let length = max(wavelength, 1)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var xPos = rect.minX
        while xPos <= rect.maxX {
            let angle = Double((xPos - rect.minX) / length + phase) * 2 * .pi
            path.addLine(to: CGPoint(x: xPos, y: crest + CGFloat(sin(angle)) * amplitude))
            xPos += 3
        }
        let endAngle = Double((rect.maxX - rect.minX) / length + phase) * 2 * .pi
        path.addLine(to: CGPoint(x: rect.maxX, y: crest + CGFloat(sin(endAngle)) * amplitude))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Three layered waves rolling past each other. They roll slowly unless Reduce Motion is on, in which
/// case they hold still.
struct Shoreline: View {
    var height: CGFloat = 70
    /// The colour the front wave settles into, so the shoreline can hem a surface of any colour.
    var frontColor: Color = .primaryBackground

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .bottom) {
                WaveShape(amplitude: 7, wavelength: 140, phase: CGFloat(time / 9))
                    .fill(Color.secondaryAccent)
                    .frame(height: height)
                WaveShape(amplitude: 6, wavelength: 110, phase: CGFloat(-time / 7) + 0.3)
                    .fill(Color.accent.opacity(0.55))
                    .frame(height: height * 0.72)
                WaveShape(amplitude: 5, wavelength: 90, phase: CGFloat(time / 5) + 0.6)
                    .fill(frontColor)
                    .frame(height: height * 0.42)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Bubbles

/// A handful of bubbles drifting upward and wobbling, like the view is underwater. Under Reduce Motion
/// they stay put, so the scene keeps its texture without moving.
struct BubbleField: View {
    var count: Int = 9
    var color: Color = .accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for index in 0..<count {
                    let bubble = Self.bubble(index: index, time: time, in: size)
                    let rect = CGRect(
                        x: bubble.center.x - bubble.radius, y: bubble.center.y - bubble.radius,
                        width: bubble.radius * 2, height: bubble.radius * 2
                    )
                    context.stroke(Circle().path(in: rect), with: .color(color.opacity(0.35)), lineWidth: 1.5)
                    // A glint, top left, so it reads as a bubble rather than a ring.
                    let glint = CGRect(
                        x: rect.minX + bubble.radius * 0.45, y: rect.minY + bubble.radius * 0.4,
                        width: bubble.radius * 0.45, height: bubble.radius * 0.45
                    )
                    context.fill(Circle().path(in: glint), with: .color(color.opacity(0.3)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where bubble `index` is at `time`: each has its own lane, size and speed, and loops bottom to top.
    static func bubble(index: Int, time: TimeInterval, in size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        // Cheap, stable pseudo-random numbers per bubble.
        func noise(_ salt: Double) -> Double {
            let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43_758.5453
            return value - value.rounded(.down)
        }
        let radius = CGFloat(3 + noise(1) * 7)
        let speed = 0.05 + noise(2) * 0.07
        let rise = (noise(3) + time * speed).truncatingRemainder(dividingBy: 1)
        let lane = noise(4) * Double(size.width)
        let wobble = sin(time * (1 + noise(5)) + Double(index)) * 6
        let travel = Double(size.height) + Double(radius) * 2
        let yPos = Double(size.height) + Double(radius) - rise * travel
        return (CGPoint(x: lane + wobble, y: yPos), radius)
    }
}

// MARK: - Dock planks

/// Weathered boards laid side by side with nail heads at each end, for footers, sign backs and the dock
/// under the lakehouse.
struct DockPlanks: View {
    var boards: Int = 3
    var color: Color = .driftwood

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<boards, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(index.isMultiple(of: 2) ? 1 : 0.85))
                    .overlay(alignment: .leading) { nail.padding(.leading, 8) }
                    .overlay(alignment: .trailing) { nail.padding(.trailing, 8) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var nail: some View {
        Circle().fill(Color.black.opacity(0.25)).frame(width: 3, height: 3)
    }
}

// MARK: - Backdrop

/// The standard page background: sand (or night lagoon) with a faint scatter of sky flowers.
struct LagoonBackdrop: View {
    var body: some View {
        ZStack {
            Color.primaryBackground
            SkyFlowerScatter(strength: 0.28)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Places the sand-and-sky-flowers backdrop behind this view, edge to edge.
    func lagoonBackground() -> some View {
        background { LagoonBackdrop() }
    }

    /// Gives the bottom edge of a surface a wavy hem in `color` (usually the colour of what sits below).
    func wavyHem(_ color: Color, height: CGFloat = 10) -> some View {
        overlay(alignment: .bottom) {
            WaveShape(amplitude: height / 3, wavelength: 56)
                .fill(color)
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Motifs") {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            SkyFlowerMark().frame(width: 60)
            SkyFlowerMark(petalColor: .secondaryAccent, heartColor: .tertiaryBackground, petals: 6).frame(width: 44)
        }
        BubbleField().frame(height: 120)
        DockPlanks().frame(height: 36)
        Shoreline()
    }
    .padding()
    .lagoonBackground()
}
