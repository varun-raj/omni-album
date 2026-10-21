//
//  ShareLinkBuilder.swift
//  OmniAlbum
//
//  Rebuilds the share URL a user would paste from what we store (base URL, share key, provider).
//

import Foundation

enum ShareLinkBuilder {
    static func link(provider: PhotoProvider, baseURL: String, shareKey: String) -> String {
        switch provider {
        case .immich:
            return "\(baseURL)/share/\(shareKey)"
        case .nextcloud:
            return "\(baseURL)/apps/photos/public/\(shareKey)"
        case .photoprism:
            // shareKey is composite: "linkToken|previewToken|downloadToken|albumUID"
            return "\(baseURL)/s/\(shareKey.components(separatedBy: "|").first ?? shareKey)"
        case .lychee:
            return "\(baseURL)/gallery/\(shareKey)"
        case .ente:
            // shareKey is composite: "accessToken|base58Key"
            let parts = shareKey.components(separatedBy: "|")
            if parts.count >= 2 { return "https://albums.ente.io?t=\(parts[0])#\(parts[1])" }
            return "\(baseURL)/\(shareKey)"
        }
    }
}
