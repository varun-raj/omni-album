//
//  SettingsView.swift
//  OmniAlbum
//
//  Settings screen with organized sections for sync, cache, uploads, and about.
//

import SwiftUI
import Kingfisher
import UniformTypeIdentifiers

// MARK: - User Defaults Keys

enum SettingsKeys {
    static let iCloudSyncEnabled = "iCloudSyncEnabled"
    static let wifiOnlyUpload = "wifiOnlyUpload"
}

// MARK: - Settings row label

/// iOS-Settings-style label: white symbol on a small rounded colour square.
private struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: .rect(cornerRadius: 7))
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage(SettingsKeys.iCloudSyncEnabled) private var iCloudSyncEnabled = true
    @AppStorage(SettingsKeys.wifiOnlyUpload) private var wifiOnlyUpload = false
    @ObservedObject private var uploadService = UploadQueueService.shared

    @State private var showingImportPicker = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var importSuccess = false
    @State private var importedCount = 0

    var body: some View {
        NavigationStack {
            List {
                // Sync Section
                Section {
                    Toggle(isOn: $iCloudSyncEnabled) {
                        SettingsLabel("iCloud Sync", symbol: "icloud", color: .blue)
                    }
                    Toggle(isOn: $wifiOnlyUpload) {
                        SettingsLabel("Wi-Fi Only Uploads", symbol: "wifi", color: .green)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync your album list across all your devices using iCloud. Wi-Fi only uploads will pause uploads when on cellular data.")
                }

                // Storage Section
                Section("Storage") {
                    NavigationLink {
                        CacheSettingsView()
                    } label: {
                        SettingsLabel("Cache Settings", symbol: "internaldrive", color: .gray)
                    }

                    NavigationLink {
                        UploadQueueView()
                    } label: {
                        HStack {
                            SettingsLabel("Upload Queue", symbol: "arrow.up.circle", color: .orange)
                            Spacer()
                            uploadStatusBadge
                        }
                    }
                }

                // Data Section
                Section {
                    Button {
                        exportAlbumsToCSV()
                    } label: {
                        SettingsLabel("Export Albums to CSV", symbol: "square.and.arrow.up", color: .indigo)
                    }

                    Button {
                        showingImportPicker = true
                    } label: {
                        SettingsLabel("Import Albums from CSV", symbol: "square.and.arrow.down", color: .indigo)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export your album list to CSV for backup, or import from a previously exported file.")
                }

                // About Section
                Section("About") {
                    HStack {
                        SettingsLabel("Version", symbol: "info.circle", color: .gray)
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://micro.skcript.com/omni-album")!) {
                        HStack {
                            SettingsLabel("OmniAlbum Website", symbol: "globe", color: .blue)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://apps.apple.com/us/app/omni-album/id6759308996")!) {
                        HStack {
                            SettingsLabel("View on App Store", symbol: "apple.logo", color: .black)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Feedback Section
                Section("Feedback") {
                    Button {
                        requestAppReview()
                    } label: {
                        SettingsLabel("Rate on App Store", symbol: "star", color: .yellow)
                    }

                    Link(destination: URL(string: "https://skcript-micro.featureos.app/b/omni-album")!) {
                        HStack {
                            SettingsLabel("Send Feedback", symbol: "envelope", color: .teal)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://twitter.com/immaborh")!) {
                        HStack {
                            SettingsLabel("Follow on X", symbol: "at", color: .black)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .alert("Import Error", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "Unknown error occurred")
            }
            .alert("Import Successful", isPresented: $importSuccess) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Successfully imported \(importedCount) album\(importedCount == 1 ? "" : "s").")
            }
        }
    }

    // MARK: - Export/Import Methods

    private func exportAlbumsToCSV() {
        let localService = LocalAlbumsService()
        let albums = localService.loadAlbums()

        guard !albums.isEmpty else {
            importError = "No albums to export"
            showingImportError = true
            return
        }

        let csvContent = AlbumCSV.export(albums)

        // Write to temp file and share
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "omnialbum-albums-\(formatDateForFilename()).csv"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
            presentShareSheet(for: fileURL)
        } catch {
            importError = "Failed to create export file: \(error.localizedDescription)"
            showingImportError = true
        }
    }

    private func formatDateForFilename() -> String {
        Formatters.fileDate.string(from: Date())
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Cannot access the selected file"
                showingImportError = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let shareLinks = AlbumCSV.parseShareLinks(content)

                guard !shareLinks.isEmpty else {
                    importError = "No valid share links found in the CSV file"
                    showingImportError = true
                    return
                }

                // Add albums via share links (validates against server)
                Task {
                    let viewModel = AggregatorViewModel()
                    // Wait for initial load so we can check duplicates
                    try? await Task.sleep(for: .seconds(0.5))

                    var addedCount = 0
                    let albumCountBefore = viewModel.albums.count
                    for (link, provider) in shareLinks {
                        let countBefore = viewModel.albums.count
                        await viewModel.addAlbum(shareLinkURL: link, provider: provider)
                        if viewModel.albums.count > countBefore {
                            addedCount += 1
                        }
                    }

                    importedCount = addedCount
                    importSuccess = true

                    // Post notification to refresh album list
                    NotificationCenter.default.post(name: .albumDataUpdated, object: nil)
                }

            } catch {
                importError = "Failed to read file: \(error.localizedDescription)"
                showingImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    @ViewBuilder
    private var uploadStatusBadge: some View {
        let pending = uploadService.pendingCount
        let failed = uploadService.failedCount

        HStack(spacing: 6) {
            if failed > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if pending > 0 || failed > 0 {
                Text("\(pending + failed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func presentShareSheet(for url: URL) {
        ShareHelper.share(items: [url])
    }

    private func requestAppReview() {
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            if #available(iOS 18.0, *) {
                // Use new StoreKit API for iOS 18+
                Task {
                    try? await AppStore.requestReview(in: scene)
                }
            } else {
                // Use legacy API for older iOS versions
                SKStoreReviewController.requestReview(in: scene)
            }
        }
        #endif
    }
}

#if os(iOS)
import StoreKit
#endif

#Preview {
    SettingsView()
}
