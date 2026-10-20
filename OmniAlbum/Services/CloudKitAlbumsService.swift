//
//  CloudKitAlbumsService.swift
//  OmniAlbum
//
//  Persists added albums in CloudKit for sync across devices and after restart.
//  You must create the "Album" record type in the CloudKit Dashboard first — see CLOUDKIT_SETUP.md.
//

import Foundation
import CloudKit

private let recordType = "Album"
private let containerIdentifier = "iCloud.com.skcript.omnialbum"

enum CloudKitAlbumsError: LocalizedError {
    case containerUnavailable
    case saveFailed(Error)
    case fetchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: return "iCloud is not available."
        case .saveFailed(let e): return "Failed to save: \(e.localizedDescription)"
        case .fetchFailed(let e): return "Failed to load albums: \(e.localizedDescription)"
        }
    }
}

final class CloudKitAlbumsService {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    init(containerIdentifier: String = containerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    func save(_ album: DisplayAlbum) async throws {
        try await saveWithRetry(album, retryCount: 0)
    }

    private func saveWithRetry(_ album: DisplayAlbum, retryCount: Int) async throws {
        let id = recordID(for: album.id)

        // Try to fetch existing record first, or create new one
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            // Record doesn't exist, create new one
            record = CKRecord(recordType: recordType, recordID: id)
            record["createdAt"] = Date()
        } catch {
            throw CloudKitAlbumsError.saveFailed(error)
        }

        // Update all fields
        record["id"] = album.id
        record["albumName"] = album.albumName
        record["albumThumbnailAssetId"] = album.albumThumbnailAssetId
        record["baseURL"] = album.baseURL
        record["shareKey"] = album.shareKey
        record["albumId"] = album.albumId
        record["assetCount"] = album.assetCount
        record["allowUpload"] = album.allowUpload ? 1 : 0
        record["allowDownload"] = album.allowDownload ? 1 : 0
        record["showMetadata"] = album.showMetadata ? 1 : 0
        record["password"] = nil  // lives in the Keychain (PasswordStore); clears legacy plaintext
        record["provider"] = album.provider.rawValue

        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged && retryCount < 3 {
            // Conflict - retry with fresh record
            try await saveWithRetry(album, retryCount: retryCount + 1)
        } catch {
            throw CloudKitAlbumsError.saveFailed(error)
        }
    }

    func fetchAll() async throws -> [DisplayAlbum] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        do {
            let (results, _) = try await database.records(matching: query)
            return results.compactMap { _, result in
                switch result {
                case .success(let record): return displayAlbum(from: record)
                case .failure: return nil
                }
            }
        } catch {
            throw CloudKitAlbumsError.fetchFailed(error)
        }
    }

    func delete(albumId: String) async throws {
        let id = recordID(for: albumId)
        do {
            _ = try await database.deleteRecord(withID: id)
        } catch {
            throw CloudKitAlbumsError.saveFailed(error)
        }
    }

    private func recordID(for albumId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "album-\(albumId)", zoneID: CKRecordZone.default().zoneID)
    }

    private func displayAlbum(from record: CKRecord) -> DisplayAlbum? {
        guard let id = record["id"] as? String,
              let albumName = record["albumName"] as? String,
              let baseURL = record["baseURL"] as? String,
              let shareKey = record["shareKey"] as? String,
              let albumId = record["albumId"] as? String else { return nil }
        return DisplayAlbum(
            id: id,
            albumName: albumName,
            albumThumbnailAssetId: record["albumThumbnailAssetId"] as? String,
            baseURL: baseURL,
            shareKey: shareKey,
            albumId: albumId,
            assetCount: record["assetCount"] as? Int,
            allowUpload: (record["allowUpload"] as? Int ?? 0) == 1,
            allowDownload: (record["allowDownload"] as? Int ?? 1) == 1,  // Default true
            showMetadata: (record["showMetadata"] as? Int ?? 1) == 1,    // Default true
            password: record["password"] as? String,
            provider: PhotoProvider(rawValue: record["provider"] as? String ?? "immich") ?? .immich
        )
    }
}
