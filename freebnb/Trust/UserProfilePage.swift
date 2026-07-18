//
//  UserProfilePage.swift
//  freebnb
//
//  Somebody else's profile: who they are, what the platform can vouch for, what
//  their guests and hosts said, and what their friends say (features 1 and 2).
//  Reached from a listing, a conversation, or the friends list.
//

import SwiftUI

struct UserProfilePage: View {
    let userID: String
    /// Shown while the full profile loads, so the title isn't empty on push.
    let fallbackName: String

    @Environment(ReviewStore.self) private var reviewStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(AuthManager.self) private var authManager
    @Environment(HomeStore.self) private var homeStore

    @State private var showWriteReference = false
    @State private var showReport = false
    @State private var showBlockConfirm = false

    private var isBlocked: Bool { userProfileStore.isBlocked(userID) }

    private var profile: UserProfile? { userProfileStore.profile(for: userID) }
    private var displayName: String { profile?.displayName ?? fallbackName }
    private var isSelf: Bool { authManager.userID == userID }

    /// This person's listings that the viewer is allowed to see. `visibleListings`
    /// is already privacy-filtered to the viewer's network, so filtering it by host
    /// never exposes a home the viewer couldn't otherwise reach. Keyed on
    /// `hostUserID` to match the "N homes" count on the Friends list.
    private var hostHomes: [Home] {
        homeStore.visibleListings.filter { $0.hostUserID == userID }
    }

    /// Only an accepted friend may write a reference, which is exactly what the
    /// rules enforce. Checking the same condition here keeps the button from
    /// offering a write that would be rejected.
    private var canWriteReference: Bool {
        !isSelf && authManager.authMethod != .guest && friendStore.isFriend(userID)
    }

    private var myReference: CharacterReference? {
        reviewStore.references(about: userID).first { $0.authorUserID == authManager.userID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                TrustBadgeRow(
                    profile: profile,
                    mutualFriends: reviewStore.mutualFriends(with: userID),
                    isSelf: isSelf
                )

                if !isSelf && authManager.authMethod != .guest {
                    // The relationship control only earns space up here when there's
                    // an action to take (add, or answer a request). Once you're
                    // friends, status and unfriending move to the bottom, so this is
                    // absent rather than an empty gap above Message.
                    if !friendStore.isFriend(userID) {
                        FriendshipControl(userID: userID, displayName: displayName)
                    }

                    NavigationLink {
                        MessagingPage(otherUserID: userID, otherName: displayName)
                    } label: {
                        Label("Message \(displayName)", systemImage: "message")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accent.opacity(0.12))
                            .foregroundColor(Color.accent)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.pressable)
                }

                if canWriteReference {
                    Button {
                        showWriteReference = true
                    } label: {
                        Label(
                            myReference == nil ? "Vouch for \(displayName)" : "Edit your reference",
                            systemImage: "quote.bubble"
                        )
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accent.opacity(0.12))
                        .foregroundColor(Color.accent)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.pressable)
                }

                if !hostHomes.isEmpty {
                    Divider()
                    homesSection
                }

                Divider()

                ReviewsSection(subjectUserID: userID, subjectName: displayName)

                if isSelf {
                    Divider()
                    PrivateFeedbackSection(subjectUserID: userID)
                }

                Divider()

                ReferencesSection(subjectUserID: userID, subjectName: displayName)

                if !isSelf && authManager.authMethod != .guest {
                    Divider()
                    // Manage section: the friendship status plus the rare, deliberate
                    // ways to step back from someone. Colour signals severity, so red
                    // is spent on exactly one action. "Friends" is a positive status
                    // (accent) that hides unfriending behind a tap; reporting (routes
                    // to us, costs the other person nothing yet) stays neutral;
                    // blocking, the one hostile, self-protective cut, is the only red.
                    VStack(alignment: .leading, spacing: 16) {
                        FriendStatusButton(userID: userID, displayName: displayName)

                        Button {
                            showReport = true
                        } label: {
                            Label("Report \(displayName)", systemImage: "flag")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showBlockConfirm = true
                        } label: {
                            Label(isBlocked ? "Unblock \(displayName)" : "Block \(displayName)",
                                  systemImage: isBlocked ? "person.fill.checkmark" : "person.fill.xmark")
                                .font(.subheadline)
                                .foregroundColor(isBlocked ? .secondary : .red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle(displayName)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // The public doc carries trustStats, so this one fetch also fills the
            // badge row. Mutual friends need the callable.
            _ = await userProfileStore.fetchProfileOnce(userID: userID)
            await reviewStore.loadMutualFriends(with: userID)
        }
        .sheet(isPresented: $showWriteReference) {
            WriteReferenceSheet(
                subjectUserID: userID,
                subjectName: displayName,
                existing: myReference
            )
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: .user, targetID: userID, targetName: displayName)
        }
        .confirmationDialog(
            isBlocked ? "Unblock \(displayName)?" : "Block \(displayName)?",
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            if isBlocked {
                Button("Unblock") {
                    Task { try? await userProfileStore.unblockUser(userID) }
                }
            } else {
                Button("Block", role: .destructive) {
                    Task { try? await userProfileStore.blockUser(userID) }
                }
            }
        } message: {
            if !isBlocked {
                Text("You won't see messages or listings from \(displayName). You can unblock them any time.")
            }
        }
    }

    /// The person's places, each tapping through to the full listing. Uses the
    /// same `HomeCard` the feed shows, so a home looks identical wherever it
    /// appears. Destination-based `NavigationLink` rather than value-based because
    /// this page is pushed from stacks (the Friends sheet) that don't register a
    /// `Home` navigation destination.
    private var homesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSelf ? "Your homes" : "\(displayName)'s homes")
                .font(.headline)

            ForEach(hostHomes) { home in
                NavigationLink {
                    HomeDetailPage(home: home)
                } label: {
                    HomeCard(listing: home)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            GeneratedAvatar(seed: userID, size: 72, accessibilityName: displayName)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                if let tenure = profile?.tenureText {
                    Text(tenure)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
}

#Preview {
    NavigationStack {
        UserProfilePage(userID: PreviewData.friendID, fallbackName: "Maya")
    }
    .previewEnvironment()
}
