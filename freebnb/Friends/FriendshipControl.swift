//
//  FriendshipControl.swift
//  freebnb
//
//  The relationship control on someone's profile: start, answer or end a friendship. A
//  friendship is the whole trust grant, so ending one is deliberate: behind a menu and a confirmation.
//

import SwiftUI

struct FriendshipControl: View {
    let userID: String
    let displayName: String

    @Environment(FriendStore.self) private var friendStore
    @Environment(AuthManager.self) private var authManager

    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Relationship {
        case none
        case outgoing(FriendEdge)
        case incoming(FriendEdge)
        case friends(FriendEdge)
    }

    private var relationship: Relationship {
        guard let edge = friendStore.existingEdge(with: userID) else { return .none }
        switch edge.status {
        case .accepted:
            return .friends(edge)
        case .pending:
            return edge.initiator == authManager.userID ? .outgoing(edge) : .incoming(edge)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let errorMessage {
                InlineErrorLabel(message: errorMessage)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch relationship {
        case .none:
            addButton
        case .outgoing(let edge):
            outgoingControls(edge)
        case .incoming(let edge):
            incomingControls(edge)
        case .friends:
            // Once friends, the status and the (buried) way to end it live at the bottom, beside Report and Block (see `FriendStatusButton`).
            EmptyView()
        }
    }

    // MARK: - States

    private var addButton: some View {
        Button {
            perform { try await friendStore.sendRequest(to: userID) }
        } label: {
            Label("Add Friend", systemImage: "person.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accent)
                .foregroundColor(.onAccent)
                .cornerRadius(10)
        }
        .buttonStyle(.pressable)
        .disabled(isWorking)
    }

    private func outgoingControls(_ edge: FriendEdge) -> some View {
        HStack(spacing: 10) {
            Label("Request Sent", systemImage: "clock")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.secondaryText.opacity(0.12))
                .foregroundColor(.secondaryText)
                .cornerRadius(10)
            Button("Cancel") {
                perform { try await friendStore.remove(edge) }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.pressable)
            .disabled(isWorking)
        }
    }

    private func incomingControls(_ edge: FriendEdge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(displayName) sent you a friend request. Accepting lets you see each other's places and request stays.")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
            HStack(spacing: 10) {
                Button {
                    perform { try await friendStore.decline(edge) }
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.secondaryText.opacity(0.12))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
                Button {
                    perform { try await friendStore.accept(edge) }
                } label: {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accent)
                        .foregroundColor(.onAccent)
                        .cornerRadius(8)
                }
                .buttonStyle(.pressable)
            }
            .font(.subheadline.weight(.semibold))
            .disabled(isWorking)
        }
    }

    // MARK: - Actions

    /// Runs a friend-graph mutation with a shared busy flag and inline error, so every button disables and fails alike.
    private func perform(_ action: @escaping () async throws -> Void) {
        errorMessage = nil
        isWorking = true
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}

/// The friendship status at the bottom of a profile beside Report and Block: a quiet
/// "Friends ✓" with unfriending behind a tap and confirmation. Renders nothing unless friends.
struct FriendStatusButton: View {
    let userID: String
    let displayName: String

    @Environment(FriendStore.self) private var friendStore
    @Environment(AuthManager.self) private var authManager
    @Environment(StayRequestStore.self) private var stayRequestStore

    @State private var confirming = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// Whether unfriending can be offered; the stay lists give three answers, not two.
    private enum UnfriendAvailability {
        case available
        /// A stay is on the books; ending the friendship would remove the thread they need for key handoffs.
        case blockedByStay
        /// The lists haven't arrived or a listener failed; an empty list isn't "no stay".
        case unknown
    }

    private var unfriendAvailability: UnfriendAvailability {
        guard stayRequestStore.hasLoadedRequests else { return .unknown }
        let stays = stayRequestStore.incomingRequests + stayRequestStore.outgoingRequests
        return stays.outstandingStay(between: authManager.userID, and: userID) == nil
            ? .available
            : .blockedByStay
    }

    var body: some View {
        if let edge = friendStore.existingEdge(with: userID), edge.status == .accepted {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    confirming = true
                } label: {
                    Label("Friends", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(Color.accent)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                if let errorMessage {
                    InlineErrorLabel(message: errorMessage)
                }
            }
            .confirmationDialog(
                "You're friends with \(displayName)",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                // No unfriend while a stay is on the books; the dialog still opens and says why, since a vanished option reads as a bug.
                if case .available = unfriendAvailability {
                    Button("Unfriend \(displayName)", role: .destructive) {
                        errorMessage = nil
                        isWorking = true
                        Task {
                            do { try await friendStore.remove(edge) }
                            catch { errorMessage = error.localizedDescription }
                            isWorking = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Blocking stays available from the row below and isn't mentioned here; offering it for "unfriend" would suggest escalating.
                switch unfriendAvailability {
                case .available:
                    Text("Unfriending means you'll no longer see each other's homes. To reconnect, one of you will need to send a new friend request.")
                case .blockedByStay:
                    Text("You have a stay booked with \(displayName), so unfriending is unavailable until it's finished. Ending it now would close the thread you'd use to sort out arrival or keys.")
                case .unknown:
                    Text("Your stays haven't loaded yet, and unfriending during a booked stay would close the thread you'd use to sort out arrival or keys. This becomes available once they arrive.")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        FriendshipControl(userID: PreviewData.friendID, displayName: "Maya")
            .padding()
    }
    .previewEnvironment()
}
