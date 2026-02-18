//
//  ProviderRegistry.swift
//  OmniAlbum
//
//  Singleton registry that maps URLs and PhotoProvider types to their ShareLinkProvider.
//

import Foundation

final class ProviderRegistry: Sendable {
    static let shared = ProviderRegistry()

    private let providers: [PhotoProvider: any ShareLinkProvider]

    private init() {
        providers = [
            .immich: ImmichProvider(),
            .nextcloud: NextcloudProvider(),
            .photoprism: PhotoPrismProvider(),
            .ente: EnteProvider(),
            .lychee: LycheeProvider()
        ]
    }

    /// Resolve a provider by asking each one if it can handle the URL
    func provider(for urlString: String) -> (any ShareLinkProvider)? {
        providers.values.first { $0.canHandle(urlString: urlString) }
    }

    /// Direct lookup by provider type
    func provider(for type: PhotoProvider) -> (any ShareLinkProvider)? {
        providers[type]
    }

    /// Detect which provider can handle a URL, checking in deterministic order
    /// (most-specific first: Ente → Nextcloud → Lychee → Immich → PhotoPrism)
    func detectProvider(from urlString: String) -> PhotoProvider? {
        let order: [PhotoProvider] = [.ente, .nextcloud, .lychee, .immich, .photoprism]
        for type in order {
            if let p = providers[type], p.canHandle(urlString: urlString) {
                return type
            }
        }
        return nil
    }
}
