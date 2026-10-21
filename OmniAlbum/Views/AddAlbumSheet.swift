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
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Mode", selection: $mode) {
                        ForEach(AddMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .single:
                        singleModeContent
                    case .bulk:
                        bulkModeContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: mode)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { primaryButton }
            .navigationTitle("Add Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .url
                }
            }
            .onChange(of: urlText) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let detected = ProviderRegistry.shared.detectProvider(from: trimmed) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedProvider = detected }
                }
                requiresPassword = false
                localError = nil
            }
            .onChange(of: passwordText) { _, _ in
                localError = nil
            }
        }
    }

    // MARK: - Building blocks

    /// Rounded, shadowless container used for every field.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
    }

    private func field<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Primary button

    private var primaryButton: some View {
        let isSingle = mode == .single
        let busy = isSingle ? isValidating : bulkIsProcessing
        let enabled = isSingle
            ? (canAdd && !isValidating)
            : (!bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bulkIsProcessing)

        return Button {
            if isSingle { addAndDismissIfSuccess() } else { addAllBulk() }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(busy ? (isSingle ? "Validating…" : "Adding…") : (isSingle ? "Add Album" : "Add All"))
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!enabled)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Single Mode Content

    @ViewBuilder
    private var singleModeContent: some View {
        linkSection
        providerSection
        if selectedProvider == .immich && !requiresPassword {
            passwordField(title: "Password", placeholder: "Optional", footer: "If the share link is password protected, enter the password here.")
        }
        if requiresPassword {
            passwordField(title: "Password", placeholder: "Required", footer: "This album is password protected. Enter the password to access it.")
        }
        if let error = localError {
            errorBanner(error)
        }
    }

    // MARK: - Share Link

    private var linkSection: some View {
        field("Share link", footer: linkFooterText) {
            card {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Share link", text: $urlText, prompt: Text("https://…"))
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
                    if urlText.isEmpty {
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { urlText = first }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    } else if !requiresPassword {
                        Button {
                            urlText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel("Clear link")
                    }
                }
            }
        }
    }

    private var linkFooterText: String {
        if let provider = selectedProvider {
            return provider.linkFooter
        }
        return "Paste a shared album link from any supported service."
    }

    // MARK: - Provider

    private var providerSection: some View {
        field("Service", footer: "Auto-detected from the link, or choose manually.") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PhotoProvider.allCases, id: \.self) { provider in
                        providerTile(provider)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private func providerTile(_ provider: PhotoProvider) -> some View {
        let selected = selectedProvider == provider
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedProvider = provider }
        } label: {
            VStack(spacing: 8) {
                if let logoAsset = provider.logoAssetName {
                    Image(logoAsset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .clipShape(.rect(cornerRadius: 9))
                } else {
                    Image(systemName: provider.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(provider.accentColor, in: .rect(cornerRadius: 9))
                }
                Text(provider.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 84)
            .padding(.vertical, 12)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 20)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Password

    private func passwordField(title: String, placeholder: String, footer: String) -> some View {
        field(title, footer: footer) {
            card {
                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                    SecureField(title, text: $passwordText, prompt: Text(placeholder))
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit {
                            if canAdd && !isValidating {
                                addAndDismissIfSuccess()
                            }
                        }
                }
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error)
                .font(.footnote)
        }
        .foregroundStyle(.red)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 16))
    }

    // MARK: - Bulk Mode Content

    @ViewBuilder
    private var bulkModeContent: some View {
        field("Links", footer: "Paste one link per line. Providers are auto-detected.") {
            card {
                TextEditor(text: $bulkText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(bulkIsProcessing)
                    .overlay(alignment: .topLeading) {
                        if bulkText.isEmpty {
                            Text("https://…")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }

        if !bulkLineStatuses.isEmpty {
            bulkLogSection
        }
    }

    // MARK: - Bulk Log

    private var bulkLogSection: some View {
        field("Log") {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bulkLineStatuses) { entry in
                        bulkRow(entry)
                    }
                    if !bulkIsProcessing {
                        bulkSummaryRow
                    }
                }
            }
        }
    }

    private func bulkRow(_ entry: BulkLineStatus) -> some View {
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
                Label("\(successCount) added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote.weight(.medium))
            }
            if failCount > 0 {
                Label("\(failCount) failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
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
