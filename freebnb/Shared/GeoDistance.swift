//
//  GeoDistance.swift
//  freebnb
//
//  Distance between a listing and a place the user searched for, and the radius
//  scope the feed narrows by (feature 11). Every coordinate that reaches this
//  file is the listing's *public* one, already rounded to a neighbourhood by
//  `Home.approximate(_:)` — so a distance computed here is honest to about a
//  kilometre and no closer, which is exactly as precise as the map circle a
//  guest is allowed to see before their stay is accepted.
//

import CoreLocation
import Foundation

/// A latitude/longitude pair that is `Equatable` and `Hashable`, which
/// `CLLocationCoordinate2D` is not. Equatability is what lets a coordinate sit in
/// SwiftUI state and drive an `onChange`.
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
    /// The listing's public, neighbourhood-rounded coordinate. Nil for a listing
    /// created before the field existed, or one whose address never geocoded.
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

    /// "0.4 mi away", "12 mi away". Sub-mile distances keep a decimal because at
    /// this scale the rounding would otherwise read as "0 mi", and anything under
    /// a mile is within the blur radius of the coordinate anyway.
    static func distanceText(_ miles: Double) -> String {
        let value = miles < 10
            ? String(format: "%.1f", miles)
            : String(Int(miles.rounded()))
        return "\(value) mi away"
    }
}

/// Where the user is searching from, and how far out they will look. Produced by
/// geocoding the feed's city query; `radiusMiles` of nil means "any distance",
/// which still permits distance *sorting* without discarding anything.
struct GeoScope: Equatable, Sendable {
    var center: Coordinate
    var radiusMiles: Double?

    /// Distance from the search center, or nil for a listing with no coordinate.
    func distance(to home: Home) -> Double? {
        home.coordinate.map { Geo.distanceMiles(from: center, to: $0) }
    }

    /// Whether the listing survives the radius filter.
    ///
    /// A listing with no coordinate is dropped once a radius is set. It cannot
    /// prove it is nearby, and a radius filter is a promise about distance: quietly
    /// admitting the unlocatable would break that promise on the one listing the
    /// user cannot check.
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
