//
//  ContentView.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI

struct ContentView: View {
    @State private var showTabs = false
    @State private var listingsPath = NavigationPath()
    let listings = sampleData

    var body: some View {
        if showTabs {
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
                    .navigationDestination(for: Home.self) { home in
                        HomeDetailPage(home: home)
                    }
                }
                .tabItem {
                    Label("Listings", systemImage: "house")
                }
            }
            .tint(.mintGreen)
        } else {
            WelcomePage {
                showTabs = true
            }
        }
    }
}


#Preview {
    ContentView()
}
