//
//  freebnbApp.swift
//  freebnb
//
//  Created by Irene Tang on 7/24/25.
//

import SwiftUI
import FirebaseCore

@main
struct freebnbApp: App {
    @State private var authManager: AuthManager
    @State private var homeStore: HomeStore
    @State private var messageStore: MessageStore

    init() {
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(homeStore)
                .environment(messageStore)
        }
    }
}
