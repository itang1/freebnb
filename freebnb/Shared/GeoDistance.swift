//
//  GeoDistance.swift
//  freebnb
//
//  Distance between a listing and a searched place, and the radius scope the feed narrows by.
//  Every coordinate here is the listing's public one, rounded to a neighbourhood by
//  `Home.approximate(_:)`, so distances are honest to about a kilometre, as precise as the pre-acceptance map circle.
//

import CoreLocation
import Foundation

/// A latitude/longitude pair that is `Equatable` and `Hashable` (`CLLocationCoordinate2D` isn't), so it can sit in SwiftUI state and drive `onChange`.
struct Coordinate: Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Home {
    /// The listing's public, rounded coordinate; nil for older listings or addresses that never geocoded.
    var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

enum Geo {
    private static let metresPerMile = 1609.344

    /// Great-circle distance in miles.
    static func distanceMiles(from origin: Coordinate, to destination: Coordinate) -> Double {
        let a = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let b = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        return a.distance(from: b) / metresPerMile
    }

    /// "0.4 mi away", "12 mi away". Sub-mile distances keep a decimal so they don't read "0 mi"; under a mile is within the blur anyway.
    static func distanceText(_ miles: Double) -> String {
        let value = miles < 10
            ? String(format: "%.1f", miles)
            : String(Int(miles.rounded()))
        return "\(value) mi away"
    }
}

/// Where the user is searching from and how far they'll look; from geocoding the city query. A nil `radiusMiles` means any distance, still permitting distance sorting.
struct GeoScope: Equatable, Sendable {
    var center: Coordinate
    var radiusMiles: Double?

    /// Distance from the search center, or nil for a listing with no coordinate.
    func distance(to home: Home) -> Double? {
        home.coordinate.map { Geo.distanceMiles(from: center, to: $0) }
    }

    /// Whether the listing survives the radius filter. Once a radius is set a listing without
    /// a coordinate is dropped, since it can't prove it's nearby.
    func contains(_ home: Home) -> Bool {
        guard let radiusMiles else { return true }
        guard let distance = distance(to: home) else { return false }
        return distance <= radiusMiles
    }
}

/// The radii the feed offers, in miles. `nil` is "Any distance".
enum SearchRadius {
    static let options: [Double] = [5, 10, 25, 50, 100]

    static func label(_ miles: Double?) -> String {
        guard let miles else { return "Any distance" }
        return "Within \(Int(miles)) mi"
    }
}
