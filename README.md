# FreeBNB

A free, network-based home-sharing app for iOS.

![Platform](https://img.shields.io/badge/iOS-18%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Firestore%20%2B%20Auth-FFCA28?logo=firebase&logoColor=black)

FreeBNB makes it easy for people to offer their home to friends and friends-of-friends when they travel. Hosts list their space; guests browse and request stays. Everything is free, with no fees or middlemen. Listings are only visible to people in the host's network, never to strangers.

This README covers technical details for engineers. User-facing documentation lives in the app under the Info tab.

---

## Contents

- [Features](#features)
- [Setup](#setup)
- [Architecture](#architecture)
- [Stack](#stack)
- [Technical Decisions](#technical-decisions)

---

## Features

| Area | Status |
|------|--------|
| Browse listings (real-time, filter, sort) | Live |
| Listing detail with amenities and map | Live |
| In-app messaging (real-time, per listing) | Live |
| Sign in with Apple / anonymous guest sessions | Live |
| Dark mode, appearance preferences | Live |
| Host listing creation and editing | Planned |
| Stay requests, calendar availability | Planned |
| Friend connections and listing visibility controls | Planned |
| Discovery: map view, city search, saved listings | Planned |
| Profiles, trust, reviews, trip history | Planned |
| Personalized recommendations | Planned |
| Host dashboard | Planned |
| Push notifications | Planned |

---

## Setup

The app requires `GoogleService-Info.plist` from the FreeBNB Firebase project. This file is gitignored and must not be committed. Add it to the `freebnb/` folder in Xcode, then open `freebnb.xcodeproj` and build.

---

## Architecture

Organized by feature, structured for MVVM.

```
freebnb/
├── App/             # Entry point and root tab navigation
├── Auth/            # Firebase Auth logic and sign-in screen
├── Homes/           # Listing model, browse and filter screen, listing detail
├── Messaging/       # In-app chat and conversation list
├── Profile/         # Account settings and preferences
├── Onboarding/      # First-launch onboarding flow
├── Info/            # Static pages (About, FAQ, tips, safety)
└── Shared/          # Types, extensions, and utilities shared across features
```

State is managed through `ObservableObject` stores injected as environment objects at the app root:

| Store | Responsibility |
|-------|---------------|
| `HomeStore` | Real-time listing feed from Firestore |
| `MessageStore` | Real-time conversations from Firestore |
| `AuthManager` | Auth state, user ID, sign-in and sign-out |

---

## Stack

| Technology | Role |
|-----------|------|
| [SwiftUI](https://developer.apple.com/xcode/swiftui/) | All UI, every screen |
| [Firebase Auth](https://firebase.google.com/docs/auth) | Sign in with Apple, anonymous sessions |
| [Firebase Firestore](https://firebase.google.com/docs/firestore) | Real-time database for listings and messages |
| [MapKit](https://developer.apple.com/documentation/mapkit/) | Address map on listing detail |

**SwiftUI** uses a declarative style: describe what the UI should look like, and Apple handles rendering and state updates.

**Firebase** is Google's backend-as-a-service. App data lives on Google's global cloud infrastructure rather than on hardware FreeBNB needs to maintain, with automatic scaling and no server to manage. A Firebase project is actually a Google Cloud project behind the scenes.

**MapKit** geocodes the host's street address on Apple's servers to produce map coordinates. The app never requests the user's device location.

---

## Technical Decisions

**Authentication: Firebase Auth with Sign in with Apple**
Sign in with Apple exchanges an Apple credential for a Firebase UID, a stable ID that works across devices and never changes. Anonymous guest sessions also produce a real UID, so permission logic is identical for both user types. The nonce required by Apple is generated in `AuthManager`, hashed with SHA-256, and passed to Firebase to verify the token.

**Appearance: UIKit window override instead of `preferredColorScheme`**
SwiftUI's `preferredColorScheme` doesn't reliably update when `@AppStorage` changes from a child view. The app instead calls `overrideUserInterfaceStyle` on every `UIWindowScene` window directly. This is encapsulated in `AppearanceModifier` (`Shared/Extensions.swift`) so any view can opt in with `.appliesStoredAppearance()`.

**Adaptive colors: asset catalog with explicit dark variants**
Named color sets in `Assets.xcassets` carry separate light and dark entries. Background fills adapt to the color scheme automatically with no conditional logic in views.

**Listings: live Firestore listener, shuffled on first load**
`HomeStore` attaches a real-time Firestore listener on launch. Results are shuffled on first load for variety. When listings are added or removed, shuffle order is preserved for existing items and new entries are appended to the end, so the list doesn't re-randomize on every change.

**Data model: `Codable` with a JSON bridge instead of `FirebaseFirestoreSwift`**
`Home` and `Message` conform to `Codable`. Serialization goes through `JSONEncoder`/`JSONDecoder` with `JSONSerialization` as a bridge to Firestore's `[String: Any]` format. This avoids an extra dependency and keeps the models usable in non-Firestore contexts (such as `NavigationPath`). Document IDs are injected into the decoded dictionary before decoding so `id` is always populated.

**Messaging: collection group query across all conversations**
`MessageStore` uses a Firestore collection group query across all `conversations/{homeID}/messages` subcollections. A single listener covers all conversations without knowing their IDs up front. Messages are sorted by timestamp on read and grouped by `homeID` in memory for fast lookup.

**User identity: Firebase UID, not a boolean flag**
Messages store `senderUserID` (a Firebase UID) rather than a boolean `senderIsGuest`. This is consistent across Apple and anonymous auth users and won't break as host-side replies and full accounts are added.

**Filter logic: owned by the enum, not the view**
`FilterOption` evaluates itself against a `Home` via `applies(to:)`. The view iterates selected filters and calls that method. Adding a new filter requires only a new enum case with no changes to any view.

**Navigation: programmatic `NavigationPath` for listings, declarative elsewhere**
The listings tab uses a `NavigationPath` owned by `ContentView` so the parent controls navigation and can push `HomeDetailPage` without the list knowing about it. All other tabs use declarative `NavigationLink` since they don't need external push control.

**Map: forward geocoding, no location permission**
`HomeDetailPage` converts the listing's street address to coordinates using `CLGeocoder`, which runs on Apple's servers without accessing the device's location. The app never prompts for location permission.

**Preferences: `@AppStorage` for lightweight local state**
Appearance mode, notification preference, and onboarding completion are stored in `UserDefaults` via `@AppStorage`. Anything that needs to sync across devices or associate with a user account is not stored here.
