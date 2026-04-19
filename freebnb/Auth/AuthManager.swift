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
    private let userNameKey = "userName"

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Session restore

    private func restoreSession() {
        guard let user = Auth.auth().currentUser else { return }
        userID     = user.uid
        userName   = UserDefaults.standard.string(forKey: userNameKey) ?? user.displayName ?? ""
        userEmail  = user.email ?? ""
        authMethod = user.isAnonymous ? .guest : .apple
        isSignedIn = true
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
        else { return }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        Task {
            await MainActor.run { isLoading = true }
            do {
                let authResult = try await Auth.auth().signIn(with: firebaseCredential)
                let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                    .compactMap { $0 }.joined(separator: " ")
                if !fullName.isEmpty {
                    UserDefaults.standard.set(fullName, forKey: userNameKey)
                }
                await MainActor.run {
                    userID     = authResult.user.uid
                    userName   = UserDefaults.standard.string(forKey: userNameKey) ?? authResult.user.displayName ?? ""
                    userEmail  = authResult.user.email ?? ""
                    authMethod = .apple
                    isLoading  = false
                    isSignedIn = true
                }
            } catch {
                await MainActor.run {
                    isLoading  = false
                    authError  = "Sign in failed. Please try again."
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
                let result = try await Auth.auth().signInAnonymously()
                await MainActor.run {
                    userID     = result.user.uid
                    authMethod = .guest
                    isLoading  = false
                    isSignedIn = true
                }
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
        try? Auth.auth().signOut()
        clearLocalSession()
    }

    func deleteAccount() {
        Task { try? await Auth.auth().currentUser?.delete() }
        clearLocalSession()
    }

    private func clearLocalSession() {
        UserDefaults.standard.removeObject(forKey: userNameKey)
        isSignedIn = false
        authMethod = .none
        userID     = ""
        userName   = ""
        userEmail  = ""
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
