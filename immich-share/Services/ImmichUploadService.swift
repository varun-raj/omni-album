//
//  ImmichUploadService.swift
//  immich-share
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

        // Get asset data and metadata
        let (imageData, mimeType) = try await loadAssetData(asset: asset)

        // Build multipart request
        let boundary = UUID().uuidString
        let url = buildUploadURL(baseURL: task.baseURL, shareKey: task.shareKey, password: task.password)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body
        let body = buildMultipartBody(
            boundary: boundary,
            imageData: imageData,
            fileName: task.fileName,
            mimeType: mimeType,
            asset: asset,
            deviceAssetId: task.localAssetIdentifier
        )

        // Upload with progress tracking
        let (data, response) = try await uploadWithProgress(
            request: request,
            body: body,
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
        components.path = "/api/albums/\(albumId)/assets"
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
        components.path = "/api/assets"
        var queryItems = [URLQueryItem(name: "key", value: shareKey)]
        if let password = password, !password.isEmpty {
            queryItems.append(URLQueryItem(name: "password", value: password))
        }
        components.queryItems = queryItems
        return components.url!
    }

    private func loadAssetData(asset: PHAsset) async throws -> (Data, String) {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            if asset.mediaType == .video {
                // For videos, get the video data
                let videoOptions = PHVideoRequestOptions()
                videoOptions.isNetworkAccessAllowed = true
                videoOptions.deliveryMode = .highQualityFormat

                PHImageManager.default().requestAVAsset(forVideo: asset, options: videoOptions) { avAsset, _, _ in
                    guard let urlAsset = avAsset as? AVURLAsset else {
                        continuation.resume(throwing: ImmichUploadError.dataLoadFailed)
                        return
                    }

                    do {
                        let data = try Data(contentsOf: urlAsset.url)
                        let mimeType = self.mimeType(for: urlAsset.url.pathExtension)
                        continuation.resume(returning: (data, mimeType))
                    } catch {
                        continuation.resume(throwing: ImmichUploadError.dataLoadFailed)
                    }
                }
            } else {
                // For images, get the image data
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                    guard let imageData = data else {
                        continuation.resume(throwing: ImmichUploadError.dataLoadFailed)
                        return
                    }

                    let mimeType = self.mimeType(fromUTI: uti)
                    continuation.resume(returning: (imageData, mimeType))
                }
            }
        }
    }

    private func mimeType(fromUTI uti: String?) -> String {
        switch uti {
        case "public.jpeg", "public.jpg":
            return "image/jpeg"
        case "public.png":
            return "image/png"
        case "public.heic", "public.heif":
            return "image/heic"
        case "com.compuserve.gif":
            return "image/gif"
        case "public.tiff":
            return "image/tiff"
        case "com.adobe.raw-image":
            return "image/x-adobe-dng"
        default:
            return "image/jpeg"
        }
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "avi":
            return "video/x-msvideo"
        case "mkv":
            return "video/x-matroska"
        case "webm":
            return "video/webm"
        default:
            return "video/mp4"
        }
    }

    private func buildMultipartBody(
        boundary: String,
        imageData: Data,
        fileName: String,
        mimeType: String,
        asset: PHAsset,
        deviceAssetId: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        // Helper to append string as data
        func appendString(_ string: String) {
            body.append(string.data(using: .utf8)!)
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
        body.append(imageData)
        appendString("\(crlf)")

        // End boundary
        appendString("--\(boundary)--\(crlf)")

        return body
    }

    private func uploadWithProgress(
        request: URLRequest,
        body: Data,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        let delegate = UploadProgressDelegate(progressHandler: progressHandler)
        let delegateSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        defer { delegateSession.finishTasksAndInvalidate() }

        // Write body to temp file for upload task (required for delegate progress)
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try body.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let (data, response) = try await delegateSession.upload(for: request, fromFile: tempFile)
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
