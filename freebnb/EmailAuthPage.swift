//
//  EmailAuthPage.swift
//  freebnb
//

import SwiftUI

struct EmailAuthPage: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var isSignUp = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Toggle
                Picker("Mode", selection: $isSignUp) {
                    Text("Sign In").tag(false)
                    Text("Create Account").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)

                VStack(spacing: 14) {
                    if isSignUp {
                        FloatingField(label: "Name", text: $name)
                    }
                    FloatingField(label: "Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    FloatingField(label: "Password", text: $password, isSecure: true)
                    if isSignUp {
                        FloatingField(label: "Confirm Password", text: $confirmPassword, isSecure: true)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    Text(isSignUp ? "Create Account" : "Sign In")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("AppTeal"))
                        .flippedPrimaryColor()
                        .cornerRadius(12)
                }
            }
            .padding(30)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(Color.creamWhite.ignoresSafeArea())
        .navigationTitle(isSignUp ? "Create Account" : "Sign In")
        .onChange(of: isSignUp) { _, _ in errorMessage = nil }
    }

    private func submit() {
        errorMessage = nil
        do {
            if isSignUp {
                try authManager.signUp(name: name, email: email, password: password, confirm: confirmPassword)
            } else {
                try authManager.signInWithEmail(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FloatingField: View {
    let label: String
    @Binding var text: String
    var isSecure = false
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        Group {
            if isSecure {
                SecureField(label, text: $text)
            } else {
                TextField(label, text: $text)
                    .keyboardType(keyboardType)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
    }
}

#Preview {
    NavigationStack {
        EmailAuthPage()
            .environmentObject(AuthManager())
    }
}
