//
//  UserSearchTermsTests.swift
//  freebnbTests
//
//  The name-search index. These pin the contract three things depend on: firestore.rules'
//  isValidSearchTerms, scripts/search_terms.js (the Node twin) and the query in searchProfiles.
//

import Foundation
import Testing
@testable import freebnb

@Suite
struct UserSearchTermsTests {

    // MARK: - terms(for:)

    // The rules require the whole lowercased name among the terms; breaking this fails every profile write.
    @Test func termsAlwaysCarryTheWholeLowercasedName() {
        #expect(UserSearchTerms.terms(for: "SpongeBob SquarePants").contains("spongebob squarepants"))
        #expect(UserSearchTerms.terms(for: "Devna").contains("devna"))
    }

    @Test func termsCoverEveryPrefixOfEveryWord() {
        let terms = Set(UserSearchTerms.terms(for: "SpongeBob SquarePants"))
        // Leading edge of the first word and the second (a last-name search a whole-name prefix index
        // couldn't serve).
        #expect(terms.isSuperset(of: ["s", "sp", "spo", "sponge", "spongebob"]))
        #expect(terms.isSuperset(of: ["sq", "squ", "square", "squarepants"]))
    }

    // Mid-word fragments aren't indexed (every substring is quadratic); pinned so the omission stays a decision.
    @Test func termsOmitMidWordFragments() {
        #expect(!UserSearchTerms.terms(for: "SpongeBob").contains("ponge"))
    }

    // The exact array scripts/search_terms.js produces for the same name. A profile indexed by one
    // implementation and queried by the other can't be found; if this fails, fix both and re-run the backfill.
    @Test func termsMatchTheNodeTwinExactly() {
        #expect(UserSearchTerms.terms(for: "SpongeBob SquarePants") == [
            "spongebob squarepants",
            "s", "sp", "spo", "spon", "spong", "sponge", "spongeb", "spongebo", "spongebob",
            "sq", "squ", "squa", "squar", "square", "squarep", "squarepa", "squarepan",
            "squarepant", "squarepants"
        ])
        #expect(UserSearchTerms.terms(for: "Mrs. Puff") == [
            "mrs. puff", "m", "mr", "mrs", "p", "pu", "puf", "puff"
        ])
        #expect(UserSearchTerms.terms(for: "Ann Ann") == ["ann ann", "a", "an", "ann"])
        #expect(UserSearchTerms.terms(for: "!!!") == ["!!!"])
    }

    @Test func termsDedupeRepeatedWords() {
        let terms = UserSearchTerms.terms(for: "Ann Ann")
        #expect(terms.count == Set(terms).count)
    }

    @Test func termsStayWithinTheCapTheRulesEnforce() {
        // Well past both caps: many long words.
        let name = (1...30).map { _ in "Bartholomewshire" }.joined(separator: " ")
        let terms = UserSearchTerms.terms(for: name)
        #expect(terms.count <= UserSearchTerms.maxTerms)
        // The name the rules check for survives the cap.
        #expect(terms.contains(name.lowercased()))
    }

    @Test func longWordsAreIndexedOnlyToTheCappedPrefix() {
        let terms = Set(UserSearchTerms.terms(for: "Bartholomewshirington"))
        #expect(terms.contains("bartholomewshi"))       // 14 chars
        #expect(terms.contains("bartholomewshir"))      // 15, the cap
        #expect(!terms.contains("bartholomewshiri"))    // 16, past it
    }

    @Test func punctuationAndCaseAreNotPartOfAWord() {
        let terms = Set(UserSearchTerms.terms(for: "Mrs. Puff"))
        #expect(terms.contains("mrs"))
        #expect(terms.contains("puff"))
        #expect(!terms.contains("mrs."))
    }

    @Test func aNameWithNoIndexableWordsStillCarriesItself() {
        // The rules' hasAll check runs regardless of what the name is made of.
        #expect(UserSearchTerms.terms(for: "!!!").contains("!!!"))
    }

    // MARK: - queryTerm(for:)

    // The lookup rides on one term, and the longest word is the most selective.
    @Test func queryTermPicksTheLongestWord() {
        #expect(UserSearchTerms.queryTerm(for: "bob squarepants") == "squarepants")
        #expect(UserSearchTerms.queryTerm(for: "SpongeBob") == "spongebob")
    }

    // Or the query would ask for a term longer than anything indexed and match nothing.
    @Test func queryTermIsCappedLikeTheStoredPrefixes() {
        #expect(UserSearchTerms.queryTerm(for: "Bartholomewshirington") == "bartholomewshir")
    }

    @Test func queryTermIsNilWhenThereIsNothingToSearchFor() {
        #expect(UserSearchTerms.queryTerm(for: "") == nil)
        #expect(UserSearchTerms.queryTerm(for: "   ") == nil)
        #expect(UserSearchTerms.queryTerm(for: "!!!") == nil)
    }

    // MARK: - matches(displayName:query:)

    @Test func everyQueryWordMustPrefixSomeNameWord() {
        #expect(UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "sponge"))
        #expect(UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "square"))
        // Multi-word: both words land, in either order.
        #expect(UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "sponge square"))
        #expect(UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "square sponge"))
    }

    // The arrayContains lookup carries only the longest word, so without this "sponge square" would match
    // every Square.
    @Test func aQueryWordThatMatchesNothingRejectsTheProfile() {
        #expect(!UserSearchTerms.matches(displayName: "Squidward Tentacles", query: "sponge square"))
        #expect(!UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "patrick"))
    }

    @Test func matchingIgnoresCase() {
        #expect(UserSearchTerms.matches(displayName: "SpongeBob SquarePants", query: "SPONGE"))
    }

    @Test func anEmptyQueryMatchesNobody() {
        #expect(!UserSearchTerms.matches(displayName: "SpongeBob", query: ""))
    }
}
