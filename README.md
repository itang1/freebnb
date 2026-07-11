# FreeBNB

A free, network-based home-sharing app for iOS.

![Platform](https://img.shields.io/badge/iOS-18.5%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/SwiftUI-Swift%205-F05138?logo=swift&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Auth%20%7C%20Firestore%20%7C%20Functions-FFCA28?logo=firebase&logoColor=black)

FreeBNB lets people offer their home to friends and friends-of-friends when they travel. You can list your space as a host, as well as browse, message, and request stays as a guest. Everything is free, and listings are only visible within the host's network.

This README covers technical details for engineers. User-facing documentation lives in the app under the Info tab, and a complete feature inventory lives in [FEATURES.md](FEATURES.md).

## What's in the app

- **Listings**: Hosts create, edit, and manage listings with amenities, capacity, availability, and house preferences. Guests browse a paginated feed, an interactive map with pin clustering, or a city search, and can save listings and filter across every listing attribute. Photo upload is scaffolded but not shipped: the model, Storage rules, and a `PhotoUploader` seam exist, but the default implementation is a no-op, and there is no picker or gallery yet.
- **Stays**: Guests request stays for specific dates; hosts review, confirm, or decline from a per-listing dashboard.
- **Messaging**: Real-time in-app chat between guests and hosts, scoped per listing, with new-message push notifications.
- **Friends**: Friend connections are the visibility model: every listing is visible to the host's accepted friends only, and friends of friends surface solely as friend suggestions.
- **Accounts**: Sign in with Apple or anonymous guest browsing, profile management, and full account deletion with server-side data cascade.
- **Safety**: Age gate, user reporting, blocking enforced at the security-rules level, and message rate limiting.

## Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (iOS 18.5+), MapKit |
| Auth | Firebase Auth (Sign in with Apple, anonymous sessions) |
| Data | Cloud Firestore (real-time listeners, security rules); Firebase Storage rules are in place for photos, which are not yet shipped |
| Backend | Cloud Functions (TypeScript, Node 20) |
| Testing | Swift Testing with injected in-memory repositories, XCUITest |
| Tooling | SwiftLint, Firebase Emulator Suite |

## Architecture

The iOS app is organized by feature (`Auth`, `Homes`, `Stays`, `Messaging`, `Friends`, `Profile`, `Safety`, `Onboarding`, `Info`, `Shared`) and follows MVVM. State lives in `ObservableObject` stores injected as environment objects at the app root:

| Store | Responsibility |
|-------|---------------|
| `HomeStore` | Listing feed, creation, editing, soft deletes |
| `StayRequestStore` | Stay requests and confirmations |
| `MessageStore` | Real-time conversations via a collection group query |
| `FriendStore` | Friend connections |
| `UserProfileStore` | Profile, saved listings, blocking |
| `AuthManager` | Auth state, sign-in, sign-out, account deletion |

Stores never talk to Firestore directly. Each one depends on a repository protocol (`Shared/Repositories.swift`), with a Firestore-backed implementation for production and in-memory doubles (`Shared/InMemoryRepositories.swift`) for unit tests and SwiftUI previews. Listeners are capped and the feed is cursor-paginated so read costs stay predictable.

The backend is intentionally thin. Firestore security rules are the real authorization boundary (guests can read but not write, blocked users cannot message, message sends are rate-limited via a per-user counter gated in the write path, private profile data is owner-only), and Cloud Functions handle what clients can't be trusted with: push notification fan-out on new messages, the account-deletion data cascade, user data export, and a daily scheduled Firestore backup.

## Design palette

The visual theme is "summer lakeside cabin": sandy neutrals, lake and sky blues, and a sunset-coral accent. Colorsets live in the `Color/` namespace of `freebnb/Assets.xcassets` with light and dark variants, named by semantic role rather than hue. `Shared/AppColor.swift` is the single Swift interface: an `AppColor` enum plus `Color` and `UIColor` extensions (`Color.accent`, `UIColor.app(.accent)`), so views reference roles and never hardcode hex values. Generated asset symbol extensions are disabled in favor of this hand-written API.

| Colorset (`Color/`) | Role | Light | Dark |
|---------------------|------|-------|------|
| `primaryBackground` | Warm sand; page and sheet backgrounds | `#FAF3E8` | `#211E19` |
| `secondaryBackground` | Sky blue; card washes (used at low opacity) | `#B7E0EA` | `#27454F` |
| `tertiaryBackground` | Shell pink; soft blush fills and badges | `#FFDDD6` | `#492722` |
| `accent` | Lake teal; primary brand, tints, buttons | `#0B7382` | `#5CC1CD` |
| `secondaryAccent` | Seafoam; secondary water tone | `#A9DCD3` | `#2E5551` |
| `callToAction` | Sunset coral; high-emphasis actions | `#E85443` | `#FF7E6A` |
| `success` | Pine sage; positive states, greenery accents | `#6B8E6E` | `#A6C6A4` |
| `onAccent` | Text and icons on `accent` or `callToAction` fills | `#FFF8F0` | `#2A1F1A` |
| `AccentColor` (top level) | System tint; mirrors `accent` | `#0B7382` | `#5CC1CD` |

Brand fills invert with the appearance: in light mode fills are deep (lake teal, sunset coral) with cream labels, and in dark mode fills brighten (moonlit teal, warm coral) with espresso labels, which is what `OnBrandFill` encodes. `AppTeal` clears 4.5:1 contrast as text on `CreamWhite` in both modes.

## Getting started

### Requirements

- Xcode 16 or later
- Access to the FreeBNB Firebase project (or your own Firebase project with Auth, Firestore, and Storage enabled)
- Node 20 and the Firebase CLI, only if you work on Cloud Functions or rules

### Run the app

1. Clone the repo and open `freebnb.xcodeproj`.
2. Add `GoogleService-Info.plist` (from the Firebase console) to the `freebnb/` folder. This file is gitignored; never commit it.
3. Build and run.

To point Debug and Release builds at separate Firebase projects, place environment-specific plists at `Config/GoogleService-Info.Debug.plist` and `Config/GoogleService-Info.Release.plist`. A pre-compile run script (`Config/select_google_services.sh`) copies the right one into the app bundle, and the `Config/*.xcconfig` files give the Debug build its own bundle ID suffix and display name so both installs can coexist on one device.

### Backend

```sh
cd functions
npm install
npm run build
npm run serve          # local emulators (Auth on 9099, Firestore on 8080)
npm run deploy         # deploy functions
```

Deploy rules and indexes with `firebase deploy --only firestore:rules,firestore:indexes`.

### Tests

Run the test suite in Xcode (Cmd-U). `freebnbTests` exercises the stores against in-memory repositories, so unit tests never touch Firestore or production data. `freebnbUITests` covers launch and core flows.

## Technical decisions

**Repository seam over direct Firestore access.** Stores depend on protocols, not the SDK. This keeps business logic unit-testable without network access and keeps previews fast and deterministic.

**Security rules as the authorization boundary.** The UI restricts what guests and blocked users can do, but the Firestore rules enforce it. Anonymous accounts are read-only, blocking is checked server-side on message writes, and PII lives in an owner-only private subdocument rather than the public user document.

**`Codable` models with a JSON bridge instead of `FirebaseFirestoreSwift`.** `Home`, `Message`, and friends serialize through `JSONEncoder`/`JSONDecoder` with `JSONSerialization` bridging to Firestore's `[String: Any]`. This avoids an extra dependency and keeps models usable outside Firestore contexts, such as `NavigationPath`.

**Forward geocoding, no location permission.** Listing addresses are geocoded on Apple's servers via `CLGeocoder` (with an on-device cache); the app never requests the user's device location.

**Soft deletes for listings.** Deleted listings get a `deletedAt` timestamp instead of being removed, preserving history for past stays and conversations.

**UIKit window override for appearance.** SwiftUI's `preferredColorScheme` doesn't reliably react to `@AppStorage` changes from child views, so the app sets `overrideUserInterfaceStyle` on each window, wrapped in a single `.appliesStoredAppearance()` modifier.
