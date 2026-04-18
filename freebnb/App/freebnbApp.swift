//
//  freebnbApp.swift
//  freebnb
//
//  Created by Irene Tang on 7/24/25.
//

import SwiftUI

@main
struct freebnbApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var messageStore = MessageStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(messageStore)
                .preferredColorScheme(preferredScheme)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
