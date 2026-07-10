//
//  NotificationPreferences.swift
//  freebnb
//
//  Per-category push notification preferences. Stored server-side in the owner's
//  private profile subdocument so a mute actually silences the push (the Cloud
//  Functions read these before sending), and syncs across the user's devices
//  (feature 37). A missing map or key means "enabled" — users only ever persist
//  the categories they turn off.
//

import Foundation

enum NotificationCategory: String, CaseIterable, Identifiable, Sendable {
    /// New chat messages (onMessageCreated).
    case messages
    /// A new stay request landed on one of your listings (you are the host).
    case stayRequests
    /// A stay request you sent was accepted or declined (you are the guest).
    case stayUpdates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages:     return "Messages"
        case .stayRequests: return "Stay requests"
        case .stayUpdates:  return "Trip updates"
        }
    }

    var subtitle: String {
        switch self {
        case .messages:     return "New messages from your friends"
        case .stayRequests: return "When someone asks to stay at your place"
        case .stayUpdates:  return "When a host accepts or declines your request"
        }
    }

    var icon: String {
        switch self {
        case .messages:     return "message"
        case .stayRequests: return "tray.and.arrow.down"
        case .stayUpdates:  return "suitcase"
        }
    }
}

/// Enabled/disabled state per category. Codable so it rides along on `UserProfile`
/// (populated from the private subdocument by the profile merger), and round-trips
/// to a Firestore map via `firestoreValue`.
struct NotificationPreferences: Codable, Hashable, Sendable {
    var messages: Bool
    var stayRequests: Bool
    var stayUpdates: Bool

    init(messages: Bool = true, stayRequests: Bool = true, stayUpdates: Bool = true) {
        self.messages = messages
        self.stayRequests = stayRequests
        self.stayUpdates = stayUpdates
    }

    /// Builds from the raw Firestore map. An absent map or key defaults to `true`
    /// (enabled), matching the Cloud Functions' `!== false` check.
    init(firestore map: [String: Any]?) {
        func flag(_ key: String) -> Bool { (map?[key] as? Bool) ?? true }
        self.init(
            messages: flag(NotificationCategory.messages.rawValue),
            stayRequests: flag(NotificationCategory.stayRequests.rawValue),
            stayUpdates: flag(NotificationCategory.stayUpdates.rawValue)
        )
    }

    func isEnabled(_ category: NotificationCategory) -> Bool {
        switch category {
        case .messages:     return messages
        case .stayRequests: return stayRequests
        case .stayUpdates:  return stayUpdates
        }
    }

    func setting(_ category: NotificationCategory, to newValue: Bool) -> NotificationPreferences {
        var copy = self
        switch category {
        case .messages:     copy.messages = newValue
        case .stayRequests: copy.stayRequests = newValue
        case .stayUpdates:  copy.stayUpdates = newValue
        }
        return copy
    }

    var firestoreValue: [String: Bool] {
        [
            NotificationCategory.messages.rawValue: messages,
            NotificationCategory.stayRequests.rawValue: stayRequests,
            NotificationCategory.stayUpdates.rawValue: stayUpdates
        ]
    }
}
