//
//  FreeBNBApp.swift
//  freebnb
//

import FirebaseAuth
import FirebaseCore
import SwiftUI
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

@main
struct FreeBNBApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var router = DeepLinkRouter()
    @State private var authManager: AuthManager
    @State private var homeStore: HomeStore
    @State private var messageStore: MessageStore
    @State private var userProfileStore: UserProfileStore
    @State private var stayRequestStore: StayRequestStore
    @State private var friendStore: FriendStore

    init() {
        FirebaseApp.configure()
#if canImport(FirebaseMessaging)
        Messaging.messaging().isAutoInitEnabled = true
#endif
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
        _userProfileStore = State(initialValue: UserProfileStore())
        _stayRequestStore = State(initialValue: StayRequestStore())
        _friendStore = State(initialValue: FriendStore())
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
                .environment(router)
                .onAppear {
                    // Wire the store and router into the delegate.
                    appDelegate.userProfileStore = userProfileStore
                    appDelegate.router = router
#if canImport(FirebaseMessaging)
                    Messaging.messaging().delegate = appDelegate
#endif
                    requestPushPermission()
                }
                .onOpenURL { url in handleIncomingURL(url) }
        }
    }

    private func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // Handle freebnb://invite?from=<uid>&name=<name>
    // The URL scheme "freebnb" must be registered in the project's Info.plist
    // under CFBundleURLTypes before this fires (Xcode -> Info -> URL Types).
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "freebnb",
              url.host == "invite" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let inviterID = components?.queryItems?.first(where: { $0.name == "from" })?.value,
              !inviterID.isEmpty else { return }
        let inviterName = components?.queryItems?.first(where: { $0.name == "name" })?.value

        // Record the invite and let ContentView confirm it with the user once
        // they're signed in. We deliberately do NOT send a friend request here:
        // a crafted link must not silently write on the recipient's behalf, and
        // the previous fixed one-second sleep was a race against auth state.
        router.pendingInvite = PendingInvite(inviterID: inviterID, inviterName: inviterName)
    }
}
