//
//  HomeDetailPage.swift
//  freebnb
//

import SwiftUI
import MapKit

struct HomeDetailPage: View {
    let home: Home

    @Environment(MessageStore.self) private var messageStore
    @Environment(AuthManager.self) private var authManager
    @Environment(StayRequestStore.self) private var requestStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(HomeStore.self) private var homeStore
    @Environment(ReviewStore.self) private var reviewStore
    @State private var region = MKCoordinateRegion()
    @State private var mapItems: [MKMapItem] = []
    @State private var mapState: MapState = .loading
    /// Non-nil once the exact address has been disclosed to this viewer: they are
    /// the host, or the host accepted their stay. Everyone else sees the city and
    /// a blurred coordinate.
    @State private var exactLocation: ListingLocation?
    @State private var isExactCoordinate = false
    /// The host's house manual, loaded only once disclosure resolves (host or
    /// accepted guest). nil while loading or when none exists / not entitled.
    @State private var houseManual: HouseManual?
    @State private var showManualEditor = false
    @State private var showReport = false
    @State private var showBlockConfirm = false
    // Bridge @Observable → @State so the toolbar re-renders reliably.
    @State private var isListingSaved = false
    @State private var saveError: String?

    private enum MapState: Equatable {
        case loading
        case loaded
        case failed
    }

    private var isHost: Bool { authManager.userID == home.hostUserID }

    /// The viewer's own confirmed stay at this listing, if any — drives the
    /// guest-facing logistics card.
    private var acceptedStay: StayRequest? {
        requestStore.outgoingRequests.first {
            $0.listingID == home.id && $0.status == .accepted
        }
    }

    /// Host sees the manual editor entry point; an accepted guest sees their
    /// confirmed-stay card. Everyone else sees nothing here.
    @ViewBuilder
    private var stayLogisticsSection: some View {
        if isHost {
            HouseManualHostCard(manual: houseManual) { showManualEditor = true }
        } else if let stay = acceptedStay {
            StayLogisticsCard(stay: stay, home: home, manual: houseManual, location: exactLocation)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: Host motivation + trust signals
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: home.hostMotivation.iconName)
                            .font(.caption2)
                        Text(home.hostMotivation.homeText)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(home.hostMotivation.tintColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(home.hostMotivation.tintColor.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel("Host motivation: \(home.hostMotivation.homeText)")

                    hostTrustSignals
                }

                stayLogisticsSection

                if authManager.userID != home.hostUserID {
                    Text("Contact Host")
                        .font(.headline)
                    contactSection
                }

                Spacer(minLength: 10)

                Text("View on Map")
                    .font(.headline)

                Text(formattedAddress)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if exactLocation == nil {
                    Label(
                        "\(home.hostName) shares the exact address once they accept your stay.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                mapSection

                Button(action: openInMaps) {
                    // Teal, not coral: opening Maps is a utility, and coral is
                    // reserved for the one action this screen exists for
                    // (messaging the host below).
                    Text("Open in Apple Maps")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .cornerRadius(10)
                }
                .disabled(mapState != .loaded || exactLocation == nil)

                Spacer(minLength: 10)

                // MARK: Details
                Text("Details")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Guest Rooms: \(home.sleeping.numGuestRooms)")
                    // Omitted rather than shown as zero: an unanswered question,
                    // not an answer of "none" (feature 17).
                    if home.sleeping.numBathrooms > 0 {
                        Text("Bathrooms: \(home.sleeping.numBathrooms)")
                    }
                    Text("Max Guests: \(home.guestPolicy.maxGuests)")
                    Text("Max Stay: \(home.guestPolicy.maxStayDays) night\(home.guestPolicy.maxStayDays == 1 ? "" : "s")")
                    if !home.sleeping.sleepingCounts.isEmpty {
                        Text("Sleeping Arrangements: \(home.sleeping.arrangementsDescription)")
                    }
                    if !home.sleeping.bedSizeCounts.isEmpty {
                        Text("Bed Sizes: \(home.sleeping.bedSizesDescription)")
                    }
                }
                .font(.subheadline)

                // MARK: Guests & Space
                Text("Guests & Space")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Kids Allowed", available: home.guestPolicy.kidsAllowed)
                    amenityRow("Guest Can Bring Pets", available: home.guestPolicy.guestPetsAllowed)
                    amenityRow("Host Has Pets", available: home.amenities.hostHasPets)
                }
                .font(.subheadline)

                // MARK: Accessibility
                // Only rendered when the host claimed something. A grid of grey
                // crosses would read as "this home is inaccessible", which is not
                // what an unanswered question means.
                if home.amenities.hasAnyAccessibility {
                    Text("Accessibility")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        if home.amenities.hasStepFreeEntry {
                            amenityRow("Step-free Entry", available: true)
                        }
                        if home.amenities.hasElevator {
                            amenityRow("Elevator", available: true)
                        }
                        if home.amenities.hasAccessibleBathroom {
                            amenityRow("Accessible Bathroom", available: true)
                        }
                    }
                    .font(.subheadline)
                }

                // MARK: Amenities
                Text("Amenities")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Air Conditioning", available: home.amenities.hasAC)
                    amenityRow("Heating", available: home.amenities.hasHeating)
                    amenityRow("Kitchen", available: home.amenities.hasKitchen)
                    amenityRow("Fridge Space", available: home.amenities.hasFridgeSpace)
                    amenityRow("Microwave", available: home.amenities.hasMicrowave)
                    amenityRow("TV", available: home.amenities.hasTV)
                    amenityRow("Wifi", available: home.amenities.hasWifi)
                }
                .font(.subheadline)

                // MARK: Rooms & Laundry
                Text("Rooms & Laundry")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Private Guest Bathroom", available: home.amenities.hasPrivateGuestBathroom)
                    amenityRow("In-unit Laundry", available: home.amenities.hasInUnitLaundry)
                    amenityRow("Coin Laundry Nearby", available: home.amenities.hasCoinLaundryNearby)
                }
                .font(.subheadline)

                // MARK: Parking
                if !home.amenities.parkingDetails.isEmpty {
                    Text("Parking")
                        .font(.headline)
                    Text(home.amenities.parkingDetails)
                        .font(.subheadline)
                }

                // MARK: Provisions
                Text("Provisions")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    amenityRow("Pillows", available: home.amenities.providesPillows)
                    amenityRow("Blankets", available: home.amenities.providesBlankets)
                    amenityRow("Towels", available: home.amenities.providesTowels)
                    amenityRow("Toiletries", available: home.amenities.providesToiletries)
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .foregroundColor(home.amenities.foodProvision == .none ? .secondary.opacity(0.75) : .green)
                            .accessibilityHidden(true)
                        Text("Food: \(home.amenities.foodProvision.displayName)")
                            .foregroundColor(home.amenities.foodProvision == .none ? .secondary.opacity(0.75) : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .font(.subheadline)

                // MARK: Cancellation Policy
                let policy = home.cancellationPolicy ?? .flexible
                Spacer(minLength: 10)
                Text("Cancellation Policy")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(policy.displayName)
                        .font(.subheadline).fontWeight(.medium)
                    Text(policy.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let description = home.description, !description.isEmpty {
                    Spacer(minLength: 10)
                    Text("Memo")
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                }

                Spacer(minLength: 10)

                // What past guests said about this host (feature 1). Capped, with
                // the full list one tap away on their profile.
                ReviewsSection(subjectUserID: home.hostUserID, subjectName: home.hostName, limit: 3)

                if authManager.userID != home.hostUserID {
                    Divider().padding(.vertical, 8)
                    HStack(spacing: 24) {
                        Button {
                            showReport = true
                        } label: {
                            Label("Report listing", systemImage: "flag")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showBlockConfirm = true
                        } label: {
                            let blocked = userProfileStore.isBlocked(home.hostUserID)
                            Label(blocked ? "Unblock \(home.hostName)" : "Block \(home.hostName)",
                                  systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .onAppear {
            isListingSaved = userProfileStore.isSaved(home.id)
        }
        // Disclosure has to resolve before the map does: an accepted guest gets a
        // pin on the front door, everyone else gets a circle over the neighbourhood.
        .task {
            exactLocation = await homeStore.location(for: home.id)
            await resolveMapLocation()
            // The manual shares the location's accepted-guest gate, so only fetch
            // it once the viewer is entitled: the host, or a guest whose stay was
            // accepted (a disclosed address is the same entitlement).
            if isHost || acceptedStay != nil || exactLocation != nil {
                houseManual = await homeStore.manual(for: home.id)
            }
        }
        // The host's reputation (feature 2). `trustStats` rides on the public
        // user document, so one fetch fills the chips; mutual friends need the
        // callable, and neither is worth blocking the page on.
        .task {
            _ = await userProfileStore.fetchProfileOnce(userID: home.hostUserID)
            await reviewStore.loadMutualFriends(with: home.hostUserID)
        }
        .onChange(of: userProfileStore.currentProfile?.savedListingIDs) { _, _ in
            isListingSaved = userProfileStore.isSaved(home.id)
        }
        .navigationTitle(home.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A long name (e.g. "Spongebob Squarepants") has no room to breathe
            // next to the save/share buttons in the nav bar; shrink rather than
            // truncate so it's always fully readable. Tapping it is now the only
            // way to the host's profile, since the redundant pill in the body is gone.
            ToolbarItem(placement: .principal) {
                if isHost {
                    Text(home.hostName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    NavigationLink {
                        UserProfilePage(userID: home.hostUserID, fallbackName: home.hostName)
                    } label: {
                        HStack(spacing: 4) {
                            Text(home.hostName)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .opacity(0.7)
                        }
                        .font(.headline)
                        .foregroundColor(.primary)
                    }
                    .accessibilityLabel("View \(home.hostName)'s profile")
                }
            }
            if authManager.authMethod != .guest {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let newValue = !isListingSaved
                        isListingSaved = newValue          // optimistic
                        Task {
                            do {
                                try await userProfileStore.toggleSavedListing(home.id)
                            } catch {
                                isListingSaved = !newValue // revert
                                saveError = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: isListingSaved ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(Color.accent)
                    }
                    .accessibilityLabel(isListingSaved ? "Remove from saved" : "Save listing")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: "\(home.hostName) is hosting in \(home.address.city), \(home.address.state) on FreeBNB, a free, friends-only home-sharing app. If you know them, you can connect on the app and request a stay.",
                    subject: Text("FreeBNB Listing")
                )
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: .listing, targetID: home.id, targetName: "\(home.hostName)'s listing in \(home.address.city)")
        }
        .sheet(isPresented: $showManualEditor) {
            HouseManualEditorView(homeID: home.id)
                .environment(homeStore)
        }
        .confirmationDialog(
            userProfileStore.isBlocked(home.hostUserID)
                ? "Unblock \(home.hostName)?"
                : "Block \(home.hostName)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            if userProfileStore.isBlocked(home.hostUserID) {
                Button("Unblock") { Task { try? await userProfileStore.unblockUser(home.hostUserID) } }
            } else {
                Button("Block", role: .destructive) { Task { try? await userProfileStore.blockUser(home.hostUserID) } }
            }
        } message: {
            if userProfileStore.isBlocked(home.hostUserID) {
                Text("You will see their listings again.")
            } else {
                Text("Their listings won't appear and they won't be able to message you.")
            }
        }
        .background(Color.primaryBackground)
        .alert("Couldn't save listing", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let saveError { Text(saveError) }
        }
    }
}

// Kept as an extension in the same file (not a separate one) so these stay
// under SwiftLint's type_body_length cap without losing access to the
// struct's `private` state — private is file-scoped, so same-file
// extensions still see it.
extension HomeDetailPage {

    // MARK: - Trust signals (feature 2)

    /// Stays hosted, rating, response rate, tenure, mutual friends. Rendered from
    /// the host's public user document, which carries `trustStats`, so this costs
    /// the one profile fetch the page already makes.
    @ViewBuilder
    private var hostTrustSignals: some View {
        TrustBadgeRow(
            profile: userProfileStore.profile(for: home.hostUserID),
            mutualFriends: reviewStore.mutualFriends(with: home.hostUserID),
            isSelf: isHost
        )
    }

    // MARK: - Map section

    /// Roughly the blur `Home.approximate(_:)` applies, so the circle honestly
    /// covers where the listing could be rather than implying a smaller area.
    private static let approximateRadiusMeters: CLLocationDistance = 1_200

    @ViewBuilder
    private var mapSection: some View {
        Group {
            switch mapState {
            case .loading:
                SkeletonMapBlock()
            case .loaded:
                Map(initialPosition: .region(region)) {
                    if isExactCoordinate {
                        ForEach(mapItems, id: \.self) { item in
                            Marker(item.name ?? "Location", coordinate: item.placemark.coordinate)
                        }
                    } else if let center = mapItems.first?.placemark.coordinate {
                        MapCircle(center: center, radius: Self.approximateRadiusMeters)
                            .foregroundStyle(Color.accent.opacity(0.18))
                            .stroke(Color.accent.opacity(0.5), lineWidth: 1)
                    }
                }
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "location.slash")
                        .foregroundColor(.secondary)
                    Text("Map unavailable — address shown above")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .crossFades(on: mapState)
    }

    // MARK: - Geocoding

    /// Resolves the best coordinate this viewer is entitled to, preferring the
    /// exact one from the private location document, then the blurred public one,
    /// and only geocoding for listings saved before coordinates were stored.
    private func resolveMapLocation() async {
        guard mapState == .loading else { return }

        if let latitude = exactLocation?.latitude, let longitude = exactLocation?.longitude {
            show(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), exact: true)
            return
        }
        if let latitude = home.latitude, let longitude = home.longitude {
            show(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), exact: false)
            return
        }

        // Legacy listing with no stored coordinate. `formattedAddress` already
        // reflects what this viewer may see, so geocoding it can't leak a street
        // they weren't given.
        let address = formattedAddress
        let exact = exactLocation != nil
        do {
            let coordinate = try await GeocodingCache.shared.coordinate(for: address)
            guard !Task.isCancelled else { return }
            show(coordinate, exact: exact)
        } catch {
            guard !Task.isCancelled else { return }
            mapState = .failed
        }
    }

    private func show(_ coordinate: CLLocationCoordinate2D, exact: Bool) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = home.hostName
        mapItems = [item]
        isExactCoordinate = exact
        // A blurred point deserves a wider frame; zooming to a street on a
        // kilometre-accurate coordinate would imply precision that isn't there.
        let span = exact ? 0.01 : 0.05
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        mapState = .loaded
    }

    private var formattedAddress: String {
        let area = "\(home.address.city), \(home.address.state) \(home.address.zip)"
        guard let street = exactLocation?.street, !street.isEmpty else { return area }
        return "\(street), \(area)"
    }

    // MARK: - Contact section

    @ViewBuilder
    private var contactSection: some View {
        switch home.contactPreference {
        case .inApp:
            if authManager.authMethod == .guest {
                Text("Create a free account to message \(home.hostName) and request a stay.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                let existing = requestStore.activeRequest(for: home.id, guestUserID: authManager.userID)
                // "Open conversation" the moment a thread exists, not only once a
                // request does: sending a plain message already starts the chat, so
                // the button shouldn't keep inviting a first message after one.
                let hasThread = messageStore.hasConversation(with: home.hostUserID)
                VStack(spacing: 10) {
                    if let existing {
                        existingRequestBanner(existing)
                    }
                    NavigationLink {
                        MessagingPage(
                            otherUserID: home.hostUserID,
                            otherName: home.hostName,
                            listing: home
                        )
                    } label: {
                        // Requesting a stay isn't a separate button; it happens
                        // inside the conversation. The label carries that so nobody
                        // has to hunt for a request action or read fine print.
                        Label(
                            (existing == nil && !hasThread) ? "Message \(home.hostName) to request a stay" : "Open conversation",
                            systemImage: "message.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        // Coral marks the screen's one primary action; everything
                        // else on the page stays in brand teal.
                        .background(Color.callToAction)
                        .foregroundColor(.onAccent)
                        .cornerRadius(10)
                    }
                    .accessibilityIdentifier("homeDetail.messageHostButton")
                }
            }
        case .contactInfo:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(home.hostName) prefers to be contacted directly:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let info = home.hostContactInfo, !info.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .foregroundColor(Color.accent)
                        Text(info)
                            .font(.subheadline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(10)
                }
            }
        }
    }

    // MARK: - Existing request banner

    private func existingRequestBanner(_ request: StayRequest) -> some View {
        let f = AppDateFormatters.mediumDate
        return HStack(spacing: 10) {
            Image(systemName: request.status == .accepted ? "checkmark.circle.fill" : "clock")
                .foregroundColor(request.status == .accepted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.status == .accepted ? "Stay accepted" : "Request pending")
                    .font(.subheadline).fontWeight(.semibold)
                Text("\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background((request.status == .accepted ? Color.green : Color.orange).opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private func openInMaps() {
        mapItems.first?.openInMaps(launchOptions: nil)
    }

    private func amenityRow(_ label: String, available: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(available ? .green : .secondary.opacity(0.75))
                .accessibilityHidden(true)
            Text(available ? label : "\(label) (not available)")
                .foregroundColor(available ? .primary : .secondary.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        HomeDetailPage(home: Home(
            hostUserID: "preview-host",
            hostName: "Michaela",
            address: Address(city: "Brighton", state: "MA", zip: "02135"),
            description: "Spots misses you!",
            contactPreference: .inApp,
            hostMotivation: .eager,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 14, kidsAllowed: true, guestPetsAllowed: false),
            amenities: Amenities(
                hasAC: true, hasHeating: true, hasKitchen: true, hasFridgeSpace: true,
                hasMicrowave: true, hasTV: true, hasWifi: true,
                hasPrivateGuestBathroom: false, hostHasPets: true, parkingDetails: "Street parking",
                hasInUnitLaundry: true, hasCoinLaundryNearby: false,
                providesPillows: true, providesBlankets: true, providesTowels: true, providesToiletries: true,
                foodProvision: .all
            )
        ))
        .previewEnvironment()
    }
}
