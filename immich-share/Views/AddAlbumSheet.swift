//
//  AddAlbumSheet.swift
//  immich-share
//
//  Dialog to add an album: choose a provider, then paste a share link.
//  Supports password-protected albums.
//

import SwiftUI
import UIKit

struct AddAlbumSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: AggregatorViewModel
    var onAdded: () -> Void

    @State private var selectedProvider: PhotoProvider?
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
        guard let provider = selectedProvider, provider.isSupported else { return false }
        let hasURL = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if requiresPassword {
            return hasURL && !passwordText.isEmpty
        }
        return hasURL
    }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                if let provider = selectedProvider {
                    if provider.isSupported {
                        linkSection
                    } else {
                        comingSoonSection
                    }
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
            .onChange(of: selectedProvider) { _, _ in
                urlText = ""
                passwordText = ""
                requiresPassword = false
                localError = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .url
                }
            }
            .onChange(of: urlText) { _, _ in
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

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            ForEach(PhotoProvider.allCases, id: \.self) { provider in
                providerRow(provider)
            }
        } header: {
            Text("Service")
        } footer: {
            Text("Choose the photo service this album is hosted on.")
        }
    }

    private func providerRow(_ provider: PhotoProvider) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedProvider = provider
            }
            localError = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: provider.iconName)
                    .font(.title3)
                    .foregroundStyle(provider.accentColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(provider.isSupported ? .primary : .secondary)
                        if !provider.isSupported {
                            Text("Coming soon")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill.tertiary, in: .capsule)
                        }
                    }
                    Text(provider.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

    // MARK: - Link Section

    @ViewBuilder
    private var linkSection: some View {
        if let provider = selectedProvider {
            Section {
                TextField(
                    provider.linkPlaceholderLabel,
                    text: $urlText,
                    prompt: Text(provider.linkPlaceholder)
                )
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
                Text(provider.linkFooter)
            }
        }
    }

    // MARK: - Password Section

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

    // MARK: - Coming Soon Section

    private var comingSoonSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "hammer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Support for \(selectedProvider?.displayName ?? "this service") is coming in a future update.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
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
            let password = requiresPassword ? passwordText : nil
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
