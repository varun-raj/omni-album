//
//  AddImmichAccountSheet.swift
//  OmniAlbum
//
//  Sign in to an Immich server. Run it again for another server, or another user on the same one:
//  every account is kept, each with its own library.
//

import SwiftUI

struct AddImmichAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case server, email, password }

    private var canSignIn: Bool { !server.isEmpty && !email.isEmpty && !password.isEmpty && !isSigningIn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your photos and albums are copied to this device once, then only changes sync. You can add as many accounts as you like.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    field("Server", symbol: "server.rack") {
                        TextField("https://photos.example.com", text: $server)
                            .textContentType(.URL).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .server)
                            .submitLabel(.next).onSubmit { focused = .email }
                    }
                    field("Email", symbol: "envelope") {
                        TextField("you@example.com", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .email)
                            .submitLabel(.next).onSubmit { focused = .password }
                    }
                    field("Password", symbol: "lock") {
                        SecureField("Password", text: $password).textContentType(.password)
                            .focused($focused, equals: .password)
                            .submitLabel(.go).onSubmit { if canSignIn { signIn() } }
                    }

                    Text("Syncing needs a normal sign-in. Immich doesn't allow API keys to sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 16))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if isSigningIn { ProgressView().tint(.white) }
                        Text(isSigningIn ? "Signing in…" : "Sign In").font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!canSignIn)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle("Add Immich Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = .server }
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await ImmichHub.shared.signIn(server: server, email: email, password: password)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    private func field<Content: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        }
    }
}
