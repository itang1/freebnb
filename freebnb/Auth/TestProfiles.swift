//
//  TestProfiles.swift
//  freebnb
//

#if DEBUG
import SwiftUI

/// The seeded development accounts, shown as one-tap sign-in buttons in DEBUG builds
/// pointed at the Auth emulator (WelcomePage, ProfilePage); tapping one while signed in
/// hops between the SpongeBob cast.
///
/// Keep in sync with the `users` array in scripts/seed_test_data.js (emails must match
/// exactly). The cast shares `emulatorPassword`, mirroring that script's EMULATOR_PASSWORD.
/// It's public by design: it unlocks only throwaway emulator accounts, and the prod
/// cast uses a secret (SEED_PROD_PASSWORD), so these buttons can't sign into production.
struct TestProfile: Identifiable {
    let displayName: String
    let email: String
    let password: String
    let systemImage: String

    var id: String { email }

    /// The slug for accessibility identifiers, from the email handle; Guest and Devna keep the IDs the UI
    /// tests target (see `accessibilityID(surface:)`).
    var slug: String { String(email.prefix(while: { $0 != "@" })) }

    /// `"<surface>.<slug>SignInButton"`, e.g. `"welcome.spongebobSignInButton"`. Quirk: the dev
    /// account's welcome button is `welcome.devnaSignInButton` but its profile button is
    /// `profile.devSignInButton`, preserved for existing UI tests.
    func accessibilityID(surface: String) -> String {
        let token = (surface == "welcome" && slug == "dev") ? "devna" : slug
        return "\(surface).\(token)SignInButton"
    }

    /// Mirrors EMULATOR_PASSWORD in scripts/seed_test_data.js; emulator-only, so not a secret.
    static let emulatorPassword = "emulator-only"

    private static func seed(_ name: String, _ handle: String, _ symbol: String) -> TestProfile {
        TestProfile(displayName: name, email: "\(handle)@seed.freebnb.test",
                    password: emulatorPassword, systemImage: symbol)
    }

    /// The two utility accounts first, then the cast, with short names for compact buttons.
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
