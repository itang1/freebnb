//
//  NetworkMonitor.swift
//  freebnb
//
//  Live connectivity, surfaced so the UI can show an offline banner and reassure
//  the user that queued writes will send later (feature 41). Firestore's on-disk
//  persistence already queues writes made while offline and replays them on
//  reconnect; this type only observes and reports connectivity, it does not do
//  the queueing itself.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    /// Whether the device currently has a usable path to the network. Starts
    /// `true` so the app never flashes an offline banner during the brief window
    /// before the first path update arrives; a real outage flips it within a
    /// moment of launch.
    private(set) var isOnline: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.freebnb.NetworkMonitor")

    /// `start: false` builds an idle monitor for previews and tests, which must
    /// never touch the real network interfaces.
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

    /// The pure mapping from a path status to "usable", split out so it is
    /// unit-testable without a live interface. Only a fully `.satisfied` path
    /// counts as online; `.requiresConnection` and `.unsatisfied` do not.
    nonisolated static func isSatisfied(_ status: NWPath.Status) -> Bool {
        status == .satisfied
    }

    deinit {
        monitor.cancel()
    }
}
