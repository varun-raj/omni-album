//
//  UploadDestination.swift
//  OmniAlbum
//
//  Where picked photos go: a shared-link album, or an Immich account (its library, or one of its albums).
//

import Foundation

struct UploadDestination {
    /// Groups tasks in the queue UI.
    let albumId: String
    let title: String
    let allowUpload: Bool
    let makeTask: (SelectedAsset) -> UploadTask

    static func shareLink(_ album: DisplayAlbum) -> UploadDestination {
        UploadDestination(albumId: album.albumId, title: album.albumName, allowUpload: album.allowUpload) { asset in
            UploadTask(albumId: album.albumId, albumName: album.albumName, baseURL: album.baseURL, shareKey: album.shareKey,
                       password: album.password, localAssetIdentifier: asset.localIdentifier, fileName: asset.fileName,
                       fileSize: asset.fileSize, provider: album.provider.rawValue)
        }
    }

    /// An Immich account's library, or (with `albumId`) one of its albums. Photos the server already has aren't re-sent.
    static func immich(account: ImmichAccountInfo, albumId: String? = nil, albumName: String? = nil) -> UploadDestination {
        let group = albumId ?? "library|\(account.id)"
        let title = albumName ?? "Immich library"
        return UploadDestination(albumId: group, title: title, allowUpload: true) { asset in
            UploadTask(albumId: group, albumName: title, baseURL: account.server, shareKey: "", password: nil,
                       localAssetIdentifier: asset.localIdentifier, fileName: asset.fileName, fileSize: asset.fileSize,
                       provider: PhotoProvider.immich.rawValue, accountID: account.id, targetAlbumId: albumId)
        }
    }
}
