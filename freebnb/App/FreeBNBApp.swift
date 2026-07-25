//
//  FreeBNBApp.swift
//  freebnb
//

import CoreSpotlight
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseMessaging
import GoogleSignIn
import SwiftUI
import UserNotifications

// Attests that requests come from a genuine, unmodified build of this app so
// Firestore/Storage/Functions can reject traffic that bypasses the app.
final class FreeBNBAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}

@main
struct FreeBNBApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var router = DeepLinkRouter()
    @State private var authManager: AuthManager
    @State private var homeStore: HomeStore
    @State private var messageStore: MessageStore
    @State private var userProfileStore: UserProfileStore
    @State private var stayRequestStore: StayRequestStore
    @State private var friendStore: FriendStore
    @State private var circleStore: CircleStore
    // Declared without an initializer, like the other repository-backed stores:
    // an inline `= BookingPolicyStore()` runs while the property wrappers are
    // built, which is before `FirebaseApp.configure()` below, and constructing
    // a Firestore handle there throws on the way up.
    @State private var bookingPolicyStore: BookingPolicyStore
    @State private var reviewStore: ReviewStore
    @State private var friendNoteStore: FriendNoteStore
    @State private var guestNoteStore: GuestNoteStore
    @State private var networkMonitor = NetworkMonitor()
    @State private var checkInKitStore = CheckInKitStore()

    init() {
        // App Check must be registered before FirebaseApp.configure() so the
        // first backend calls are attested. The simulator can't do App Attest, so
        // DEBUG builds use the debug provider: it reads the token from the
        // FIRAAppCheckDebugToken environment variable (set in the freebnb scheme)
        // and falls back to minting a fresh one, logged to the Xcode console, that
        // must then be registered in Firebase Console → App Check → Manage debug
        // tokens.
#if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
#else
        AppCheck.setAppCheckProviderFactory(FreeBNBAppCheckProviderFactory())
#endif
        FirebaseApp.configure()
#if DEBUG
        Self.configureEmulatorIfRequested()
        Self.resetStateIfUITesting()
#endif
        // Enable crash reporting and analytics collection (A6). Must follow
        // FirebaseApp.configure(), and the emulator check above, so an emulator
        // or UI-test run is correctly excluded from collection.
        Telemetry.configure()
        Messaging.messaging().isAutoInitEnabled = true
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
        _userProfileStore = State(initialValue: UserProfileStore())
        _stayRequestStore = State(initialValue: StayRequestStore())
        _friendStore = State(initialValue: FriendStore())
        _circleStore = State(initialValue: CircleStore())
        _bookingPolicyStore = State(initialValue: BookingPolicyStore())
        _reviewStore = State(initialValue: ReviewStore())
        _friendNoteStore = State(initialValue: FriendNoteStore())
        _guestNoteStore = State(initialValue: GuestNoteStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(homeStore)
                .environment(messageStore)
                .environment(userProfileStore)
                .environment(stayRequestStore)
                .environment(friendStore)
                .environment(circleStore)
                .environment(bookingPolicyStore)
                .environment(reviewStore)
                .environment(friendNoteStore)
                .environment(guestNoteStore)
                .environment(networkMonitor)
                .environment(router)
                .environment(checkInKitStore)
                .onAppear {
                    appDelegate.userProfileStore = userProfileStore
                    appDelegate.router = router
                    Messaging.messaging().delegate = appDelegate
                    requestPushPermission()
                }
                .onOpenURL { url in handleIncomingURL(url) }
                // An invite link tapped in Messages or Mail. A Universal Link is
                // handed over as a browsing activity, not as a URL, so `onOpenURL`
                // alone would never see it — the tap would open Safari instead.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handleIncomingURL(url)
                }
                // A saved listing tapped in Spotlight hands back its identifier;
                // route it into the app, which pushes the listing (feature 40).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let listingID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        router.pendingListingID = listingID
                    }
                }
        }
    }

    // Points Auth and Firestore at `firebase emulators:start` instead of the
    // production project, so automated runs never write real data. See
    // EmulatorEnvironment for how the emulator is requested. DEBUG-only;
    // production builds never check for this.
#if DEBUG
    private static func configureEmulatorIfRequested() {
        guard EmulatorEnvironment.isActive else { return }
        let host = EmulatorEnvironment.host
        Auth.auth().useEmulator(withHost: host, port: 9099)
        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings
        Functions.functions().useEmulator(withHost: host, port: 5001)
    }
#endif

    // UI tests pass `-UITesting` so every run starts from the age gate with no
    // signed-in user, regardless of what a previous run (or a developer) left
    // in this simulator.
#if DEBUG
    private static func resetStateIfUITesting() {
        guard ProcessInfo.processInfo.arguments.contains("-UITesting") else { return }
        try? Auth.auth().signOut()
        let defaults = UserDefaults.standard
        [UserDefaultsKey.ageGateAccepted,
         UserDefaultsKey.hasSeenOnboarding,
         UserDefaultsKey.selectedTab].forEach { defaults.removeObject(forKey: $0) }
    }
#endif

    private func requestPushPermission() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // Routes an incoming URL, from either entry point above. The
    // reversed-client-ID scheme is the Google sign-in callback; our own
    // `freebnb://stays` scheme is what the home-screen widgets and the
    // current-stay Live Activity open when tapped, and it simply switches to the
    // Stays tab. An invite arrives as an https Universal Link (or the older
    // `freebnb://invite` scheme) and lands on Friends with the sender's card on
    // screen when it names one. Friend connections are still made only in-app,
    // so a link never creates one; the most an invite does is save a search.
    private func handleIncomingURL(_ url: URL) {
        if GIDSignIn.sharedInstance.handle(url) { return }
        guard let route = DeepLinkRouter.route(for: url) else { return }
        router.handle(route)
    }
}
