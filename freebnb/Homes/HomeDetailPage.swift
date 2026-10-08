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
    /// Non-nil once the exact address is disclosed to this viewer (host or accepted guest).
    @State private var exactLocation: ListingLocation?
    @State private var isExactCoordinate = false
    /// The house manual, loaded once disclosure resolves; nil while loading, absent or not entitled.
    @State private var houseManual: HouseManual?
    @State private var showManualEditor = false
    @State private var showReport = false
    @State private var showBlockConfirm = false
    // Bridge @Observable to @State so the toolbar re-renders reliably.
    @State private var isListingSaved = false
    @State private var saveError: String?
    @State private var blockError: String?

    private enum MapState: Equatable {
        case loading
        case loaded
        case failed
    }

    private var isHost: Bool { authManager.userID == home.hostUserID }

    /// The viewer's own confirmed stay here, if any; drives the logistics card.
    private var acceptedStay: StayRequest? {
        requestStore.outgoingRequests.first {
            $0.listingID == home.id && $0.status == .accepted
        }
    }

    /// Hosts get the manual editor entry point; accepted guests get their stay card.
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
            // Ordered the way someone decides: the place, the host's words, contents, location, cancellation,
            // host.
            // The one guest action is pinned below.
            VStack(alignment: .leading, spacing: 14) {
                heroSection

                // Anything settled between these two people outranks the description.
                stayLogisticsSection

                // Where a pending or accepted request stands, near the top.
                if !isHost,
                   let existing = requestStore.activeRequest(for: home.id, guestUserID: authManager.userID) {
                    existingRequestBanner(existing)
                }

                // The host's own words, directly under the header.
                if let description = home.description, !description.isEmpty {
                    ListingSection("From \(home.hostName)", systemImage: "quote.bubble") {
                        Text(description)
                            .font(.subheadline)
                    }
                }

                spaceSection
                whoCanComeSection
                amenitiesSection
                provisionsSection

                // Only when the host claimed something; a grid of grey crosses would read as "inaccessible".
                if home.amenities.hasAnyAccessibility {
                    ListingSection("Accessibility", systemImage: "figure.roll") {
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
                }

                // Off-app hosts only; the in-app button is pinned.
                if authManager.userID != home.hostUserID && !pinsContactAction {
                    contactSection
                }

                locationSection
                cancellationSection

                // What past guests said about this host, capped; the rest is on their profile.
                ReviewsSection(subjectUserID: home.hostUserID, subjectName: home.hostName, limit: 3)

                // A private note about this listing, quietest control on the page.
                // Full members only; anonymous browsers have nowhere to store one.
                if authManager.userID != home.hostUserID && authManager.authMethod != .guest {
                    GuestNotesLink(
                        subjectType: .listing,
                        subjectID: home.id,
                        subjectName: home.displayTitle
                    )
                }

                if authManager.userID != home.hostUserID {
                    reportFooter
                }
            }
            .padding()
        }
        // Pinned so the screen's one action is always reachable.
        .safeAreaInset(edge: .bottom) {
            if pinsContactAction {
                contactSection
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .background(.bar)
            }
        }
        .onAppear {
            isListingSaved = userProfileStore.isSaved(home.id)
        }
        // Disclosure resolves before the map: accepted guests get a pin, everyone else a circle.
        .task {
            exactLocation = await homeStore.location(for: home.id)
            await resolveMapLocation()
            // The manual shares the location's gate, so fetch it only once entitled.
            if isHost || acceptedStay != nil || exactLocation != nil {
                houseManual = await homeStore.manual(for: home.id)
            }
        }
        // The host's reputation: `trustStats` rides on the public user doc; mutual friends need the callable.
        // Neither blocks the page.
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
            // Shrink rather than truncate long names; tapping is the only way to the host's profile.
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
                Button("Unblock") {
                    Task {
                        do { try await userProfileStore.unblockUser(home.hostUserID) }
                        catch { blockError = error.localizedDescription }
                    }
                }
            } else {
                Button("Block", role: .destructive) {
                    Task {
                        do { try await userProfileStore.blockUser(home.hostUserID) }
                        catch { blockError = error.localizedDescription }
                    }
                }
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
        .alert("Error", isPresented: Binding(
            get: { blockError != nil },
            set: { if !$0 { blockError = nil } }
        )) {
            Button("OK", role: .cancel) { blockError = nil }
        } message: {
            if let blockError { Text(blockError) }
        }
    }
}

// An extension in the same file keeps these under SwiftLint's type_body_length
// cap while still seeing the struct's file-scoped `private` state.
extension HomeDetailPage {

    // MARK: - Trust signals

    /// Stays hosted, rating, response rate, tenure and mutual friends, from the host's public user document.
    @ViewBuilder
    private var hostTrustSignals: some View {
        TrustBadgeRow(
            profile: userProfileStore.profile(for: home.hostUserID),
            mutualFriends: reviewStore.mutualFriends(with: home.hostUserID),
            isSelf: isHost
        )
    }

    // MARK: - Hero

    /// Photos, the listing's name and the trust signals. The page shows
    /// `displayTitle`, as the feed card, chat banner and request sheet do.
    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !home.photos.isEmpty {
                photoCarousel
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(home.displayTitle)
                    .font(.title2).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("\(home.address.city), \(home.address.state)")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)

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
        }
    }

    /// The listing's photos.
    private var photoCarousel: some View {
        TabView {
            ForEach(Array(home.photos.enumerated()), id: \.offset) { _, urlString in
                CachedAsyncImage(url: URL(string: urlString), maxPointSize: 900) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.accent.opacity(0.25)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title)
                                    .foregroundColor(.onAccent.opacity(0.8))
                            )
                    case .empty:
                        Color.accent.opacity(0.2)
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .tabViewStyle(.page)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("\(home.photos.count) photo\(home.photos.count == 1 ? "" : "s") of \(home.displayTitle)")
    }

    // MARK: - The space

    /// Rooms, beds and capacity in one card.
    private var spaceSection: some View {
        ListingSection("The space", systemImage: "bed.double") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Guest rooms", "\(home.sleeping.numGuestRooms)")
                // Omitted rather than zero: unanswered, not "none".
                if home.sleeping.numBathrooms > 0 {
                    detailRow("Bathrooms", "\(home.sleeping.numBathrooms)")
                }
                detailRow("Sleeps up to", "\(home.guestPolicy.maxGuests)")
                detailRow(
                    "Longest stay",
                    "\(home.guestPolicy.maxStayDays) night\(home.guestPolicy.maxStayDays == 1 ? "" : "s")"
                )
                if !home.sleeping.sleepingCounts.isEmpty {
                    detailRow("Sleeping arrangements", home.sleeping.arrangementsDescription)
                }
                if !home.sleeping.bedSizeCounts.isEmpty {
                    detailRow("Bed sizes", home.sleeping.bedSizesDescription)
                }
            }
        }
    }

    private var whoCanComeSection: some View {
        ListingSection("Who can come", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 6) {
                amenityRow("Kids Allowed", available: home.guestPolicy.kidsAllowed)
                amenityRow("Guest Can Bring Pets", available: home.guestPolicy.guestPetsAllowed)
                amenityRow("Host Has Pets", available: home.amenities.hostHasPets)
            }
            .font(.subheadline)
        }
    }

    /// Amenities and rooms/laundry in one card; parking is a footnote.
    private var amenitiesSection: some View {
        ListingSection("Amenities", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                amenityRow("Air Conditioning", available: home.amenities.hasAC)
                amenityRow("Heating", available: home.amenities.hasHeating)
                amenityRow("Kitchen", available: home.amenities.hasKitchen)
                amenityRow("Fridge Space", available: home.amenities.hasFridgeSpace)
                amenityRow("Microwave", available: home.amenities.hasMicrowave)
                amenityRow("TV", available: home.amenities.hasTV)
                amenityRow("Wifi", available: home.amenities.hasWifi)
                amenityRow("Private Guest Bathroom", available: home.amenities.hasPrivateGuestBathroom)
                amenityRow("In-unit Laundry", available: home.amenities.hasInUnitLaundry)
                amenityRow("Coin Laundry Nearby", available: home.amenities.hasCoinLaundryNearby)

                if !home.amenities.parkingDetails.isEmpty {
                    Divider().padding(.vertical, 2)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "car")
                            .foregroundColor(Color.accent)
                            .accessibilityHidden(true)
                        Text(home.amenities.parkingDetails)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Parking: \(home.amenities.parkingDetails)")
                }
            }
            .font(.subheadline)
        }
    }

    private var provisionsSection: some View {
        ListingSection("What's provided", systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 6) {
                amenityRow("Pillows", available: home.amenities.providesPillows)
                amenityRow("Blankets", available: home.amenities.providesBlankets)
                amenityRow("Towels", available: home.amenities.providesTowels)
                amenityRow("Toiletries", available: home.amenities.providesToiletries)
                HStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .foregroundColor(home.amenities.foodProvision == .none ? .secondaryText.opacity(0.75) : .green)
                        .accessibilityHidden(true)
                    Text("Food: \(home.amenities.foodProvision.displayName)")
                        .foregroundColor(home.amenities.foodProvision == .none ? .secondaryText.opacity(0.75) : .primary)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.subheadline)
        }
    }

    // MARK: - Location

    /// The address, disclosure notice, map and Maps handoff.
    private var locationSection: some View {
        ListingSection("Where you'll be", systemImage: "mappin.and.ellipse") {
            VStack(alignment: .leading, spacing: 10) {
                Text(formattedAddress)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)

                if exactLocation == nil {
                    Label(
                        "\(home.hostName) shares the exact address once they accept your stay.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                }

                mapSection

                Button(action: openInMaps) {
                    // Teal, not coral: opening Maps is a utility; coral is reserved for messaging the host.
                    Text("Open in Apple Maps")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .cornerRadius(10)
                }
                .disabled(mapState != .loaded || exactLocation == nil)
            }
        }
    }

    private var cancellationSection: some View {
        let policy = home.cancellationPolicy ?? .flexible
        return ListingSection("If plans change", systemImage: "arrow.uturn.backward") {
            VStack(alignment: .leading, spacing: 4) {
                Text(policy.displayName)
                    .font(.subheadline).fontWeight(.medium)
                Text(policy.description)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
    }

    // MARK: - Report / block footer

    private var reportFooter: some View {
        HStack(spacing: 24) {
            Button {
                showReport = true
            } label: {
                Label("Report listing", systemImage: "flag")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
            .buttonStyle(.plain)

            Button {
                showBlockConfirm = true
            } label: {
                let blocked = userProfileStore.isBlocked(home.hostUserID)
                Label(blocked ? "Unblock \(home.hostName)" : "Block \(home.hostName)",
                      systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Map section

    /// Roughly the blur `Home.approximate(_:)` applies, so the circle covers where the listing could be.
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
                        .foregroundColor(.secondaryText)
                    Text("Map unavailable. Address shown above")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.secondaryText.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .crossFades(on: mapState)
    }

    // MARK: - Geocoding

    /// Resolves the best coordinate this viewer may have: the exact private one,
    /// then the blurred public one, geocoding only for listings saved before coordinates existed.
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

        // Legacy listing with no stored coordinate; `formattedAddress` already respects what this viewer may see.
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
        // A blurred point gets a wider frame so the zoom doesn't imply precision.
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

    /// True when contact is a single button worth pinning. Off-app hosts get a
    /// card in the page flow instead.
    var pinsContactAction: Bool {
        home.contactPreference == .inApp && authManager.userID != home.hostUserID
    }

    @ViewBuilder
    private var contactSection: some View {
        switch home.contactPreference {
        case .inApp:
            if authManager.authMethod == .guest {
                Text("Create a free account to message \(home.hostName) and request a stay.")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
            } else {
                let existing = requestStore.activeRequest(for: home.id, guestUserID: authManager.userID)
                // "Open conversation" as soon as a thread exists, not only once a request does.
                let hasThread = messageStore.hasConversation(with: home.hostUserID)
                // The status banner sits in the page flow; pinning it would cost a quarter of the screen.
                Group {
                    NavigationLink {
                        MessagingPage(
                            otherUserID: home.hostUserID,
                            otherName: home.hostName,
                            listing: home
                        )
                    } label: {
                        // Requesting a stay happens inside the conversation; the label says so.
                        Label(
                            (existing == nil && !hasThread) ? "Message \(home.hostName) to request a stay" : "Open conversation",
                            systemImage: "message.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        // Coral marks the screen's one primary action.
                        .background(Color.callToAction)
                        .foregroundColor(.onAccent)
                        .cornerRadius(10)
                    }
                    .accessibilityIdentifier("homeDetail.messageHostButton")
                }
            }
        case .contactInfo:
            ListingSection("Contact \(home.hostName)", systemImage: "person.crop.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(home.hostName) prefers to be contacted directly:")
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                    if let info = home.hostContactInfo, !info.isEmpty {
                        Text(info)
                            .font(.subheadline)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondaryText.opacity(0.08))
                            .cornerRadius(10)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Existing request banner

    private func existingRequestBanner(_ request: StayRequest) -> some View {
        let f = AppDateFormatters.mediumDate
        return HStack(spacing: 10) {
            Image(systemName: request.status == .accepted ? "checkmark.circle.fill" : "clock")
                .foregroundColor(request.status == .accepted ? .success : .warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.status == .accepted ? "Stay accepted" : "Request pending")
                    .font(.subheadline).fontWeight(.semibold)
                Text("\(f.string(from: request.checkIn)) – \(f.string(from: request.checkOut))")
                    .font(.caption).foregroundColor(.secondaryText)
            }
            Spacer()
        }
        .padding()
        .background((request.status == .accepted ? Color.success : Color.warning).opacity(0.12))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private func openInMaps() {
        mapItems.first?.openInMaps(launchOptions: nil)
    }

    /// A label/value pair for non-yes/no facts, so they line up as a table.
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func amenityRow(_ label: String, available: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(available ? .success : .secondaryText.opacity(0.75))
                .accessibilityHidden(true)
            Text(available ? label : "\(label) (not available)")
                .foregroundColor(available ? .primary : .secondaryText.opacity(0.75))
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
