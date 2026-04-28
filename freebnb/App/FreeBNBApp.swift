//
//  FreeBNBApp.swift
//  freebnb
//

import FirebaseAuth
import FirebaseCore
import SwiftUI

// To enable push notifications:
// 1. Add FirebaseMessaging via Xcode → Package Dependencies
// 2. Uncomment the import and the Messaging.messaging() calls below
// 3. Set FreeBNBApp as UNUserNotificationCenterDelegate and MessagingDelegate
// import FirebaseMessaging

@main
struct FreeBNBApp: App {
    @State private var authManager: AuthManager
    @State private var homeStore: HomeStore
    @State private var messageStore: MessageStore
    @State private var userProfileStore: UserProfileStore
    @State private var stayRequestStore: StayRequestStore
    @State private var friendStore: FriendStore

    init() {
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
        _userProfileStore = State(initialValue: UserProfileStore())
        _stayRequestStore = State(initialValue: StayRequestStore())
        _friendStore = State(initialValue: FriendStore())
    }

    // Called from the scene body once auth + stores are ready.
    // Swap the body of this function for real FCM token fetching once
    // FirebaseMessaging is linked:
    //   Messaging.messaging().token { token, _ in
    //       guard let token, let uid = Auth.auth().currentUser?.uid else { return }
    //       Task { try? await userProfileStore.saveFCMToken(token) }
    //   }
    private func registerForPushIfNeeded() {
        // no-op until FirebaseMessaging is linked
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(homeStore)
                .environment(messageStore)
                .environment(userProfileStore)
                .environment(stayRequestStore)
                .environment(friendStore)
                .onAppear { registerForPushIfNeeded() }
        }
    }
}
