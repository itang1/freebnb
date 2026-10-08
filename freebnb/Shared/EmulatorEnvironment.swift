//
//  EmulatorEnvironment.swift
//  freebnb
//

import Foundation

/// Single source of truth for "is this process talking to the Local Emulator Suite, not production?" UI and
/// store-level tests launch with `-UseFirebaseEmulator YES` (or `FIREBASE_EMULATOR=1`). `FreeBNBApp` repoints
/// Auth and Firestore from it, and debug sign-in reads it so a hardcoded credential can't reach production.
/// Always `false` outside DEBUG: release builds never inspect launch arguments.
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

    /// Host running the emulator suite; meaningful only when `isActive`.
    static var host: String {
        ProcessInfo.processInfo.environment["FIREBASE_EMULATOR_HOST"] ?? "localhost"
    }
}
