//
//  ImmichUploadService.swift
//  OmniAlbum
//
//  Handles uploading assets to Immich API via multipart/form-data.
//

import Foundation
import Photos
import UIKit

enum ImmichUploadError: LocalizedError {
    case assetNotFound
    case dataLoadFailed
    case uploadFailed(String)
    case invalidResponse
    case noPermission

    var errorDescription: String? {
        switch self {
        case .assetNotFound:
            return "Photo not found in library."
        case .dataLoadFailed:
            return "Failed to load photo data."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .invalidResponse:
            return "Invalid response from server."
        case .noPermission:
            return "No permission to access photos."
        }
    }
}

final class ImmichUploadService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600  // 10 minutes for large files
        self.session = URLSession(configuration: config)
    }

    /// Upload a single asset to Immich and add it to the album
    /// - Parameters:
    ///   - task: The upload task containing asset info and credentials
    ///   - progressHandler: Called with progress (0.0 to 1.0)
    /// - Returns: The uploaded asset ID
    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        print("Upload: Starting upload for \(task.fileName) to album \(task.albumId)")
        // Fetch the PHAsset
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [task.localAssetIdentifier],
            options: nil
        )

        guard let asset = fetchResult.firstObject else {
            throw ImmichUploadError.assetNotFound
        }

        // Stream the asset to disk instead of loading it into memory
        let exported = try await AssetFileExporter.export(asset)
        defer { try? FileManager.default.removeItem(at: exported.url) }

        // Build multipart request
        let boundary = UUID().uuidString
        let url = buildUploadURL(baseURL: task.baseURL, shareKey: task.shareKey, password: task.password)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body on disk
        let bodyFile = try buildMultipartFile(
            boundary: boundary,
            assetFile: exported.url,
            fileName: task.fileName,
            mimeType: exported.mimeType,
            asset: asset,
            deviceAssetId: task.localAssetIdentifier
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        // Upload with progress tracking
        let (data, response) = try await uploadWithProgress(
            request: request,
            bodyFile: bodyFile,
            progressHandler: progressHandler
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImmichUploadError.invalidResponse
        }

        // Log the raw response for debugging
        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        print("Upload API Response [\(httpResponse.statusCode)]: \(responseString)")

        if httpResponse.statusCode == 201 || httpResponse.statusCode == 200 {
            // Parse response to get asset ID
            var assetId: String?

            let decoder = JSONDecoder()
            do {
                let uploadResponse = try decoder.decode(UploadResponse.self, from: data)
                print("Upload successful - Asset ID: \(uploadResponse.id), Status: \(uploadResponse.status ?? "nil"), Duplicate: \(uploadResponse.duplicate ?? false)")
                assetId = uploadResponse.id
            } catch {
                print("Failed to decode upload response: \(error)")
                // Try to extract ID from raw response if possible
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] as? String {
                    print("Extracted asset ID from raw JSON: \(id)")
                    assetId = id
                }
            }

            guard let finalAssetId = assetId else {
                throw ImmichUploadError.invalidResponse
            }

            // Add the asset to the album
            print("Adding asset \(finalAssetId) to album \(task.albumId)...")
            try await addAssetToAlbum(
                assetId: finalAssetId,
                albumId: task.albumId,
                baseURL: task.baseURL,
                shareKey: task.shareKey,
                password: task.password
            )

            return finalAssetId
        } else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Upload failed with status \(httpResponse.statusCode): \(errorMessage)")
            throw ImmichUploadError.uploadFailed("Status \(httpResponse.statusCode): \(errorMessage)")
        }
    }

    /// Add an asset to an album
    private func addAssetToAlbum(
        assetId: String,
        albumId: String,
        baseURL: String,
        shareKey: String,
        password: String?
    ) async throws {
        var components = URLComponents(string: baseURL)!
        components.path += "/api/albums/\(albumId)/assets"
        var queryItems = [URLQueryItem(name: "key", value: shareKey)]
        if let password = password, !password.isEmpty {
            queryItems.append(URLQueryItem(name: "password", value: password))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["ids": [assetId]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImmichUploadError.invalidResponse
        }

        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
        print("Add to album response [\(httpResponse.statusCode)]: \(responseString)")

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            print("Warning: Failed to add asset to album (status \(httpResponse.statusCode)), but upload succeeded")
            // Don't throw - the upload itself succeeded
        }
    }

    private func buildUploadURL(baseURL: String, shareKey: String, password: String?) -> URL {
        var components = URLComponents(string: baseURL)!
        components.path += "/api/assets"
        var queryItems = [URLQueryItem(name: "key", value: shareKey)]
        if let password = password, !password.isEmpty {
            queryItems.append(URLQueryItem(name: "password", value: password))
        }
        components.queryItems = queryItems
        return components.url!
    }

    /// Writes the multipart body to a temp file, copying the asset in 1 MB chunks.
    private func buildMultipartFile(
        boundary: String,
        assetFile: URL,
        fileName: String,
        mimeType: String,
        asset: PHAsset,
        deviceAssetId: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }
        let crlf = "\r\n"

        func appendString(_ string: String) {
            try? out.write(contentsOf: Data(string.utf8))
        }

        // deviceAssetId
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"deviceAssetId\"\(crlf)\(crlf)")
        appendString("\(deviceAssetId)\(crlf)")

        // deviceId
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"deviceId\"\(crlf)\(crlf)")
        appendString("\(UIDevice.current.identifierForVendor?.uuidString ?? "ios-device")\(crlf)")

        // fileCreatedAt
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let createdAt = asset.creationDate ?? Date()
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"fileCreatedAt\"\(crlf)\(crlf)")
        appendString("\(isoFormatter.string(from: createdAt))\(crlf)")

        // fileModifiedAt
        let modifiedAt = asset.modificationDate ?? createdAt
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"fileModifiedAt\"\(crlf)\(crlf)")
        appendString("\(isoFormatter.string(from: modifiedAt))\(crlf)")

        // isFavorite
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"isFavorite\"\(crlf)\(crlf)")
        appendString("\(asset.isFavorite)\(crlf)")

        // duration (for videos)
        if asset.mediaType == .video {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"duration\"\(crlf)\(crlf)")
            appendString("\(asset.duration)\(crlf)")
        }

        // assetData (the actual file)
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(fileName)\"\(crlf)")
        appendString("Content-Type: \(mimeType)\(crlf)\(crlf)")
        let input = try FileHandle(forReadingFrom: assetFile)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        appendString("\(crlf)")

        // End boundary
        appendString("--\(boundary)--\(crlf)")

        return bodyURL
    }

    private func uploadWithProgress(
        request: URLRequest,
        bodyFile: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        let delegate = UploadProgressDelegate(progressHandler: progressHandler)
        let delegateSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        defer { delegateSession.finishTasksAndInvalidate() }

        let (data, response) = try await delegateSession.upload(for: request, fromFile: bodyFile)
        progressHandler(1.0)
        return (data, response)
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler(min(progress, 0.99)) // Cap at 99% until response received
    }
}
