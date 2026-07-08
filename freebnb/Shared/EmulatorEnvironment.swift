//
//  EmulatorEnvironment.swift
//  freebnb
//

import Foundation

/// Single source of truth for "is this process talking to the Local Emulator
/// Suite rather than the production Firebase project?"
///
/// UI tests and store-level unit tests launch with `-UseFirebaseEmulator YES`
/// (or `FIREBASE_EMULATOR=1` in the environment). `FreeBNBApp` reads this to
/// repoint Auth and Firestore; the debug email sign-in reads it so a hardcoded
/// development credential can never be sent to production Auth, even from a
/// Debug build running against the real project.
///
/// Always `false` outside DEBUG: release builds never inspect the launch
/// arguments at all.
enum EmulatorEnvironment {
    static var isActive: Bool {
#if DEBUG
        let info = ProcessInfo.processInfo
        return info.arguments.contains("-UseFirebaseEmulator")
            || info.environment["FIREBASE_EMULATOR"] == "1"
#else
        return false
#endif
    }

    /// Host running the emulator suite. Only meaningful when `isActive`.
    static var host: String {
        ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"] ?? "localhost"
    }
}
