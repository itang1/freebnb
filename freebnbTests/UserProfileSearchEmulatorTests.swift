//
//  UserProfileSearchEmulatorTests.swift
//  freebnbTests
//
//  Friend search end to end against the emulator (R1): the terms the write path
//  stamps, the rules that admit them, and the arrayContains query that reads
//  them back. The unit tests in UserSearchTermsTests cover the term-building in
//  isolation; only this proves the three agree on a live Firestore.
//
//  Nested in EmulatorBackedTests, which carries the opt-in gate and the
//  serialization — these share the same Auth session as every other suite there.
//

import FirebaseFirestore
import Foundation
import Testing
@testable import freebnb

extension EmulatorBackedTests {
    @Suite
    struct UserProfileSearchEmulatorTests {

        private var repository: FirestoreUserProfileRepository {
            FirestoreUserProfileRepository(db: EmulatorSupport.firestore)
        }

        /// Signs in a fresh member and gives them a public profile under `name`.
        /// The rules only let a user write their own document, so each profile
        /// needs its own account.
        @discardableResult
        private func createMember(named name: String) async throws -> String {
            let uid = try await EmulatorSupport.signInFullMember()
            try await repository.createInitialProfile(userID: uid, displayName: name, email: nil)
            return uid
        }

        // The write path's terms have to satisfy the rules on a real create. If
        // isValidSearchTerms and UserSearchTerms ever disagree, every new
        // account fails to get a profile at all — this is that canary.
        @Test func creatingAProfileWritesTermsTheRulesAccept() async throws {
            let uid = try await createMember(named: "SpongeBob SquarePants")
            let doc = try await EmulatorSupport.firestore
                .collection(FirestorePaths.users).document(uid).getDocument()
            let terms = doc.data()?["searchTerms"] as? [String]
            #expect(terms?.contains("spongebob squarepants") == true)
            #expect(terms?.contains("sponge") == true)
        }

        @Test func findsAMemberByThePrefixOfTheirFirstName() async throws {
            let name = "Spongebob \(UUID().uuidString.prefix(6))"
            try await createMember(named: name)
            let found = try await repository.searchProfiles(query: "spong")
            #expect(found.contains { $0.displayName == name })
        }

        // The last-name search a whole-name prefix index could not have served,
        // and the reason the terms are per word rather than per name.
        @Test func findsAMemberByThePrefixOfTheirLastName() async throws {
            let surname = "Tentacles\(UUID().uuidString.prefix(6))"
            let name = "Squidward \(surname)"
            try await createMember(named: name)
            let found = try await repository.searchProfiles(query: String(surname.prefix(9)))
            #expect(found.contains { $0.displayName == name })
        }

        // The arrayContains lookup only carries the query's longest word, so
        // without the client-side pass this would return every other Star.
        @Test func everyWordOfAMultiWordQueryHasToLand() async throws {
            let tag = String(UUID().uuidString.prefix(6))
            let patrick = "Patrick Star\(tag)"
            let sandy = "Sandy Cheeks\(tag)"
            try await createMember(named: patrick)
            try await createMember(named: sandy)

            let both = try await repository.searchProfiles(query: "star\(tag)")
            #expect(both.contains { $0.displayName == patrick })
            #expect(!both.contains { $0.displayName == sandy })

            let narrowed = try await repository.searchProfiles(query: "patrick star\(tag)")
            #expect(narrowed.contains { $0.displayName == patrick })

            // Both words are real, but they belong to two different people.
            let crossed = try await repository.searchProfiles(query: "sandy star\(tag)")
            #expect(crossed.isEmpty)
        }

        @Test func aRenameMovesTheMemberToTheNewName() async throws {
            let tag = String(UUID().uuidString.prefix(6))
            let uid = try await createMember(named: "Beforename\(tag)")
            try await repository.updateDisplayName(userID: uid, newName: "Aftername\(tag)")

            let underNew = try await repository.searchProfiles(query: "aftername\(tag)")
            #expect(underNew.contains { $0.id == uid })
            // The old terms must not linger, or a rename would leave the user
            // findable under a name they no longer have.
            let underOld = try await repository.searchProfiles(query: "beforename\(tag)")
            #expect(!underOld.contains { $0.id == uid })
        }

        @Test func anEmptyQueryAsksFirestoreForNothing() async throws {
            try await EmulatorSupport.signInFullMember()
            #expect(try await repository.searchProfiles(query: "   ").isEmpty)
        }
    }
}
