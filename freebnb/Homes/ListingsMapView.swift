//
//  ListingsMapView.swift
//  freebnb
//

import MapKit
import SwiftUI

struct ListingsMapView: View {
    let listings: [Home]
    let onSelectHome: (Home) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedHome: Home?
    @State private var mapPosition: MapCameraPosition = .automatic
    // Coordinates resolved at display time; keyed by listing ID.
    @State private var resolvedCoords: [String: CLLocationCoordinate2D] = [:]
    @State private var isGeocoding = false
    // The region under the camera right now, and the region the user last locked
    // in with "Search this area". While `appliedRegion` is set, only pins inside
    // it show, turning the map into a proximity filter (feature 11).
    @State private var currentRegion: MKCoordinateRegion?
    @State private var appliedRegion: MKCoordinateRegion?

    private var allPins: [(home: Home, coordinate: CLLocationCoordinate2D)] {
        listings.compactMap { home in
            if let stored = home.coordinate {
                return (home, stored.clCoordinate)
            }
            if let coord = resolvedCoords[home.id] {
                return (home, coord)
            }
            return nil
        }
    }

    private var pins: [(home: Home, coordinate: CLLocationCoordinate2D)] {
        guard let region = appliedRegion else { return allPins }
        return allPins.filter { region.contains($0.coordinate) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $mapPosition, selection: $selectedHome) {
                    ForEach(pins, id: \.home.id) { pin in
                        Marker(pin.home.address.city, systemImage: "house.fill", coordinate: pin.coordinate)
                            .tag(pin.home)
                            .tint(.accent)
                    }
                }
                .mapStyle(.standard)
                .onMapCameraChange(frequency: .onEnd) { context in
                    currentRegion = context.region
                }

                searchThisAreaButton

                if let home = selectedHome {
                    selectedCard(home)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.35), value: selectedHome?.id)
                }

                if isGeocoding && pins.isEmpty {
                    ProgressView("Finding listings…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if !isGeocoding && pins.isEmpty {
                    ContentUnavailableView {
                        Label(appliedRegion == nil ? "No map pins" : "Nothing in this area",
                              systemImage: "map")
                            .foregroundStyle(Color.accent)
                    } description: {
                        if appliedRegion == nil {
                            Text("None of the visible listings have a geocodable address.")
                        } else {
                            Text("No listings fall inside the area you searched. Zoom out and search again, or show all.")
                            Button("Show all areas") { appliedRegion = nil }
                                .padding(.top, 8)
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await geocodeMissing() }
        }
    }

    // Geocode any listing that doesn't already have stored coordinates. This is a
    // browse surface for people who have not been given the street address, so it
    // geocodes the public part only and lands on the city, not the door.
    private func geocodeMissing() async {
        let missing = listings.filter { $0.latitude == nil || $0.longitude == nil }
        guard !missing.isEmpty else { return }
        isGeocoding = true
        await withTaskGroup(of: (String, CLLocationCoordinate2D?).self) { group in
            for home in missing {
                group.addTask {
                    let address = "\(home.address.city), \(home.address.state) \(home.address.zip)"
                    let coord = try? await GeocodingCache.shared.coordinate(for: address)
                    return (home.id, coord)
                }
            }
            for await (id, coord) in group {
                if let coord {
                    resolvedCoords[id] = coord
                }
            }
        }
        isGeocoding = false
    }

    // Floating top control that turns the current viewport into a proximity
    // filter, plus a reset once one is applied.
    private var searchThisAreaButton: some View {
        VStack(spacing: 8) {
            Button {
                appliedRegion = currentRegion
                selectedHome = nil
            } label: {
                Label("Search this area", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundColor(Color.accent)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
            .disabled(currentRegion == nil)

            if appliedRegion != nil {
                Button {
                    appliedRegion = nil
                } label: {
                    Label("\(pins.count) in this area · Show all", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundColor(.primary)
                }
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
    }

    private func selectedCard(_ home: Home) -> some View {
        Button {
            onSelectHome(home)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(home.hostName)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("\(home.address.city), \(home.address.state)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Label("\(home.guestPolicy.maxGuests) guest\(home.guestPolicy.maxGuests == 1 ? "" : "s")", systemImage: "person.2")
                    Label("\(home.guestPolicy.maxStayDays) night max", systemImage: "moon")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.primaryBackground, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .buttonStyle(.plain)
    }
}

private extension MKCoordinateRegion {
    /// Whether a coordinate falls within this region's latitude/longitude span.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(coordinate.latitude - center.latitude) <= span.latitudeDelta / 2
            && abs(coordinate.longitude - center.longitude) <= span.longitudeDelta / 2
    }
}

#Preview {
    ListingsMapView(listings: PreviewData.homes) { _ in }
}
