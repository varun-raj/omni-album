//
//  CacheSettingsView.swift
//  OmniAlbum
//
//  Image cache usage and limits.
//

import SwiftUI
import Kingfisher

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
