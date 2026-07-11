//
//  FeedbackTests.swift
//  freebnbTests
//
//  Pure-logic coverage for the feedback composer's validation (feature 43) and
//  the "what's new" auto-present decision. The Firestore round trip is proven
//  separately by rules-tests/feedback.test.mjs; the store's submit method is
//  auth-gated and so is not deterministic in this host.
//

import Testing
@testable import freebnb

struct FeedbackDraftTests {
    @Test func emptyMessageIsInvalid() {
        #expect(FeedbackDraft(message: "").isValid == false)
    }

    @Test func whitespaceOnlyMessageIsInvalid() {
        #expect(FeedbackDraft(message: "   \n\t ").isValid == false)
    }

    @Test func trimmedNonEmptyMessageIsValid() {
        #expect(FeedbackDraft(message: "  Love the app  ").isValid == true)
    }

    @Test func messageAtTheCapIsValid() {
        let atCap = String(repeating: "x", count: FeedbackDraft.maxLength)
        #expect(FeedbackDraft(message: atCap).isValid == true)
    }

    @Test func messageOverTheCapIsInvalid() {
        let overCap = String(repeating: "x", count: FeedbackDraft.maxLength + 1)
        let draft = FeedbackDraft(message: overCap)
        #expect(draft.isValid == false)
        #expect(draft.remainingCharacters == -1)
    }

    @Test func remainingCharactersCountsTrimmedLength() {
        // Surrounding whitespace is not counted against the cap, since it is
        // trimmed before the note is sent.
        let draft = FeedbackDraft(message: "  hi  ")
        #expect(draft.remainingCharacters == FeedbackDraft.maxLength - 2)
    }

    @Test func everyCategoryHasTitleAndPrompt() {
        for category in FeedbackCategory.allCases {
            #expect(category.title.isEmpty == false)
            #expect(category.prompt.isEmpty == false)
            #expect(category.icon.isEmpty == false)
        }
    }
}

struct WhatsNewTests {
    private var current: String { WhatsNew.latest?.version ?? "1.0" }

    @Test func presentsWhenLastSeenIsAnOlderVersion() {
        #expect(WhatsNew.shouldPresent(currentVersion: current, lastSeenVersion: "0.9") == true)
    }

    @Test func doesNotPresentWhenLastSeenIsCurrent() {
        #expect(WhatsNew.shouldPresent(currentVersion: current, lastSeenVersion: current) == false)
    }

    @Test func doesNotPresentOnFirstEverLaunch() {
        // nil last-seen is a brand-new install; onboarding, not the changelog,
        // greets them.
        #expect(WhatsNew.shouldPresent(currentVersion: current, lastSeenVersion: nil) == false)
    }

    @Test func doesNotPresentForAnUntrackedBuild() {
        // A build with no matching release notes never auto-presents.
        #expect(WhatsNew.shouldPresent(currentVersion: "9.9", lastSeenVersion: "0.9") == false)
    }

    @Test func releasesAreNonEmptyAndWellFormed() {
        #expect(WhatsNew.releases.isEmpty == false)
        for release in WhatsNew.releases {
            #expect(release.version.isEmpty == false)
            #expect(release.highlights.isEmpty == false)
        }
    }
}
