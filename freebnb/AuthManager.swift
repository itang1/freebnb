//
//  AuthManager.swift
//  freebnb
//

import AuthenticationServices
import CommonCrypto
import Security
import SwiftUI

enum AuthMethod {
    case apple, email, guest, none
}

class AuthManager: NSObject, ObservableObject {
    @Published var isSignedIn = false
    @Published var userName = ""
    @Published var userEmail = ""
    @Published var authMethod: AuthMethod = .none

    private let appleUserIDKey  = "appleUserID"
    private let userNameKey     = "userName"
    private let userEmailKey    = "userEmail"
    private let emailAccountKey = "emailAccount"

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Session restore

    private func restoreSession() {
        if let appleID = UserDefaults.standard.string(forKey: appleUserIDKey) {
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
            return
        }
        if let savedEmail = UserDefaults.standard.string(forKey: emailAccountKey) {
            userName   = UserDefaults.standard.string(forKey: userNameKey) ?? ""
            userEmail  = savedEmail
            authMethod = .email
            isSignedIn = true
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

    // MARK: - Email / password

    enum EmailAuthError: LocalizedError {
        case emailInUse, invalidCredentials, emptyFields, passwordMismatch, securityError

        var errorDescription: String? {
            switch self {
            case .emailInUse:          return "An account with that email already exists."
            case .invalidCredentials:  return "Incorrect email or password."
            case .emptyFields:         return "Please fill in all fields."
            case .passwordMismatch:    return "Passwords do not match."
            case .securityError:       return "A security error occurred. Please try again."
            }
        }
    }

    func signUp(name: String, email: String, password: String, confirm: String) throws {
        guard !name.isEmpty, !email.isEmpty, !password.isEmpty else { throw EmailAuthError.emptyFields }
        guard password == confirm else { throw EmailAuthError.passwordMismatch }
        if let existing = UserDefaults.standard.string(forKey: emailAccountKey), existing == email {
            throw EmailAuthError.emailInUse
        }
        let salt = PasswordHasher.generateSalt()
        guard let hash = PasswordHasher.hash(password, salt: salt) else { throw EmailAuthError.securityError }
        var credential = salt
        credential.append(hash)
        Keychain.save(credential, account: email)

        UserDefaults.standard.set(email, forKey: emailAccountKey)
        UserDefaults.standard.set(name, forKey: userNameKey)
        UserDefaults.standard.set(email, forKey: userEmailKey)
        self.userName   = name
        self.userEmail  = email
        self.authMethod = .email
        self.isSignedIn = true
    }

    func signInWithEmail(email: String, password: String) throws {
        guard !email.isEmpty, !password.isEmpty else { throw EmailAuthError.emptyFields }
        guard let savedEmail = UserDefaults.standard.string(forKey: emailAccountKey),
              savedEmail == email else { throw EmailAuthError.invalidCredentials }
        guard let stored = Keychain.load(account: email),
              stored.count == PasswordHasher.saltLength + PasswordHasher.hashLength
        else { throw EmailAuthError.invalidCredentials }

        let salt       = stored.prefix(PasswordHasher.saltLength)
        let storedHash = stored.suffix(PasswordHasher.hashLength)
        guard let computed = PasswordHasher.hash(password, salt: Data(salt)),
              computed == Data(storedHash) else { throw EmailAuthError.invalidCredentials }

        self.userName   = UserDefaults.standard.string(forKey: userNameKey) ?? ""
        self.userEmail  = email
        self.authMethod = .email
        self.isSignedIn = true
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
        UserDefaults.standard.removeObject(forKey: appleUserIDKey)
        isSignedIn = false
        authMethod  = .none
        userName    = ""
        userEmail   = ""
    }

    func deleteAccount() {
        if let email = UserDefaults.standard.string(forKey: emailAccountKey) {
            Keychain.delete(account: email)
        }
        for key in [appleUserIDKey, emailAccountKey, userNameKey, userEmailKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        isSignedIn = false
        authMethod  = .none
        userName    = ""
        userEmail   = ""
    }
}

// MARK: - Keychain

private enum Keychain {
    static let service = "com.freebnb.emailAuth"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Password hashing (PBKDF2-SHA256)

private enum PasswordHasher {
    static let saltLength = 16
    static let hashLength = 32
    static let iterations: UInt32 = 100_000

    static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        return Data(bytes)
    }

    static func hash(_ password: String, salt: Data) -> Data? {
        guard let passwordData = password.data(using: .utf8) else { return nil }
        let passwordBytes = [UInt8](passwordData)
        let saltBytes     = [UInt8](salt)
        var derivedKey    = [UInt8](repeating: 0, count: hashLength)
        let status = passwordBytes.withUnsafeBytes { pwPtr in
            saltBytes.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordBytes.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derivedKey,
                    hashLength
                )
            }
        }
        return status == kCCSuccess ? Data(derivedKey) : nil
    }
}
