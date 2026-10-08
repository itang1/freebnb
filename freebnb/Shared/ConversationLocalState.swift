//
//  ConversationLocalState.swift
//  freebnb
//
//  Per-device read and mute state for conversations. These once lived on the `conversations`
//  summary document, which only `onMessageCreated` writes (its create rule is `if false`) and
//  prod deploys no functions, so marking a thread read wrote to a document that didn't exist.
//  Keeping them on-device is the honest version; the cost is that reading on one device doesn't clear
//  another's badge.
//

import Foundation

/// Read and mute state per signed-in user, so two accounts on one device don't inherit each other's badges.
final class ConversationLocalState: @unchecked Sendable {
    static let shared = ConversationLocalState()

    /// Posted after any mutation, so a derived conversation list can recompute without a new message.
    static let didChange = Notification.Name("ConversationLocalStateDidChange")

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func readKey(_ userID: String) -> String { "conversationLastRead.\(userID)" }
    private func muteKey(_ userID: String) -> String { "conversationMuted.\(userID)" }

    // MARK: - Read state

    /// Conversation id → the moment this device last opened it.
    func lastReadDates(userID: String) -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        let raw = defaults.dictionary(forKey: readKey(userID)) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func markRead(conversationID: String, userID: String, at date: Date = Date()) {
        lock.lock()
        var raw = defaults.dictionary(forKey: readKey(userID)) as? [String: Double] ?? [:]
        raw[conversationID] = date.timeIntervalSince1970
        defaults.set(raw, forKey: readKey(userID))
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Mute state

    func mutedIDs(userID: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: muteKey(userID)) ?? [])
    }

    func setMuted(conversationID: String, userID: String, muted: Bool) {
        lock.lock()
        var ids = Set(defaults.stringArray(forKey: muteKey(userID)) ?? [])
        if muted { ids.insert(conversationID) } else { ids.remove(conversationID) }
        defaults.set(Array(ids), forKey: muteKey(userID))
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Drops everything for a user, so sign-out doesn't leave their read state to the next account.
    func clear(userID: String) {
        lock.lock()
        defaults.removeObject(forKey: readKey(userID))
        defaults.removeObject(forKey: muteKey(userID))
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
