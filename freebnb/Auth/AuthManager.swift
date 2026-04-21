//
//  AuthManager.swift
//  freebnb
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import Observation
import SwiftUI
import os

enum AuthMethod {
    case apple, guest, none
}

enum AuthError: LocalizedError, Equatable {
    case cancelled
    case invalidToken
    case signInFailed
    case guestFailed
    case deleteFailed
    case reauthRequired

    var errorDescription: String? {
        switch self {
        case .cancelled:      return nil
        case .invalidToken:   return "Sign in returned an invalid token."
        case .signInFailed:   return "Sign in failed. Please try again."
        case .guestFailed:    return "Could not continue as guest. Please try again."
        case .deleteFailed:   return "Could not delete account. Please try again."
        case .reauthRequired: return "Please sign in again to delete your account."
        }
    }
}

@MainActor
@Observable
final class AuthManager {
    private(set) var isSignedIn = false
    private(set) var isLoading = false
    var authError: AuthError?
    private(set) var userID = ""
    private(set) var userEmail = ""
    private(set) var authMethod: AuthMethod = .none

    private var currentNonce: String?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let log = AppLog.logger("auth")

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.applyAuthState(user) }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Single source of truth

    private func applyAuthState(_ user: User?) {
        if let user {
            userID     = user.uid
            userEmail  = user.email ?? ""
            authMethod = user.isAnonymous ? .guest : .apple
            isSignedIn = true
        } else {
            userID     = ""
            userEmail  = ""
            authMethod = .none
            isSignedIn = false
        }
    }

    // MARK: - Sign in with Apple

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        let nonce = currentNonce
        currentNonce = nil

        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            log.error("apple authorization failed: \(error.localizedDescription, privacy: .public)")
            self.authError = .signInFailed
            return

        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let nonce,
                  let idTokenData = credential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8)
            else {
                authError = .invalidToken
                return
            }

            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")

            Task { @MainActor in
                isLoading = true
                defer { isLoading = false }
                do {
                    _ = try await Auth.auth().signIn(with: firebaseCredential)
                    if !fullName.isEmpty {
                        UserDefaults.standard.set(fullName, forKey: "userName")
                    }
                } catch {
                    log.error("apple sign in failed: \(error.localizedDescription, privacy: .public)")
                    authError = .signInFailed
                }
            }
        }
    }

    // MARK: - Guest

    func continueAsGuest() {
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                _ = try await Auth.auth().signInAnonymously()
            } catch {
                log.error("anonymous sign in failed: \(error.localizedDescription, privacy: .public)")
                authError = .guestFailed
            }
        }
    }

    // MARK: - Sign out / delete

    func signOut() {
        UserDefaults.standard.removeObject(forKey: "userName")
        do { try Auth.auth().signOut() }
        catch { log.error("sign out failed: \(error.localizedDescription, privacy: .public)") }
    }

    func deleteAccount() async {
        guard let user = Auth.auth().currentUser else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if authMethod == .apple {
                try await revokeAppleAndReauthenticate(user: user)
            }
            try await user.delete()
            UserDefaults.standard.removeObject(forKey: "userName")
        } catch AuthError.cancelled {
            return
        } catch {
            log.error("delete account failed: \(error.localizedDescription, privacy: .public)")
            authError = .deleteFailed
        }
    }

    // Apple requires revokeToken with a fresh authorization code. The code expires in
    // ~5 minutes, so we re-run Sign in with Apple at delete time to get a usable one,
    // reauthenticate, then revoke before deleting the user.
    private func revokeAppleAndReauthenticate(user: User) async throws {
        let rawNonce = randomNonceString()
        let coordinator = AppleSignInCoordinator()
        let authorization: ASAuthorization
        do {
            authorization = try await coordinator.signIn(nonce: sha256(rawNonce))
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw AuthError.cancelled
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = credential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8),
              let codeData = credential.authorizationCode,
              let authCode = String(data: codeData, encoding: .utf8)
        else {
            throw AuthError.invalidToken
        }
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )
        _ = try await user.reauthenticate(with: firebaseCredential)
        try await Auth.auth().revokeToken(withAuthorizationCode: authCode)
    }

    // MARK: - Nonce helpers

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
