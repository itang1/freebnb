//
//  FreeBNBApp.swift
//  freebnb
//

import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import SwiftUI
import UserNotifications

#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

#if canImport(FirebaseAppCheck)
import FirebaseAppCheck

// Attests that requests come from a genuine, unmodified build of this app so
// Firestore/Storage/Functions can reject traffic that bypasses the app. App
// Attest is used in production; DeviceCheck covers older devices.
final class FreeBNBAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
    }
}
#endif

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
    @State private var reviewStore: ReviewStore
    @State private var networkMonitor = NetworkMonitor()

    init() {
        // App Check must be registered before FirebaseApp.configure() so the
        // first backend calls are attested. In DEBUG the debug provider lets the
        // simulator obtain a token (register it in the Firebase console).
#if canImport(FirebaseAppCheck)
#if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
#else
        AppCheck.setAppCheckProviderFactory(FreeBNBAppCheckProviderFactory())
#endif
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
#if canImport(FirebaseMessaging)
        Messaging.messaging().isAutoInitEnabled = true
#endif
        _authManager = State(initialValue: AuthManager())
        _homeStore = State(initialValue: HomeStore())
        _messageStore = State(initialValue: MessageStore())
        _userProfileStore = State(initialValue: UserProfileStore())
        _stayRequestStore = State(initialValue: StayRequestStore())
        _friendStore = State(initialValue: FriendStore())
        _reviewStore = State(initialValue: ReviewStore())
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
                .environment(reviewStore)
                .environment(networkMonitor)
                .environment(router)
                .onAppear {
                    appDelegate.userProfileStore = userProfileStore
                    appDelegate.router = router
#if canImport(FirebaseMessaging)
                    Messaging.messaging().delegate = appDelegate
#endif
                    requestPushPermission()
                }
                .onOpenURL { url in handleIncomingURL(url) }
#if canImport(CoreSpotlight)
                // A saved listing tapped in Spotlight hands back its identifier;
                // route it into the app, which pushes the listing (feature 40).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let listingID = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        router.pendingListingID = listingID
                    }
                }
#endif
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

    // Claims the Google sign-in callback, which arrives through the reversed
    // client ID URL scheme. Our own `freebnb://` links carry no action — opening
    // one simply launches the app — so there is nothing else to route here.
    // Friend connections are made only in-app, through search, request, and
    // accept; a deep link never creates one.
    private func handleIncomingURL(_ url: URL) {
#if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.handle(url)
#endif
    }
}
