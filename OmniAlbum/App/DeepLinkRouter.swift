//
//  DeepLinkRouter.swift
//  OmniAlbum
//
//  Handles deep link URLs from widgets and Spotlight.
//

import Foundation
import Combine

/// Pending deep link target for navigation
struct DeepLinkTarget {
    let albumId: String
    let assetId: String?
}

/// Shared router that holds pending deep link state, observed by navigation views
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingTarget: DeepLinkTarget?
    @Published var selectedTab: Int = 0

    /// Parse an incoming URL and set the pending target
    /// Format: omnialbum://photo?albumId=X&assetId=Y
    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        guard let albumId = params["albumId"] else { return }

        // Switch to Albums tab and set pending target
        selectedTab = 0
        pendingTarget = DeepLinkTarget(albumId: albumId, assetId: params["assetId"])
    }

    /// Consume the pending target (called after navigation completes)
    func consumeTarget() -> DeepLinkTarget? {
        let target = pendingTarget
        pendingTarget = nil
        return target
    }
}
