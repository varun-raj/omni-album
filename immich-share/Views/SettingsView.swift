//
//  SettingsView.swift
//  immich-share
//
//  Settings screen with organized sections for sync, cache, uploads, and about.
//

import SwiftUI
import Kingfisher
import UniformTypeIdentifiers

// MARK: - User Defaults Keys

enum SettingsKeys {
    static let iCloudSyncEnabled = "iCloudSyncEnabled"
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage(SettingsKeys.iCloudSyncEnabled) private var iCloudSyncEnabled = true
    @ObservedObject private var uploadService = UploadQueueService.shared

    @State private var showingExportSheet = false
    @State private var showingImportPicker = false
    @State private var exportURL: URL?
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
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync your album list across all your devices using iCloud.")
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

                    Link(destination: URL(string: "https://immich.app")!) {
                        HStack {
                            Label("Immich Website", systemImage: "globe")
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

                    Link(destination: URL(string: "https://github.com/anthropics/claude-code/issues")!) {
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
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
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

        // Create CSV content
        var csvContent = "albumName,baseURL,shareKey,albumId,assetCount,allowUpload\n"

        for album in albums {
            let escapedName = album.albumName.replacingOccurrences(of: "\"", with: "\"\"")
            let row = "\"\(escapedName)\",\"\(album.baseURL)\",\"\(album.shareKey)\",\"\(album.albumId)\",\(album.assetCount ?? 0),\(album.allowUpload)\n"
            csvContent.append(row)
        }

        // Write to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "immich-albums-\(formatDateForFilename()).csv"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showingExportSheet = true
        } catch {
            importError = "Failed to create export file: \(error.localizedDescription)"
            showingImportError = true
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
                let importedAlbums = parseCSV(content)

                guard !importedAlbums.isEmpty else {
                    importError = "No valid albums found in the CSV file"
                    showingImportError = true
                    return
                }

                // Add imported albums
                let localService = LocalAlbumsService()
                var addedCount = 0

                for album in importedAlbums {
                    // Check if album already exists
                    let existing = localService.loadAlbums()
                    if !existing.contains(where: { $0.id == album.id || $0.shareKey == album.shareKey }) {
                        localService.addAlbum(album)
                        addedCount += 1
                    }
                }

                importedCount = addedCount
                importSuccess = true

                // Post notification to refresh album list
                NotificationCenter.default.post(name: .albumDataUpdated, object: nil)

            } catch {
                importError = "Failed to read file: \(error.localizedDescription)"
                showingImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func parseCSV(_ content: String) -> [DisplayAlbum] {
        var albums: [DisplayAlbum] = []
        let lines = content.components(separatedBy: .newlines)

        // Skip header row
        for (index, line) in lines.enumerated() {
            guard index > 0, !line.isEmpty else { continue }

            let fields = parseCSVLine(line)
            guard fields.count >= 4 else { continue }

            let albumName = fields[0]
            let baseURL = fields[1]
            let shareKey = fields[2]
            let albumId = fields[3]
            let assetCount = fields.count > 4 ? Int(fields[4]) : nil
            let allowUpload = fields.count > 5 ? (fields[5] == "true" || fields[5] == "1") : false

            let album = DisplayAlbum(
                id: shareKey, // Use shareKey as ID
                albumName: albumName,
                albumThumbnailAssetId: nil,
                baseURL: baseURL,
                shareKey: shareKey,
                albumId: albumId,
                assetCount: assetCount,
                allowUpload: allowUpload
            )
            albums.append(album)
        }

        return albums
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
        let total = uploadService.queue.count

        if pending > 0 {
            Text("\(pending) uploading")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.blue, in: Capsule())
        } else if failed > 0 {
            Text("\(failed) failed")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.red, in: Capsule())
        } else if total > 0 {
            Text("\(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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

// MARK: - Share Sheet

#if os(iOS)
import StoreKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#Preview {
    SettingsView()
}
