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

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

#if canImport(UIKit)
import UIKit
#endif

enum AuthMethod {
    case apple, google, email, guest, none
}

enum AuthError: LocalizedError, Equatable {
    case cancelled
    case invalidToken
    case signInFailed
    case deleteFailed
    case reauthRequired
    case nonceGenerationFailed
    case emailInUse
    case invalidEmail
    case weakPassword
    case wrongPassword
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .cancelled:             return nil
        case .invalidToken:          return "Sign in returned an invalid token."
        case .signInFailed:          return "Sign in failed. Please try again."
        case .deleteFailed:          return "Could not delete account. Please try again."
        case .reauthRequired:        return "Please sign in again to delete your account."
        case .nonceGenerationFailed: return "Could not prepare sign in. Please try again."
        case .emailInUse:            return "That email is already registered. Try signing in instead."
        case .invalidEmail:          return "Enter a valid email address."
        case .weakPassword:          return "Password must be at least 6 characters."
        case .wrongPassword:         return "Incorrect email or password."
        case .userNotFound:          return "No account found for that email."
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
    // `nonisolated(unsafe)` because `deinit` is nonisolated and must remove
    // the listener. Only assigned from @MainActor contexts, and
    // `Auth.removeStateDidChangeListener(_:)` is thread-safe.
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

    // The seeded guest-tester account's fixed uid (scripts/seed_test_data.js),
    // signed into via the DEBUG-only "Sign in as guest" button. Recognizing it
    // here — rather than deriving `.guest` purely from `isAnonymous` — lets
    // that button exercise the same restricted guest UI a true anonymous
    // session used to, without the app ever creating disposable, unconnected
    // Firebase Auth users. No real Sign in with Apple uid can ever equal this
    // fixed string, so the check is harmless outside DEBUG.
    static let guestTesterUID = "seed-guest-tester"

    // MARK: - Single source of truth

    private func applyAuthState(_ user: User?) {
        if let user {
            userID     = user.uid
            userEmail  = user.email ?? ""
            authMethod = Self.method(for: user)
            isSignedIn = true
        } else {
            userID     = ""
            userEmail  = ""
            authMethod = .none
            isSignedIn = false
        }
        // Attribute crash reports and analytics to the current user (A6).
        Telemetry.setUserID(user?.uid)
    }

    // Derives the sign-in method from Firebase's provider data rather than
    // assuming Apple, so Google, email/password, and the seeded guest tester
    // each surface correctly in the UI. The guest tester keeps its special case
    // (see `guestTesterUID`); everything else is read from `providerData`.
    // `nonisolated` (with `emailAuthError` below): a pure function of its
    // argument, so tests can call it without hopping onto the main actor.
    nonisolated static func method(for user: User) -> AuthMethod {
        if user.isAnonymous || user.uid == Self.guestTesterUID { return .guest }
        let providers = Set(user.providerData.map(\.providerID))
        if providers.contains("apple.com")  { return .apple }
        if providers.contains("google.com") { return .google }
        if providers.contains("password")   { return .email }
        return .apple
    }

    // MARK: - Sign in with Apple

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try randomNonceString()
            currentNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)
        } catch {
            log.error("nonce generation failed: \(error.localizedDescription, privacy: .public)")
            authError = .nonceGenerationFailed
        }
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
                    if let anon = Auth.auth().currentUser, anon.isAnonymous {
                        do {
                            _ = try await anon.link(with: firebaseCredential)
                        } catch let linkError as NSError
                            where linkError.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                            _ = try await Auth.auth().signIn(with: firebaseCredential)
                        }
                    } else {
                        _ = try await Auth.auth().signIn(with: firebaseCredential)
                    }
                    if !fullName.isEmpty {
                        UserDefaults.standard.set(fullName, forKey: UserDefaultsKey.userName)
                    }
                    Telemetry.log(.signInCompleted, parameters: ["method": "apple"])
                } catch {
                    log.error("apple sign in failed: \(error.localizedDescription, privacy: .public)")
                    Telemetry.log(.signInFailed, parameters: ["method": "apple"])
                    authError = .signInFailed
                }
            }
        }
    }

    // MARK: - Sign in with Google

#if canImport(GoogleSignIn)
    /// Presents Google's sign-in sheet, then exchanges the returned tokens for a
    /// Firebase credential. Requires the GoogleSignIn SDK and the reversed client
    /// ID URL scheme (see the manual setup notes); guarded by `canImport` so the
    /// project still builds before the package is added.
    func signInWithGoogle() {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            log.error("google sign in: missing Firebase clientID (GoogleService-Info.plist)")
            authError = .signInFailed
            return
        }
        guard let presenter = Self.topViewController() else {
            log.error("google sign in: no presenting view controller")
            authError = .signInFailed
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                guard let idToken = result.user.idToken?.tokenString else {
                    authError = .invalidToken
                    return
                }
                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken,
                    accessToken: result.user.accessToken.tokenString
                )
                _ = try await Auth.auth().signIn(with: credential)
                Telemetry.log(.signInCompleted, parameters: ["method": "google"])
            } catch let error as NSError where error.code == GIDSignInError.canceled.rawValue {
                return
            } catch {
                log.error("google sign in failed: \(error.localizedDescription, privacy: .public)")
                Telemetry.log(.signInFailed, parameters: ["method": "google"])
                authError = .signInFailed
            }
        }
    }
#endif

    // MARK: - Email / password

    /// Signs an existing user in with an email and password.
    func signIn(withEmail email: String, password: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                _ = try await Auth.auth().signIn(withEmail: email, password: password)
                Telemetry.log(.signInCompleted, parameters: ["method": "email"])
            } catch {
                authError = Self.emailAuthError(from: error)
                Telemetry.log(.signInFailed, parameters: ["method": "email"])
                log.error("email sign in failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Creates a new email/password account, optionally stamping a display name.
    func register(withEmail email: String, password: String, displayName: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await Auth.auth().createUser(withEmail: email, password: password)
                if !name.isEmpty {
                    let change = result.user.createProfileChangeRequest()
                    change.displayName = name
                    try? await change.commitChanges()
                    UserDefaults.standard.set(name, forKey: UserDefaultsKey.userName)
                }
                Telemetry.log(.signInCompleted, parameters: ["method": "email"])
            } catch {
                authError = Self.emailAuthError(from: error)
                Telemetry.log(.signInFailed, parameters: ["method": "email"])
                log.error("email registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // Maps a FirebaseAuth error into a user-facing `AuthError`, so the email form
    // can show "that email is already registered" instead of a raw SDK message.
    nonisolated static func emailAuthError(from error: Error) -> AuthError {
        switch (error as NSError).code {
        case AuthErrorCode.emailAlreadyInUse.rawValue: return .emailInUse
        case AuthErrorCode.invalidEmail.rawValue:      return .invalidEmail
        case AuthErrorCode.weakPassword.rawValue:      return .weakPassword
        case AuthErrorCode.wrongPassword.rawValue,
             AuthErrorCode.invalidCredential.rawValue: return .wrongPassword
        case AuthErrorCode.userNotFound.rawValue:      return .userNotFound
        default:                                       return .signInFailed
        }
    }

    // MARK: - Debug sign-in (emulator only)

    #if DEBUG
    /// Email/password sign-in for the seeded development accounts (devna, the
    /// guest tester).
    ///
    /// Compile-gated to DEBUG *and* refused unless this process is pointed at the
    /// Auth emulator. A hardcoded credential that only ever reaches localhost is
    /// not a backdoor into production, so weakening one guard is not enough to
    /// turn it into one.
    func signInWithEmail(_ email: String, password: String) {
        guard EmulatorEnvironment.isActive else {
            log.error("debug sign in refused: not running against the Auth emulator")
            authError = .signInFailed
            return
        }
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                _ = try await Auth.auth().signIn(withEmail: email, password: password)
            } catch {
                log.error("debug sign in failed: \(error.localizedDescription, privacy: .public)")
                authError = .signInFailed
            }
        }
    }
    #endif

    // MARK: - Sign out / delete

    func signOut() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.userName)
        do { try Auth.auth().signOut() }
        catch { log.error("sign out failed: \(error.localizedDescription, privacy: .public)") }
    }

    func deleteAccount() async {
        guard let user = Auth.auth().currentUser else { return }
        // Captured before the delete, which is the last moment this is readable.
        let userID = user.uid
        isLoading = true
        defer { isLoading = false }
        do {
            if authMethod == .apple {
                try await revokeAppleAndReauthenticate(user: user)
            }
            // Delete only the Auth user here. The `onUserDeleted` Cloud Function
            // owns the full data cascade (listings, profile, messages, stay
            // requests, friend edges, private location, storage photos), so the
            // client no longer soft-deletes listings or removes the profile
            // itself. Doing so client-side left a partial-failure window: if
            // `user.delete()` threw after those writes, the account survived with
            // its data half-gone (L8). One deletion, one owner.
            try await user.delete()
            UserDefaults.standard.removeObject(forKey: UserDefaultsKey.userName)
            // `onUserDeleted` cannot reach this device. An unfinished listing draft
            // holds the host's street address, so the one copy the cascade can't
            // see has to go here (feature 13).
            ListingDraftStore().clear(userID: userID)
        } catch AuthError.cancelled {
            return
        } catch let error as NSError where error.code == AuthErrorCode.requiresRecentLogin.rawValue {
            // Google/email deletes can require a fresh login (Apple is reauthed
            // above). Ask the user to sign in again rather than failing opaquely.
            authError = .reauthRequired
        } catch {
            log.error("delete account failed: \(error.localizedDescription, privacy: .public)")
            authError = .deleteFailed
        }
    }

    // Apple requires revokeToken with a fresh authorization code. The code expires in
    // ~5 minutes, so we re-run Sign in with Apple at delete time to get a usable one,
    // reauthenticate, then revoke before deleting the user.
    private func revokeAppleAndReauthenticate(user: User) async throws {
        let rawNonce = try randomNonceString()
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

    private func randomNonceString(length: Int = 32) throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard errorCode == errSecSuccess else {
            throw AuthError.nonceGenerationFailed
        }
        // 64-char set keeps `UInt8 % 64` unbiased (256 / 64 = 4 evenly).
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Presentation helper

    // The frontmost view controller, used as the presenter for Google's sign-in
    // sheet. Apple's flow supplies its own anchor via the coordinator, so this is
    // only needed on platforms with UIKit.
#if canImport(UIKit)
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
#endif
}
