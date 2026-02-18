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

    // MARK: - Mode

    private enum AddMode: String, CaseIterable {
        case single = "Single"
        case bulk = "Bulk Import"
    }

    @State private var mode: AddMode = .single

    // MARK: - Single Mode State

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

    // MARK: - Bulk Mode State

    private struct BulkLineStatus: Identifiable {
        let id = UUID()
        let url: String
        var provider: PhotoProvider?
        var phase: Phase

        enum Phase {
            case adding
            case succeeded
            case failed(String)
            case unrecognized
        }
    }

    @State private var bulkText = ""
    @State private var bulkIsProcessing = false
    @State private var bulkLineStatuses: [BulkLineStatus] = []

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
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(AddMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch mode {
                case .single:
                    singleModeContent
                case .bulk:
                    bulkModeContent
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

    // MARK: - Single Mode Content

    @ViewBuilder
    private var singleModeContent: some View {
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

    // MARK: - Bulk Mode Content

    @ViewBuilder
    private var bulkModeContent: some View {
        Section {
            TextEditor(text: $bulkText)
                .frame(minHeight: 150)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(bulkIsProcessing)
        } header: {
            Text("Links")
        } footer: {
            Text("Paste one link per line. Providers are auto-detected.")
        }

        if !bulkLineStatuses.isEmpty {
            bulkLogSection
        }
    }

    // MARK: - Bulk Log

    private var bulkLogSection: some View {
        Section {
            ForEach(bulkLineStatuses) { entry in
                HStack(spacing: 10) {
                    Group {
                        switch entry.phase {
                        case .adding:
                            ProgressView()
                                .controlSize(.small)
                        case .succeeded:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        case .unrecognized:
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.url)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        switch entry.phase {
                        case .adding:
                            Text("Detected \(entry.provider?.displayName ?? "") — Adding…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .succeeded:
                            Text("Detected \(entry.provider?.displayName ?? "") — Added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .failed(let error):
                            Text("Detected \(entry.provider?.displayName ?? "") — \(error)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        case .unrecognized:
                            Text("Unrecognized link")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if !bulkIsProcessing {
                bulkSummaryRow
            }
        } header: {
            Text("Log")
        }
    }

    @ViewBuilder
    private var bulkSummaryRow: some View {
        let successCount = bulkLineStatuses.filter {
            if case .succeeded = $0.phase { return true }
            return false
        }.count
        let failCount = bulkLineStatuses.count - successCount

        HStack(spacing: 16) {
            if successCount > 0 {
                Label(
                    "\(successCount) added",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.footnote.weight(.medium))
            }
            if failCount > 0 {
                Label(
                    "\(failCount) failed",
                    systemImage: "xmark.circle.fill"
                )
                .foregroundStyle(.red)
                .font(.footnote.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
            switch mode {
            case .single:
                Button("Add") {
                    addAndDismissIfSuccess()
                }
                .disabled(!canAdd || isValidating)
            case .bulk:
                Button("Add All") {
                    addAllBulk()
                }
                .disabled(bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bulkIsProcessing)
            }
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

    // MARK: - Bulk Actions

    private func addAllBulk() {
        let lines = bulkText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        bulkIsProcessing = true
        bulkLineStatuses = []

        Task {
            for line in lines {
                let index = bulkLineStatuses.count

                // Detect provider
                guard let provider = ProviderRegistry.shared.detectProvider(from: line) else {
                    withAnimation {
                        bulkLineStatuses.append(BulkLineStatus(url: line, phase: .unrecognized))
                    }
                    continue
                }

                // Show "adding" state with detected provider
                withAnimation {
                    bulkLineStatuses.append(BulkLineStatus(url: line, provider: provider, phase: .adding))
                }

                // Add the album
                viewModel.clearError()
                await viewModel.addAlbum(shareLinkURL: line, provider: provider)

                withAnimation {
                    if let error = viewModel.errorMessage {
                        bulkLineStatuses[index].phase = .failed(error)
                        viewModel.clearError()
                    } else {
                        bulkLineStatuses[index].phase = .succeeded
                    }
                }
            }

            bulkIsProcessing = false

            let hasFailures = bulkLineStatuses.contains {
                switch $0.phase {
                case .failed, .unrecognized: return true
                default: return false
                }
            }

            if !hasFailures {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onAdded()
                isPresented = false
            } else {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                onAdded()
            }
        }
    }
}
