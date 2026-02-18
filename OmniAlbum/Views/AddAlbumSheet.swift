//
//  AddAlbumSheet.swift
//  OmniAlbum
//
//  Dialog to add an album: paste a share link, auto-detect provider,
//  and optionally enter a password.
//

import SwiftUI
import UIKit

struct AddAlbumSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: AggregatorViewModel
    var onAdded: () -> Void

    @State private var urlText = ""
    @State private var passwordText = ""
    @State private var isValidating = false
    @State private var localError: String?
    @State private var requiresPassword = false
    @State private var selectedProvider: PhotoProvider?
    @FocusState private var focusedField: Field?

    private enum Field {
        case url, password
    }

    private var canAdd: Bool {
        guard selectedProvider != nil else { return false }
        let hasURL = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasURL { return false }
        if requiresPassword { return !passwordText.isEmpty }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                providerSection
                if selectedProvider == .immich && !requiresPassword {
                    optionalPasswordSection
                }
                if requiresPassword {
                    passwordSection
                }
                if isValidating {
                    validatingSection
                }
                if let error = localError {
                    errorSection(error)
                }
            }
            .navigationTitle("Add album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .url
                }
            }
            .onChange(of: urlText) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let detected = ProviderRegistry.shared.detectProvider(from: trimmed) {
                    selectedProvider = detected
                }
                requiresPassword = false
                localError = nil
            }
            .onChange(of: passwordText) { _, _ in
                localError = nil
            }
        }
    }

    // MARK: - Share Link Section

    private var linkSection: some View {
        Section {
            TextField(
                "Share link",
                text: $urlText,
                prompt: Text("https://…")
            )
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .focused($focusedField, equals: .url)
            .submitLabel(requiresPassword || selectedProvider == .immich ? .next : .done)
            .onSubmit {
                if requiresPassword || selectedProvider == .immich {
                    focusedField = .password
                } else if canAdd && !isValidating {
                    addAndDismissIfSuccess()
                }
            }
            .disabled(requiresPassword)
        } header: {
            Text("Share link")
        } footer: {
            Text(linkFooterText)
        }
    }

    private var linkFooterText: String {
        if let provider = selectedProvider {
            return provider.linkFooter
        }
        return "Paste a shared album link from any supported service."
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            ForEach(PhotoProvider.allCases, id: \.self) { provider in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedProvider = provider
                    }
                } label: {
                    HStack(spacing: 12) {
                        if let logoAsset = provider.logoAssetName {
                            Image(logoAsset)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .clipShape(.rect(cornerRadius: 7))
                        } else {
                            Image(systemName: provider.iconName)
                                .font(.title3)
                                .foregroundStyle(provider.accentColor)
                                .frame(width: 32, height: 32)
                        }

                        Text(provider.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        if selectedProvider == provider {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.title3)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Service")
        } footer: {
            Text("Auto-detected from the link, or choose manually.")
        }
    }

    // MARK: - Optional Password Section (Immich only)

    private var optionalPasswordSection: some View {
        Section {
            SecureField("Password (optional)", text: $passwordText)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.done)
                .onSubmit {
                    if canAdd && !isValidating {
                        addAndDismissIfSuccess()
                    }
                }
        } header: {
            Text("Additional Options")
        } footer: {
            Text("If the share link is password protected, enter the password here.")
        }
    }

    // MARK: - Required Password Section (shown after 401)

    private var passwordSection: some View {
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

    // MARK: - Status Sections

    private var validatingSection: some View {
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

    private func errorSection(_ error: String) -> some View {
        Section {
            Text(error)
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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

    // MARK: - Actions

    private func addAndDismissIfSuccess() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, let provider = selectedProvider else { return }

        isValidating = true
        localError = nil

        Task {
            let password = passwordText.isEmpty ? nil : passwordText
            await viewModel.addAlbum(shareLinkURL: url, provider: provider, password: password)
            isValidating = false

            if let error = viewModel.errorMessage {
                if isPasswordRequiredError(error) {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.warning)
                    requiresPassword = true
                    localError = nil
                    viewModel.clearError()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        focusedField = .password
                    }
                } else {
                    localError = error
                }
            } else {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onAdded()
                isPresented = false
            }
        }
    }

    private func isPasswordRequiredError(_ error: String) -> Bool {
        let lowercased = error.lowercased()
        return lowercased.contains("401") ||
               lowercased.contains("password") ||
               lowercased.contains("unauthorized") ||
               lowercased.contains("authentication")
    }
}
