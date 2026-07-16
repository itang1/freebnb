//
//  AuthTests.swift
//  freebnbTests
//
//  Covers the two pure derivations behind sign-in (the SDK-error → AuthError
//  mapping and the provider → AuthMethod mapping), plus emulator-backed checks
//  that the real FirebaseAuth SDK still produces the error codes and provider
//  IDs those mappings expect. The UI above this is thin — EmailAuthView only
//  gates its button and relays these values — so this is where email and
//  Google sign-in correctness actually lives.
//

import FirebaseAuth
import Foundation
import Testing
@testable import freebnb

// MARK: - Error mapping (pure, runs everywhere)

struct AuthErrorMappingTests {
    private func map(_ code: AuthErrorCode) -> AuthError {
        AuthManager.emailAuthError(from: NSError(domain: AuthErrorDomain, code: code.rawValue))
    }

    @Test func mapsEachFirebaseCodeToItsUserFacingCase() {
        #expect(map(.emailAlreadyInUse) == .emailInUse)
        #expect(map(.invalidEmail) == .invalidEmail)
        #expect(map(.weakPassword) == .weakPassword)
        #expect(map(.wrongPassword) == .wrongPassword)
        // Firebase reports a bad password as invalidCredential when email
        // enumeration protection is on, so both must land on the same message.
        #expect(map(.invalidCredential) == .wrongPassword)
        #expect(map(.userNotFound) == .userNotFound)
    }

    @Test func anyOtherCodeFallsBackToTheGenericFailure() {
        #expect(map(.networkError) == .signInFailed)
    }
}

// MARK: - Auth flows against the emulator

extension EmulatorBackedTests {
    // Nested in EmulatorBackedTests, which supplies both traits: the opt-in gate
    // and the serialization these need to not trip over
    // FirestoreHomesRepositoryEmulatorTests on the shared Auth session.
    @Suite
    struct AuthEmulatorTests {

        private var auth: Auth { EmulatorSupport.auth }

        private func freshEmail(_ tag: String) -> String {
            "\(tag)-\(UUID().uuidString.prefix(8))@emulator.test"
        }

        // Registration is create + profile stamp: the account exists, carries the
        // display name, and derives as an email member (not a guest).
        @Test func registrationCreatesAnEmailMemberWithADisplayName() async throws {
            try? auth.signOut()
            let result = try await auth.createUser(withEmail: freshEmail("reg"), password: "password123")
            let change = result.user.createProfileChangeRequest()
            change.displayName = "New Member"
            try await change.commitChanges()
            // commitChanges persists the name to the backend but does not reliably
            // refresh the in-memory user (especially against the emulator); reload it
            // before reading the display name back.
            try await result.user.reload()

            #expect(AuthManager.method(for: result.user) == .email)
            #expect(result.user.displayName == "New Member")
        }

        // The real SDK error for a duplicate email must still map to .emailInUse —
        // this is the integration half of AuthErrorMappingTests.
        @Test func duplicateRegistrationSurfacesEmailInUse() async throws {
            let email = freshEmail("dupe")
            _ = try await auth.createUser(withEmail: email, password: "password123")
            do {
                _ = try await auth.createUser(withEmail: email, password: "password456")
                Issue.record("duplicate registration unexpectedly succeeded")
            } catch {
                #expect(AuthManager.emailAuthError(from: error) == .emailInUse)
            }
        }

        @Test func wrongPasswordSurfacesWrongPassword() async throws {
            let email = freshEmail("pw")
            _ = try await auth.createUser(withEmail: email, password: "password123")
            try? auth.signOut()
            do {
                _ = try await auth.signIn(withEmail: email, password: "not-the-password")
                Issue.record("sign-in with the wrong password unexpectedly succeeded")
            } catch {
                #expect(AuthManager.emailAuthError(from: error) == .wrongPassword)
            }
        }

        // The Google path minus the GIDSignIn sheet: exchanging a Google credential
        // yields a user whose providerData derives as .google. The emulator accepts
        // an unsigned JSON claim set in place of a real ID token.
        @Test func googleCredentialDerivesTheGoogleMethod() async throws {
            try? auth.signOut()
            let claims = #"{"sub": "google-uid-1", "email": "google-member@emulator.test", "email_verified": true}"#
            let credential = GoogleAuthProvider.credential(withIDToken: claims, accessToken: "")
            let result = try await auth.signIn(with: credential)
            #expect(AuthManager.method(for: result.user) == .google)
        }

        @Test func anonymousSessionDerivesTheGuestMethod() async throws {
            try? auth.signOut()
            let result = try await auth.signInAnonymously()
            #expect(AuthManager.method(for: result.user) == .guest)
        }
    }
}
