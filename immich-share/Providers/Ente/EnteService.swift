//
//  EnteService.swift
//  immich-share
//
//  REST API client for Ente's public collection endpoints.
//  All data returned is encrypted and must be decrypted client-side.
//

import Foundation

// MARK: - Error Types

enum EnteServiceError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(Int)
    case passwordRequired
    case decryptionFailed
    case linkExpired
    case noFilesFound

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid Ente API URL."
        case .invalidResponse: return "Invalid response from Ente server."
        case .httpError(let code): return "Ente server returned error \(code)."
        case .passwordRequired: return "This shared album requires a password."
        case .decryptionFailed: return "Failed to decrypt album data."
        case .linkExpired: return "This share link has expired."
        case .noFilesFound: return "No files found in this shared album."
        }
    }
}

// MARK: - Response Models

struct EnteCollectionResponse: Codable, Sendable {
    let collection: EnteCollection
}

struct EnteCollection: Codable, Sendable {
    let id: Int64
    let encryptedKey: String
    let keyDecryptionNonce: String
    let encryptedName: String?
    let nameDecryptionNonce: String?
    let publicURLs: [EntePublicURL]?
}

struct EntePublicURL: Codable, Sendable {
    let url: String?
    let deviceLimit: Int?
    let validTill: Int64?
    let enableDownload: Bool?
    let enableCollect: Bool?
    let passwordEnabled: Bool?
    let nonce: String?
    let opsLimit: Int?
    let memLimit: Int?
}

struct EnteDiffResponse: Codable, Sendable {
    let diff: [EnteFile]
    let hasMore: Bool
}

struct EnteFile: Codable, Sendable {
    let id: Int64
    let collectionID: Int64?
    let encryptedKey: String
    let keyDecryptionNonce: String
    let file: EnteFileData
    let thumbnail: EnteFileData
    let metadata: EnteFileMetadata
    let info: EnteFileInfo?
    let updationTime: Int64?
    let isDeleted: Bool?
    let pubMagicMetadata: EntePubMagicMetadata?
}

struct EnteFileData: Codable, Sendable {
    let decryptionHeader: String
    let objectKey: String?
    let size: Int64?
}

struct EnteFileMetadata: Codable, Sendable {
    let encryptedData: String
    let decryptionHeader: String
}

struct EnteFileInfo: Codable, Sendable {
    let fileSize: Int64?
    let thumbSize: Int64?
}

struct EntePubMagicMetadata: Codable, Sendable {
    let data: String?
    let header: String?
}

struct EnteDecryptedMetadata: Codable, Sendable {
    let title: String?
    let creationTime: Int64?
    let modificationTime: Int64?
    let latitude: Double?
    let longitude: Double?
    let fileType: Int?
    let w: Int?
    let h: Int?

    // ente uses numeric keys in some cases
    enum CodingKeys: String, CodingKey {
        case title, creationTime, modificationTime, latitude, longitude, fileType
        case w, h
    }
}

// MARK: - Service

struct EnteService: Sendable {

    private static let apiBase = "https://api.ente.io"

    /// Fetch collection info for a public shared link
    static func fetchCollectionInfo(accessToken: String) async throws -> EnteCollection {
        guard let url = URL(string: "\(apiBase)/public-collection/info?accessToken=\(accessToken)") else {
            throw EnteServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnteServiceError.invalidResponse
        }

        if httpResponse.statusCode == 410 {
            throw EnteServiceError.linkExpired
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EnteServiceError.httpError(httpResponse.statusCode)
        }

        let collectionResponse = try JSONDecoder().decode(EnteCollectionResponse.self, from: data)
        return collectionResponse.collection
    }

    /// Fetch files from a public collection, paginating via sinceTime
    static func fetchFiles(accessToken: String) async throws -> [EnteFile] {
        var allFiles: [EnteFile] = []
        var sinceTime: Int64 = 0
        var hasMore = true

        while hasMore {
            guard let url = URL(string: "\(apiBase)/public-collection/diff?accessToken=\(accessToken)&sinceTime=\(sinceTime)") else {
                throw EnteServiceError.invalidBaseURL
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EnteServiceError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw EnteServiceError.httpError(httpResponse.statusCode)
            }

            let diffResponse = try JSONDecoder().decode(EnteDiffResponse.self, from: data)
            allFiles.append(contentsOf: diffResponse.diff)
            hasMore = diffResponse.hasMore

            if let lastFile = diffResponse.diff.last, let updation = lastFile.updationTime {
                sinceTime = updation
            } else {
                hasMore = false
            }
        }

        return allFiles
    }

    /// Download an encrypted thumbnail
    static func downloadThumbnail(fileId: Int64, accessToken: String) async throws -> Data {
        guard let url = URL(string: "\(apiBase)/public-collection/files/preview/\(fileId)?accessToken=\(accessToken)") else {
            throw EnteServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnteServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EnteServiceError.httpError(httpResponse.statusCode)
        }

        return data
    }

    /// Download an encrypted full-resolution file
    static func downloadFile(fileId: Int64, accessToken: String) async throws -> Data {
        guard let url = URL(string: "\(apiBase)/public-collection/files/download/\(fileId)?accessToken=\(accessToken)") else {
            throw EnteServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnteServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EnteServiceError.httpError(httpResponse.statusCode)
        }

        return data
    }
}
