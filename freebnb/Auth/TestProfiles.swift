//
//  TestProfiles.swift
//  freebnb
//

#if DEBUG
import SwiftUI

/// The seeded development accounts, surfaced as one-tap sign-in buttons in DEBUG
/// builds pointed at the Auth emulator (see WelcomePage and ProfilePage). Because
/// `signInWithEmail` signs straight into the target account, tapping one while
/// already signed in is how you hop between the whole SpongeBob cast without ever
/// signing out.
///
/// Keep this list in sync with the `users` array in scripts/seed_test_data.js:
/// the emails must match exactly, or a button signs into nothing. The whole cast
/// shares `emulatorPassword`, which mirrors that script's EMULATOR_PASSWORD.
///
/// That password is public and that is fine: it unlocks throwaway accounts on a
/// local emulator port and nothing else. The prod cast answers to a secret the
/// seed script takes from SEED_PROD_PASSWORD, so these buttons cannot sign into
/// production — which is the point. They used to, because the same committed
/// string worked in both places.
struct TestProfile: Identifiable {
    let displayName: String
    let email: String
    let password: String
    let systemImage: String

    var id: String { email }

    /// The stable slug used to build accessibility identifiers, derived from the
    /// email handle (the part before "@"). Guest and Devna keep the exact IDs the
    /// UI tests already target; see `accessibilityID(surface:)`.
    var slug: String { String(email.prefix(while: { $0 != "@" })) }

    /// `"<surface>.<slug>SignInButton"`, e.g. `"welcome.spongebobSignInButton"`.
    /// The one historical quirk: the dev account's welcome button is
    /// `welcome.devnaSignInButton` (its display name), while its profile button is
    /// `profile.devSignInButton` (its email handle). Preserved so existing UI
    /// tests keep matching.
    func accessibilityID(surface: String) -> String {
        let token = (surface == "welcome" && slug == "dev") ? "devna" : slug
        return "\(surface).\(token)SignInButton"
    }

    /// Mirrors EMULATOR_PASSWORD in scripts/seed_test_data.js. Emulator-only, so
    /// it is not a secret; see the note above.
    static let emulatorPassword = "emulator-only"

    private static func seed(_ name: String, _ handle: String, _ symbol: String) -> TestProfile {
        TestProfile(displayName: name, email: "\(handle)@seed.freebnb.test",
                    password: emulatorPassword, systemImage: symbol)
    }

    /// The two utility accounts first (the everyday testing entry points), then
    /// the cast. Short display names so they read well on compact buttons.
    static let all: [TestProfile] = [
        TestProfile(displayName: "Guest",  email: "guest@freebnb.test", password: emulatorPassword,
                    systemImage: "person.fill.questionmark"),
        TestProfile(displayName: "Devna",  email: "dev@freebnb.test", password: emulatorPassword,
                    systemImage: "hammer.fill"),
        seed("SpongeBob",   "spongebob",   "square.fill"),
        seed("Patrick",     "patrick",     "star.fill"),
        seed("Squidward",   "squidward",   "music.note"),
        seed("Mr. Krabs",   "krabs",       "dollarsign.circle.fill"),
        seed("Sandy",       "sandy",       "atom"),
        seed("Gary",        "gary",        "tortoise.fill"),
        seed("Plankton",    "plankton",    "testtube.2"),
        seed("Karen",       "karen",       "desktopcomputer"),
        seed("Pearl",       "pearl",       "bag.fill"),
        seed("Larry",       "larry",       "dumbbell.fill"),
        seed("Mrs. Puff",   "puff",        "car.fill"),
        seed("King Neptune", "neptune",    "crown.fill"),
        seed("Mermaid Man", "mermaidman",  "shield.fill"),
        seed("Barnacle Boy", "barnacleboy", "shield.lefthalf.filled"),
    ]
}
#endif
