//
//  AuthTests.swift
//  freebnbTests
//
//  Covers the pure sign-in derivations (SDK error → AuthError, provider → AuthMethod) plus
//  emulator checks that the real FirebaseAuth SDK still produces the codes and provider IDs
//  they expect. The UI is thin, so sign-in correctness lives here.
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
        // Bad password reports as invalidCredential when email enumeration protection is on; both must map alike.
        #expect(map(.invalidCredential) == .wrongPassword)
        #expect(map(.userNotFound) == .userNotFound)
    }

    @Test func anyOtherCodeFallsBackToTheGenericFailure() {
        #expect(map(.networkError) == .signInFailed)
    }
}

// MARK: - Auth flows against the emulator

extension EmulatorBackedTests {
    // Nested in EmulatorBackedTests, which supplies the opt-in gate and the serialization for the shared Auth
    // session.
    @Suite
    struct AuthEmulatorTests {

        private var auth: Auth { EmulatorSupport.auth }

        private func freshEmail(_ tag: String) -> String {
            "\(tag)-\(UUID().uuidString.prefix(8))@emulator.test"
        }

        // Registration is create + profile stamp: the account carries the display name and derives as an
        // email member.
        @Test func registrationCreatesAnEmailMemberWithADisplayName() async throws {
            try? auth.signOut()
            let result = try await auth.createUser(withEmail: freshEmail("reg"), password: "password123")
            let change = result.user.createProfileChangeRequest()
            change.displayName = "New Member"
            try await change.commitChanges()
            // commitChanges doesn't reliably refresh the in-memory user (esp. on the emulator); reload before
            // reading the name.
            try await result.user.reload()

            #expect(AuthManager.method(for: result.user) == .email)
            #expect(result.user.displayName == "New Member")
        }

        // The real SDK error for a duplicate email must still map to .emailInUse (the integration half of
        // AuthErrorMappingTests).
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

        // The Google path minus the GIDSignIn sheet: exchanging a credential yields a .google user; the
        // emulator accepts an unsigned JSON claim set.
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
