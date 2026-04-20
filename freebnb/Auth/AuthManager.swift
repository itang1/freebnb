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

    var errorDescription: String? {
        switch self {
        case .cancelled:     return "Sign in was cancelled."
        case .invalidToken:  return "Sign in returned an invalid token."
        case .signInFailed:  return "Sign in failed. Please try again."
        case .guestFailed:   return "Could not continue as guest. Please try again."
        case .deleteFailed:  return "Could not delete account. Please try again."
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
    private(set) var userName = ""
    private(set) var userEmail = ""
    private(set) var authMethod: AuthMethod = .none

    private var currentNonce: String?
    @ObservationIgnored nonisolated(unsafe) private var authHandle: AuthStateDidChangeListenerHandle?
    private let userNameKey = "userName"
    @ObservationIgnored private let log = Logger(subsystem: "com.freebnb.app", category: "auth")

    init() {
        // Firebase fires this immediately with the current user, so no separate restoreSession().
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
            userName   = UserDefaults.standard.string(forKey: userNameKey) ?? user.displayName ?? ""
            userEmail  = user.email ?? ""
            authMethod = user.isAnonymous ? .guest : .apple
            isSignedIn = true
        } else {
            userID     = ""
            userName   = ""
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
        guard case .success(let auth) = result,
              let credential = auth.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentNonce,
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
                    UserDefaults.standard.set(fullName, forKey: userNameKey)
                }
                // Auth state listener populates the rest.
            } catch {
                log.error("apple sign in failed: \(error.localizedDescription, privacy: .public)")
                authError = .signInFailed
            }
        }
    }

    func updateName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: userNameKey)
        userName = trimmed
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
        UserDefaults.standard.removeObject(forKey: userNameKey)
        do { try Auth.auth().signOut() }
        catch { log.error("sign out failed: \(error.localizedDescription, privacy: .public)") }
        // Listener clears published state.
    }

    func deleteAccount() {
        Task { @MainActor in
            do {
                try await Auth.auth().currentUser?.delete()
                UserDefaults.standard.removeObject(forKey: userNameKey)
            } catch {
                log.error("delete account failed: \(error.localizedDescription, privacy: .public)")
                authError = .deleteFailed
            }
        }
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
