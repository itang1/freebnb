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
    /// Someone asked to connect, or accepted your request (onFriendEdgeWritten).
    case friendRequests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages:       return "Messages"
        case .stayRequests:   return "Stay requests"
        case .stayUpdates:    return "Trip updates"
        case .friendRequests: return "Friend requests"
        }
    }

    var subtitle: String {
        switch self {
        case .messages:       return "New messages from your friends"
        case .stayRequests:   return "When someone asks to stay at your place"
        case .stayUpdates:    return "When a host accepts or declines your request"
        case .friendRequests: return "When someone asks to connect, or accepts your request"
        }
    }

    var icon: String {
        switch self {
        case .messages:       return "message"
        case .stayRequests:   return "tray.and.arrow.down"
        case .stayUpdates:    return "suitcase"
        case .friendRequests: return "person.2"
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
    var friendRequests: Bool

    init(
        messages: Bool = true,
        stayRequests: Bool = true,
        stayUpdates: Bool = true,
        friendRequests: Bool = true
    ) {
        self.messages = messages
        self.stayRequests = stayRequests
        self.stayUpdates = stayUpdates
        self.friendRequests = friendRequests
    }

    /// Builds from the raw Firestore map. An absent map or key defaults to `true`
    /// (enabled), matching the Cloud Functions' `!== false` check.
    init(firestore map: [String: Any]?) {
        func flag(_ key: String) -> Bool { (map?[key] as? Bool) ?? true }
        self.init(
            messages: flag(NotificationCategory.messages.rawValue),
            stayRequests: flag(NotificationCategory.stayRequests.rawValue),
            stayUpdates: flag(NotificationCategory.stayUpdates.rawValue),
            friendRequests: flag(NotificationCategory.friendRequests.rawValue)
        )
    }

    /// Tolerant of payloads written before a category existed: a missing key is
    /// enabled, matching both `init(firestore:)` and the functions' `!== false`.
    /// The synthesized decoder would throw on one instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? true
        }
        self.init(
            messages: try flag(.messages),
            stayRequests: try flag(.stayRequests),
            stayUpdates: try flag(.stayUpdates),
            friendRequests: try flag(.friendRequests)
        )
    }

    func isEnabled(_ category: NotificationCategory) -> Bool {
        switch category {
        case .messages:       return messages
        case .stayRequests:   return stayRequests
        case .stayUpdates:    return stayUpdates
        case .friendRequests: return friendRequests
        }
    }

    func setting(_ category: NotificationCategory, to newValue: Bool) -> NotificationPreferences {
        var copy = self
        switch category {
        case .messages:       copy.messages = newValue
        case .stayRequests:   copy.stayRequests = newValue
        case .stayUpdates:    copy.stayUpdates = newValue
        case .friendRequests: copy.friendRequests = newValue
        }
        return copy
    }

    var firestoreValue: [String: Bool] {
        [
            NotificationCategory.messages.rawValue: messages,
            NotificationCategory.stayRequests.rawValue: stayRequests,
            NotificationCategory.stayUpdates.rawValue: stayUpdates,
            NotificationCategory.friendRequests.rawValue: friendRequests
        ]
    }
}
