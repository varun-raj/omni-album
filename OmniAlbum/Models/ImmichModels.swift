//
//  ImmichModels.swift
//  OmniAlbum
//
//  Data structures for Immich API responses.
//

import Foundation

// MARK: - Shared link (GET /api/shared-links/me?key=...)

struct SharedLinkResponse: Codable {
    let id: String
    let description: String?
    let password: String?
    let userId: String
    let key: String
    let type: String
    let createdAt: String
    let expiresAt: String?
    let assets: [SharedLinkAsset]?
    let album: SharedLinkAlbum?
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
    let slug: String?
}

struct SharedLinkAlbum: Codable {
    let albumName: String
    let description: String?
    let albumThumbnailAssetId: String?
    let createdAt: String
    let updatedAt: String
    let id: String
    let ownerId: String
    let owner: SharedLinkOwner?
    let albumUsers: [SharedLinkAlbumUser]
    let shared: Bool
    let hasSharedLink: Bool
    let startDate: String?
    let endDate: String?
    let assets: [SharedLinkAsset]?
    let assetCount: Int
    let isActivityEnabled: Bool
    let order: String?
}

struct SharedLinkOwner: Codable {
    let id: String
    let email: String?
    let name: String?
    let profileImagePath: String?
    let avatarColor: String?
    let profileChangedAt: String?
}

struct SharedLinkAlbumUser: Codable {
    let role: String?
    let user: SharedLinkOwner?
}

struct SharedLinkAsset: Codable {
    let id: String
    let type: String?
    let originalFileName: String?
    let localDateTime: String?
    let duration: String?
    let thumbhash: String?
    let fileCreatedAt: String?
    let fileModifiedAt: String?
    let createdAt: String?
    let updatedAt: String?
}

// MARK: - Album with assets (GET /api/albums/[id]?key=[shareKey])

struct AlbumWithAssetsResponse: Codable {
    let albumName: String
    let description: String?
    let albumThumbnailAssetId: String?
    let createdAt: String
    let updatedAt: String
    let id: String
    let ownerId: String
    let owner: AlbumOwner
    let albumUsers: [AlbumUser]
    let shared: Bool
    let hasSharedLink: Bool
    let startDate: String?
    let endDate: String?
    let assets: [ImmichAsset]
    let assetCount: Int
    let isActivityEnabled: Bool
    let order: String?
    let lastModifiedAssetTimestamp: String?
    let contributorCounts: [ContributorCount]?
}

struct AlbumOwner: Codable {
    let id: String
    let email: String?
    let name: String?
    let profileImagePath: String?
    let avatarColor: String?
    let profileChangedAt: String?
}

struct AlbumUser: Codable {
    let role: String?
    let user: AlbumOwner?
}

struct ContributorCount: Codable {
    let userId: String
    let assetCount: Int
}

struct ImmichAsset: Codable {
    let id: String
    let createdAt: String?
    let deviceAssetId: String?
    let ownerId: String?
    let deviceId: String?
    let libraryId: String?
    let type: String
    let originalPath: String?
    let originalFileName: String
    let originalMimeType: String?
    let thumbhash: String?
    let fileCreatedAt: String?
    let fileModifiedAt: String?
    let localDateTime: String?
    let updatedAt: String?
    let isFavorite: Bool?
    let isArchived: Bool?
    let isTrashed: Bool?
    let visibility: String?
    let duration: String?
    let exifInfo: ExifInfo?
    let livePhotoVideoId: String?
    let people: [Person]?
    let checksum: String?
    let isOffline: Bool?
    let hasMetadata: Bool?
    let duplicateId: String?
    let resized: Bool?
    let width: Int?
    let height: Int?
    let isEdited: Bool?
}

struct ExifInfo: Codable {
    let make: String?
    let model: String?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    let fileSizeInByte: Int64?
    let orientation: String?
    let dateTimeOriginal: String?
    let modifyDate: String?
    let timeZone: String?
    let lensModel: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Int?
    let exposureTime: String?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
    let description: String?
    let projectionType: String?
    let rating: Double?
}

struct Person: Codable {
    let id: String?
    let name: String?
    let birthDate: String?
    let thumbnailPath: String?
    let faces: [Face]?
}

struct Face: Codable {
    let id: String?
    let imageHeight: Int?
    let imageWidth: Int?
    let boundingBoxX1: Int?
    let boundingBoxX2: Int?
    let boundingBoxY1: Int?
    let boundingBoxY2: Int?
}
