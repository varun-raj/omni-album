//
//  AlbumDetail.swift
//  immich-share
//
//  Generic album detail model used by all views. Provider-specific responses
//  (e.g. AlbumWithAssetsResponse) are mapped to this type by their respective providers.
//

import Foundation

/// A user who has access to a shared album
struct AlbumSharedUser: Sendable {
    let id: String
    let name: String?
    let email: String?
    let role: String?
    let avatarColor: String?
}

/// Generic album detail containing assets and metadata
struct AlbumDetail: Sendable {
    let albumName: String
    let description: String?
    let thumbnailAssetId: String?
    let createdAt: String
    let updatedAt: String
    let ownerName: String?
    let ownerEmail: String?
    let ownerAvatarColor: String?
    let assetCount: Int
    let assets: [Asset]
    let sharedUsers: [AlbumSharedUser]
}
