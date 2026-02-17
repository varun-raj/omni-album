//
//  UploadModels.swift
//  OmniAlbum
//
//  Data models for upload queue management.
//

import Foundation

/// Status of an upload task
enum UploadStatus: String, Codable {
    case pending
    case uploading
    case completed
    case failed
}

/// Represents a single asset upload task
struct UploadTask: Codable, Identifiable, Equatable {
    let id: UUID
    let albumId: String
    let albumName: String
    let baseURL: String
    let shareKey: String
    let password: String?  // For password-protected albums
    let localAssetIdentifier: String  // PHAsset local identifier
    let fileName: String
    let fileSize: Int64?
    let provider: String  // PhotoProvider rawValue, defaults to "immich"
    let createdAt: Date
    var completedAt: Date?  // When the upload finished (success or failure)
    var status: UploadStatus
    var progress: Double  // 0.0 to 1.0
    var errorMessage: String?
    var uploadedAssetId: String?  // Asset ID after successful upload

    init(
        id: UUID = UUID(),
        albumId: String,
        albumName: String,
        baseURL: String,
        shareKey: String,
        password: String? = nil,
        localAssetIdentifier: String,
        fileName: String,
        fileSize: Int64? = nil,
        provider: String = "immich",
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        status: UploadStatus = .pending,
        progress: Double = 0.0,
        errorMessage: String? = nil,
        uploadedAssetId: String? = nil
    ) {
        self.id = id
        self.albumId = albumId
        self.albumName = albumName
        self.baseURL = baseURL
        self.shareKey = shareKey
        self.password = password
        self.localAssetIdentifier = localAssetIdentifier
        self.fileName = fileName
        self.fileSize = fileSize
        self.provider = provider
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.progress = progress
        self.errorMessage = errorMessage
        self.uploadedAssetId = uploadedAssetId
    }

    // Custom decoding for backward compat (older tasks lack provider field)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        albumId = try container.decode(String.self, forKey: .albumId)
        albumName = try container.decode(String.self, forKey: .albumName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        shareKey = try container.decode(String.self, forKey: .shareKey)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        localAssetIdentifier = try container.decode(String.self, forKey: .localAssetIdentifier)
        fileName = try container.decode(String.self, forKey: .fileName)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "immich"
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        status = try container.decode(UploadStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        uploadedAssetId = try container.decodeIfPresent(String.self, forKey: .uploadedAssetId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, albumId, albumName, baseURL, shareKey, password
        case localAssetIdentifier, fileName, fileSize, provider, createdAt
        case completedAt, status, progress, errorMessage, uploadedAssetId
    }

    static func == (lhs: UploadTask, rhs: UploadTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Response from Immich upload API
struct UploadResponse: Codable {
    let id: String
    let status: String?
    let duplicate: Bool?
    let deviceAssetId: String?
    let deviceId: String?
    let createdAt: String?
    let modifiedAt: String?
    let ownerId: String?
    let type: String?
    let originalFileName: String?

    // Allow unknown keys
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate)
        deviceAssetId = try container.decodeIfPresent(String.self, forKey: .deviceAssetId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
        ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, duplicate, deviceAssetId, deviceId
        case createdAt, modifiedAt, ownerId, type, originalFileName
    }
}
