//
//  StayOfferTests.swift
//  freebnbTests
//
//  Host-initiated offers (feature 43). The rules tests in rules-tests/offers.test.mjs
//  cover who may write what; these cover the model's own reading of a document —
//  which side owes a reply, and who started it.
//
//  Both questions used to have a single answer because there was only one way a
//  stay could begin. Everything here is a place that assumption was baked in.
//

import Foundation
import Testing
@testable import freebnb

private let host = "host-1"
private let guest = "guest-1"

private func stay(
    status: StayRequestStatus,
    initiatedBy: String? = nil
) -> StayRequest {
    StayRequest(
        listingID: "listing-1",
        listingCity: "Town",
        listingHostName: "Host",
        hostUserID: host,
        guestUserID: guest,
        checkIn: Date(timeIntervalSince1970: 1_800_000_000),
        checkOut: Date(timeIntervalSince1970: 1_800_400_000),
        status: status,
        initiatedBy: initiatedBy
    )
}

struct StayInitiatorTests {
    @Test func anOfferIsInitiatedByTheHost() {
        #expect(stay(status: .offered, initiatedBy: host).initiator == .host)
    }

    @Test func aRequestIsInitiatedByTheGuest() {
        #expect(stay(status: .pending, initiatedBy: guest).initiator == .guest)
    }

    /// Requests written before offers existed carry no `initiatedBy`, and could
    /// only ever have been the guest asking — that was the only thing the app
    /// could do. Reading them as host-initiated would misfile every past trip.
    @Test func aRequestWithNoInitiatorIsTheGuestAsking() {
        #expect(stay(status: .pending, initiatedBy: nil).initiator == .guest)
        #expect(stay(status: .completed, initiatedBy: nil).initiator == .guest)
    }

    /// The initiator has to survive the stay moving on, which is the whole reason
    /// it is a stored field rather than a read of `status`. An accepted offer and
    /// an accepted request are both just "accepted".
    @Test func theInitiatorOutlivesTheStatus() {
        #expect(stay(status: .accepted, initiatedBy: host).initiator == .host)
        #expect(stay(status: .completed, initiatedBy: host).initiator == .host)
        #expect(stay(status: .declined, initiatedBy: host).initiator == .host)
        #expect(stay(status: .accepted, initiatedBy: guest).initiator == .guest)
    }
}

struct AwaitingReplyTests {
    @Test func aPendingRequestWaitsOnTheHost() {
        let request = stay(status: .pending, initiatedBy: guest)
        #expect(request.awaitingParty == host)
        #expect(request.awaitsReply(from: host))
        #expect(request.awaitsReply(from: guest) == false)
    }

    /// The mirror, and the point of the feature: an offer is the one thing in the
    /// app that lands in a guest's lap needing their answer.
    @Test func anOfferWaitsOnTheGuest() {
        let offer = stay(status: .offered, initiatedBy: host)
        #expect(offer.awaitingParty == guest)
        #expect(offer.awaitsReply(from: guest))
        #expect(offer.awaitsReply(from: host) == false)
    }

    @Test func aResolvedStayWaitsOnNobody() {
        for status in [StayRequestStatus.accepted, .completed, .declined, .cancelled] {
            #expect(stay(status: status, initiatedBy: host).awaitingParty == nil)
            #expect(stay(status: status, initiatedBy: host).awaitsReply(from: guest) == false)
            #expect(stay(status: status, initiatedBy: host).awaitsReply(from: host) == false)
        }
    }

    /// An empty user id is what a signed-out viewer looks like, and it must not
    /// match a document that happens to be missing the same field.
    @Test func nobodyIsAwaitedWhenThereIsNoViewer() {
        #expect(stay(status: .pending, initiatedBy: guest).awaitsReply(from: "") == false)
    }
}

struct OfferAcceptanceTests {
    /// Whoever owes the answer is the only one who can give it. A host accepting
    /// their own offer would book a friend into a stay they never agreed to.
    @Test func onlyTheGuestCanAcceptAnOffer() {
        let offer = stay(status: .offered, initiatedBy: host)
        #expect(offer.canBeAccepted(by: guest))
        #expect(offer.canBeAccepted(by: host) == false)
    }

    @Test func onlyTheHostCanAcceptARequest() {
        let request = stay(status: .pending, initiatedBy: guest)
        #expect(request.canBeAccepted(by: host))
        #expect(request.canBeAccepted(by: guest) == false)
    }

    @Test func nobodyCanAcceptAResolvedStay() {
        for status in [StayRequestStatus.accepted, .completed, .declined, .cancelled] {
            #expect(stay(status: status, initiatedBy: host).canBeAccepted(by: guest) == false)
            #expect(stay(status: status, initiatedBy: guest).canBeAccepted(by: host) == false)
        }
    }

    @Test func aStrangerCanAcceptNothing() {
        #expect(stay(status: .offered, initiatedBy: host).canBeAccepted(by: "someone-else") == false)
        #expect(stay(status: .pending, initiatedBy: guest).canBeAccepted(by: "someone-else") == false)
    }
}

struct OfferStatusTests {
    /// An offer is unresolved, so it must count as active. `updateStatus` revokes
    /// the guest's address grant on every inactive status, and an offer that read
    /// as inactive would have that grant torn out from under it.
    @Test func anOfferIsActiveAndAwaitingAReply() {
        #expect(StayRequestStatus.offered.isActive)
        #expect(StayRequestStatus.offered.isAwaitingReply)
    }

    /// An offer is a proposal, not a stay. It must not count toward anybody's
    /// hosted or taken totals until it actually happens.
    @Test func anOfferIsNotAStayThatHappened() {
        #expect(StayRequestStatus.offered.didHappen == false)
    }

    @Test func resolvedStatusesAreNotAwaitingAReply() {
        #expect(StayRequestStatus.accepted.isAwaitingReply == false)
        #expect(StayRequestStatus.declined.isAwaitingReply == false)
        #expect(StayRequestStatus.cancelled.isAwaitingReply == false)
        #expect(StayRequestStatus.completed.isAwaitingReply == false)
    }
}
