//
//  UploadModels.swift
//  immich-share
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
    let createdAt: Date
    var completedAt: Date?  // When the upload finished (success or failure)
    var status: UploadStatus
    var progress: Double  // 0.0 to 1.0
    var errorMessage: String?
    var uploadedAssetId: String?  // Immich asset ID after successful upload

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
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.progress = progress
        self.errorMessage = errorMessage
        self.uploadedAssetId = uploadedAssetId
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
