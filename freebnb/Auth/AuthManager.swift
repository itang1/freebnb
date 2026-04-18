//
//  AuthManager.swift
//  freebnb
//

import AuthenticationServices
import SwiftUI

enum AuthMethod {
    case apple, guest, none
}

class AuthManager: NSObject, ObservableObject {
    @Published var isSignedIn = false
    @Published var userName = ""
    @Published var userEmail = ""
    @Published var authMethod: AuthMethod = .none

    private let appleUserIDKey = "appleUserID"
    private let userNameKey    = "userName"
    private let userEmailKey   = "userEmail"

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Session restore

    private func restoreSession() {
        guard let appleID = UserDefaults.standard.string(forKey: appleUserIDKey) else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleID) { [weak self] state, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if state == .authorized {
                    self.userName   = UserDefaults.standard.string(forKey: self.userNameKey) ?? ""
                    self.userEmail  = UserDefaults.standard.string(forKey: self.userEmailKey) ?? ""
                    self.authMethod = .apple
                    self.isSignedIn = true
                } else {
                    UserDefaults.standard.removeObject(forKey: self.appleUserIDKey)
                }
            }
        }
    }

    // MARK: - Sign in with Apple

    func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let credential = auth.credential as? ASAuthorizationAppleIDCredential
        else { return }

        UserDefaults.standard.set(credential.user, forKey: appleUserIDKey)

        let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        if !fullName.isEmpty { UserDefaults.standard.set(fullName, forKey: userNameKey) }
        if let email = credential.email, !email.isEmpty { UserDefaults.standard.set(email, forKey: userEmailKey) }

        DispatchQueue.main.async {
            self.userName   = UserDefaults.standard.string(forKey: self.userNameKey) ?? ""
            self.userEmail  = UserDefaults.standard.string(forKey: self.userEmailKey) ?? ""
            self.authMethod = .apple
            self.isSignedIn = true
        }
    }

    func updateName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: userNameKey)
        self.userName = trimmed
    }

    // MARK: - Guest

    func continueAsGuest() {
        authMethod = .guest
        isSignedIn = true
    }

    // MARK: - Sign out / delete

    func signOut() {
        clearLocalSession()
    }

    func deleteAccount() {
        // Today this only clears local state. When a backend is added,
        // this will also delete the server-side account.
        clearLocalSession()
    }

    private func clearLocalSession() {
        for key in [appleUserIDKey, userNameKey, userEmailKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        isSignedIn = false
        authMethod = .none
        userName   = ""
        userEmail  = ""
    }
}
