//
//  StaysTabComponents.swift
//  freebnb
//
//  Small pieces of the Stays tab that don't need its state: the nested types,
//  the mode switcher, the placeholder states and the row conversation actions.
//

import SwiftUI

extension StaysTab {
    enum StaysTabSelection { case trips, listings }

    /// A stay plus the role the signed-in user reviews it in.
    struct ReviewTarget: Identifiable {
        let stay: StayRequest
        let role: ReviewRole
        let subjectName: String
        var id: String { stay.id }
    }
}

extension GuestNoteComposition {
    /// What a trip note is about: always a listing the guest stayed at, labelled
    /// from the cached `listings` or else the trip's denormalized label.
    func subjectName(listings: [Home], trips: [StayRequest]) -> String {
        switch self {
        case .new(_, let subjectID, let stayRequestID):
            if let home = listings.first(where: { $0.id == subjectID }) {
                return home.displayTitle
            }
            // Not in the guest's cached set (it's the host's); use the label the stay snapshotted.
            if let stayRequestID,
               let stay = trips.first(where: { $0.id == stayRequestID }) {
                return stay.listingLabel
            }
            return "this listing"
        case .editing(let note):
            if let home = listings.first(where: { $0.id == note.subjectID }) {
                return home.displayTitle
            }
            return "this listing"
        }
    }
}

// MARK: - Placeholder states

struct StaysLoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primaryBackground.ignoresSafeArea())
            .accessibilityLabel("Loading stays")
    }
}

struct StaysLoadErrorView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(ThemeCopy.Status.staysLoadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.danger)
        } description: {
            Text(error)
                .font(.caption)
            Button("Retry", action: onRetry)
                .font(.subheadline.weight(.medium))
                .foregroundColor(Color.accent)
                .padding(.top, 8)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
    }
}

struct NoTripsView: View {
    var body: some View {
        EmptyStateView(
            title: ThemeCopy.Empty.tripsTitle,
            systemImage: ThemeCopy.Tab.tripsIcon,
            message: ThemeCopy.Empty.tripsMessage
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lagoonBackground()
    }
}

/// The Show/Hide row that folds away past trips or past hosting.
struct PastStaysToggle: View {
    @Binding var isShown: Bool
    let label: String

    var body: some View {
        Section {
            Button {
                withAnimation { isShown.toggle() }
            } label: {
                Label(isShown ? "Hide \(label)" : "Show \(label)",
                      systemImage: isShown ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
        }
    }
}

// Every stay row gets a jump into the conversation: a swipe plus a context menu, as in YourListingsPage.
extension View {
    func stayConversationActions(name: String, open: @escaping () -> Void) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(action: open) {
                    Label("Message", systemImage: "message")
                }
                .tint(.accent)
            }
            .contextMenu {
                Button(action: open) {
                    Label("Message \(name)", systemImage: "message")
                }
            }
    }
}

// MARK: - Mode switcher

/// Two full-width filled pills replacing the system segmented control, which
/// went unnoticed in the nav bar; a badge marks the pane that owes the user something.
struct StaysModeSwitcher: View {
    @Binding var selection: StaysTab.StaysTabSelection
    let tripsBadge: Int
    let listingsBadge: Int

    var body: some View {
        HStack(spacing: 8) {
            segment(
                title: "My Trips",
                systemImage: "suitcase.fill",
                badge: tripsBadge,
                isSelected: selection == .trips
            ) {
                selection = .trips
            }
            segment(
                title: "My Listings",
                systemImage: "house.fill",
                badge: listingsBadge,
                isSelected: selection == .listings
            ) {
                selection = .listings
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.primaryBackground)
    }

    private func segment(
        title: String,
        systemImage: String,
        badge: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.onAccent.opacity(0.3) : Color.callToAction, in: Capsule())
                        .foregroundColor(isSelected ? Color.onAccent : .white)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(isSelected ? Color.onAccent : .primary)
            .background(
                isSelected ? Color.accent : Color.secondaryBackground,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) need\(badge == 1 ? "s" : "") your attention" : title)
    }
}
