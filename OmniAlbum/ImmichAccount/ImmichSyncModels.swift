//
//  ImmichSyncModels.swift
//  OmniAlbum
//
//  Payloads of Immich's /sync/stream (fields from the server's OpenAPI spec, v3.3).
//

import Foundation

struct SyncAsset: Decodable, Sendable {
    let id: String
    let ownerId: String?
    let type: String
    let originalFileName: String
    let checksum: String?
    let fileCreatedAt: String?
    let localDateTime: String?
    let width: Int?
    let height: Int?
    let duration: Int?
    let isFavorite: Bool
    let visibility: String
    let thumbhash: String?
    let livePhotoVideoId: String?
    let stackId: String?
    let deletedAt: String?
    let isEdited: Bool?
}

struct SyncExif: Decodable, Sendable {
    let assetId: String
    let city: String?
    let state: String?
    let country: String?
    let make: String?
    let model: String?
    let lensModel: String?
    let latitude: Double?
    let longitude: Double?
    let description: String?
    let fileSizeInByte: Int?
    let iso: Int?
    let fNumber: Double?
    let focalLength: Double?
    let exposureTime: String?
    let rating: Int?
    let orientation: String?
    let dateTimeOriginal: String?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
}

struct SyncAlbum: Decodable, Sendable {
    let id: String
    let name: String
    let description: String
    let thumbnailAssetId: String?
    let createdAt: String
    let updatedAt: String
    let order: String?
}

/// One line of the JSON-lines stream. `data` is decoded per `type` afterwards.
struct SyncLineHeader: Decodable {
    let type: String
    let ack: String
}

private struct DataEnvelope<T: Decodable>: Decodable { let data: T }
private struct AssetIdPayload: Decodable { let assetId: String }
private struct AlbumIdPayload: Decodable { let albumId: String }
private struct MembershipPayload: Decodable { let albumId: String; let assetId: String }

enum SyncLine {
    case change(LibraryChange)
    case reset
    case complete
    case ignored // a type we don't mirror (still acked, so the server doesn't resend it)

    /// Maps a stream entity type to a store change. Unknown types are ignored, never fatal:
    /// newer servers add entity types.
    static func decode(_ data: Data, header: SyncLineHeader, decoder: JSONDecoder) throws -> SyncLine {
        func payload<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(DataEnvelope<T>.self, from: data).data }

        switch header.type {
        case "SyncResetV1": return .reset
        case "SyncCompleteV1": return .complete
        case "AssetV2", "AlbumAssetCreateV2", "AlbumAssetUpdateV2", "AlbumAssetBackfillV2":
            return .change(.asset(try payload(SyncAsset.self)))
        case "AssetDeleteV1":
            return .change(.assetDeleted(id: try payload(AssetIdPayload.self).assetId))
        case "AssetExifV1", "AlbumAssetExifCreateV1", "AlbumAssetExifUpdateV1", "AlbumAssetExifBackfillV1":
            return .change(.exif(try payload(SyncExif.self)))
        case "AlbumV2":
            return .change(.album(try payload(SyncAlbum.self)))
        case "AlbumDeleteV1":
            return .change(.albumDeleted(id: try payload(AlbumIdPayload.self).albumId))
        case "AlbumToAssetV1", "AlbumToAssetBackfillV1":
            let m = try payload(MembershipPayload.self)
            return .change(.albumAsset(albumId: m.albumId, assetId: m.assetId))
        case "AlbumToAssetDeleteV1":
            let m = try payload(MembershipPayload.self)
            return .change(.albumAssetDeleted(albumId: m.albumId, assetId: m.assetId))
        default:
            return .ignored
        }
    }
}
