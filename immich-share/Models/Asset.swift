//
//  Asset.swift
//  immich-share
//
//  Generic asset model used by all views. Provider-specific models (e.g. ImmichAsset)
//  are mapped to this type by their respective ShareLinkProvider implementations.
//

import Foundation

/// The type of media asset
enum AssetType: String, Codable, Sendable {
    case image
    case video
}

/// Generic EXIF metadata
struct AssetExif: Sendable {
    let make: String?
    let model: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Int?
    let exposureTime: String?
    let width: Int?
    let height: Int?
    let fileSizeInBytes: Int64?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let lensModel: String?
    let orientation: String?
    let description: String?
}

/// A generic photo/video asset used throughout the view layer
struct Asset: Identifiable, Sendable {
    let id: String
    let type: AssetType
    let originalFileName: String
    let createdAt: String?
    let duration: String?
    let thumbhash: String?
    let width: Int?
    let height: Int?
    let exif: AssetExif?
    /// Opaque bag for provider-specific fields (e.g. checksum, originalMimeType).
    /// Views should not inspect this directly.
    let providerData: [String: String]?
}
