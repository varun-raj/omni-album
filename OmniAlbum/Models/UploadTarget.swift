//
//  UploadTarget.swift
//  OmniAlbum
//
//  Everywhere photos can be uploaded to, as one list for the Upload tab: each signed-in Immich account's
//  library and albums, then shared-link albums that allow uploads.
//

import Foundation

struct UploadTarget: Identifiable {
    enum Kind { case immichLibrary, immichAlbum, shareLink }

    let id: String
    let kind: Kind
    let provider: PhotoProvider
    let title: String
    let subtitle: String
    let destination: UploadDestination

    /// Grouping label in the picker.
    let group: String

    static func build(accounts: [ImmichAccountInfo], albums: [AccountAlbum], shareLinkAlbums: [DisplayAlbum]) -> [UploadTarget] {
        var targets: [UploadTarget] = []

        for account in accounts {
            let group = "\(account.email) · \(account.host)"
            targets.append(UploadTarget(
                id: "immich|\(account.id)", kind: .immichLibrary, provider: .immich, title: "Library", subtitle: "Just add to \(account.host)",
                destination: .immich(account: account), group: group))

            let mine = albums.filter { $0.account.id == account.id }
                .sorted { $0.album.name.localizedCaseInsensitiveCompare($1.album.name) == .orderedAscending }
            for album in mine {
                targets.append(UploadTarget(
                    id: "immich|\(account.id)|\(album.album.id)", kind: .immichAlbum, provider: .immich, title: album.album.name,
                    subtitle: "Album · \(album.album.assetCount) item\(album.album.assetCount == 1 ? "" : "s")",
                    destination: .immich(account: account, albumId: album.album.id, albumName: album.album.name), group: group))
            }
        }

        for link in shareLinkAlbums where link.allowUpload {
            targets.append(UploadTarget(
                id: "link|\(link.id)", kind: .shareLink, provider: link.provider, title: link.albumName,
                subtitle: URL(string: link.baseURL)?.host ?? link.baseURL, destination: .shareLink(link), group: "Shared links"))
        }
        return targets
    }
}
