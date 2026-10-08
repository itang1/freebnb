//
//  PreviewEnvironment.swift
//  freebnb
//
//  One environment injection for every #Preview. A missing store fatal-errors the preview when read, so this
//  injects the complete set on in-memory repositories (and never constructs a Firestore-backed store).
//  Not #if DEBUG-gated, like PreviewData: #Preview bodies compile in release, so gating would break archives.
//

import SwiftUI

extension View {
    /// Injects the full set of stores the app provides at launch on empty in-memory repositories. To seed
    /// fixture data, attach a nearer `.environment(...)`; the nearer value wins.
    @MainActor
    func previewEnvironment() -> some View {
        environment(AuthManager())
            .environment(HomeStore(repository: InMemoryHomesRepository()))
            .environment(MessageStore(repository: InMemoryMessagesRepository()))
            .environment(UserProfileStore(repository: InMemoryUserProfileRepository()))
            .environment(StayRequestStore(repository: InMemoryStayRequestsRepository()))
            .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
            .environment(CircleStore(repository: InMemoryCircleRepository()))
            .environment(BookingPolicyStore(repository: InMemoryCircleRepository()))
            .environment(ReviewStore(repository: InMemoryReviewsRepository()))
            .environment(FriendNoteStore(repository: InMemoryFriendNoteRepository()))
            .environment(GuestNoteStore(repository: InMemoryGuestNoteRepository()))
            .environment(NetworkMonitor(start: false))
            .environment(DeepLinkRouter())
            // A temporary directory, so previews never touch the real kits or fight over files.
            .environment(CheckInKitStore(
                files: CheckInKitFileStore(
                    directory: URL.temporaryDirectory
                        .appendingPathComponent("PreviewCheckInKits-\(UUID().uuidString)", isDirectory: true)
                )
            ))
    }
}
