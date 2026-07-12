//
//  EmailAuthView.swift
//  freebnb
//

import SwiftUI

/// Email + password sign-in and registration, presented as a sheet from the
/// welcome screen. Drives `AuthManager` directly; dismisses itself once a signed
/// in state arrives (ContentView swaps out the whole welcome flow at that point,
/// so this only needs to close the sheet).
struct EmailAuthView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    private enum Mode {
        case signIn, register
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case name, email, password
    }

    private var isRegistering: Bool { mode == .register }

    // Enough to enable the button; Firebase does the authoritative validation and
    // reports failures back through `authManager.authError`.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 6
            && (!isRegistering || !displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            && !authManager.isLoading
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Sign In").tag(Mode.signIn)
                        Text("Create Account").tag(Mode.register)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .onChange(of: mode) { _, _ in authManager.authError = nil }
                }

                Section {
                    if isRegistering {
                        TextField("Name", text: $displayName)
                            .textContentType(.name)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .email }
                            .accessibilityIdentifier("emailAuth.nameField")
                    }

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("emailAuth.emailField")

                    SecureField(isRegistering ? "Password (6+ characters)" : "Password",
                                text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .accessibilityIdentifier("emailAuth.passwordField")
                }

                if let error = authManager.authError, let description = error.errorDescription {
                    Section {
                        Text(description)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if authManager.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(isRegistering ? "Create Account" : "Sign In")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    .listRowBackground(canSubmit ? Color.accent : Color.accent.opacity(0.4))
                    .foregroundColor(.white)
                    .accessibilityIdentifier("emailAuth.submitButton")
                }
            }
            .navigationTitle(isRegistering ? "Create Account" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // ContentView switches away from the welcome flow the moment auth
            // state flips, so closing the sheet is all that's left to do.
            .onChange(of: authManager.isSignedIn) { _, signedIn in
                if signedIn { dismiss() }
            }
            .onAppear { authManager.authError = nil }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        if isRegistering {
            authManager.register(withEmail: email, password: password, displayName: displayName)
        } else {
            authManager.signIn(withEmail: email, password: password)
        }
    }
}

#Preview {
    EmailAuthView()
        .previewEnvironment()
}
