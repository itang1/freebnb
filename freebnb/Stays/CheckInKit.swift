//
//  CheckInKit.swift
//  freebnb
//
//  The offline check-in kit (feature 44): everything a guest needs while standing
//  outside a door in a foreign city with no data plan — the street, the door code,
//  the wifi, and the host's phone number.
//
//  This is the one moment the app absolutely must work, and until now it was the
//  moment it was least equipped for. The address and the manual are both fetched
//  on demand into `HomeStore`'s in-memory caches, so a cold launch on a dead
//  network had nothing: the caches start empty, and the fetch that fills them is
//  the thing that cannot happen. Firestore's own disk cache probably covered it.
//  "Probably" is not what you want to be relying on at a stranger's front door at
//  midnight, so this makes it explicit and testable.
//
//  # What this stores, and why that needs care
//
//  A door code, a wifi password, and a street address, written to disk in the
//  clear. That is a real escalation from holding them in memory, and it is why:
//
//   - the file is written with `.completeUntilFirstUserAuthentication`, so it is
//     unreadable until the device has been unlocked once after boot. Stronger
//     protection (`.complete`) would lock the kit away exactly when a guest needs
//     it — phone in hand, screen off, standing at the door.
//   - the kit is reconciled against the live stays on every snapshot, so a
//     cancelled or finished stay takes its kit off the device. The server already
//     revokes the address grant when a stay ends (`expireCompletedStays`); a
//     local copy that outlived it would quietly undo that promise.
//   - it lives in Application Support, which is excluded from backups here, so a
//     host's door code does not end up in someone's iCloud backup forever.
//

import Foundation
import os

/// The disk-persisted arrival essentials for one accepted stay.
///
/// Deliberately a flat snapshot rather than a reference to the live documents:
/// the whole point is to be readable when nothing can be fetched. It is a copy,
/// and like every copy it can go stale — `CheckInKitStore` refreshes it whenever
/// the app is online and the stay is still live.
struct CheckInKit: Codable, Hashable, Sendable {
    /// The stay this kit belongs to. Also the file name, and the key the store
    /// reconciles on.
    let stayID: String
    let listingID: String
    /// Denormalized so the kit renders without touching the listing document.
    let listingTitle: String
    let city: String
    let state: String
    let hostName: String
    let checkIn: Date
    let checkOut: Date

    /// The exact street, released to the guest only once the host accepted.
    var street: String?
    var latitude: Double?
    var longitude: Double?

    /// The house-manual fields worth having at the door. Not the whole manual:
    /// house notes and the like are nice to have, but they are not what stops a
    /// guest being locked out, and every field here is one more secret on disk.
    var checkInInstructions: String?
    var keyHandoff: String?
    var wifiNetwork: String?
    var wifiPassword: String?
    var hostPhone: String?

    /// When this snapshot was taken, so the UI can be honest about how old it is.
    var savedAt: Date

    /// Whether the kit holds anything worth showing. A stay whose host wrote no
    /// manual and whose address hasn't been fetched yet is an empty promise, and
    /// telling the guest it's "saved for offline" would be worse than silence.
    var hasContent: Bool {
        [street, checkInInstructions, keyHandoff, wifiNetwork, wifiPassword, hostPhone]
            .contains { !($0 ?? "").isEmpty }
    }

    /// Builds a kit from the live documents. Returns nil when there is nothing
    /// useful to save yet, so a half-loaded stay never overwrites a good kit with
    /// an empty one.
    static func make(
        stay: StayRequest,
        home: Home,
        location: ListingLocation?,
        manual: HouseManual?
    ) -> CheckInKit? {
        /// Empty strings are what the manual's unset fields hold; nil is what the
        /// kit stores, so `hasContent` doesn't count a blank as an answer.
        func present(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        let kit = CheckInKit(
            stayID: stay.id,
            listingID: home.id,
            listingTitle: home.displayTitle,
            city: home.address.city,
            state: home.address.state,
            hostName: home.hostName,
            checkIn: stay.checkIn,
            checkOut: stay.checkOut,
            street: present(location?.street),
            latitude: location?.latitude,
            longitude: location?.longitude,
            checkInInstructions: present(manual?.checkInInstructions),
            keyHandoff: present(manual?.keyHandoff),
            wifiNetwork: present(manual?.wifiNetwork),
            wifiPassword: present(manual?.wifiPassword),
            hostPhone: present(manual?.hostPhone),
            savedAt: Date()
        )
        return kit.hasContent ? kit : nil
    }
}

/// Reads and writes check-in kits on disk.
///
/// Split from the store so the file handling is testable without a Firestore
/// listener, and so there is exactly one place that knows the protection level
/// and the backup exclusion.
struct CheckInKitFileStore: Sendable {
    private let directory: URL
    private let log = AppLog.logger("checkin")

    /// `directory` is injectable so tests get a temporary one instead of the real
    /// Application Support folder.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL.temporaryDirectory
            self.directory = base.appendingPathComponent("CheckInKits", isDirectory: true)
        }
    }

    private func url(for stayID: String) -> URL {
        // Stay ids are UUIDs the app generates, so they carry no path separators.
        // Percent-encoding anyway costs nothing and means a hostile id — from a
        // modified client that wrote its own document id — cannot walk the path.
        let safe = stayID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? stayID
        return directory.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        var dir = directory
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            // The directory's own protection; the file below sets its own too.
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // A door code has no business in an iCloud backup. The kit is derived
        // data, rebuildable from the server whenever the guest is online, so
        // there is nothing here worth preserving across a restore.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func save(_ kit: CheckInKit) {
        do {
            try ensureDirectory()
            let data = try JSONEncoder().encode(kit)
            // `.completeUntilFirstUserAuthentication`, not `.complete`: the guest
            // needs this with the screen locked, standing at the door.
            try data.write(to: url(for: kit.stayID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A kit that fails to save costs the guest an offline convenience, not
            // their stay. Log and move on rather than surfacing an alert about a
            // file they never asked us to write.
            log.error("check-in kit save failed for \(kit.stayID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func load(stayID: String) -> CheckInKit? {
        guard let data = try? Data(contentsOf: url(for: stayID)) else { return nil }
        return try? JSONDecoder().decode(CheckInKit.self, from: data)
    }

    func loadAll() -> [CheckInKit] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CheckInKit.self, from: data)
            }
    }

    func delete(stayID: String) {
        try? FileManager.default.removeItem(at: url(for: stayID))
    }

    /// Drops every kit whose stay is no longer one the guest is entitled to.
    /// The counterpart to the server's `expireCompletedStays` sweep: that
    /// withdraws the address grant, and this is what stops a local copy from
    /// outliving it. Returns the ids it removed, for the tests and the log.
    @discardableResult
    func prune(keeping liveStayIDs: Set<String>) -> [String] {
        let stale = loadAll().map(\.stayID).filter { !liveStayIDs.contains($0) }
        for stayID in stale { delete(stayID: stayID) }
        return stale
    }
}
