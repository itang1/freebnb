//
//  AuthManager.swift
//  freebnb
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import SwiftUI

enum AuthMethod {
    case apple, guest, none
}

class AuthManager: NSObject, ObservableObject {
    @Published var isSignedIn = false
    @Published var isLoading = false
    @Published var authError: String?
    @Published var userID = ""
    @Published var userName = ""
    @Published var userEmail = ""
    @Published var authMethod: AuthMethod = .none

    private var currentNonce: String?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private let userNameKey = "userName"

    override init() {
        super.init()
        // Firebase fires this immediately with current state, so no separate restoreSession().
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async { self?.applyAuthState(user) }
        }
    }

    deinit {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    // MARK: - Single source of truth for auth state

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
            Task { @MainActor in authError = "Sign in was cancelled or returned an invalid token." }
            return
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        Task {
            await MainActor.run { isLoading = true }
            do {
                _ = try await Auth.auth().signIn(with: firebaseCredential)
                let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                    .compactMap { $0 }.joined(separator: " ")
                if !fullName.isEmpty {
                    UserDefaults.standard.set(fullName, forKey: userNameKey)
                }
                // The auth state listener will populate isSignedIn/userID/etc.
                await MainActor.run { isLoading = false }
            } catch {
                await MainActor.run {
                    isLoading = false
                    authError = "Sign in failed. Please try again."
                }
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
        Task {
            await MainActor.run { isLoading = true }
            do {
                _ = try await Auth.auth().signInAnonymously()
                await MainActor.run { isLoading = false }
            } catch {
                await MainActor.run {
                    isLoading = false
                    authError = "Could not continue as guest. Please try again."
                }
            }
        }
    }

    // MARK: - Sign out / delete

    func signOut() {
        UserDefaults.standard.removeObject(forKey: userNameKey)
        try? Auth.auth().signOut()
        // Listener will clear the rest.
    }

    func deleteAccount() {
        Task {
            do {
                try await Auth.auth().currentUser?.delete()
                await MainActor.run { UserDefaults.standard.removeObject(forKey: userNameKey) }
            } catch {
                await MainActor.run { authError = "Could not delete account. Please try again." }
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
