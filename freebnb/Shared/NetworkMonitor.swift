//
//  NetworkMonitor.swift
//  freebnb
//
//  Live connectivity so the UI can show an offline banner and reassure that queued writes will send. Firestore's
//  persistence does the queueing; this only observes connectivity.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    /// Whether the device has a usable network path. Starts `true` so no offline banner flashes before the first path update.
    private(set) var isOnline: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.freebnb.NetworkMonitor")

    /// `start: false` builds an idle monitor for previews and tests, which must never touch real interfaces.
    init(start: Bool = true) {
        monitor = NWPathMonitor()
        if start { self.start() }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = NetworkMonitor.isSatisfied(path.status)
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    /// The pure path-status mapping to "usable", unit-testable without an interface; only `.satisfied` counts as online.
    nonisolated static func isSatisfied(_ status: NWPath.Status) -> Bool {
        status == .satisfied
    }

    deinit {
        monitor.cancel()
    }
}
