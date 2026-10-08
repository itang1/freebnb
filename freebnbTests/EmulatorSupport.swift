//
//  EmulatorSupport.swift
//  freebnbTests
//
//  Shared plumbing for the Firestore-backed repository tests. They run the real
//  repositories against the Local Emulator Suite, so they exercise firestore.rules
//  end to end, which the in-memory doubles can't.
//
//  The harness stands up its own secondary FirebaseApp pointed at the emulator, so it
//  needs neither launch arguments nor inherited environment. Suites are gated on the
//  explicit opt-in `isEnabled`, so they skip rather than fail elsewhere (including a
//  dev machine whose emulator serves freebnb-6814a on the same ports). Run with:
//
//    firebase emulators:exec --only firestore,auth \
//      --project freebnb-emulator-tests \
//      "xcodebuild test -scheme freebnb -testPlan EmulatorTests \
//         -only-testing:freebnbTests/EmulatorBackedTests \
//         CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO"
//
//  In Xcode, switch the scheme's test plan to EmulatorTests; the default leaves the flag unset.
//

import Darwin
import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation
import Testing

/// Parent of every emulator-backed suite. Nesting keeps them from running alongside
/// each other (`.serialized` only orders a suite's own tests). They share one Auth
/// session, so interleaved sign-ins swap `request.auth.uid` mid-test and fail the
/// rules with PERMISSION_DENIED; serialized here, the trait covers every descendant.
@Suite(.serialized, .enabled(if: EmulatorSupport.isEnabled))
struct EmulatorBackedTests {}

enum EmulatorSupport {
    // Must match the --project passed to `firebase emulators:exec`.
    static let projectID = "freebnb-emulator-tests"
    static let host = "127.0.0.1"
    static let firestorePort: UInt16 = 8080
    static let authPort = 9099

    /// The opt-in switch the suites gate on, set by the EmulatorTests test plan and
    /// the `emulator-tests` CI job. Reachability alone is wrong: `scripts/dev_emulator.sh`
    /// keeps a freebnb-6814a emulator on these ports, so a plain `xcodebuild test`
    /// would run against the wrong project. (A `TEST_RUNNER_` build setting doesn't
    /// work here; it only forwards to UI test runners.)
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FREEBNB_EMULATOR_TESTS"] == "1"
            && isEmulatorReachable
    }

    /// True when something listens on the Firestore emulator port; a blocking
    /// localhost connect resolves immediately, guarding against a hang when the emulator never started.
    static var isEmulatorReachable: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = firestorePort.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    /// The secondary FirebaseApp wired to the emulator, configured once and kept off the default app.
    // `nonisolated(unsafe)`: not Sendable, but the suite is serialized.
    nonisolated(unsafe) private static let app: FirebaseApp = {
        let name = "emulator-tests"
        if let existing = FirebaseApp.app(name: name) { return existing }
        // FirebaseCore validates the app ID (hex last segment) and API key (39 chars
        // starting "AIza") at configure time; neither reaches a real backend.
        let options = FirebaseOptions(
            googleAppID: "1:1234567890:ios:00e701a700757000",
            gcmSenderID: "1234567890"
        )
        options.projectID = projectID
        // The Auth emulator requires a well-formed API key but validates nothing.
        options.apiKey = "AIzaSyEmulatorFakeKey000000000000000000"
        FirebaseApp.configure(name: name, options: options)
        return FirebaseApp.app(name: name)!
    }()

    /// A Firestore handle for the emulator with persistence off, so each run starts from emulator state.
    nonisolated(unsafe) static let firestore: Firestore = {
        let db = Firestore.firestore(app: app)
        let settings = db.settings
        settings.host = "\(host):\(firestorePort)"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        db.settings = settings
        return db
    }()

    nonisolated(unsafe) static let auth: Auth = {
        let auth = Auth.auth(app: app)
        auth.useEmulator(withHost: host, port: authPort)
        return auth
    }()

    /// A member's identity plus credentials to sign back in, for tests that swap between two accounts.
    struct Member {
        let uid: String
        let email: String
        let password: String
    }

    static let memberPassword = "password123"

    /// Signs in a new email/password user and returns its uid; rules treat that as a full member who may
    /// create listings.
    @discardableResult
    static func signInFullMember() async throws -> String {
        try await createFullMember().uid
    }

    /// As `signInFullMember`, but hands back what `signIn` needs to return here.
    static func createFullMember() async throws -> Member {
        try? auth.signOut()
        let email = "member-\(UUID().uuidString.prefix(8))@emulator.test"
        let result = try await auth.createUser(withEmail: email, password: memberPassword)
        return Member(uid: result.user.uid, email: email, password: memberPassword)
    }

    @discardableResult
    static func signIn(as member: Member) async throws -> String {
        try? auth.signOut()
        let result = try await auth.signIn(withEmail: member.email, password: member.password)
        return result.user.uid
    }

    /// Signs in an anonymous guest; rules must reject its writes.
    @discardableResult
    static func signInGuest() async throws -> String {
        try? auth.signOut()
        let result = try await auth.signInAnonymously()
        return result.user.uid
    }
}
