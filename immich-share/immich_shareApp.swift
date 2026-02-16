//
//  immich_shareApp.swift
//  immich-share
//
//  Created by Varun on 04/02/26.
//

import SwiftUI

@main
struct immich_shareApp: App {
    init() {
        // Register default settings
        UserDefaults.standard.register(defaults: [
            SettingsKeys.iCloudSyncEnabled: true
        ])

        // Configure Kingfisher image cache
        ImageCacheConfig.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
