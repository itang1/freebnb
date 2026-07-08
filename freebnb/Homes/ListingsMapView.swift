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

    private var pins: [(home: Home, coordinate: CLLocationCoordinate2D)] {
        listings.compactMap { home in
            if let lat = home.latitude, let lon = home.longitude {
                return (home, CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            if let coord = resolvedCoords[home.id] {
                return (home, coord)
            }
            return nil
        }
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
                        Label("No map pins", systemImage: "map")
                            .foregroundStyle(Color.accent)
                    } description: {
                        Text("None of the visible listings have a geocodable address.")
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

    // Geocode any listing that doesn't already have stored coordinates.
    private func geocodeMissing() async {
        let missing = listings.filter { $0.latitude == nil || $0.longitude == nil }
        guard !missing.isEmpty else { return }
        isGeocoding = true
        await withTaskGroup(of: (String, CLLocationCoordinate2D?).self) { group in
            for home in missing {
                group.addTask {
                    let address = "\(home.address.street), \(home.address.city), \(home.address.state) \(home.address.zip)"
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
