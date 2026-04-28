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

    private var mappableListing: [Home] {
        listings.compactMap { home in
            guard home.latitude != nil, home.longitude != nil else { return nil }
            return home
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $mapPosition, selection: $selectedHome) {
                    ForEach(mappableListing) { home in
                        Marker(
                            home.address.city,
                            systemImage: "house.fill",
                            coordinate: CLLocationCoordinate2D(
                                latitude: home.latitude!,
                                longitude: home.longitude!
                            )
                        )
                        .tag(home)
                        .tint(.appTeal)
                    }
                }
                .mapStyle(.standard)

                if let home = selectedHome {
                    selectedCard(home)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.35), value: selectedHome?.id)
                }

                if mappableListing.isEmpty {
                    ContentUnavailableView {
                        Label("No map pins yet", systemImage: "map")
                            .foregroundStyle(Color.appTeal)
                    } description: {
                        Text("Listings appear on the map once hosts save their address. Ask a host to re-save their listing to add a pin.")
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
        }
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
            .background(Color.creamWhite, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .buttonStyle(.plain)
    }
}
