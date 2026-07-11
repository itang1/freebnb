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
//  arguments nor any simulator-inherited environment. The whole suite is gated
//  on `isEmulatorReachable`, a plain TCP probe, so on a machine or CI job
//  without the emulator running the tests skip rather than fail. Run them with:
//
//    firebase emulators:exec --only firestore,auth \
//      --project freebnb-emulator-tests "xcodebuild test -scheme freebnb ..."
//

import Darwin
import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation

enum EmulatorSupport {
    // Must match the --project passed to `firebase emulators:exec` so the
    // secondary app writes into the same namespace the emulator serves.
    static let projectID = "freebnb-emulator-tests"
    static let host = "127.0.0.1"
    static let firestorePort: UInt16 = 8080
    static let authPort = 9099

    /// True when something is listening on the Firestore emulator port. A blocking
    /// connect to localhost resolves immediately (accept or refuse), so no timeout
    /// dance is needed. Used as the suite's `.enabled(if:)` condition.
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
        let options = FirebaseOptions(
            googleAppID: "1:1234567890:ios:emulatortestapp",
            gcmSenderID: "1234567890"
        )
        options.projectID = projectID
        // The Auth emulator requires a non-empty API key but validates nothing.
        options.apiKey = "emulator-fake-api-key"
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

    nonisolated(unsafe) private static let auth: Auth = {
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
