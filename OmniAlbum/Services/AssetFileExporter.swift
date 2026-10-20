//
//  AssetFileExporter.swift
//  OmniAlbum
//
//  Copies a PHAsset's bytes to a temp file without holding them in memory, so
//  uploads of large videos/RAWs don't blow the memory limit.
//

import Foundation
import Photos
import UniformTypeIdentifiers

enum AssetFileExporter {
    struct Exported {
        let url: URL
        let mimeType: String
    }

    /// Exports the edited rendition when one exists, else the original. Caller deletes `url`.
    static func export(_ asset: PHAsset) async throws -> Exported {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferred.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
            throw ImmichUploadError.dataLoadFailed
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)

        let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType
            ?? UTType(filenameExtension: ext)?.preferredMIMEType
            ?? (asset.mediaType == .video ? "video/mp4" : "image/jpeg")
        return Exported(url: url, mimeType: mime)
    }
}
