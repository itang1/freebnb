//
//  ContentView.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI


struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var messageStore: MessageStore
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var listingsPath = NavigationPath()
    let listings = sampleData

    var body: some View {
        if authManager.isSignedIn {
            TabView {
                NavigationStack {
                    InfoPage()
                }
                .tabItem {
                    Label("Info", systemImage: "book.fill")
                }

                NavigationStack(path: $listingsPath) {
                    HomesPage(listings: listings) { home in
                        listingsPath.append(home)
                    }
                    .navigationDestination(for:
                                            Home.self) { home in
                        HomeDetailPage(home: home)
                    }
                }
                .tabItem {
                    Label("Listings", systemImage: "house")
                }

                NavigationStack {
                    MessagesTab(listings: listings)
                }
                .tabItem {
                    Label("Messages", systemImage: "message")
                }

                NavigationStack {
                    ProfilePage()
                }
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
            }
            .tint(Color("AppTeal"))
            .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
                OnboardingPage(isPresented: $showOnboarding)
            }
            .onAppear {
                if !hasSeenOnboarding { showOnboarding = true }
            }
        } else {
            NavigationStack {
                WelcomePage()
            }
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(AuthManager())
        .environmentObject(MessageStore())
}
