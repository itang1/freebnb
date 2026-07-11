//
//  NetworkMonitorTests.swift
//  freebnbTests
//
//  The pure status→online mapping behind the offline banner (feature 41). The
//  live NWPathMonitor can't be driven deterministically in a test, but the
//  decision it feeds can.
//

import Network
import Testing
@testable import freebnb

struct NetworkMonitorTests {
    @Test func satisfiedPathIsOnline() {
        #expect(NetworkMonitor.isSatisfied(.satisfied) == true)
    }

    @Test func unsatisfiedPathIsOffline() {
        #expect(NetworkMonitor.isSatisfied(.unsatisfied) == false)
    }

    @Test func requiresConnectionIsOffline() {
        // A path that "requires connection" (e.g. VPN/hotspot not yet up) is not
        // usable, so the banner should show.
        #expect(NetworkMonitor.isSatisfied(.requiresConnection) == false)
    }
}
