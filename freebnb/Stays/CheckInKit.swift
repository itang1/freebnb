//
//  CheckInKit.swift
//  freebnb
//
//  The offline check-in kit: the street, door code, wifi and host's phone number
//  a guest needs outside a door with no data. `HomeStore`'s caches start empty on
//  a cold launch, so this persists them explicitly rather than trusting Firestore's disk cache.
//
//  Door codes and wifi passwords are written to disk in the clear, so:
//   - the file uses `.completeUntilFirstUserAuthentication`; `.complete` would
//     lock it away exactly when a guest needs it (screen off, at the door).
//   - it is reconciled against live stays on every snapshot, so a cancelled or
//     finished stay removes its kit (the server revokes the address grant too).
//   - it lives in Application Support, excluded from backups.
//

import Foundation
import os

/// The disk-persisted arrival essentials for one accepted stay: a flat snapshot
/// so it's readable when nothing can be fetched. `CheckInKitStore` refreshes it while online.
struct CheckInKit: Codable, Hashable, Sendable {
    /// The stay this kit belongs to; also the file name and reconcile key.
    let stayID: String
    let listingID: String
    /// Denormalized so the kit renders without the listing document.
    let listingTitle: String
    let city: String
    let state: String
    let hostName: String
    let checkIn: Date
    let checkOut: Date

    /// The exact street, released only once the host accepted.
    var street: String?
    var latitude: Double?
    var longitude: Double?

    /// The house-manual fields worth having at the door; every extra field is another secret on disk.
    var checkInInstructions: String?
    var keyHandoff: String?
    var wifiNetwork: String?
    var wifiPassword: String?
    var hostPhone: String?

    /// When the snapshot was taken, so the UI can show its age.
    var savedAt: Date

    /// Whether the kit holds anything worth showing; an empty "saved for offline" promise is worse than silence.
    var hasContent: Bool {
        [street, checkInInstructions, keyHandoff, wifiNetwork, wifiPassword, hostPhone]
            .contains { !($0 ?? "").isEmpty }
    }

    /// Builds a kit from the live documents; nil when there's nothing useful, so a half-loaded stay can't
    /// overwrite a good kit.
    static func make(
        stay: StayRequest,
        home: Home,
        location: ListingLocation?,
        manual: HouseManual?
    ) -> CheckInKit? {
        /// The manual's unset fields hold empty strings; the kit stores nil so `hasContent` ignores blanks.
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

/// Reads and writes check-in kits on disk. Split from the store so file handling
/// is testable and one place knows the protection level and backup exclusion.
struct CheckInKitFileStore: Sendable {
    private let directory: URL
    private let log = AppLog.logger("checkin")

    /// `directory` is injectable so tests use a temporary one.
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
        // Stay ids are app-generated UUIDs; percent-encoding anyway stops a hostile id walking the path.
        let safe = stayID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? stayID
        return directory.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        var dir = directory
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            // The directory's protection; the file sets its own too.
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // Kept out of iCloud backups; the kit is rebuildable from the server.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func save(_ kit: CheckInKit) {
        do {
            try ensureDirectory()
            let data = try JSONEncoder().encode(kit)
            // Not `.complete`: the guest needs this with the screen locked.
            try data.write(to: url(for: kit.stayID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A failed save costs an offline convenience, not the stay; log rather than alert.
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

    /// Drops every kit whose stay the guest is no longer entitled to, so a local
    /// copy can't outlive the server's address revocation. Returns the removed ids.
    @discardableResult
    func prune(keeping liveStayIDs: Set<String>) -> [String] {
        let stale = loadAll().map(\.stayID).filter { !liveStayIDs.contains($0) }
        for stayID in stale { delete(stayID: stayID) }
        return stale
    }
}
