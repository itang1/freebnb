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

    @State private var showWriteReference = false
    @State private var showReport = false

    private var profile: UserProfile? { userProfileStore.profile(for: userID) }
    private var displayName: String { profile?.displayName ?? fallbackName }
    private var isSelf: Bool { authManager.userID == userID }

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
                    Button {
                        showReport = true
                    } label: {
                        Label("Report \(displayName)", systemImage: "flag")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
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
    }

    private var header: some View {
        HStack(spacing: 16) {
            PersonAvatar()
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
