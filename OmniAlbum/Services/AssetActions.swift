//
//  AssetActions.swift
//  OmniAlbum
//
//  Share and save-to-Photos for an asset, used by the viewer and the grid's long-press menu.
//

import Foundation
import Photos

@MainActor
enum AssetActions {
    /// The asset's original bytes (decrypted for Ente) in a temp file named like the asset.
    /// Downloads straight to disk, so large videos don't sit in memory. Falls back from the original
    /// to smaller renditions if the server refuses it.
    static func originalFile(for asset: Asset, viewModel: AlbumDetailViewModel) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(asset.originalFileName)

        if let decrypted = try await viewModel.loadImageData(for: asset, variant: .original) {
            try decrypted.write(to: file)
            return file
        }

        let candidates: [URL?] = viewModel.isVideo(asset)
            ? [viewModel.videoPlaybackURL(for: asset), viewModel.originalURL(for: asset)]
            : [viewModel.originalURL(for: asset), viewModel.previewURL(for: asset), viewModel.thumbnailURL(for: asset)]

        var lastError: Error = URLError(.badURL)
        for url in candidates.compactMap({ $0 }) {
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: downloaded, to: file)
                return file
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func share(_ asset: Asset, viewModel: AlbumDetailViewModel) async throws {
        let file = try await originalFile(for: asset, viewModel: viewModel)
        ShareHelper.share(items: [file])
    }

    static func saveToPhotos(_ asset: Asset, viewModel: AlbumDetailViewModel) async throws {
        let file = try await originalFile(for: asset, viewModel: viewModel)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let isVideo = viewModel.isVideo(asset)
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
        }
    }
}
