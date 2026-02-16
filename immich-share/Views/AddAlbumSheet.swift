//
//  AddAlbumSheet.swift
//  immich-share
//
//  Dialog to paste an Immich share link and add the album.
//  Supports password-protected albums.
//

import SwiftUI

struct AddAlbumSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: AggregatorViewModel
    var onAdded: () -> Void

    @State private var urlText = ""
    @State private var passwordText = ""
    @State private var isValidating = false
    @State private var localError: String?
    @State private var requiresPassword = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case url, password
    }

    private var canAdd: Bool {
        let hasURL = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if requiresPassword {
            return hasURL && !passwordText.isEmpty
        }
        return hasURL
    }

    var body: some View {
        NavigationStack {
            Form {
                // URL Section
                Section {
                    TextField("Immich share link", text: $urlText, prompt: Text("https://…/share/…"))
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .url)
                        .submitLabel(requiresPassword ? .next : .done)
                        .onSubmit {
                            if requiresPassword {
                                focusedField = .password
                            } else if canAdd && !isValidating {
                                addAndDismissIfSuccess()
                            }
                        }
                        .disabled(requiresPassword)
                } header: {
                    Text("Share link")
                } footer: {
                    Text("Paste the full link you get when sharing an album from Immich.")
                }

                // Password Section (shown when required)
                if requiresPassword {
                    Section {
                        SecureField("Password", text: $passwordText)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.done)
                            .onSubmit {
                                if canAdd && !isValidating {
                                    addAndDismissIfSuccess()
                                }
                            }
                    } header: {
                        Text("Password")
                    } footer: {
                        Text("This album is password protected. Enter the password to access it.")
                    }
                }

                // Loading indicator
                if isValidating {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Validating link…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }

                // Error message
                if let error = localError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addAndDismissIfSuccess()
                    }
                    .disabled(!canAdd || isValidating)
                }
            }
            .onAppear {
                // Delay focus slightly to avoid keyboard animation issues
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .url
                }
            }
            .onChange(of: urlText) { _, _ in
                // Reset password requirement if URL changes
                if requiresPassword {
                    requiresPassword = false
                    passwordText = ""
                }
                localError = nil
            }
            .onChange(of: passwordText) { _, _ in
                localError = nil
            }
        }
    }

    private func addAndDismissIfSuccess() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        isValidating = true
        localError = nil

        Task {
            let password = requiresPassword ? passwordText : nil
            await viewModel.addAlbum(shareLinkURL: url, password: password)
            isValidating = false

            if let error = viewModel.errorMessage {
                // Check if error indicates password is required
                if isPasswordRequiredError(error) {
                    requiresPassword = true
                    localError = nil
                    viewModel.clearError()
                    // Focus password field
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        focusedField = .password
                    }
                } else {
                    localError = error
                }
            } else {
                onAdded()
                isPresented = false
            }
        }
    }

    /// Check if the error indicates a password is required
    private func isPasswordRequiredError(_ error: String) -> Bool {
        let lowercased = error.lowercased()
        // Immich returns 401 with "password required" or similar message
        return lowercased.contains("401") ||
               lowercased.contains("password") ||
               lowercased.contains("unauthorized") ||
               lowercased.contains("authentication")
    }
}
