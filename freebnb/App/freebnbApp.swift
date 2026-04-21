//
//  freebnbApp.swift
//  freebnb
//

import SwiftUI
import FirebaseCore

@main
struct FreeBNBApp: App {
    @State private var authManager: AuthManager
    @State private var homeStore: HomeStore
    @State private var messageStore: MessageStore
    @State private var userProfileStore: UserProfileStore

    init() {
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
        _userProfileStore = State(initialValue: UserProfileStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(homeStore)
                .environment(messageStore)
                .environment(userProfileStore)
        }
    }
}
