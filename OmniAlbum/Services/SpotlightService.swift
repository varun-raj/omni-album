//
//  SpotlightService.swift
//  OmniAlbum
//
//  Indexes albums in Core Spotlight for system-wide search.
//

import Foundation
import CoreSpotlight

final class SpotlightService {
    static let shared = SpotlightService()
    private let searchableIndex = CSSearchableIndex.default()

    private init() {}

    /// Index a single album in Spotlight
    func indexAlbum(_ album: DisplayAlbum) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributeSet.title = album.albumName
        attributeSet.contentDescription = descriptionForAlbum(album)
        attributeSet.identifier = album.albumId

        let item = CSSearchableItem(
            uniqueIdentifier: album.albumId,
            domainIdentifier: "com.skcript.omnialbum.albums",
            attributeSet: attributeSet
        )
        item.expirationDate = .distantFuture

        searchableIndex.indexSearchableItems([item]) { error in
            if let error {
                print("Spotlight: Failed to index album \(album.albumName): \(error.localizedDescription)")
            }
        }
    }

    /// Index multiple albums at once
    func indexAlbums(_ albums: [DisplayAlbum]) {
        let items = albums.map { album -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
            attributeSet.title = album.albumName
            attributeSet.contentDescription = descriptionForAlbum(album)
            attributeSet.identifier = album.albumId

            let item = CSSearchableItem(
                uniqueIdentifier: album.albumId,
                domainIdentifier: "com.skcript.omnialbum.albums",
                attributeSet: attributeSet
            )
            item.expirationDate = .distantFuture
            return item
        }

        searchableIndex.indexSearchableItems(items) { error in
            if let error {
                print("Spotlight: Failed to index albums: \(error.localizedDescription)")
            }
        }
    }

    /// Remove an album from Spotlight index
    func deindexAlbum(albumId: String) {
        searchableIndex.deleteSearchableItems(withIdentifiers: [albumId]) { error in
            if let error {
                print("Spotlight: Failed to deindex album \(albumId): \(error.localizedDescription)")
            }
        }
    }

    /// Remove all indexed albums
    func deindexAll() {
        searchableIndex.deleteSearchableItems(withDomainIdentifiers: ["com.skcript.omnialbum.albums"]) { error in
            if let error {
                print("Spotlight: Failed to deindex all: \(error.localizedDescription)")
            }
        }
    }

    private func descriptionForAlbum(_ album: DisplayAlbum) -> String {
        var parts: [String] = []
        if let count = album.assetCount {
            parts.append(count == 1 ? "1 photo" : "\(count) photos")
        }
        if let host = URL(string: album.baseURL)?.host {
            parts.append(host)
        }
        return parts.joined(separator: " - ")
    }
}
