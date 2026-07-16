//
//  EmulatorSupport.swift
//  freebnbTests
//
//  Shared plumbing for the Firestore-backed repository tests (A5/A6 follow-on:
//  rules-regression coverage). These tests talk to the real repositories
//  against the Local Emulator Suite, so they exercise firestore.rules end to
//  end — the client-side doubles in InMemoryRepositories.swift cannot.
//
//  The harness is deliberately self-contained: it stands up its own secondary
//  FirebaseApp pointed straight at the emulator (host + port set on the
//  Firestore settings and Auth), so it depends on neither the app's launch
//  arguments nor any simulator-inherited environment. The suites are gated on
//  `isEnabled`, an explicit opt-in, so they skip rather than fail anywhere they
//  weren't asked for — including a dev machine whose emulator is serving the
//  freebnb-6814a dev project on these same ports. Run them with:
//
//    firebase emulators:exec --only firestore,auth \
//      --project freebnb-emulator-tests \
//      "xcodebuild test -scheme freebnb -testPlan EmulatorTests \
//         -only-testing:freebnbTests/EmulatorBackedTests \
//         CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO"
//
//  In Xcode, switch the scheme's test plan to EmulatorTests. The default plan
//  leaves the flag unset, so these suites skip there.
//

import Darwin
import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation
import Testing

/// Parent of every emulator-backed suite. Nesting them here is what keeps them
/// from running *alongside each other*: `.serialized` on a suite only orders
/// that suite's own tests, and Swift Testing is free to run two peer suites in
/// parallel. These share one Auth session (`EmulatorSupport.auth` — one
/// `currentUser`), so interleaved sign-ins swap `request.auth.uid` out from
/// under a test in flight; the listing writes then fail the rules' hostUserID
/// check with PERMISSION_DENIED, and the run wedges long enough for the test
/// host's watchdog to kill it. Serialized here, the trait applies to every
/// descendant, so the suites take turns. Run either one on its own and it has
/// always passed — which is exactly what made this look like a flake.
@Suite(.serialized, .enabled(if: EmulatorSupport.isEnabled))
struct EmulatorBackedTests {}

enum EmulatorSupport {
    // Must match the --project passed to `firebase emulators:exec` so the
    // secondary app writes into the same namespace the emulator serves.
    static let projectID = "freebnb-emulator-tests"
    static let host = "127.0.0.1"
    static let firestorePort: UInt16 = 8080
    static let authPort = 9099

    /// The opt-in switch these suites gate on, set by the `emulator-tests` CI job.
    ///
    /// Reachability alone is the wrong condition: `scripts/dev_emulator.sh` (the
    /// scheme's build pre-action) keeps an emulator on these same ports for the
    /// `freebnb-6814a` dev project, so a plain `xcodebuild test` on a dev machine
    /// used to run these suites against that namespace — the wrong project, with
    /// a different ruleset and no guarantee of a clean slate. Requiring the flag
    /// means the suites run only where someone stood the emulator up for them.
    ///
    /// Set from the EmulatorTests test plan, which exists for exactly this. (A
    /// `TEST_RUNNER_`-prefixed build setting does not work here: that forwarding
    /// only applies to a UI test runner, not to app-hosted unit tests.)
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FREEBNB_EMULATOR_TESTS"] == "1"
            && isEmulatorReachable
    }

    /// True when something is listening on the Firestore emulator port. A blocking
    /// connect to localhost resolves immediately (accept or refuse), so no timeout
    /// dance is needed. Guards against a hang when the flag is set but the
    /// emulator never came up.
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

    /// The secondary FirebaseApp wired to the emulator, configured once. Kept off
    /// the default app so it never collides with the one FreeBNBApp.init() stands
    /// up from the placeholder GoogleService-Info.plist.
    // `nonisolated(unsafe)`: these Firebase handles aren't Sendable, but the
    // suite is serialized so they're only ever touched from one test at a time.
    nonisolated(unsafe) private static let app: FirebaseApp = {
        let name = "emulator-tests"
        if let existing = FirebaseApp.app(name: name) { return existing }
        // FirebaseCore validates the app ID's shape at configure time: the last
        // segment must parse as hex, and the API key must be 39 chars starting
        // with "AIza" or FirebaseInstallations aborts. Neither value reaches a
        // real backend — everything is pointed at the emulator.
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

    /// A Firestore handle pointed at the emulator, persistence off so each run
    /// starts from the emulator's state rather than a local cache.
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

    /// Signs in a brand-new email/password user and returns its uid. Rules treat
    /// email/password as a full member (sign_in_provider != 'anonymous'), so this
    /// is the identity that may create listings.
    @discardableResult
    static func signInFullMember() async throws -> String {
        try? auth.signOut()
        let email = "member-\(UUID().uuidString.prefix(8))@emulator.test"
        let result = try await auth.createUser(withEmail: email, password: "password123")
        return result.user.uid
    }

    /// Signs in an anonymous "guest". Rules must reject any write from this
    /// identity, which is what the negative tests assert.
    @discardableResult
    static func signInGuest() async throws -> String {
        try? auth.signOut()
        let result = try await auth.signInAnonymously()
        return result.user.uid
    }
}
