//
//  ContentView.swift
//  freebnb
//
//  Created by Irene Tang on 7/25/25.
//

import SwiftUI

enum AppScreen: Hashable {
    case welcome
    case features
    case homes
    case homeDetail(Home)
}

struct ContentView: View {
    @State private var path = NavigationPath()
    let listings = sampleData

    var body: some View {
        NavigationStack(path: $path) {
            WelcomePage {
                path.append(AppScreen.features)
            }
            .navigationDestination(for: AppScreen.self) { screen in
                switch screen {
                case .welcome:
                    WelcomePage {
                        path.append(AppScreen.features)
                    }
                case .features:
                    FeaturesPage {
                        path.append(AppScreen.homes)
                    }
                case .homes:
                    HomesPage(listings: listings) { home in
                        path.append(AppScreen.homeDetail(home))
                    }
                case .homeDetail(let home):
                    HomeDetailPage(home: home)
                }
            }
        }
    }
}


#Preview {
    ContentView()
}
