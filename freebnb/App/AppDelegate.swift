//
//  AppDelegate.swift
//  freebnb
//
//  Handles remote-notification registration and FCM token delivery.
//
//  Manual steps required before push notifications go live:
//    1. In Apple Developer → Certificates, create an APNs Auth Key (.p8),
//       then upload it in Firebase Console → Project Settings → Cloud Messaging.
//    2. In Xcode → Signing & Capabilities, add "Push Notifications".
//    3. Change the aps-environment entitlement to "production" before archiving.
//

import FirebaseMessaging
import UIKit
import UserNotifications
import os

final class AppDelegate: NSObject, UIApplicationDelegate {

    // Held weakly so AppDelegate doesn't extend the stores' lifetimes.
    weak var userProfileStore: UserProfileStore?
    weak var router: DeepLinkRouter?

    // The most recent FCM token delivered, so a retry of a failed save can
    // stand down once a newer token has superseded it.
    @MainActor private var latestFCMToken: String?

    private let log = AppLog.logger("apns")

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
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
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

    // Deep-link into the correct conversation when the user taps a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        // Delivered on the main thread and DeepLinkRouter is @MainActor, so assume isolation; hopping would
        // race the completionHandler below.
        MainActor.assumeIsolated {
            switch info["type"] as? String {
            case "message":
                if let senderID = info["senderUserID"] as? String {
                    router?.pendingConversationUserID = senderID
                }
            case "friend_request", "friend_accepted":
                // Both land on Friends: requests are answered there, and an acceptance is worth meeting the
                // sender.
                router?.pendingFriendsTab = true
            case "stay_request", "stay_update", "stay_reminder":
                // Stay pushes and local reminders land on the Stays tab, where the stay is already visible.
                router?.pendingStayEvent = true
            default:
                break
            }
        }
        completionHandler()
    }
}

// MARK: - MessagingDelegate

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        // Not guaranteed on the main thread, and userProfileStore is main-actor isolated, so hop explicitly.
        Task { @MainActor in
            await saveFCMToken(token)
        }
    }

    /// Saves the token, retrying with backoff: a failed save loses it until FCM rotates it (weeks),
    /// so pushes would silently not arrive. Retries stop once a newer token supersedes it.
    @MainActor
    private func saveFCMToken(_ token: String) async {
        latestFCMToken = token
        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                guard latestFCMToken == token else { return }
            }
            do {
                try await userProfileStore?.saveFCMToken(token)
                return
            } catch {
                log.error("FCM token save failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
