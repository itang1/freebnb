//
//  StayOfferTests.swift
//  freebnbTests
//
//  Host-initiated offers. rules-tests/offers.test.mjs covers who may write what; these cover
//  the model's reading of a document: which side owes a reply and who started it, questions that
//  once had a single answer.
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

    /// Requests predating offers have no `initiatedBy` and were the guest asking; reading them as host-initiated would misfile past trips.
    @Test func aRequestWithNoInitiatorIsTheGuestAsking() {
        #expect(stay(status: .pending, initiatedBy: nil).initiator == .guest)
        #expect(stay(status: .completed, initiatedBy: nil).initiator == .guest)
    }

    /// The initiator must survive the stay moving on, which is why it's stored and not read off `status`.
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

    /// The mirror: an offer is the one thing that lands in a guest's lap needing their answer.
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

    /// An empty user id (signed out) must not match a document missing the same field.
    @Test func nobodyIsAwaitedWhenThereIsNoViewer() {
        #expect(stay(status: .pending, initiatedBy: guest).awaitsReply(from: "") == false)
    }
}

struct OfferAcceptanceTests {
    /// Only whoever owes the answer can give it; a host accepting their own offer would book a friend into a stay they never agreed to.
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
    /// An offer is unresolved, so it must count as active, or `updateStatus` would revoke the guest's address grant.
    @Test func anOfferIsActiveAndAwaitingAReply() {
        #expect(StayRequestStatus.offered.isActive)
        #expect(StayRequestStatus.offered.isAwaitingReply)
    }

    /// An offer is a proposal, not a stay; it mustn't count toward hosted or taken totals until it happens.
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
