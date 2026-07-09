//
//  Geohash.swift
//  freebnb
//
//  Minimal geohash encoder. A geohash is a short base-32 string whose shared
//  prefix length grows with geographic proximity, which makes it an index-only
//  primitive for "listings near here" range queries (feature 11). Listings store
//  a geohash of their *public* (neighbourhood-rounded) coordinate, so it never
//  reveals more than the map circle already does.
//

import CoreLocation
import Foundation

enum Geohash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Encodes a coordinate to a geohash of the given precision (characters).
    /// Precision 6 is roughly a 1.2 km × 0.6 km cell — a good match for a
    /// coordinate already blurred to a neighbourhood.
    static func encode(latitude: Double, longitude: Double, precision: Int = 6) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var ch = 0
        var evenBit = true

        while hash.count < precision {
            if evenBit {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid { ch |= (1 << (4 - bit)); lonRange.0 = mid }
                else { lonRange.1 = mid }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid { ch |= (1 << (4 - bit)); latRange.0 = mid }
                else { latRange.1 = mid }
            }
            evenBit.toggle()

            if bit < 4 {
                bit += 1
            } else {
                hash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        return hash
    }

    static func encode(_ coordinate: CLLocationCoordinate2D, precision: Int = 6) -> String {
        encode(latitude: coordinate.latitude, longitude: coordinate.longitude, precision: precision)
    }
}
