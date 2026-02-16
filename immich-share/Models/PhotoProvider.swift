//
//  PhotoProvider.swift
//  immich-share
//
//  Enum identifying which photo service provider an album belongs to.
//

import Foundation
import SwiftUI

enum PhotoProvider: String, Codable, CaseIterable, Sendable {
    case immich
    case nextcloud
    case lychee
    case ente

    var displayName: String {
        switch self {
        case .immich: return "Immich"
        case .nextcloud: return "Nextcloud"
        case .lychee: return "Lychee"
        case .ente: return "Ente"
        }
    }

    var iconName: String {
        switch self {
        case .immich: return "photo.on.rectangle.angled"
        case .nextcloud: return "cloud"
        case .lychee: return "leaf"
        case .ente: return "lock.shield"
        }
    }

    var accentColor: Color {
        switch self {
        case .immich: return .blue
        case .nextcloud: return .cyan
        case .lychee: return .green
        case .ente: return .purple
        }
    }

    var tagline: String {
        switch self {
        case .immich: return "Self-hosted photo & video backup"
        case .nextcloud: return "Self-hosted productivity platform"
        case .lychee: return "Self-hosted photo management"
        case .ente: return "End-to-end encrypted photo storage"
        }
    }

    /// Placeholder label for the URL text field
    var linkPlaceholderLabel: String {
        switch self {
        case .immich: return "Immich share link"
        case .nextcloud: return "Nextcloud share link"
        case .lychee: return "Lychee gallery link"
        case .ente: return "Ente album link"
        }
    }

    /// Placeholder text shown inside the URL text field
    var linkPlaceholder: String {
        switch self {
        case .immich: return "https://…/share/…"
        case .nextcloud: return "https://…/apps/photos/public/…"
        case .lychee: return "https://…/gallery/…"
        case .ente: return "https://albums.ente.io/…"
        }
    }

    /// Footer help text below the URL field
    var linkFooter: String {
        switch self {
        case .immich: return "Paste the full link you get when sharing an album from Immich."
        case .nextcloud: return "Paste the public album link from Nextcloud Photos."
        case .lychee: return "Paste the gallery link for your public Lychee album."
        case .ente: return "Paste the shared album link from Ente Photos."
        }
    }

    /// Whether this provider's integration is fully implemented
    var isSupported: Bool {
        switch self {
        case .immich, .nextcloud: return true
        case .lychee, .ente: return false
        }
    }
}
