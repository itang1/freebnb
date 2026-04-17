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
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearance) { _, newValue in applyAppearance(newValue) }
        }
    }

    private func applyAppearance(_ value: String) {
        let style: UIUserInterfaceStyle = value == "dark" ? .dark : (value == "light" ? .light : .unspecified)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.overrideUserInterfaceStyle = style }
    }
}
