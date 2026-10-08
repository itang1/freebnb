//
//  UserProfileSearchEmulatorTests.swift
//  freebnbTests
//
//  Friend search end to end against the emulator: the write path's terms, the rules admitting
//  them, and the arrayContains query. UserSearchTermsTests covers term-building alone; only
//  this proves the three agree on live Firestore. Nested in EmulatorBackedTests (gate, shared Auth session).
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

        /// Signs in a fresh member with a public profile under `name`; the rules let a user write only their
        /// own document.
        @discardableResult
        private func createMember(named name: String) async throws -> String {
            let uid = try await EmulatorSupport.signInFullMember()
            try await repository.createInitialProfile(userID: uid, displayName: name, email: nil)
            return uid
        }

        // The write path's terms must satisfy the rules on a real create; if they disagree, every new account
        // fails to get a profile (the canary).
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

        // The last-name search a whole-name prefix index couldn't serve, why terms are per word.
        @Test func findsAMemberByThePrefixOfTheirLastName() async throws {
            let surname = "Tentacles\(UUID().uuidString.prefix(6))"
            let name = "Squidward \(surname)"
            try await createMember(named: name)
            let found = try await repository.searchProfiles(query: String(surname.prefix(9)))
            #expect(found.contains { $0.displayName == name })
        }

        // The arrayContains lookup carries only the longest word, so without the client pass this returns
        // every other Star.
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

            // Both words are real but belong to two different people.
            let crossed = try await repository.searchProfiles(query: "sandy star\(tag)")
            #expect(crossed.isEmpty)
        }

        @Test func aRenameMovesTheMemberToTheNewName() async throws {
            let tag = String(UUID().uuidString.prefix(6))
            let uid = try await createMember(named: "Beforename\(tag)")
            try await repository.updateDisplayName(userID: uid, newName: "Aftername\(tag)")

            let underNew = try await repository.searchProfiles(query: "aftername\(tag)")
            #expect(underNew.contains { $0.id == uid })
            // Old terms mustn't linger, or a rename leaves the user findable under a name they no longer have.
            let underOld = try await repository.searchProfiles(query: "beforename\(tag)")
            #expect(!underOld.contains { $0.id == uid })
        }

        @Test func anEmptyQueryAsksFirestoreForNothing() async throws {
            try await EmulatorSupport.signInFullMember()
            #expect(try await repository.searchProfiles(query: "   ").isEmpty)
        }
    }
}
