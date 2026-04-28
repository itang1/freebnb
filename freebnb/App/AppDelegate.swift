//
//  AppDelegate.swift
//  freebnb
//
//  Handles remote-notification registration and FCM token delivery.
//
//  Manual steps required before push notifications go live:
//    1. In Xcode → Package Dependencies, add FirebaseMessaging from
//       https://github.com/firebase/firebase-ios-sdk
//    2. In Apple Developer → Certificates, create an APNs Auth Key (.p8),
//       then upload it in Firebase Console → Project Settings → Cloud Messaging.
//    3. In Xcode → Signing & Capabilities, add "Push Notifications".
//    4. Change the aps-environment entitlement to "production" before archiving.
//

import UIKit
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {

    // Held weakly so AppDelegate doesn't extend the stores' lifetimes.
    weak var userProfileStore: UserProfileStore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Called after the user grants or has previously granted notification permission.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
#if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken
#endif
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Non-fatal on simulators; log and continue.
        print("[FCM] APNs registration failed: \(error.localizedDescription)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show notification banners while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

#if canImport(FirebaseMessaging)
// MARK: - MessagingDelegate

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        Task {
            try? await userProfileStore?.saveFCMToken(token)
        }
    }
}
#endif
