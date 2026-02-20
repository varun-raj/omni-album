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
                        Label("iCloud Sync", systemImage: "icloud")
                    }
                    Toggle(isOn: $wifiOnlyUpload) {
                        Label("Wi-Fi Only Uploads", systemImage: "wifi")
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
                        Label("Cache Settings", systemImage: "internaldrive")
                    }

                    NavigationLink {
                        UploadQueueView()
                    } label: {
                        HStack {
                            Label("Upload Queue", systemImage: "arrow.up.circle")
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
                        Label("Export Albums to CSV", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showingImportPicker = true
                    } label: {
                        Label("Import Albums from CSV", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export your album list to CSV for backup, or import from a previously exported file.")
                }

                // About Section
                Section("About") {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://micro.skcript.com/omni-album")!) {
                        HStack {
                            Label("OmniAlbum Website", systemImage: "globe")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://apps.apple.com/us/app/omni-album/id6759308996")!) {
                        HStack {
                            Label("View on App Store", systemImage: "apple.logo")
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
                        Label("Rate on App Store", systemImage: "star")
                    }

                    Link(destination: URL(string: "https://skcript-micro.featureos.app/b/omni-album")!) {
                        HStack {
                            Label("Send Feedback", systemImage: "envelope")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://twitter.com/immaborh")!) {
                        HStack {
                            Label("Follow on X", systemImage: "at")
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

        // Create CSV content with full share URL
        var csvContent = "albumName,shareLink,assetCount,allowUpload,allowDownload,provider\n"

        for album in albums {
            let escapedName = album.albumName.replacingOccurrences(of: "\"", with: "\"\"")
            let shareLink = reconstructShareURL(for: album)
            let escapedLink = shareLink.replacingOccurrences(of: "\"", with: "\"\"")
            let row = "\"\(escapedName)\",\"\(escapedLink)\",\(album.assetCount ?? 0),\(album.allowUpload),\(album.allowDownload),\(album.provider.rawValue)\n"
            csvContent.append(row)
        }

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

    /// Reconstruct the original share URL from stored baseURL, shareKey, and provider
    private func reconstructShareURL(for album: DisplayAlbum) -> String {
        switch album.provider {
        case .immich:
            return "\(album.baseURL)/share/\(album.shareKey)"
        case .nextcloud:
            return "\(album.baseURL)/apps/photos/public/\(album.shareKey)"
        case .photoprism:
            // shareKey is composite: "linkToken|previewToken|downloadToken|albumUID"
            let linkToken = album.shareKey.components(separatedBy: "|").first ?? album.shareKey
            return "\(album.baseURL)/s/\(linkToken)"
        case .lychee:
            return "\(album.baseURL)/gallery/\(album.shareKey)"
        case .ente:
            // shareKey is composite: "accessToken|base58Key"
            let parts = album.shareKey.components(separatedBy: "|")
            if parts.count >= 2 {
                return "https://albums.ente.io?t=\(parts[0])#\(parts[1])"
            }
            return "\(album.baseURL)/\(album.shareKey)"
        }
    }

    private func formatDateForFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
                let shareLinks = parseCSVShareLinks(content)

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

    /// Parse CSV and extract share links with their providers.
    /// Supports new format (albumName,shareLink,...,provider) and
    /// legacy format (albumName,baseURL,shareKey,albumId,...,provider).
    private func parseCSVShareLinks(_ content: String) -> [(String, PhotoProvider)] {
        var results: [(String, PhotoProvider)] = []
        let lines = content.components(separatedBy: .newlines)

        guard let header = lines.first else { return results }
        let headerFields = parseCSVLine(header).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let isNewFormat = headerFields.contains("sharelink")

        for (index, line) in lines.enumerated() {
            guard index > 0, !line.isEmpty else { continue }
            let fields = parseCSVLine(line)

            if isNewFormat {
                // New format: albumName,shareLink,assetCount,allowUpload,allowDownload,provider
                guard fields.count >= 2 else { continue }
                let shareLink = fields[1]
                guard !shareLink.isEmpty else { continue }

                // Detect provider from the link or from the CSV column
                let provider: PhotoProvider
                if fields.count >= 6, let p = PhotoProvider(rawValue: fields[5]) {
                    provider = p
                } else {
                    provider = detectProvider(from: shareLink) ?? .immich
                }
                results.append((shareLink, provider))
            } else {
                // Legacy format: albumName,baseURL,shareKey,albumId,assetCount,allowUpload,allowDownload,provider
                guard fields.count >= 4 else { continue }
                let baseURL = fields[1]
                let shareKey = fields[2]
                let provider = fields.count > 7 ? (PhotoProvider(rawValue: fields[7]) ?? .immich) : .immich

                // Reconstruct share URL from legacy fields
                let shareLink = reconstructShareURLFromFields(baseURL: baseURL, shareKey: shareKey, provider: provider)
                results.append((shareLink, provider))
            }
        }

        return results
    }

    /// Auto-detect provider from a share link URL
    private func detectProvider(from urlString: String) -> PhotoProvider? {
        for providerType in PhotoProvider.allCases {
            if let provider = ProviderRegistry.shared.provider(for: providerType),
               provider.canHandle(urlString: urlString) {
                return providerType
            }
        }
        return nil
    }

    /// Reconstruct share URL from legacy CSV fields
    private func reconstructShareURLFromFields(baseURL: String, shareKey: String, provider: PhotoProvider) -> String {
        switch provider {
        case .immich:
            return "\(baseURL)/share/\(shareKey)"
        case .nextcloud:
            return "\(baseURL)/apps/photos/public/\(shareKey)"
        case .photoprism:
            let linkToken = shareKey.components(separatedBy: "|").first ?? shareKey
            return "\(baseURL)/s/\(linkToken)"
        case .lychee:
            return "\(baseURL)/gallery/\(shareKey)"
        case .ente:
            let parts = shareKey.components(separatedBy: "|")
            if parts.count >= 2 {
                return "https://albums.ente.io?t=\(parts[0])#\(parts[1])"
            }
            return "\(baseURL)/\(shareKey)"
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }
        }
        fields.append(currentField)

        return fields
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
        #if os(iOS)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            // Walk to the topmost presented controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
        #endif
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

// MARK: - Cache Settings View

struct CacheSettingsView: View {
    @State private var diskCacheSize: String = "Calculating..."
    @State private var memoryCacheSize: String = "Calculating..."
    @State private var isClearing = false

    var body: some View {
        List {
            // Current Usage
            Section {
                HStack {
                    Label("Disk Cache", systemImage: "internaldrive")
                    Spacer()
                    Text(diskCacheSize)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Memory Cache", systemImage: "memorychip")
                    Spacer()
                    Text(memoryCacheSize)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    clearCache()
                } label: {
                    HStack {
                        Label("Clear All Cache", systemImage: "trash")
                        Spacer()
                        if isClearing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isClearing)
            } header: {
                Text("Current Usage")
            } footer: {
                Text("Images are cached locally for faster loading.")
            }

            // Cache Limits
            Section("Cache Limits") {
                HStack {
                    Label("Max Disk Cache", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(formatBytes(UInt64(ImageCacheConfig.diskCacheLimit)))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Max Memory Cache", systemImage: "arrow.up.circle")
                    Spacer()
                    Text(formatBytes(UInt64(ImageCacheConfig.memoryCacheLimit)))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Expiration", systemImage: "clock")
                    Spacer()
                    Text("\(ImageCacheConfig.cacheExpirationDays) days")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cache Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            calculateCacheSize()
        }
        .refreshable {
            calculateCacheSize()
        }
    }

    private func calculateCacheSize() {
        ImageCache.default.calculateDiskStorageSize { result in
            switch result {
            case .success(let size):
                DispatchQueue.main.async {
                    diskCacheSize = formatBytes(UInt64(size))
                }
            case .failure:
                DispatchQueue.main.async {
                    diskCacheSize = "Unknown"
                }
            }
        }

        memoryCacheSize = "Up to \(formatBytes(UInt64(ImageCacheConfig.memoryCacheLimit)))"
    }

    private func clearCache() {
        isClearing = true

        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache {
            DispatchQueue.main.async {
                isClearing = false
                diskCacheSize = "0 B"
                memoryCacheSize = "0 B"

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    calculateCacheSize()
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Upload Queue View (Full Page)

struct UploadQueueView: View {
    @ObservedObject private var uploadService = UploadQueueService.shared

    private var groupedUploads: [(String, [UploadTask])] {
        let grouped = Dictionary(grouping: uploadService.queue) { $0.status }
        var result: [(String, [UploadTask])] = []

        if let uploading = grouped[.uploading], !uploading.isEmpty {
            result.append(("Uploading", uploading))
        }
        if let pending = grouped[.pending], !pending.isEmpty {
            result.append(("Pending", pending))
        }
        if let failed = grouped[.failed], !failed.isEmpty {
            result.append(("Failed", failed))
        }
        if let completed = grouped[.completed], !completed.isEmpty {
            result.append(("Completed", completed))
        }

        return result
    }

    var body: some View {
        Group {
            if uploadService.queue.isEmpty {
                ContentUnavailableView {
                    Label("No Uploads", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Photos you upload will appear here.")
                }
            } else {
                List {
                    ForEach(groupedUploads, id: \.0) { section, tasks in
                        Section(section) {
                            ForEach(tasks) { uploadTask in
                                UploadQueueTaskRow(uploadTask: uploadTask)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Upload Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !uploadService.queue.isEmpty {
                    Menu {
                        if uploadService.failedCount > 0 {
                            Button {
                                uploadService.retryFailed()
                            } label: {
                                Label("Retry Failed", systemImage: "arrow.clockwise")
                            }
                        }

                        if uploadService.queue.contains(where: { $0.status == .completed }) {
                            Button {
                                uploadService.clearCompleted()
                            } label: {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            uploadService.clearAll()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

#if os(iOS)
import StoreKit
#endif

#Preview {
    SettingsView()
}
