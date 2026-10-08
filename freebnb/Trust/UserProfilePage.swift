//
//  UserProfilePage.swift
//  freebnb
//
//  Somebody else's profile: who they are, what the platform vouches for, and what guests,
//  hosts and friends said. Reached from a listing, a conversation or the friends list.
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
    @State private var blockError: String?

    private var isBlocked: Bool { userProfileStore.isBlocked(userID) }

    private var profile: UserProfile? { userProfileStore.profile(for: userID) }
    private var displayName: String { profile?.displayName ?? fallbackName }
    private var isSelf: Bool { authManager.userID == userID }

    /// This person's listings the viewer may see; `visibleListings` is already privacy-filtered, keyed on
    /// `hostUserID` like the Friends "N homes" count.
    private var hostHomes: [Home] {
        homeStore.visibleListings.filter { $0.hostUserID == userID }
    }

    /// Only an accepted friend may write a reference (as the rules enforce); checked here so the button
    /// doesn't offer a rejected write.
    private var canWriteReference: Bool {
        !isSelf && authManager.authMethod != .guest && friendStore.isFriend(userID)
    }

    /// The notes entry point follows the friendship, never your own profile (the rules refuse a self-note).
    private var canKeepNotes: Bool {
        !isSelf && authManager.authMethod != .guest && friendStore.isFriend(userID)
    }

    /// Messaging is friend-gated, so the thread opens only once the friendship exists; earlier would offer a
    /// composer the rules refuse.
    private var canMessage: Bool {
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
                    // The relationship control earns this slot only when there's an action to take;
                    // once friends it moves to the bottom and this becomes Message.
                    if !friendStore.isFriend(userID) {
                        FriendshipControl(userID: userID, displayName: displayName)
                    }
                }

                if canMessage {
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

                // The quietest control on the page (grey, below what reaches the other person): private
                // shouldn't invite broadcast.
                if canKeepNotes {
                    NavigationLink {
                        FriendNotesPage(friendID: userID, friendName: displayName)
                    } label: {
                        Label("Your private notes", systemImage: "note.text")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.secondaryText.opacity(0.10))
                            .foregroundColor(.secondaryText)
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
                    // Manage section: friendship status and the rare ways to step back. Color signals
                    // severity: "Friends" is accent, reporting neutral, blocking the one red.
                    VStack(alignment: .leading, spacing: 16) {
                        FriendStatusButton(userID: userID, displayName: displayName)

                        Button {
                            showReport = true
                        } label: {
                            Label("Report \(displayName)", systemImage: "flag")
                                .font(.subheadline)
                                .foregroundColor(.secondaryText)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showBlockConfirm = true
                        } label: {
                            Label(isBlocked ? "Unblock \(displayName)" : "Block \(displayName)",
                                  systemImage: isBlocked ? "person.fill.checkmark" : "person.fill.xmark")
                                .font(.subheadline)
                                .foregroundColor(isBlocked ? .secondaryText : .danger)
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
            // The public doc carries trustStats, so this fetch fills the badge row; mutual friends need the
            // callable.
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
                    Task {
                        do { try await userProfileStore.unblockUser(userID) }
                        catch { blockError = error.localizedDescription }
                    }
                }
            } else {
                Button("Block", role: .destructive) {
                    Task {
                        do { try await userProfileStore.blockUser(userID) }
                        catch { blockError = error.localizedDescription }
                    }
                }
            }
        } message: {
            if !isBlocked {
                Text("You won't see messages or listings from \(displayName). You can unblock them any time.")
            }
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

    /// The person's places, as the feed's `HomeCard`. A destination-based `NavigationLink`, since
    /// stacks like the Friends sheet register no `Home` destination.
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
                        .foregroundColor(.secondaryText)
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
