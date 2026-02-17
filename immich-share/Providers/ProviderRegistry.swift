//
//  ProviderRegistry.swift
//  immich-share
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
}
