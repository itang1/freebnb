# FreeBNB

A free, friends-only home-sharing app for iOS.

![Platform](https://img.shields.io/badge/iOS-18.5%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/SwiftUI-Swift%205-F05138?logo=swift&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Auth%20%7C%20Firestore%20%7C%20Functions-FFCA28?logo=firebase&logoColor=black)

FreeBNB lets people offer their home to friends when they travel. You can list your space as a host, and browse, message, and request stays as a guest. Everything is free, and every listing is visible only to the host's accepted friends.

This README covers technical details for engineers. User-facing documentation lives in the app under the Info tab.

## What's in the app

- **Listings**: Hosts create and manage listings with amenities, capacity, availability, house preferences, and co-hosts. Guests browse a paginated feed, a clustered map, or a city search, with saved listings and filtering across every attribute. Photo upload is scaffolded (`PhotoUploader` seam, Storage rules) but not shipped; the default implementation is a no-op.
- **Stays**: Guests request stays for specific dates; hosts confirm or decline from a per-listing dashboard, and a scheduled function closes out completed stays.
- **Messaging**: Real-time in-app chat between guests and hosts, scoped per listing, with push notifications, rate limiting, and automated content moderation.
- **Friends**: Friend connections are the visibility model. Every listing is visible to the host's accepted friends only; friends of friends surface solely as friend suggestions.
- **Trust**: Post-stay reviews (a public review plus a private note between the two parties), friend-written references, and trust badges on profiles.
- **Accounts**: Sign in with Apple, Google, or email/password; anonymous guest browsing; profile management; full account deletion with server-side data cascade.
- **Safety**: Age gate, user reporting with a web moderation queue (`admin/`), blocking enforced at the security-rules level, and message rate limiting.

## Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (iOS 18.5+), MapKit |
| Auth | Firebase Auth (Apple, Google, email/password, anonymous) |
| Data | Cloud Firestore (real-time listeners, security rules); Storage rules are in place for photos, which are not yet shipped |
| Backend | Cloud Functions (TypeScript, Node 20) |
| Testing | Swift Testing with injected in-memory repositories, XCUITest, Firestore rules tests (`rules-tests/`) |
| Tooling | SwiftLint, Firebase Emulator Suite |

## Architecture

The iOS app is organized by feature (`Auth`, `Homes`, `Stays`, `Messaging`, `Friends`, `Trust`, `Profile`, `Safety`, `Onboarding`, `Info`, `Shared`) and follows MVVM. State lives in `@Observable` stores created at the app root and injected through the SwiftUI environment:

| Store | Responsibility |
|-------|---------------|
| `HomeStore` | Listing feed, creation, editing, soft deletes |
| `StayRequestStore` | Stay requests and confirmations |
| `MessageStore` | Real-time conversations via a collection group query |
| `FriendStore` | Friend connections |
| `ReviewStore` | Reviews and references |
| `UserProfileStore` | Profile, saved listings, blocking |
| `AuthManager` | Auth state, sign-in, sign-out, account deletion |

Stores never talk to Firestore directly. Each one depends on a repository protocol (`Shared/Repositories.swift`), with a Firestore-backed implementation for production and in-memory doubles (`Shared/InMemoryRepositories.swift`) for unit tests and SwiftUI previews. Listeners are capped and the feed is cursor-paginated so read costs stay predictable.

The backend is intentionally thin. Firestore security rules are the real authorization boundary (guests can read but not write, blocked users cannot message, message sends are rate-limited in the write path, private profile data is owner-only). Cloud Functions handle what clients can't be trusted with: maintaining listing ACLs as the friend graph changes, push notification fan-out, the stay lifecycle, content moderation for listings and messages, friend suggestions, the account-deletion cascade, user data export, and a daily scheduled Firestore backup.

## Design palette

The visual theme is "summer lakeside cabin": sandy neutrals, lake and sky blues, and a sunset-coral accent. Colorsets live in the `Color/` namespace of `freebnb/Assets.xcassets` with light and dark variants, named by semantic role rather than hue. `Shared/AppColor.swift` is the single Swift interface (`Color.accent`, `UIColor.app(.accent)`), so views reference roles and never hardcode hex values.

## Getting started

### Requirements

- Xcode 16 or later
- Access to the FreeBNB Firebase project (or your own Firebase project with Auth, Firestore, and Storage enabled)
- Node 20, Java, and the Firebase CLI, only if you work on Cloud Functions, rules, or the emulators

### Run the app

1. Clone the repo and open `freebnb.xcodeproj`.
2. Add `GoogleService-Info.plist` (from the Firebase console) to the `freebnb/` folder. This file is gitignored; never commit it.
3. Build and run. A scheme pre-action (`scripts/dev_emulator.sh`) boots a seeded local emulator for Debug builds, which powers the DEBUG-only one-tap sign-in buttons on the welcome screen.

To point Debug and Release builds at separate Firebase projects, place environment-specific plists at `config/GoogleService-Info.Debug.plist` and `config/GoogleService-Info.Release.plist`; a pre-compile script copies the right one in, and the `config/*.xcconfig` files give Debug its own bundle ID so both installs coexist on one device.

### Backend

```sh
cd functions
npm install
npm run serve          # build + local emulators (Auth on 9099, Firestore on 8080)
npm run deploy         # deploy functions
```

Deploy rules and indexes with `firebase deploy --only firestore:rules,firestore:indexes`. The moderation queue in `admin/` is a static page over the `reports` collection; grant access with `scripts/set_admin_claim.js`.

### Before launch: App Check enforcement

Callables enforce App Check in code (`enforceAppCheck: true` in `functions/src/index.ts`). Firestore and Storage do not: their enforcement is a per-project switch in the Firebase console, and nothing in this repo turns it on. `firestore.rules` names App Check as its primary control against hand-rolled clients, so until both switches are on, anyone with a signed-in account and the public API key can call Firestore and Storage directly and only the rules stand in the way.

Work through this list on the production project before launch, in order:

1. **Give the Release build the App Attest capability.** The Release provider is `AppAttestProvider` (`freebnb/App/FreeBNBApp.swift`), which needs the App Attest capability on the App ID and the `com.apple.developer.devicecheck.appattest-environment` entitlement (`production` for App Store and TestFlight builds). `freebnb/freebnb.entitlements` does not have it yet. Without it every Release token request fails, and turning on enforcement would lock out real users.
2. **Register the app for App Check.** Firebase console → App Check → Apps → the iOS app → App Attest, and enter the Team ID. If Debug builds use the `.debug` bundle ID against the same project, register that app too (it only needs debug tokens, see below).
3. **Watch the metrics before enforcing.** App Check → APIs shows verified and unverified requests for Cloud Firestore and Cloud Storage. Ship a Release build with the entitlement, and wait until traffic from current builds shows as verified. Anything still unverified at that point is an old build or a client that is not the app.
4. **Turn on enforcement for Cloud Firestore and Cloud Storage.** App Check → APIs → each service → Enforce. It can take up to 15 minutes to apply. Callables already reject unattested calls, so there is nothing to switch for Functions.
5. **Verify** (next section).

**Debug tokens for development and CI.** The simulator cannot do App Attest, so Debug builds use `AppCheckDebugProviderFactory`. Set `FIRAAppCheckDebugToken` in your own scheme's environment variables (Edit Scheme → Run → Arguments), or run once and copy the token the SDK logs to the console, then add it under App Check → Apps → the iOS app → Manage debug tokens. Once enforcement is on, a Debug build pointed at the real project without a registered token gets permission errors from every Firestore and Storage call. Treat these tokens as secrets: keep them out of shared schemes and the repo, use one per developer or machine so each can be revoked alone, and revoke any that leaks. CI runs against the local emulators with `.github/ci/GoogleService-Info.ci.plist`, and the emulators do not check App Check, so CI needs no token today. If a job ever talks to a real Firebase project, store its debug token as a GitHub Actions secret and register it like any other.

**Verify enforcement.** After the switches have had time to apply:

- A Release build on a physical device can browse, open a listing with photos, upload a photo, and call a callable without errors.
- A request without an App Check token is refused. With a valid Firebase ID token for a full account, call the Firestore REST API and the Storage download URL for an object you can normally read, leaving out the `X-Firebase-AppCheck` header. Both should be rejected with an unauthorized or permission error rather than data. The same request was allowed before enforcement, which is how you know the switch, not the rules, is doing the refusing.
- App Check → APIs now shows unverified requests to Firestore and Storage as rejected rather than allowed.

### Tests

- **Unit and UI tests**: Cmd-U in Xcode. `freebnbTests` exercises the stores against in-memory repositories, so unit tests never touch Firestore or production data. `freebnbUITests` covers launch and core flows.
- **Rules tests**: `rules-tests/` runs `firestore.rules` against the real emulator on plain Node; see [rules-tests/README.md](rules-tests/README.md).

## Technical decisions

**Repository seam over direct Firestore access.** Stores depend on protocols, not the SDK. This keeps business logic unit-testable without network access and keeps previews fast and deterministic.

**Security rules as the authorization boundary.** The UI restricts what guests and blocked users can do, but the Firestore rules enforce it, and `rules-tests/` pins that behavior against the real rules engine.

**`Codable` models with a JSON bridge instead of `FirebaseFirestoreSwift`.** Models serialize through `JSONEncoder`/`JSONDecoder` bridged to Firestore's `[String: Any]`. This avoids an extra dependency and keeps models usable outside Firestore contexts, such as `NavigationPath`.

**Forward geocoding, no location permission.** Listing addresses are geocoded via `CLGeocoder` with an on-device cache; the app never requests the user's device location.

**Soft deletes for listings.** Deleted listings get a `deletedAt` timestamp instead of being removed, preserving history for past stays and conversations.

**UIKit window override for appearance.** SwiftUI's `preferredColorScheme` doesn't reliably react to `@AppStorage` changes from child views, so the app sets `overrideUserInterfaceStyle` on each window via a single `.appliesStoredAppearance()` modifier.
