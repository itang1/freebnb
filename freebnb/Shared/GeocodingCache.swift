//
//  GeocodingCache.swift
//  freebnb
//
//  Actor-based cache for CLGeocoder lookups (limited to ~50 requests/minute), so browsing between listings
//  doesn't re-resolve addresses; concurrent requests for one address coalesce.
//

import CoreLocation

actor GeocodingCache {
    static let shared = GeocodingCache()

    private var coordinates: [String: Coordinate] = [:]
    private var inflight: [String: Task<Coordinate, Error>] = [:]

    // CLLocationCoordinate2D isn't Sendable on older SDKs; store the components and rebuild on return.
    private struct Coordinate: Sendable {
        let latitude: Double
        let longitude: Double
        var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    enum GeocodingError: Error {
        case noResults
    }

    func coordinate(for address: String) async throws -> CLLocationCoordinate2D {
        if let cached = coordinates[address] {
            return cached.clCoordinate
        }
        if let existing = inflight[address] {
            return try await existing.value.clCoordinate
        }

        let task = Task<Coordinate, Error> {
            let placemarks = try await CLGeocoder().geocodeAddressString(address)
            guard let location = placemarks.first?.location else {
                throw GeocodingError.noResults
            }
            return Coordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
        inflight[address] = task

        do {
            let coord = try await task.value
            inflight[address] = nil
            coordinates[address] = coord
            return coord.clCoordinate
        } catch {
            inflight[address] = nil
            throw error
        }
    }
}
