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

// Attests that requests come from a genuine build of this app, so backends can reject traffic that bypasses it.
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
    // Declared without an initializer: an inline `= BookingPolicyStore()` would run before
    // `FirebaseApp.configure()` and constructing a Firestore handle there throws.
    @State private var bookingPolicyStore: BookingPolicyStore
    @State private var reviewStore: ReviewStore
    @State private var friendNoteStore: FriendNoteStore
    @State private var guestNoteStore: GuestNoteStore
    @State private var networkMonitor = NetworkMonitor()
    @State private var checkInKitStore = CheckInKitStore()

    init() {
        // App Check registers before FirebaseApp.configure() so the first calls are attested. The
        // simulator can't do App Attest, so DEBUG uses the debug provider: the FIRAAppCheckDebugToken
        // env var (set in the scheme), else a fresh token logged to the console that must be
        // registered in Firebase Console → App Check → Manage debug tokens.
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
        // Enable crash and analytics collection; must follow configure() and the emulator check above.
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
                // An invite link tapped in Messages or Mail arrives as a browsing activity, not a URL, so
                // `onOpenURL` alone would open Safari.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handleIncomingURL(url)
                }
                // A saved listing tapped in Spotlight hands back its identifier; route it into the app.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let listingID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        router.pendingListingID = listingID
                    }
                }
        }
    }

    // Points Auth and Firestore at the emulator (see EmulatorEnvironment) so automated runs never write real
    // data. DEBUG-only.
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

    // UI tests pass `-UITesting` so every run starts at the age gate with no signed-in user.
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

    // Routes an incoming URL from either entry point. The reversed-client-ID scheme is the
    // Google sign-in callback; `freebnb://stays` (widgets, Live Activity) switches to Stays; an
    // invite (https Universal Link or `freebnb://invite`) lands on Friends with the sender's
    // card. Links never create a friend connection.
    private func handleIncomingURL(_ url: URL) {
        if GIDSignIn.sharedInstance.handle(url) { return }
        guard let route = DeepLinkRouter.route(for: url) else { return }
        router.handle(route)
    }
}
