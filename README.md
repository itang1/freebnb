# FreeBNB

A free home-sharing app for iOS, built with SwiftUI.

FreeBNB helps people stay connected across cities, time, and life changes by making it easy to open your door to people you care about. High travel costs, the fear of being a burden, and the awkwardness of not knowing who is actually open to hosting keep many visits from ever happening. FreeBNB removes those barriers: hosts list their space, guests browse and request stays, and everything is free with no fees or middlemen. Listings are invite-only and never visible to strangers.

This README covers technical details for engineers. User-facing features and app information are documented inside the app under the Info tab.

## File Structure

```
freebnb/
├── App/             # Entry point and root tab navigation
├── Auth/            # Firebase Auth logic and sign-in screen
├── Homes/           # Listing data model, browse and filter screen, listing detail
├── Messaging/       # In-app chat and conversation list
├── Profile/         # Account settings and user preferences
├── Onboarding/      # First-launch onboarding flow
├── Info/            # Static informational pages (About, FAQ, tips, safety, etc.)
└── Shared/          # Types, extensions, and sample data shared across features
```

The structure is organized by feature and is set up to support the [MVVM](https://en.wikipedia.org/wiki/Model%E2%80%93view%E2%80%93viewmodel) pattern.

## Stack

- **[SwiftUI](https://developer.apple.com/xcode/swiftui/)** (Apple) for all UI, targeting iOS 17+
- **[Firebase Auth](https://firebase.google.com/docs/auth)** (Google) for authentication, supporting Sign in with Apple and anonymous guest sessions
- **[Firebase Firestore](https://firebase.google.com/docs/firestore)** (Google) is the planned backend for listings and messages
- **[MapKit](https://developer.apple.com/documentation/mapkit)** and **[CLGeocoder](https://developer.apple.com/documentation/corelocation/clgeocoder)** (Apple) for address-to-map display on listing detail pages
- **[CryptoKit](https://developer.apple.com/documentation/cryptokit)** (Apple) for SHA-256 nonce hashing required by Sign in with Apple
- **[AuthenticationServices](https://developer.apple.com/documentation/authenticationservices)** (Apple) for the Sign in with Apple button and credential flow

## Technical Decisions

**Authentication: [Firebase Auth](https://firebase.google.com/docs/auth) with [Sign in with Apple](https://developer.apple.com/sign-in-with-apple/)**
The Apple credential is exchanged for a Firebase UID via `OAuthProvider.appleCredential`, giving every user a stable cross-device identity without storing passwords. Guest sessions use Firebase anonymous auth so guests also get a real UID, which keeps permission logic consistent and makes the Firestore transition easier. The nonce is SHA-256 hashed with [CryptoKit](https://developer.apple.com/documentation/cryptokit) before being sent to Apple, as required by the Sign in with Apple spec.

**Appearance: [UIKit](https://developer.apple.com/documentation/uikit) window override instead of SwiftUI `preferredColorScheme`**
`preferredColorScheme` on a view inside `WindowGroup` does not reliably update when `@AppStorage` is written from a child view. The app instead calls `overrideUserInterfaceStyle` on every `UIWindowScene` window directly. This logic lives in `AppearanceModifier` (in `Shared/Extensions.swift`) as a `ViewModifier` so any view can opt in with `.appliesStoredAppearance()`. The profile picker and the modifier both read and write the same `@AppStorage("appearance")` key.

**Adaptive colors: Xcode asset catalog with explicit dark variants**
All background colors are defined as named color sets in `Assets.xcassets` with separate light and dark entries. Dark mode works automatically for background fills without any conditional logic in views.

**Messaging: in-memory only, designed to swap to [Firestore](https://firebase.google.com/docs/firestore)**
`MessageStore` is an `ObservableObject` injected at the app level via environment so it survives tab switches. Messages are not persisted between sessions yet. The public interface (`messages(for:)`, `hasMessages(for:)`, `send(text:to:senderUserID:)`) is intentionally narrow so the backing store can be replaced with Firestore without touching any views.

**Filter logic: owned by the enum, not the view**
`FilterOption` is an enum that knows how to evaluate itself against a `Home` via `applies(to:)`. The view just iterates selected filters and calls that method. Adding a new filter option only requires adding a case to the enum.

**Navigation: programmatic path for listings, declarative elsewhere**
The listings tab uses a `NavigationPath` owned by `ContentView` so the parent controls navigation and `HomeDetailPage` can be pushed without the list knowing about it. All other tabs use declarative `NavigationLink` since they don't need external push control.

**Map: forward geocoding via [CLGeocoder](https://developer.apple.com/documentation/corelocation/clgeocoder), no location permission required**
`HomeDetailPage` converts the listing's street address to coordinates using `CLGeocoder`, which does server-side geocoding without accessing the device's location. The app never prompts for location permission.

**Listings: shuffled once on first appear**
`HomesPage` shuffles the listings array into `@State` on first appear so the order feels varied. The state survives re-renders but resets on fresh launch, which is intentional until listings come from Firestore.

**User identity in messages: Firebase UID, not a guest flag**
Messages store `senderUserID` (a Firebase UID) rather than a boolean `senderIsGuest`. This makes sender identity work the same way for Apple and anonymous auth users and avoids a flag that would break once real accounts exist.

**Persistence: `@AppStorage` for lightweight preferences**
Appearance mode, notification preference, and onboarding state are stored with `@AppStorage` (UserDefaults). Anything that needs to sync across devices or associate with a user account is intentionally not stored here yet.
