//
//  PreviewEnvironment.swift
//  freebnb
//
//  One environment injection for every #Preview. A preview renders a subtree
//  whose children may read any of the stores FreeBNBApp provides at launch,
//  and a single missing one fatal-errors the whole preview process the moment
//  it is read. Injecting the complete set here, backed by in-memory
//  repositories, also keeps the canvas from ever constructing a
//  Firestore-backed store and talking to the real backend.
//
//  Not #if DEBUG-gated for the same reason as PreviewData: #Preview bodies are
//  compiled (then stripped) in release configurations, so gating this would
//  break archive builds.
//

import SwiftUI

extension View {
    /// Injects the full set of stores the app provides at launch, each backed
    /// by an empty in-memory repository. Apply this to every #Preview instead
    /// of injecting stores one by one. To seed a store with fixture data,
    /// attach its `.environment(...)` closer to the view than this modifier;
    /// the nearer value wins.
    @MainActor
    func previewEnvironment() -> some View {
        environment(AuthManager())
            .environment(HomeStore(repository: InMemoryHomesRepository()))
            .environment(MessageStore(repository: InMemoryMessagesRepository()))
            .environment(UserProfileStore(repository: InMemoryUserProfileRepository()))
            .environment(StayRequestStore(repository: InMemoryStayRequestsRepository()))
            .environment(FriendStore(repository: InMemoryFriendEdgeRepository()))
            .environment(ReviewStore(repository: InMemoryReviewsRepository()))
            .environment(NetworkMonitor(start: false))
            .environment(DeepLinkRouter())
            // A temporary directory, so a preview never reads or writes the real
            // kits (and so several previews can't fight over the same files).
            .environment(CheckInKitStore(
                files: CheckInKitFileStore(
                    directory: URL.temporaryDirectory
                        .appendingPathComponent("PreviewCheckInKits-\(UUID().uuidString)", isDirectory: true)
                )
            ))
    }
}
